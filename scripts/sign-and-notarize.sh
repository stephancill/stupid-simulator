#!/bin/bash
# The whole chain, in the one order that works: build, sign, notarize, staple, package, notarize,
# staple.
#
# The order is not a preference. The app is stapled before the DMG is built, so the copy a user
# drags to Applications carries its own ticket and passes Gatekeeper with no network. The DMG is
# built from that stapled app and then gets a ticket of its own, so the download is not flagged
# either. Anything that rewrites an artifact after it has been signed, a re-zip or a second
# codesign, invalidates what came before, which is also why the Sparkle signature in R6 comes last
# of all and is never generated before this script has finished.
#
# Usage: ODH_SIGNING_IDENTITY=... ODH_ASC_KEY_ID=... ODH_ASC_ISSUER_ID=... \
#        ODH_ASC_KEY_PATH=... scripts/sign-and-notarize.sh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
app="${repo_root}/build/stupid simulator.app"

echo "== build =="
"${repo_root}/scripts/build-app.sh" release

echo
echo "== sign =="
"${repo_root}/scripts/sign-app.sh" "${app}"

echo
echo "== notarize and staple the app =="
"${repo_root}/scripts/notarize.sh" "${app}"

echo
echo "== package =="
dmg="$("${repo_root}/scripts/package-dmg.sh" "${app}")"
echo "${dmg}"

echo
echo "== notarize and staple the disk image =="
"${repo_root}/scripts/notarize.sh" "${dmg}"

echo
echo "== the same disk image under a name that never changes =="
# The README's download button fetches this name from the latest release, so it never needs editing.
cp "${dmg}" "${repo_root}/build/StupidSimulator.dmg"
echo "${repo_root}/build/StupidSimulator.dmg"

echo
echo "== checksums, from the stapled artifacts =="
"${repo_root}/scripts/checksums.sh"

echo
echo "== the update feed, signed over the final bytes =="
# A build with no feed in its Info.plist cannot take updates, so there is no feed to write. That is
# every build until this fork publishes its own signed feed.
if /usr/libexec/PlistBuddy -c "Print :SUFeedURL" "${app}/Contents/Info.plist" >/dev/null 2>&1; then
  "${repo_root}/scripts/appcast.sh" "${dmg}"
else
  echo "skipped: the app has no SUFeedURL, so it takes no updates"
fi

echo
echo "== what Gatekeeper makes of them =="
spctl -a -vv "${app}" 2>&1 | sed 's/^/  app: /'
spctl -a -vv -t open --context context:primary-signature "${dmg}" 2>&1 | sed 's/^/  dmg: /'
xcrun stapler validate "${app}" 2>&1 | sed 's/^/  app: /'
xcrun stapler validate "${dmg}" 2>&1 | sed 's/^/  dmg: /'
