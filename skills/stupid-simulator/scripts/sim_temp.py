#!/usr/bin/env python3
"""
Temporary simulators that boot fast, cloned from a warmed template, with claims built in.

A simulator made with `simctl create` spends its first boot on one-time setup: data migration,
caches, indexing and asset downloads in a few hundred daemons. On a busy Mac that first boot takes
minutes. `simctl clone` of a simulator that has already booted once is an APFS copy that skips it.
This script keeps one shut-down template per device type and runtime and clones it.

Each simulator iOS 27 boots runs about two hundred processes and 1.5 to 3 GB of memory. Past what
the Mac's memory holds, every simulator slows down together: the runtime is a compressed disk image,
so each page the Mac evicts has to be decompressed again when it is next touched. So the script
warns when several are booted, trims the wallpaper extensions a new clone does not need, shuts
simulators down one at a time, and `reap` clears out ones whose agent has gone. Claims live in
~/.cache/sim-claims/<UDID> under the pid of the agent process (the nearest `claude`, `opencode` or
`node` ancestor), not a shell that exits straight away.

Commands:
  create   Clone the template for --like UDID (or --device-type and --runtime) as tmp-<name>,
           boot it and claim it, then trim it in the background. Makes the template first if there is none (one slow
           boot). Prints the new UDID as the last line.
  release  Shut down and delete a tmp- simulator and remove its claim.
  reap     Shut down and delete tmp- simulators whose claim is missing or whose agent has exited.
           --all also shuts down (never deletes) other unclaimed booted simulators. A booted one is
           left alone while a host process names its UDID or for --min-age (30 min) after boot.
  trim     Stop the wallpaper extensions a booted simulator is not showing (about 250 MB).
  template Make or refresh the template: --from UDID clones a shut-down simulator that has
           already booted once instead of booting a new one.
  status   Booted simulators, their memory, who claims them and whether that process is alive.

Examples:
  T=$(sim_temp.py create --name checkout-flow --like <UDID> | tail -1)
  sim_temp.py release $T
  sim_temp.py reap --dry-run
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
# reap leaves a simulator alone for this long after it boots, since a claim can name a process that has
# already exited (a shell's $$) while its agent is still at work.
REAP_MIN_AGE = int(os.environ.get("IOS_SIM_REAP_MIN_AGE", "1800"))
# How long to wait for the wallpaper extensions to stop appearing after boot before trimming them.
POSTER_SETTLE = int(os.environ.get("IOS_SIM_POSTER_SETTLE", "120"))


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


def launchd_sims() -> dict[str, int]:
    """Each booted simulator's launchd_sim pid by UDID. Every guest process is its child."""
    found = {}
    out = subprocess.run(["ps", "-axo", "pid=,command="], capture_output=True, text=True).stdout
    for line in out.splitlines():
        pid, _, command = line.strip().partition(" ")
        if "launchd_sim" not in command or "/Devices/" not in command:
            continue
        udid = command.split("/Devices/", 1)[1].split("/", 1)[0]
        found[udid] = int(pid)
    return found


def megabytes(value: str) -> float:
    value = value.rstrip("+-")
    units = {"B": 1 / 1048576, "K": 1 / 1024, "M": 1, "G": 1024}
    if value and value[-1] in units:
        return float(value[:-1]) * units[value[-1]]
    return float(value) / 1048576


def guest_processes() -> list[tuple[int, int, float, str]]:
    """(pid, ppid, footprint MB, command) for every process. top's memory column is the physical
    footprint, which counts compressed pages that ps's RSS leaves out."""
    out = subprocess.run(
        ["top", "-l", "1", "-n", "100000", "-stats", "pid,ppid,mem"], capture_output=True, text=True
    ).stdout
    commands = {}
    for line in subprocess.run(["ps", "-axo", "pid=,command="], capture_output=True, text=True).stdout.splitlines():
        pid, _, command = line.strip().partition(" ")
        commands[int(pid)] = command
    rows, started = [], False
    for line in out.splitlines():
        parts = line.split()
        if parts[:1] == ["PID"]:
            started = True
            continue
        if not started or len(parts) < 3 or not parts[0].isdigit():
            continue
        pid = int(parts[0])
        rows.append((pid, int(parts[1]), megabytes(parts[2]), commands.get(pid, "")))
    return rows


def booted_report(with_memory: bool = False) -> list[str]:
    usage: dict[str, tuple[int, float]] = {}
    if with_memory:
        roots = {pid: udid for udid, pid in launchd_sims().items()}
        for _, ppid, mb, _ in guest_processes():
            if ppid in roots:
                count, total = usage.get(roots[ppid], (0, 0.0))
                usage[roots[ppid]] = (count + 1, total + mb)
    lines = []
    for entry in devices():
        if entry["state"] != "Booted":
            continue
        pid, alive = claim_of(entry["udid"])
        owner = "unclaimed" if pid is None else f"claimed by {pid} ({'alive' if alive else 'dead'})"
        memory = ""
        if entry["udid"] in usage:
            count, total = usage[entry["udid"]]
            memory = f", {total / 1024:.1f} GB in {count} processes"
        lines.append(f"{entry['name']} ({entry['udid']}): {owner}{memory}")
    return lines


def is_poster_extension(command: str) -> bool:
    """A wallpaper extension (MercuryPosterExtension, AegirPoster, PhotosPosterProvider, ...), not
    PosterBoard, which hosts them. Verified on iOS 27.0 (24A434)."""
    if ".appex/" not in command:
        return False
    bundle = command.split(".appex/", 1)[0].rsplit("/", 1)[-1]
    return "Poster" in bundle


def posters(udid: str) -> list[tuple[int, float, str]]:
    root = launchd_sims().get(udid)
    if root is None:
        sys.exit(f"{udid} is not booted, so there is nothing to trim.")
    return [
        (pid, mb, command.split(".appex/", 1)[0].rsplit("/", 1)[-1])
        for pid, ppid, mb, command in guest_processes()
        if ppid == root and is_poster_extension(command)
    ]


def poster_board_alive(udid: str) -> bool:
    root = launchd_sims().get(udid)
    out = subprocess.run(["ps", "-axo", "ppid=,command="], capture_output=True, text=True).stdout
    return any(
        line.split(None, 1)[0] == str(root) and "PosterBoard.app/PosterBoard" in line
        for line in out.splitlines()
        if line.strip()
    )


def wait_for_posters(udid: str) -> None:
    """PosterBoard starts every wallpaper extension in the minute or so after boot. Trimming before
    it is done would only have it start the rest afterwards, so wait until the count holds still."""
    deadline = time.monotonic() + POSTER_SETTLE
    last, steady_since = -1, time.monotonic()
    while time.monotonic() < deadline:
        count = len(posters(udid))
        if count != last:
            last, steady_since = count, time.monotonic()
        elif count > 0 and time.monotonic() - steady_since >= 15:
            return
        time.sleep(5)


def trim(udid: str) -> None:
    """Stops every wallpaper extension. PosterBoard starts again the one the device is showing, so
    the wallpaper still draws and the others' memory comes back: on iOS 27.0 (24A434), 16 of 17 stayed
    gone and about 250 MB was freed per simulator."""
    found = posters(udid)
    if not found:
        print(f"trim: no wallpaper extensions running on {udid}; nothing to stop", file=sys.stderr)
        return
    for pid, _, _ in found:
        try:
            os.kill(pid, 15)
        except ProcessLookupError:
            pass
    time.sleep(15)
    if not poster_board_alive(udid):
        sys.exit(f"trim: PosterBoard is no longer running on {udid}; the lock and home screen may not draw.")
    back = posters(udid)
    freed = sum(mb for _, mb, _ in found) - sum(mb for _, mb, _ in back)
    print(
        f"trim: stopped {len(found)} wallpaper extensions, {len(back)} started again "
        f"({', '.join(name for _, _, name in back) or 'none'}); about {freed:.0f} MB freed",
        file=sys.stderr,
    )


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


class FileLock:
    def __init__(self, name: str):
        STATE.mkdir(parents=True, exist_ok=True)
        self.path = STATE / name

    def __enter__(self):
        self.file = open(self.path, "w")
        fcntl.flock(self.file, fcntl.LOCK_EX)
        return self

    def __exit__(self, *_):
        fcntl.flock(self.file, fcntl.LOCK_UN)
        self.file.close()


def template_lock(device_type: str, runtime: str) -> FileLock:
    """Two agents warming the same template at once would both boot it."""
    return FileLock(f"{short(device_type)}-{short(runtime)}.lock")


def shutdown(udid: str) -> None:
    """One shutdown at a time across every agent. CoreSimulator gives each guest daemon 3 s to exit
    and records a crash when it misses that (SIGTERMTimeout 3, CrashOnSIGTERMTimeout in the boot
    plist; Xcode 27, CoreSimulator 1171.7). Several shutdowns at once on a loaded Mac miss it in
    bulk, and the host's ReportCrash then symbolicates dozens of reports, loading it further."""
    with FileLock("shutdown.lock"):
        simctl("shutdown", udid, check=False)


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
        shutdown(udid)
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
    with template_lock(device_type, runtime):
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
        if not args.no_trim:
            # PosterBoard takes a minute or two to start its extensions, so trim in the background
            # rather than hold up the agent that asked for the simulator.
            log = STATE / f"trim-{udid}.log"
            STATE.mkdir(parents=True, exist_ok=True)
            with open(log, "w") as out:
                subprocess.Popen(
                    [sys.executable, str(Path(__file__).resolve()), "trim", "--wait", udid],
                    stdout=out, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, start_new_session=True,
                )
            print(f"trimming wallpaper extensions in the background; log at {log}", file=sys.stderr)
    print(udid)


def cmd_release(args) -> None:
    entry = device(args.udid)
    if not entry["name"].startswith(TEMP_PREFIX) and not args.force:
        sys.exit(f"{entry['name']} is not a {TEMP_PREFIX} simulator; pass --force to delete it anyway.")
    pid, alive = claim_of(args.udid)
    if alive and pid != (args.pid or agent_pid()) and not args.force:
        sys.exit(f"{entry['name']} is claimed by process {pid}, which is still running; pass --force to delete it anyway.")
    if entry["state"] != "Shutdown":
        shutdown(args.udid)
    simctl("delete", args.udid)
    (CLAIMS / args.udid).unlink(missing_ok=True)
    print(f"deleted {entry['name']} ({args.udid})")


def boot_age(udid: str) -> float | None:
    """Seconds since boot, from the SIMULATOR_BOOT_TIME CoreSimulator writes at each boot."""
    plist = Path.home() / f"Library/Developer/CoreSimulator/Devices/{udid}/data/var/run/launchd_bootstrap.plist"
    try:
        import plistlib

        booted_at = int(plistlib.loads(plist.read_bytes())["Bootstrap"]["Child"]["SIMULATOR_BOOT_TIME"])
    except (OSError, KeyError, ValueError):
        return None
    return time.time() - booted_at


def host_users(udid: str) -> list[str]:
    """Host processes naming the UDID that are not the guest itself: stupidsim, simctl, xcodebuild,
    or an agent's shell running one of them. Their presence means someone is using it."""
    users = []
    out = subprocess.run(["ps", "-axo", "pid=,command="], capture_output=True, text=True).stdout
    for line in out.splitlines():
        pid, _, command = line.strip().partition(" ")
        if udid not in command or int(pid) == os.getpid() or "sim_temp.py" in command:
            continue
        if "launchd_sim" in command or f"/Devices/{udid}/" in command.split(" ", 1)[0]:
            continue
        users.append(f"{pid} {Path(command.split(' ', 1)[0]).name}")
    return users


def cmd_reap(args) -> None:
    acted = False
    for entry in devices():
        name, udid = entry["name"], entry["udid"]
        if name.startswith(TEMPLATE_PREFIX):
            continue
        pid, alive = claim_of(udid)
        if alive:
            continue
        why = "unclaimed" if pid is None else f"its claimant {pid} has exited"
        booted = entry["state"] != "Shutdown"
        if booted:
            users = host_users(udid)
            if users:
                print(f"skipping {name} ({udid}): {why}, but in use by {', '.join(users[:3])}")
                continue
            age = boot_age(udid)
            if age is None or age < args.min_age:
                when = "an unknown time" if age is None else f"{age / 60:.0f} min"
                print(f"skipping {name} ({udid}): {why}, but it booted {when} ago (--min-age {args.min_age} s)")
                continue
        if name.startswith(TEMP_PREFIX):
            action = "shut down and delete" if booted else "delete"
        elif args.all and booted:
            action = "shut down"
        else:
            continue
        acted = True
        if args.dry_run:
            print(f"would {action} {name} ({udid}): {why}")
            continue
        if booted:
            shutdown(udid)
        if name.startswith(TEMP_PREFIX):
            simctl("delete", udid)
            (CLAIMS / udid).unlink(missing_ok=True)
        done = {"shut down and delete": "shut down and deleted", "delete": "deleted", "shut down": "shut down"}
        print(f"{done[action]} {name} ({udid}): {why}")
    if not acted:
        print("nothing to reap")


def cmd_trim(args) -> None:
    if args.wait:
        wait_for_posters(args.udid)
    trim(args.udid)


def cmd_template(args) -> None:
    if args.source and not (args.like or args.device_type or args.runtime):
        args.like = args.source
    device_type, runtime = type_and_runtime(args)
    with template_lock(device_type, runtime):
        template = make_template(device_type, runtime, args.source)
    print(template["udid"])


def cmd_status(_args) -> None:
    lines = booted_report(with_memory=True)
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
    create.add_argument("--no-trim", action="store_true", help="leave every wallpaper extension running")
    create.set_defaults(run=cmd_create)

    release = sub.add_parser("release", help="shut down and delete a tmp- simulator and its claim")
    release.add_argument("udid")
    release.add_argument("--pid", type=int, help="the pid it was claimed under, if not the agent's")
    release.add_argument("--force", action="store_true", help="delete a simulator not named tmp-, or claimed by another live process")
    release.set_defaults(run=cmd_release)

    reap = sub.add_parser("reap", help="delete tmp- simulators whose agent has gone")
    reap.add_argument("--all", action="store_true", help="also shut down (not delete) other unclaimed booted simulators")
    reap.add_argument("--min-age", type=int, default=REAP_MIN_AGE, help="leave booted simulators younger than this many seconds (default %(default)s)")
    reap.add_argument("--dry-run", action="store_true", help="only say what would happen")
    reap.set_defaults(run=cmd_reap)

    trim_parser = sub.add_parser("trim", help="stop the wallpaper extensions a booted simulator is not showing")
    trim_parser.add_argument("udid")
    trim_parser.add_argument("--wait", action="store_true", help="first wait for PosterBoard to finish starting its extensions after boot")
    trim_parser.set_defaults(run=cmd_trim)

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
