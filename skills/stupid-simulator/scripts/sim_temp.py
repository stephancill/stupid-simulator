#!/usr/bin/env python3
"""
Temporary simulators that boot fast, cloned from a warmed template, with claims built in.

A simulator made with `simctl create` spends its first boot on one-time setup: data migration,
caches, indexing and asset downloads in a few hundred daemons. On a busy Mac that first boot takes
minutes. `simctl clone` of a simulator that has already booted once is an APFS copy that skips it.
This script keeps one shut-down template per device type and runtime and clones it.

Each simulator iOS 27 boots runs over two hundred processes, so the script also warns when several
are already booted, and records claims in ~/.cache/sim-claims/<UDID> under the pid of the agent
process (the nearest `claude`, `opencode` or `node` ancestor), not a shell that exits straight away.

Commands:
  create   Clone the template for --like UDID (or --device-type and --runtime) as tmp-<name>,
           boot it and claim it. Makes the template first if there is none (one slow boot).
           Prints the new UDID as the last line.
  release  Shut down and delete a tmp- simulator and remove its claim.
  template Make or refresh the template: --from UDID clones a shut-down simulator that has
           already booted once instead of booting a new one.
  status   Booted simulators, who claims them and whether that process is alive.

Examples:
  T=$(sim_temp.py create --name checkout-flow --like <UDID> | tail -1)
  sim_temp.py release $T
  sim_temp.py status
"""

import argparse
import fcntl
import json
import os
import subprocess
import sys
import time
from pathlib import Path

CLAIMS = Path.home() / ".cache/sim-claims"
STATE = Path.home() / ".stupid-simulator/templates"
TEMPLATE_PREFIX = "stupidsim-template"
TEMP_PREFIX = "tmp-"
MAX_BOOTED = int(os.environ.get("IOS_SIM_MAX_BOOTED", "3"))
BOOT_TIMEOUT = int(os.environ.get("IOS_SIM_BOOT_TIMEOUT", "600"))
AGENT_NAMES = ("claude", "opencode", "node")


def simctl(*args: str, check: bool = True, timeout: int | None = None) -> str:
    result = subprocess.run(["xcrun", "simctl", *args], capture_output=True, text=True, timeout=timeout)
    if check and result.returncode != 0:
        sys.exit(f"simctl {' '.join(args)} failed: {result.stderr.strip() or result.stdout.strip()}")
    return result.stdout.strip()


def devices() -> list[dict]:
    listing = json.loads(simctl("list", "devices", "--json"))
    found = []
    for runtime, entries in listing["devices"].items():
        for entry in entries:
            found.append({**entry, "runtime": runtime})
    return found


def device(udid: str) -> dict:
    for entry in devices():
        if entry["udid"] == udid:
            return entry
    sys.exit(f"No simulator with UDID {udid}.")


def pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def agent_pid() -> int:
    """The nearest ancestor that is an agent, so the claim lives as long as the agent does."""
    pid = os.getppid()
    while pid > 1:
        out = subprocess.run(["ps", "-o", "ppid=,comm=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
        if not out:
            break
        parent, command = out.split(None, 1)
        if any(name in Path(command).name.lower() for name in AGENT_NAMES):
            return pid
        pid = int(parent)
    return os.getppid()


def claim(udid: str, pid: int) -> None:
    CLAIMS.mkdir(parents=True, exist_ok=True)
    (CLAIMS / udid).write_text(f"{pid}\n")


def claim_of(udid: str) -> tuple[int | None, bool]:
    path = CLAIMS / udid
    if not path.exists():
        return None, False
    try:
        pid = int(path.read_text().strip())
    except ValueError:
        return None, False
    return pid, pid_alive(pid)


def short(identifier: str) -> str:
    return identifier.rsplit(".", 1)[-1]


def template_name(device_type: str, runtime: str) -> str:
    return f"{TEMPLATE_PREFIX} {short(device_type)} {short(runtime)}"


def find_template(device_type: str, runtime: str) -> dict | None:
    name = template_name(device_type, runtime)
    matches = [d for d in devices() if d["name"] == name and d.get("isAvailable", True)]
    if len(matches) > 1:
        sys.exit(f"Several simulators are named {name!r}; delete all but one.")
    return matches[0] if matches else None


def warm_marker(udid: str) -> Path:
    return STATE / f"{udid}.warm"


def wait_booted(udid: str) -> float:
    start = time.monotonic()
    simctl("bootstatus", udid, "-b", timeout=BOOT_TIMEOUT)
    return time.monotonic() - start


def booted_report() -> list[str]:
    lines = []
    for entry in devices():
        if entry["state"] != "Booted":
            continue
        pid, alive = claim_of(entry["udid"])
        owner = "unclaimed" if pid is None else f"claimed by {pid} ({'alive' if alive else 'dead'})"
        lines.append(f"{entry['name']} ({entry['udid']}): {owner}")
    return lines


def warn_if_crowded() -> None:
    booted = booted_report()
    if len(booted) >= MAX_BOOTED:
        print(
            f"warning: {len(booted)} simulators are already booted (IOS_SIM_MAX_BOOTED={MAX_BOOTED}); each runs "
            "a few hundred processes, so another one boots slowly and slows the rest. Shut down ones nobody uses:",
            file=sys.stderr,
        )
        for line in booted:
            print(f"  {line}", file=sys.stderr)


class TemplateLock:
    """Two agents warming the same template at once would both boot it."""

    def __init__(self, device_type: str, runtime: str):
        STATE.mkdir(parents=True, exist_ok=True)
        self.path = STATE / f"{short(device_type)}-{short(runtime)}.lock"

    def __enter__(self):
        self.file = open(self.path, "w")
        fcntl.flock(self.file, fcntl.LOCK_EX)
        return self

    def __exit__(self, *_):
        fcntl.flock(self.file, fcntl.LOCK_UN)
        self.file.close()


def make_template(device_type: str, runtime: str, source: str | None) -> dict:
    name = template_name(device_type, runtime)
    existing = find_template(device_type, runtime)
    if existing:
        if existing["state"] != "Shutdown":
            sys.exit(f"The template {name} is {existing['state'].lower()}; something is using it. Shut it down first.")
        simctl("delete", existing["udid"])
        warm_marker(existing["udid"]).unlink(missing_ok=True)

    if source:
        entry = device(source)
        if entry["state"] != "Shutdown":
            sys.exit(f"{entry['name']} must be shut down to clone it; it is {entry['state'].lower()}.")
        if (entry["deviceTypeIdentifier"], entry["runtime"]) != (device_type, runtime):
            sys.exit(f"{entry['name']} is a different device type or runtime from the template asked for.")
        udid = simctl("clone", source, name)
        print(f"template {name} ({udid}) cloned from {entry['name']}", file=sys.stderr)
    else:
        udid = simctl("create", name, device_type, runtime)
        print(f"booting the new template {name} ({udid}) once; the first boot is the slow one", file=sys.stderr)
        simctl("boot", udid)
        took = wait_booted(udid)
        # Many daemons do their first-run work just after boot finishes; let them get through it.
        time.sleep(30)
        simctl("shutdown", udid)
        print(f"template warmed in {took:.0f} s plus 30 s settling", file=sys.stderr)
    STATE.mkdir(parents=True, exist_ok=True)
    warm_marker(udid).write_text(time.strftime("%Y-%m-%dT%H:%M:%S") + "\n")
    return device(udid)


def type_and_runtime(args) -> tuple[str, str]:
    if args.like:
        entry = device(args.like)
        return entry["deviceTypeIdentifier"], entry["runtime"]
    if args.device_type and args.runtime:
        return args.device_type, args.runtime
    sys.exit("Say what to clone with --like <UDID>, or --device-type and --runtime.")


def cmd_create(args) -> None:
    device_type, runtime = type_and_runtime(args)
    name = args.name if args.name.startswith(TEMP_PREFIX) else TEMP_PREFIX + args.name
    if not args.no_boot:
        warn_if_crowded()
    with TemplateLock(device_type, runtime):
        template = find_template(device_type, runtime)
        if template is None or not warm_marker(template["udid"]).exists():
            template = make_template(device_type, runtime, None)
        elif template["state"] != "Shutdown":
            sys.exit(f"The template {template['name']} is {template['state'].lower()}; it must be shut down to clone.")
        udid = simctl("clone", template["udid"], name)
    claim(udid, args.pid or agent_pid())
    print(f"cloned {template['name']} as {name}", file=sys.stderr)
    if not args.no_boot:
        start = time.monotonic()
        simctl("boot", udid)
        wait_booted(udid)
        print(f"booted in {time.monotonic() - start:.0f} s", file=sys.stderr)
    print(udid)


def cmd_release(args) -> None:
    entry = device(args.udid)
    if not entry["name"].startswith(TEMP_PREFIX) and not args.force:
        sys.exit(f"{entry['name']} is not a {TEMP_PREFIX} simulator; pass --force to delete it anyway.")
    pid, alive = claim_of(args.udid)
    if alive and pid != (args.pid or agent_pid()) and not args.force:
        sys.exit(f"{entry['name']} is claimed by process {pid}, which is still running; pass --force to delete it anyway.")
    if entry["state"] != "Shutdown":
        simctl("shutdown", args.udid, check=False)
    simctl("delete", args.udid)
    (CLAIMS / args.udid).unlink(missing_ok=True)
    print(f"deleted {entry['name']} ({args.udid})")


def cmd_template(args) -> None:
    if args.source and not (args.like or args.device_type or args.runtime):
        args.like = args.source
    device_type, runtime = type_and_runtime(args)
    with TemplateLock(device_type, runtime):
        template = make_template(device_type, runtime, args.source)
    print(template["udid"])


def cmd_status(_args) -> None:
    lines = booted_report()
    print("\n".join(lines) if lines else "no simulators booted")
    templates = [d for d in devices() if d["name"].startswith(TEMPLATE_PREFIX)]
    for entry in templates:
        warm = "warm" if warm_marker(entry["udid"]).exists() else "not warmed"
        print(f"template {entry['name']} ({entry['udid']}): {entry['state'].lower()}, {warm}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    def like_options(p):
        p.add_argument("--like", metavar="UDID", help="use this simulator's device type and runtime")
        p.add_argument("--device-type", help="for example com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro")
        p.add_argument("--runtime", help="for example com.apple.CoreSimulator.SimRuntime.iOS-27-0")

    create = sub.add_parser("create", help="clone the warm template as tmp-<name>, boot and claim it")
    create.add_argument("--name", required=True, help="what the simulator is for; tmp- is added")
    like_options(create)
    create.add_argument("--no-boot", action="store_true", help="clone and claim but leave it shut down")
    create.add_argument("--pid", type=int, help="claim under this pid instead of the agent's")
    create.set_defaults(run=cmd_create)

    release = sub.add_parser("release", help="shut down and delete a tmp- simulator and its claim")
    release.add_argument("udid")
    release.add_argument("--pid", type=int, help="the pid it was claimed under, if not the agent's")
    release.add_argument("--force", action="store_true", help="delete a simulator not named tmp-, or claimed by another live process")
    release.set_defaults(run=cmd_release)

    template = sub.add_parser("template", help="make or refresh the warm template")
    like_options(template)
    template.add_argument("--from", dest="source", metavar="UDID", help="clone this shut-down, already-booted simulator instead of booting a new one")
    template.set_defaults(run=cmd_template)

    status = sub.add_parser("status", help="booted simulators, claims and templates")
    status.set_defaults(run=cmd_status)

    args = parser.parse_args()
    args.run(args)


if __name__ == "__main__":
    main()
