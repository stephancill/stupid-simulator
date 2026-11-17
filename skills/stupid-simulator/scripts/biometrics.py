#!/usr/bin/env python3
"""
iOS Simulator Face ID / Touch ID

Enrolls biometrics and answers biometric prompts (Face ID, Touch ID), as Simulator.app's
Features → Face ID menu does, through BiometricKit's darwin notifications. Passkeys need
enrolled biometrics: without them the simulator says "Simulator requires enrolled biometrics
to use passkeys."

Usage:
  python scripts/biometrics.py --enroll            # enroll (Face ID or Touch ID, whichever the device has)
  python scripts/biometrics.py --status            # enrolled or not
  python scripts/biometrics.py --match             # answer the prompt on screen with a matching face
  python scripts/biometrics.py --no-match          # ... with a face that doesn't match
  python scripts/biometrics.py --match --type touch   # Touch ID devices
  python scripts/biometrics.py --unenroll

--match and --no-match only act while a prompt is showing; send them after the prompt appears.
Enrollment lasts until the simulator is erased.
"""

import argparse
import json
import subprocess
import sys

from common import resolve_udid

ENROLLMENT = "com.apple.BiometricKit.enrollmentChanged"
PROMPT_NOTIFICATIONS: dict[str, dict[bool, str]] = {
    "face": {True: "com.apple.BiometricKit_Sim.pearl.match", False: "com.apple.BiometricKit_Sim.pearl.nomatch"},
    "touch": {True: "com.apple.BiometricKit_Sim.fingerTouch.match", False: "com.apple.BiometricKit_Sim.fingerTouch.nomatch"},
}


def notifyutil(udid: str, *args: str) -> str:
    try:
        result = subprocess.run(
            ["xcrun", "simctl", "spawn", udid, "notifyutil", *args],
            capture_output=True,
            text=True,
            check=False,
            timeout=30,
        )
    except subprocess.TimeoutExpired as error:
        raise RuntimeError("the simulator didn't answer within 30 s; restart it") from error
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or f"notifyutil {' '.join(args)} failed")
    return result.stdout.strip()


def set_enrolled(udid: str, enrolled: bool) -> None:
    notifyutil(udid, "-s", ENROLLMENT, "1" if enrolled else "0")
    notifyutil(udid, "-p", ENROLLMENT)


def is_enrolled(udid: str) -> bool:
    # Prints "<name> <state>".
    return notifyutil(udid, "-g", ENROLLMENT).split()[-1] == "1"


def main() -> None:
    parser = argparse.ArgumentParser(description="Enroll Face ID / Touch ID and answer biometric prompts on a simulator.")
    parser.add_argument("--udid", help="Device UDID (default: the booted simulator)")
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument("--enroll", action="store_true", help="Enroll biometrics")
    action.add_argument("--unenroll", action="store_true", help="Remove enrollment")
    action.add_argument("--status", action="store_true", help="Print whether biometrics are enrolled")
    action.add_argument("--match", action="store_true", help="Answer the prompt on screen with a match")
    action.add_argument("--no-match", action="store_true", help="Answer the prompt on screen with a non-match")
    parser.add_argument("--type", choices=["face", "touch"], default="face", help="Biometric for --match/--no-match (default: face)")
    parser.add_argument("--json", action="store_true", help="JSON output")
    args = parser.parse_args()

    try:
        udid = resolve_udid(args.udid)
        if args.enroll or args.unenroll:
            set_enrolled(udid, args.enroll)
            output = {"udid": udid, "enrolled": is_enrolled(udid)}
            message = f"Biometrics {'enrolled' if output['enrolled'] else 'not enrolled'}"
        elif args.status:
            output = {"udid": udid, "enrolled": is_enrolled(udid)}
            message = f"Biometrics {'enrolled' if output['enrolled'] else 'not enrolled'}"
        else:
            if not is_enrolled(udid):
                raise RuntimeError("biometrics are not enrolled; run --enroll first")
            notifyutil(udid, "-p", PROMPT_NOTIFICATIONS[args.type][args.match])
            output = {"udid": udid, "type": args.type, "match": args.match}
            message = f"Sent {'matching' if args.match else 'non-matching'} {args.type}"
    except RuntimeError as error:
        print(json.dumps({"error": str(error)}) if args.json else f"Error: {error}", file=sys.stderr)
        sys.exit(1)
    print(json.dumps(output) if args.json else message)


if __name__ == "__main__":
    main()
