#!/bin/bash
# Builds the test host app the verification scripts install. It reports the orientation it is in
# and echoes taps, so a script can read the device's state from a screenshot. It carries a
# Notification Service Extension that prefixes titles with "Serviced: ", for `stupidsim push`.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
source_dir="${repo_root}/testhost/ODHTestHost"
out_dir="${repo_root}/build/testhost"
bundle="${out_dir}/ODHTestHost.app"

sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"
arch="$(uname -m)"
[ "${arch}" = "arm64" ] && target="arm64-apple-ios17.0-simulator" || target="x86_64-apple-ios17.0-simulator"

rm -rf "${bundle}"
mkdir -p "${bundle}"
# xcrun exports SDKROOT for whichever SDK it was asked for, and the clang importer reads it. Left
# as plain `xcrun swiftc` it exports the macOS one, which then disagrees with -sdk and -target.
xcrun --sdk iphonesimulator swiftc -sdk "${sdk}" -target "${target}" \
  "${source_dir}/main.swift" -o "${bundle}/ODHTestHost"
cp "${source_dir}/Info.plist" "${bundle}/Info.plist"

extension="${bundle}/PlugIns/NotificationService.appex"
mkdir -p "${extension}"
# An app extension's entry point is NSExtensionMain, which finds the principal class from Info.plist.
xcrun --sdk iphonesimulator swiftc -sdk "${sdk}" -target "${target}" -application-extension \
  -parse-as-library -module-name NotificationService \
  "${repo_root}/testhost/NotificationService/NotificationService.swift" \
  -Xlinker -e -Xlinker _NSExtensionMain -o "${extension}/NotificationService"
cp "${repo_root}/testhost/NotificationService/Info.plist" "${extension}/Info.plist"
# The system only launches a signed extension; ad hoc is enough on a simulator.
codesign -s - -f "${extension}" >/dev/null 2>&1
codesign -s - -f "${bundle}" >/dev/null 2>&1
echo "${bundle}"
