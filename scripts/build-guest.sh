#!/bin/bash
# Builds stupidsim-guest, the arm64 iOS simulator program stupidsim runs inside x86Sim devices on
# Linux (see guest/stupidsim-guest.m), into guest/bin, where the Linux package takes it from. It is
# committed because Linux has no iOS simulator SDK to build it with.
#
# The committed build is signed with guest/stupidsim-guest.entitlements, which lets it read the
# pasteboard without the paste prompt. A Mac's simulator refuses to start a program that claims
# that entitlement ("Security policy issue"), so --mac-simulator builds an unentitled copy into
# build/guest for trying the guest on a Mac's simulator with `xcrun simctl spawn`.
#
# Usage: scripts/build-guest.sh [--mac-simulator]
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
source_file="${repo_root}/guest/stupidsim-guest.m"
entitlements="${repo_root}/guest/stupidsim-guest.entitlements"

if [ "${1:-}" = "--mac-simulator" ]; then
  out="${repo_root}/build/guest/stupidsim-guest"
else
  out="${repo_root}/guest/bin/stupidsim-guest"
fi
mkdir -p "$(dirname "${out}")"

xcrun --sdk iphonesimulator clang -arch arm64 -mios-simulator-version-min=17.0 \
  -fobjc-arc -Wall -Werror -Wno-objc-method-access -Os \
  -framework Foundation -framework CoreGraphics \
  "${source_file}" -o "${out}"

if [ "${1:-}" = "--mac-simulator" ]; then
  codesign -s - -f "${out}" >/dev/null 2>&1
else
  codesign -s - -f --entitlements "${entitlements}" "${out}" >/dev/null 2>&1
fi
echo "${out}"
