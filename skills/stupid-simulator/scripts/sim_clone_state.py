#!/usr/bin/env python3
"""
Copy an app's signed-in state from one simulator to another.

For when the simulator that holds an app's credentials is busy (another agent is driving it) and
you need the same signed-in state elsewhere. Copies, for one bundle id:

- the app's data container (Documents, Library, UserDefaults, caches)
- its app group containers (matched by group id; groups the target lacks are reported)
- the simulator's keychain (all of it: simulator keychains are per device, not per app)

The source is only read, never modified, so it is safe to copy from a simulator in use. The
keychain is copied with SQLite's online backup, which is consistent while the source is running.
The target is shut down while copying and replaces whatever state it had for the app.

Without --target, a new simulator is created with the source's device type and runtime. The app
must be installed on the target (pass --app to install a simulator build), because install creates
the containers the state is copied into.

Examples:
  sim_clone_state.py --source <UDID> --bundle-id tech.stupid.StupidSocial --app path/to/App.app
  sim_clone_state.py --source <UDID> --target <UDID> --bundle-id tech.stupid.StupidSocial --boot
"""

import argparse
import json
import plistlib
import subprocess
import sys
from pathlib import Path

DEVICES = Path.home() / "Library/Developer/CoreSimulator/Devices"
METADATA = ".com.apple.mobile_container_manager.metadata.plist"


def simctl(*args: str, check: bool = True) -> str:
    result = subprocess.run(["xcrun", "simctl", *args], capture_output=True, text=True)
    if check and result.returncode != 0:
        sys.exit(f"simctl {' '.join(args)} failed: {result.stderr.strip()}")
    return result.stdout.strip()


def device_plist(udid: str) -> dict:
    path = DEVICES / udid / "device.plist"
    if not path.exists():
        sys.exit(f"No simulator {udid}")
    with path.open("rb") as f:
        return plistlib.load(f)


def is_booted(udid: str) -> bool:
    return device_plist(udid).get("state") == 3


def data_container(udid: str, bundle_id: str) -> Path:
    out = simctl("get_app_container", udid, bundle_id, "data", check=False)
    if not out:
        sys.exit(f"{bundle_id} is not installed on {udid}; install it first (or pass --app)")
    return Path(out)


def group_containers(udid: str) -> dict[str, Path]:
    root = DEVICES / udid / "data/Containers/Shared/AppGroup"
    groups = {}
    for meta in root.glob(f"*/{METADATA}"):
        with meta.open("rb") as f:
            identifier = plistlib.load(f).get("MCMMetadataIdentifier")
        if identifier:
            groups[identifier] = meta.parent
    return groups


def app_groups(udid: str, bundle_id: str) -> list[str]:
    """Group ids from the installed app's entitlements, else every group whose id names the bundle id."""
    app = simctl("get_app_container", udid, bundle_id, "app", check=False)
    if app:
        result = subprocess.run(
            ["codesign", "-d", "--entitlements", "-", "--xml", app], capture_output=True
        )
        if result.returncode == 0 and result.stdout:
            try:
                entitlements = plistlib.loads(result.stdout)
                groups = entitlements.get("com.apple.security.application-groups")
                if groups:
                    return list(groups)
            except Exception:
                pass
    return [g for g in group_containers(udid) if bundle_id in g]


def mirror(source: Path, target: Path) -> None:
    """Make target's contents match source's, keeping target's container metadata."""
    subprocess.run(
        ["rsync", "-a", "--delete", "--exclude", METADATA, f"{source}/", f"{target}/"],
        check=True,
    )


def copy_keychain(source_udid: str, target_udid: str) -> list[str]:
    source = DEVICES / source_udid / "data/Library/Keychains"
    target = DEVICES / target_udid / "data/Library/Keychains"
    target.mkdir(parents=True, exist_ok=True)
    for stale in target.glob("keychain-2*"):
        stale.unlink()
    copied = []
    for db in sorted(source.glob("keychain-2*.db")):
        destination = target / db.name
        subprocess.run(["sqlite3", str(db), f".backup '{destination}'"], check=True)
        destination.chmod(0o600)
        copied.append(db.name)
    if not copied:
        sys.exit(f"No keychain databases in {source}")
    return copied


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--source", required=True, help="UDID holding the state (only read)")
    parser.add_argument("--target", help="UDID to copy into (default: create one like the source)")
    parser.add_argument("--name", help="Name for a created target (default: tmp-<bundle id>)")
    parser.add_argument("--bundle-id", required=True)
    parser.add_argument("--app", help="Simulator .app build to install on the target first")
    parser.add_argument("--boot", action="store_true", help="Boot the target after copying")
    parser.add_argument("--launch", action="store_true", help="Boot the target and launch the app")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    if args.source == args.target:
        sys.exit("--source and --target are the same simulator")
    source_device = device_plist(args.source)

    created = False
    target = args.target
    if not target:
        name = args.name or f"tmp-{args.bundle_id}"
        target = simctl("create", name, source_device["deviceType"], source_device["runtime"])
        created = True

    if args.app:
        if not is_booted(target):
            simctl("boot", target)
        simctl("bootstatus", target, "-b")
        simctl("install", target, args.app)

    source_data = data_container(args.source, args.bundle_id)
    target_data = data_container(target, args.bundle_id)
    groups = app_groups(args.source, args.bundle_id)
    source_groups = group_containers(args.source)
    target_groups = group_containers(target)

    if is_booted(target):
        simctl("shutdown", target)

    mirror(source_data, target_data)
    copied_groups, missing_groups = [], []
    for group in groups:
        if group not in source_groups:
            continue
        if group not in target_groups:
            missing_groups.append(group)
            continue
        mirror(source_groups[group], target_groups[group])
        copied_groups.append(group)
    keychains = copy_keychain(args.source, target)

    if args.boot or args.launch:
        simctl("boot", target)
        simctl("bootstatus", target, "-b")
    if args.launch:
        simctl("launch", target, args.bundle_id)

    report = {
        "target": target,
        "created": created,
        "dataContainer": str(target_data),
        "appGroups": copied_groups,
        "appGroupsMissingOnTarget": missing_groups,
        "keychains": keychains,
    }
    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print(f"Copied {args.bundle_id} state from {args.source} to {target}{' (created)' if created else ''}")
        print(f"  data container: {target_data}")
        print(f"  app groups: {', '.join(copied_groups) or 'none'}")
        print(f"  keychain: {', '.join(keychains)}")
        if missing_groups:
            print(
                f"  NOT copied, target has no container for: {', '.join(missing_groups)} "
                "(install a build signed with these groups)",
                file=sys.stderr,
            )
    if missing_groups:
        sys.exit(1)


if __name__ == "__main__":
    main()
