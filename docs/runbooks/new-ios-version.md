# Adding a new iOS version

How to make a new iOS simulator runtime (say iOS 27.3) available to agents on Linux: verify that
stupidsim works on it, record what it needs, and publish it to the runtime store so that
`stupidsim-linux setup` fetches it. On a Mac nothing needs publishing: Xcode installs the runtime
and stupidsim uses it directly; only the verification below applies.

Expect about an hour of mostly waiting: about 15 minutes to download and unpack the runtime, the
traces, and the upload.

## What you need

- **A Linux x86-64 machine with the whole runtime**, the machine traces run on. It needs about
  60 GB free (the runtime archive, the unpacked runtime, the translation cache and the store's
  files) and 16 GB of RAM. The WSL 2 distro on the GPU PC works; use lavapipe there, since dozen
  corrupts frames.
- **A Mac with Xcode and the same iOS version**, to compare the in-device helper's tree with the
  Mac's, which is the reference.
- **The store's writer credentials** (`STUPIDSIM_STORE_URL`, `STUPIDSIM_STORE_KEY_ID`,
  `STUPIDSIM_STORE_SECRET`). They are an R2 API token scoped to the store bucket. Agents need no
  credentials: they read the store's public address.
- The app builds whose manifests should be re-recorded (arm64 iOS simulator builds).

## 1. Check that x86Sim supports it

x86Sim lists what it can fetch:

```sh
~/.local/share/stupidsim/x86sim/AppRun x86sim runtime list ios
```

If the version is missing, or x86Sim's release notes say a newer x86Sim is needed for it, update
x86Sim first:

1. Download the new release's AppImage and `SHA256SUMS` from
   https://github.com/x86sim/x86sim/releases.
2. Update `X86SIM_VERSION` and `X86SIM_SHA256` in `linux/stupidsim-linux` and
   `packaging/linux/install.sh` (they must match).
3. Run the whole of this runbook against the new x86Sim, including step 3 for the iOS versions
   already in the store: the store records the x86Sim version it was built with, and
   `stupidsim-linux setup` refuses a mismatch, so every published runtime needs rebuilding.

## 2. Fetch the runtime and make a template device

```sh
A=~/.local/share/stupidsim/x86sim/AppRun
$A x86sim runtime fetch <build>                    # e.g. 24C114; about 8 GB, then unpacking
$A aot --device ~/.local/share/x86sim/var/device-a64-agent build --full   # after the device below exists
$A x86sim device create --model "iPhone 17 Pro" --ios <version> agent
stupidsim-linux boot --device agent                # the first boot takes a few minutes
```

The device is the template every agent's device starts from, so keep it free of apps and personal
data. Its name stays `agent`: `stupidsim-linux setup` creates devices under that name by default.

## 3. Verify stupidsim on it

Run through the commands with `--verify`, on the device, before recording anything. Install the
test host (`scripts/build-test-host.sh` on a Mac, then copy `build/testhost/ODHTestHost.app`
across):

```sh
export X86SIM_DEVICE=~/.local/share/x86sim/var/device-a64-agent
stupidsim doctor
stupidsim ui-tree booted --springboard --labelled      # icons are Buttons, the search pill a Slider
$A x86sim install ODHTestHost.app
$A x86sim launch io.opendevicehub.testhost --request-notifications
stupidsim tap booted --label Allow --springboard --verify
stupidsim rotate booted landscapeLeft --verify && stupidsim ui-tree booted --labelled   # LANDSCAPERIGHT
stupidsim rotate booted portrait --verify
stupidsim button booted home --verify
stupidsim push booted --bundle-id io.opendevicehub.testhost --title T --body B --verify
stupidsim notification booted dismiss --match T
stupidsim paste booted "check ✓" && stupidsim copy booted
stupidsim type booted "abc" --verify                     # with a text field focused
stupidsim screenshot booted /tmp/check.png
$A x86sim uninstall io.opendevicehub.testhost
```

Compare the in-device helper with the Mac on the same screens. Run `stupidsim ui-tree --json` on a
Mac simulator of the same iOS version, and the helper on that simulator (`scripts/build-guest.sh
--mac-simulator`, then `xcrun simctl spawn <udid> build/guest/stupidsim-guest tree`). Labels,
identifiers, values and frames should match. Roles come from accessibility traits, and a new
iOS can add traits.

If something differs, fix it in `guest/stupidsim-guest.m`, rebuild with `scripts/build-guest.sh`,
commit `guest/bin/stupidsim-guest`, and note what changed and on which runtime in
`docs/implementation-notes.md`. What tends to move between iOS versions:

- the attribute numbers (the value is 2006);
- the trait bits mapped to roles (10, 18 and 22);
- `defaultSystemShellCurrentApplications` and `explorerElements`;
- the banner's `NotificationShortLookView` identifier;
- the pasteboard entitlement name.

## 4. Record the base manifest

The base is what every session needs: booting, SpringBoard, the in-device helper, the keyboard, the
pasteboard, installing an app and a notification. Trace it on the template device:

```sh
stupidsim-linux trace begin --device agent       # marks every runtime file unread and boots
# then, against the booted device: the springboard tree; open Settings and General; Spotlight
# (swipe down on the home screen) and type; paste and copy; install the test host, allow its
# notifications, push one from the home screen, show and dismiss it; rotate; a screenshot;
# uninstall the test host
stupidsim-linux trace end base --device agent
```

`scripts/build-store.sh`-style automation of exactly these steps is in the PR that introduced the
store; keep the steps the same between versions so manifests stay comparable. Trace on a
file system that records access times (relatime, the default, works; `trace begin` refuses
noatime).

## 5. Record each app's manifest

See [app-manifest.md](app-manifest.md). Re-record every app in the store, with `--base base`,
because file paths and sizes change between iOS versions.

## 6. Build and publish

```sh
stupidsim-linux shutdown --device agent
export STUPIDSIM_STORE_DIR=~/store && rm -rf ~/store
stupidsim-linux store build --device agent --manifest base --manifest <app> ...
stupidsim-linux store lazy --device agent     # every file as range-readable blobs, ~15 min
set -a; . ~/.config-store-writer.env; set +a
stupidsim-linux store publish
```

`store build` writes, for this runtime:

- the skeleton (directories, symlinks, the simruntime's own files);
- a pack per manifest;
- the translation cache;
- the template device and its original path;
- `current.json`.

Then fold what a new machine's first boot opens into the base. Publish the store as above, then
run a fresh setup and boot on another machine or user (step 7). Trace that first boot: it is
the first boot of that device, so `layers/opened.txt` already holds everything it opened beyond
the packs. Append those paths, under RuntimeRoot, to the base manifest. Then rebuild just that
pack with `stupidsim-linux store pack --manifest base --device agent` and publish it again. A
fresh first boot should then fetch nothing (`grep -c ' fetched ' .../layers/lazy.log`).

`store lazy` writes `lazy/` (the index and the blobs every other runtime file is fetched from on
first use) and `packs/metadata.tar.zst` (every bundle's Info.plist and InfoPlist strings, which a
new machine's first boot reads for all of them). Setup refuses a runtime without them.

`publish` uploads `current.json` last, so sessions keep fetching the previous runtime until
everything is in place. To make the new runtime available without making it the default, delete
`current.json` from `~/store` before publishing; sessions then opt in with
`stupidsim-linux setup --runtime <runtime>`.

Rolling back means re-uploading the previous `current.json`. The previous runtime's files stay
under their own `runtimes/<runtime>/` prefix until removed.

Two more objects live at the store's root, outside `store build`, and are uploaded with curl
(`--aws-sigv4 "aws:amz:auto:s3"` and the writer credentials) whenever they change:
`cloud-setup.sh` (from `linux/`) and `packages/stupidsim-linux-x86_64.tar.gz` (the release's Linux
tarball from `scripts/build-linux.sh`, which is what `cloud-setup.sh` installs).

## 7. Check setup from nothing

On a machine, or as a user, with no x86Sim data:

```sh
STUPIDSIM_APPS="<app>" bash linux/cloud-setup.sh
stupidsim-linux boot
stupidsim ui-tree booted --springboard --labelled
```

Then once in a real cloud session: a one-off cloud routine running the same commands and reporting how long each step took. The setup has to
finish in about five minutes for Claude Code's setup cache to keep it. If it doesn't, the base
pack has grown and the trace should be looked at.

## 8. Update the docs

- `docs/implementation-notes.md`: the runtime verified, the setup timings, and anything the
  helper needed.
- `README.md` and `skills/stupid-simulator/SKILL.md` where they name the iOS version.
- Remove a runtime from the store once no environment pins it with `--runtime`
  (`runtimes/<runtime>/` in the store bucket).
