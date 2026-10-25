# Releasing

For maintainers. Nothing here contains a credential: the signing identity lives in the login
keychain and the App Store Connect key in a file outside the repository.

Releases are cut **locally**, on a Mac with Xcode 27, with `scripts/sign-and-notarize.sh` and
`gh release create`. The **Release** workflow in `.github/workflows/release.yml` runs the same scripts
on GitHub Actions, but needs the repository secrets listed at the end, which are not set up yet.

## Values that must never change

| Value | Why |
|---|---|
| The bundle identifier, `net.stupidtech.stupidsimulator` | A new one makes macOS treat the app as a different one, orphaning every installed copy. |
| A version number once published | Releases are compared by version and build number; reusing one hides the new build from anyone who saw the old. |
| The update feed URL, once there is one | The installed app keeps asking the old URL. Changing it silently ends updates for everyone. |

In-app updates are **off**: `packaging/Info.plist` has no `SUFeedURL` or `SUPublicEDKey`, so the
updater is never created and `sign-and-notarize.sh` skips the feed step. Turning them on needs a
Sparkle key pair, a feed repository served over HTTPS, and the Sparkle steps below.

## What a machine needs

- A **Developer ID Application** identity in the login keychain (`security find-identity -v -p
  codesigning`). Not Apple Development or Apple Distribution, which notarization rejects.
- An App Store Connect **Team** API key (`.p8`, or the same key as PEM) with its key ID and issuer
  ID, from the same team as the identity. An Individual key does not work with `notarytool`, and the
  failure only shows up at submission.
- `create-dmg` 8.1.0 on `PATH` (`bun add -g create-dmg@8.1.0`, or `npm install --global
  create-dmg@8.1.0`). `scripts/package-dmg.sh` refuses any other version.
- `gh`, signed in with write access to `stephancill/stupid-simulator`.

## Making a release

1. **Version and notes.** Add a `## <version>` section to the top of `CHANGELOG.md` and put the same
   version in `VERSION`. The GitHub release notes come from that section
   (`scripts/release-notes.py`), followed by the README's requirements and limitations.
2. **Commit and push** to `main`, so the tag points at what was built:

   ```sh
   git commit -am "chore(release): prepare <version>" && git push origin main
   ```

3. **Build, sign, notarize, staple and package.** Start from a clean `build/`, and raise
   `ODH_BUILD_NUMBER` with every release (it becomes `CFBundleVersion`):

   ```sh
   rm -rf build
   ODH_SIGNING_IDENTITY="Developer ID Application: <Name> (<TEAMID>)" \
   ODH_ASC_KEY_ID=<key id> ODH_ASC_ISSUER_ID=<issuer id> ODH_ASC_KEY_PATH=<path to .p8> \
   ODH_BUILD_NUMBER=<n> scripts/sign-and-notarize.sh
   ```

   Run `swift test --package-path engine` first; the script does not. It builds the release app, signs
   inside out, notarizes and staples the app, packages the DMG,
   notarizes and staples the DMG, copies it to the fixed name, writes `SHA256SUMS`, and ends by
   printing what Gatekeeper and `stapler validate` make of both. Both notarizations must say
   `status: Accepted`; it takes a few minutes. Logs are saved under `build/notarization/`.

4. **Check the artifacts** before publishing:

   ```sh
   cat build/SHA256SUMS
   spctl -a -t open --context context:primary-signature -vv build/StupidSimulator-<version>.dmg
   hdiutil attach -nobrowse -readonly build/StupidSimulator-<version>.dmg
   #   check "/Volumes/.../stupid simulator.app": the Info.plist version, and that
   #   Contents/MacOS/stupidsim --version prints <version>, then detach it
   ```

5. **Publish.** Tag, push the tag, and create the release with both DMGs and the checksums:

   ```sh
   python3 scripts/release-notes.py <version> > build/release-notes.md
   git tag -a v<version> -m "stupid simulator <version>" && git push origin v<version>
   gh release create v<version> --repo stephancill/stupid-simulator \
     --title "stupid simulator <version>" --notes-file build/release-notes.md \
     build/StupidSimulator-<version>.dmg build/StupidSimulator.dmg build/SHA256SUMS
   ```

   The README's download button fetches `StupidSimulator.dmg` from the latest release, so it needs
   no edit.

6. **Verify the download** the way a user gets it:

   ```sh
   curl -sSL -o /tmp/s.dmg https://github.com/stephancill/stupid-simulator/releases/latest/download/StupidSimulator.dmg
   shasum -a 256 /tmp/s.dmg    # must match SHA256SUMS
   spctl -a -t open --context context:primary-signature /tmp/s.dmg
   ```

7. **Install it** by copying `stupid simulator.app` from the DMG to `/Applications`, quitting any
   running copy first. The CLI link that **Install Command Line Tool** made keeps pointing at the new
   bundle.

## The order that matters

- **Sign inside out.** Sparkle's nested XPC services, then `Autoupdate`, then `Updater.app`, then
  the framework, then the bundled command, then the app. `--deep` is for verification only, never for
  signing. `scripts/sign-app.sh` does this.
- **Staple the app before packaging.** The copy someone drags to Applications then carries its own
  ticket and passes Gatekeeper offline. The DMG is notarized and stapled separately.
- **Checksums last.** `scripts/checksums.sh` refuses DMGs that are not stapled, because stapling
  changes the bytes.
- **Sign the update last**, once updates are on: the feed signature covers the exact bytes people
  download, so `scripts/appcast.sh` runs after everything else and refuses an unstapled artifact.

## Reading a notarization log

The log is saved for every submission under `build/notarization/`, including accepted ones.
`notarytool submit` reports `Accepted`, `Invalid` or `Rejected`; for anything but `Accepted`, the log
is the only thing that says why.

```sh
xcrun notarytool log <submission-id> --key <p8> --key-id <key-id> --issuer <issuer-id>
```

`issues` is the part that matters; each entry names a `path`, a `severity` and a `message`:

| Message | What it means |
|---|---|
| `The signature of the binary is invalid` | Something was modified after signing, or signed in the wrong order. |
| `The executable does not have the hardened runtime enabled` | A nested binary was missed. Check each one on its own, not with `--deep`. |
| `The signature does not include a secure timestamp` | Signed without `--timestamp`, usually offline. |
| `The binary is not signed with a valid Developer ID certificate` | An Apple Development identity was used. |

`status: Accepted` with a non-empty `issues` list is worth reading: those are warnings that become
failures in a later macOS.

## When a release fails midway

- **Before `gh release create`**, nothing outside this machine has changed. Fix it and run step 3
  again from a clean `build/`.
- **The tag or release exists but the artifacts are wrong**, and nobody can have downloaded it yet:
  delete both and publish again.

  ```sh
  gh release delete v<version> --yes --repo stephancill/stupid-simulator
  git push --delete origin v<version> && git tag -d v<version>
  ```

- **Notarization is stuck in progress.** It can take minutes or hours; `notarytool history` shows
  where it is. Do not resubmit the same bytes.
- **A published version is broken.** Release a fixed version instead of reusing the number. Mark the
  bad one as a pre-release, or delete it, so nobody new downloads it.

## Releasing from GitHub Actions

`.github/workflows/release.yml` (manual, with a `publish` input for a dry run) wraps the same scripts.
It needs these repository secrets, none of which are set yet:

| Secret | Contents |
|---|---|
| `DEVELOPER_ID_IDENTITY` | the full identity string, `Developer ID Application: Name (TEAMID)` |
| `DEVELOPER_ID_P12` | that identity exported as a `.p12`, base64 encoded |
| `DEVELOPER_ID_P12_PASSWORD` | the password used for that export |
| `ASC_KEY_ID` | App Store Connect key ID |
| `ASC_ISSUER_ID` | App Store Connect issuer ID |
| `ASC_KEY_P8` | the contents of the `.p8` private key |
| `SPARKLE_PRIVATE_KEY` | the update signing private key, once updates are on |

The workflow currently also imports a Sparkle key and generates a feed, so it needs adjusting before
it can release this fork while updates are off. It runs on a pinned runner image and asks for a
preferred Xcode major, falling back to the newest Xcode with a macOS 26.0 SDK or newer: the linked SDK
decides whether AppKit draws the current window appearance.
