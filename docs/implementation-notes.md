# Implementation notes

What stupid simulator changes relative to upstream [OpenDeviceHub](https://github.com/Mastersam07/OpenDeviceHub) (forked from `dev` at `e50f07f`,
v0.2.0), and what has been verified where. Newest first.

## The lazy runtime's server keeps entries and directory listings

- **What it fixes.** In a Claude Code cloud session (4 vCPU, kernel 6.18, libfuse 3.14) the Python
  FUSE server was the busiest process: 17 CPU s during a 60 s boot and 29 by the end of the first
  app run, more than SpringBoard. `STUPIDSIM_LAZY_STATS=1` showed why: 38,101 `readdir` calls in
  the boot (32.6 s of handler time) and 62,660 by the end of the run, each one a SQLite query.
  libfuse 3.14's high-level API cannot let the kernel cache listings (`fuse_lib_opendir` drops the
  `cache_readdir` flag), and overlayfs keeps a merged directory's listing only while it is open, so
  every `opendir` of a runtime directory reached the server.
- **The change.** The index never changes while mounted, so `LazyRuntime` keeps each entry and each
  directory's names in a dict after the first query.
- **Measured** in the same kind of session: `readdir` handler time in the boot 32.6 -> 5.8 s, the
  server's CPU 17 -> 9 s for the boot and 29 -> 17 s to the end of the first run. Boot and first
  run times did not improve beyond the variation between sessions (69 and 60 s against 60 and
  45 s; boots have ranged 48-70 s): the server's CPU was not what the boot waited on.
- **Left:** about 10,000 distinct `getattr` lookups (0.7 ms each, the GIL included) and `open`
  calls that wait on unit fetches.

## One boot at a time, and what a cached cloud environment does to boot time

- **`stupidsim-linux boot` waits for a boot already in progress.** An agent can start a boot in the
  background while it builds, and `stupid-app run --simulator` then boots the same device when its
  build is done (it sees no input socket yet). Two `boot-a64.sh` runs on one device would start it
  twice. `boot` now takes an exclusive `flock` on `.<device dir>.boot.lock` next to the device; a
  boot that finds it held logs that it is waiting, and once it gets the lock it returns if the
  device is up, else boots it itself. The kernel releases the lock however the holder exits.
  Verified in a Claude Code cloud session (4 vCPU): a background `boot` plus an immediate
  `stupid-app run --simulator` installed and launched the test app once the background boot was
  done, with no second boot.
- **Booting while building saves little there.** Background boot plus `run --simulator` took 106 s
  from the boot's start to the app on screen (the boot itself 65 s); one after the other it is
  48-63 s plus 56-62 s. Both are CPU bound on 4 vCPUs, so each slows the other. Not worth a flag.
- **A Claude Code environment's cached setup is slower than running setup in the session.** The
  environment caches its setup script's result as a disk snapshot (stupid-app's setup: 136 s, so it
  is cached, and a session then starts in about 4 s). But a restored snapshot reads each block the
  first time at 21-56 MB/s with one reader and about 77 MB/s at best with 32, and a boot reads
  5.2 GB: 240-256 s instead of 62 s, and the first build ~50 s slower (cold toolchain). From session
  start to an app on screen: 4:47 without the cache, 6:38 with it.
  - What the boot reads: 4.6 GB is x86Sim's translation cache. The first process of a layout reads
    the whole AOT image (`.aot`, 2.16 GB) to build its relocated shared copy (`.aot.<hash>.map`,
    1.38 GB, and `.map.idx`, 454 MB; the hash covers the image's inode and mtime, dynarmic
    `a64_emit_x64.cpp`), and every boot copies the `.map` into a huge-page tmpfs. Then 2.0 GB of
    runtime files (654 MB of the 2 GB dyld shared cache) and 205 MB of device data. Measured with
    `mincore` after a cold boot (the image has no `fincore`).
  - Booting once in the setup script (`stupidsim-linux boot; stupidsim-linux shutdown`) keeps the
    `.map`/`.idx` and x86Sim's prefetch lists in the snapshot and fits the time limit (168 s). A
    session that ran that setup itself then booted in 41 s with 6 MB read, but one restored from the
    snapshot still read 3.7 GB and took 256 s: random page faults on the cold disk are slower still.
    Reading the boot's big files first with 32 threads ran at ~38 MB/s (220 s), then a 75 s boot.
  - So the documented path stays: run the setup script in the session.

## A guest server for the accessibility tree

On Linux every `ui-tree`, `tap --label`, hit test and banner read started `stupidsim-guest` in the
device with `x86sim spawn`. Starting it was about half of each read: on the WSL 2 box (20 cores) a
trivial guest command took 0.27 s and a tree 0.46–0.69 s; in a 4-vCPU cloud session a tree took
~1 s.

- **What changed.** stupidsim now starts `stupidsim-guest serve <socket>` the first time it needs
  the guest and keeps it for the boot. Each request is a connection carrying one line, a JSON array
  of the command and its arguments; the answer is the same JSON the one-shot program prints, without
  the marker lines, and the server closes the connection after it. AXRuntime is called on the
  server's main thread, as before; connections are accepted and answered one at a time on another.
- **The socket** is `data/stupidsim-guest-<hash>.sock` beside simhid's, the guest binding it as
  Darling shows the Linux root (`/Volumes/SystemRoot` + the path). The hash is of the guest
  program's bytes, so a newer stupidsim never asks an older server. A path too long for the guest's
  104-byte `sun_path` moves to `/run/user/<uid>`.
- **Starting it.** x86Sim's `spawn` returns once its timeout passes and leaves the program running
  ("still running after N s"), so stupidsim spawns the server with a 2 s timeout and waits up to 30 s
  for its socket. A lock file beside the socket keeps two commands from starting one each. Anything
  but "still running" means the server ended, and its output is the error. After a reboot the old
  socket refuses connections and a new server is started.
- **The pasteboard still starts a program of its own.** Through the server UIPasteboard set the text
  but read back an empty string every time, while a fresh program read it; the difference is that
  the server has loaded AXRuntime and turned on accessibility automation first.
- `STUPIDSIM_GUEST_SERVER=0` starts a program per command, as before.
- **Verified on the WSL 2 box** (x86Sim 0.5.0, iOS 27.2, Settings in front):
  - `ui-tree`: 0.14–0.15 s, against 0.50–0.51 s starting a program each time, with the same output;
  - a hit test (`ui-tree --at`): 0.08 s;
  - `tap --label General --verify`: 0.94–0.96 s (1.24–1.29 s in 0.8.4, 2.0–2.1 s in 0.8.3);
  - the first read after a boot, which starts the server: 2.35–2.49 s, once;
  - two `ui-tree`s at once on a fresh boot: both answered the same, and one server ran;
  - `paste` then `copy`: the text came back; after a reboot the server started again.
- **Verified in a fresh Claude Code cloud session** (4 vCPU, branch built there, Settings in front):
  - `ui-tree`: 0.30–0.37 s, against 0.97–1.17 s with 0.8.4;
  - `tap --label General --verify`: 1.66–2.02 s, against 2.83–3.11 s;
  - the first read after the boot, which started the server: 2.63 s; `paste` then `copy` worked.

## `--verify` waits for a moving screen instead of giving up

`--verify` gave up at once, with exit 3 and without sending the input, when more than a quarter of
the screen was changing during its baseline. The message did not say that nothing was sent.

- **Where agents met it.** After a tap focuses a text field, the on-screen keyboard slides up 2–4 s
  later (Safari's address field, x86Sim 0.5.0, iOS 27.2, on the WSL 2 box). `type --verify` started
  during the slide exited 3 and the field stayed empty. Typing itself works: straight after the tap,
  after the keyboard settled and after focusing again, the text arrived ("abc", "xyz", "def", read
  back with `ui-tree`).
- **Now** a baseline that finds the screen moving that much is taken again every 0.2 s until the
  screen has settled, for up to 5 s, and only then is the input sent. Settled is stricter than the
  first baseline's bar: under 1% of pixels changing (a blinking cursor is about 0.01% of an iPhone
  17 Pro's screen), so input is not sent while an animation is still winding down. A screen that
  does not settle still exits 3, and the message now says nothing was sent. A first baseline under
  the quarter bar behaves as before.
- **The first text typed after a boot is slow to appear.** In a 4-vCPU cloud session, `type hello
  --verify` into a small SwiftUI app's field exited 2 after 4.1 s, yet the field held "Hell" 3 s later
  and every key arrived: iOS drew about a character a second while it loaded its keyboard code under
  translation. The next `type --verify` passed at once. `type` now waits up to 10 s for the change by
  default (other commands 3 s); the wait ends at the first change, so this costs only a real
  failure's time. `--verify-timeout` still overrides it.
- **What it cannot tell apart.** Motion that is not the input's and outlasts the baseline, such as a
  drag driven at the same time from another command, passed `--verify` before this change and still
  does.
- **Verified on the WSL 2 box** (Safari): typing 0, 2 and 3.5 s after tapping the address field, four
  times each, exited 0 with "abc" in the field; 0.8.4 exited 3 once, leaving it empty.
  `key left --verify` on a still Settings screen, which changes nothing, still exits 2 (2.1 s).

## `--verify`: no baseline wait on a still x86Sim screen

`--verify` takes three baseline frames 400 ms apart before sending the input, to learn which pixels
were already changing (a blinking cursor). That is 0.8 s on every verified input.

- **x86Sim's frame ring publishes only when the screen changes**, and stamps each frame with its
  publish time (CLOCK_REALTIME, the slot's second u64). An idle home screen published no frame in
  5 s (x86Sim 0.5.0, iOS 27.2).
- **So on x86Sim a still screen is known without watching it.** `SimulatorHost.screenStillFor`
  reads how long ago the newest frame was published; when that is 1 s or more (longer than the
  0.8 s the baseline spans) one frame is the baseline. A second reading after copying that frame
  falls back to the spaced baseline if a frame arrived meanwhile. Xcode's host answers nil and
  keeps the spaced baseline.
- **Verified on the WSL 2 box** (x86Sim 0.5.0, iOS 27.2, Settings):
  - `tap --label General --verify`: 1.24–1.29 s, against 2.04–2.10 s with 0.8.3;
  - a scroll with `--verify`: 0.23 s, against 1.03 s;
  - `key left --verify` with nothing focused still exits 2 ("did not change"), in 2.9 s with
    either build.
- **What an agent's step costs in the cloud** (4 vCPU, a small SwiftUI test app built with
  stupid-app, 0.8.3): the app answers a tap in 0.2–0.55 s, but `tap --label "Row 5" --verify`
  took 2.4–2.7 s: ~1 s of `ui-tree` to find the label, the 0.8 s baseline, then the change.

## How responsive the cloud device is

Measured in fresh Claude Code cloud sessions (4 vCPU, 16 GB, x86Sim 0.5.0, iOS 27.2, 0.8.3), from
the frame ring: the time from an input command starting to the first visible change, and to the
screen settling. Medians of 5–6 inputs.

| | Settings (iPhone 17 Pro) | small SwiftUI app |
|---|---|---|
| tap that pushes a page | 1.4–1.8 s / 2.1–2.3 s | 0.55 s / 1.32 s |
| tap that changes a row in place | | 0.20 s |
| edge swipe back | 0.5–0.7 s / 1.3–1.6 s | 0.49 s / 1.14 s |
| frames/s while animating | 7–12 | 12.5 |

- **Settings is heavy**: its own translated code and Metal on lavapipe (`mtlvk`) took ~16 CPU s
  each over ten navigations, with 2.6 of 4 cores busy; each frame waited 170–205 ms on lavapipe.
- **Things that did not help**: `--metal software` (19 frames/s but taps 2.3 s and more CPU);
  Reduce Motion (no change); a 3x smaller screen (iPhone SE: 28 frames/s and 49 ms a frame, but a
  tap in Settings still took 1.2 s). The tap delay in Settings is mostly the app's translated code.
- `x86sim-aot update` fails after 19 s ("VectorKit: constant pool conflict at 0x20"), so the
  precompiled image's 49–67 stale chunks (SpringBoard and Foundation among them) cannot be
  rebuilt here.

## Linux boots: no fixed 90 s wait

Every Linux boot took 96–100 s: a first boot, a reboot, one with the page cache dropped, and one
with the `minimal` feature preset. That was a fixed wait, not boot work.

- **The cause.** `stupidsim-linux boot` runs x86Sim's `cli/libexec/arm64/boot-a64.sh`, which
  starts the device and then sleeps `SECS` seconds (90 when unset) before printing a summary and
  returning. Only then did `x86sim wait home` start polling the frame. x86Sim's own launcher
  passes `SECS=20` (`tools/launcher/core/src/instance.rs`, 0.5.0).
- **The fix.** `boot` passes `SECS=20` too, and `wait home` does the waiting. What the script
  runs after the sleep is a report: spawn counts, cgroup containment and parked helpers. The
  launchd log it tails for `SECS` + 2 s is only read for diagnostics (x86Sim's launcher and
  `bootwatch.sh`).
- **A frame left from an earlier boot cannot pass `wait home`.** A shutdown (`A64_STOP_ONLY`)
  deletes the device's frame ring, and the next boot makes a new one.
- **Profiled in a fresh Claude Code cloud session** (4 vCPU, 16 GB, x86Sim 0.5.0, iOS 27.2),
  sampling per-process CPU every 5 s:
  - before the fix, all 4 CPUs were busy from about 20 s to 45 s, and fewer than 2 were busy from
    70 s on, while the boot still returned at 97–99 s;
  - with the fix, a first boot took 52 s and a reboot 32 s (34 s with `minimal`). After each,
    `stupidsim ui-tree` answered with the home screen at once, and nothing failed to fetch.
- **A reboot with a dropped page cache took as long as a first boot** (98 s against 99 s, before
  the fix). So a session that resumes a snapshot of a machine that has already booted once would
  probably not boot faster than a first boot does.
- **How responsive a booted device is** (same kind of session, measured from the frame ring after
  each input; times from when the command started):
  - a tap shows on screen after 1.1–2.2 s: opening Settings, or pushing General. The command
    itself returns in ~0.15 s;
  - an edge swipe back shows after 1.1–1.7 s, a scroll after 0.2–0.9 s;
  - animations publish 6–18 frames/s, and an idle screen publishes none (frames are sent on change);
  - `ui-tree` takes ~1 s (1.4 s the first time), `screenshot` 0.26 s;
  - `tap --label General --verify` takes 4.9 s in all (the tree lookup, the tap, then waiting for
    the change), and `type abc --verify` 4.1 s.

  So it is not realtime. It suits an agent, which waits with `--verify`, but a person would see
  each input land a second or two late, with choppy animation.
- **Where the CPU goes in a boot:** SpringBoard (~17 CPU s), x86Sim's Python helpers (~16), mtlvk
  (~13, Metal on lavapipe) and darlingserver (~5). Nothing else used more than 3.

## First boot: keeping LaunchServices' database

A new machine's first boot took ~150–175 s on the WSL 2 box, against 96–100 s for every later
boot. In a 4-vCPU cloud session it took 175–222 s. The difference was LaunchServices: `lsd` spent
~65 CPU seconds re-registering every bundle on the first boot, and none on later ones.

- **The cause was setup's repath.** Setup moves the template device to this machine's path with
  x86Sim's `device-repath.py`. That tool deletes lsd's csstores (`data/var/db/lsd/*.csstore`)
  whenever they contain the old path, because the format cannot be rewritten in place. lsd then
  rebuilds them at boot from every bundle.
- **Ruled out**, on the same box, by changing one thing per boot:
  - a new `/etc/machine-id`;
  - the runtime's top layer copied again (new inodes);
  - the device directory copied again;
  - restored directory times;
  - a remount;
  - a cold page cache.

  All of these booted in 100–105 s with lsd idle. Only putting back the device's csstores as
  setup left them (`SystemDataOnly` without `System-…csstore`) brought back the 65 s. So did the
  template's original store, which names another path.
- **The fix.** The store's template device is now made at a cloud session's path:
  `/root/.local/share/x86sim/var/device-a64-agent`, root's, since setup runs as root there.
  - It is a lazy machine's device after one boot, shut down and packed with `store warm`, with
    both stores; `store warm` keeps them.
  - Setup skips the repath when the template's path is the device's. That is needed, not only
    faster: `device-repath.py` refuses such a device ("DEVICE is the base device"), so 0.8.1 and
    earlier fail to set up a new device from this template.
  - Machines at any other path still repath, and their first boot still re-registers.
- **Measured on the WSL 2 box**, fresh machines as root:
  - with the previous template, first boot 152 s (lsd 65 s);
  - with a template made at /root, first boot 103 s (lsd 0 s), and a reboot 100 s.
- **Verified in a fresh Claude Code cloud session** (4 vCPU, 16 GB) with stupid simulator 0.8.2 and
  this template, set up as the README says:
  - setup took 81 s and the first boot 96 s, against 175–222 s before; lsd used 0 CPU s;
  - Settings came to the front in 8 s and Safari in 27 s;
  - 49 units were fetched and none failed.

## x86Sim 0.5.0

`stupidsim-linux` and `packaging/linux/install.sh` pin x86Sim 0.5.0 (was 0.3.0).

- **The interfaces stupidsim uses did not change.** Between 0.3.0 and 0.5.0 these are identical:
  `fbring.py` (the frame ring), `simtouch.py` (simhid's lines), `mksimdevice.py` (sim.env),
  `device-repath.py`, the `x86sim` command and simfb. `boot-a64.sh` only gained on-demand
  daemons.
  - One of those daemons is `dmd`: without it, ScreenTimeAgent retried a failing connection
    for good, at ~90% CPU. That was the spin seen on first boots.
  - 0.4.0 also removed iokitd's fallback to X display `:0`.
- **Darling now runs from /opt/x86sim ("system" mode).** x86Sim runs Darling either from
  `/opt/x86sim` (a setuid launcher, installed by its `install-helper.sh`) or through an
  unprivileged user namespace ("userns" mode), and picks system mode when the installed build
  matches.
  - In userns mode, 0.5.0 could not start a container on Ubuntu 24.04 under WSL 2 (kernel
    6.18), as root or as a user: "Cannot switch to your user and group ids", then "Timed out
    waiting for shellspawn in container". `aot build` failed every chunk the same way, and
    quietly assembled an image from the previous version's chunks. Its updated Darling launcher
    switches ids on start; our unconfirmed guess is that this needs `setgroups()`, which
    `unshare -r` denies.
  - `stupidsim-linux` therefore installs the matching Darling into `/opt/x86sim` (`ensure_darling`,
    at setup and boot) when it runs as root, as setup does in a cloud session. Otherwise it fails
    with the `sudo` command to run.
  - The extracted AppImage's directories are mode 700, and the helper only removes write bits,
    so the installed tree is made readable (`chmod -R a+rX`). Without that, a non-root user
    could not reach the launcher, and x86Sim fell back to userns mode for them.
- **The store's warm parts are versioned per x86Sim** (`runtimes/<runtime>/warm/x86sim-<version>/`).
  The translation cache and the template device depend on the translator, so 0.5.0 needed new
  ones.
  - stupidsim 0.7.0 and earlier keep reading the 0.3.0 parts from `warm/` unversioned, with
    `current.json`'s `"x86sim": "0.3.0"`. Neither was touched, so machines on 0.7.0 kept working.
  - Setup no longer checks `current.json`'s `x86sim`. It fetches its own version's
    `device.json` first, and says so when the store has none.
  - An existing machine re-fetches the translation cache when its x86Sim version changes (the
    `jitcache-x86sim-<version>` part), and re-extracts the AppImage when its checksum changes
    (the extraction's `.stupidsim-sha256`, as `install.sh` already did).
  - `store warm` builds only those parts. `store build` no longer writes `current.json`.
- **Verified on the WSL 2 box, as a normal user, in system mode, on iOS 27.2 (24B8117).**
  - `aot build --full` built all 1,537 chunks in 87 s, a 1,316 MB image.
  - The template device booted in 95–96 s.
  - Every stupidsim check passed: `doctor`, the SpringBoard tree, installing the test host and
    allowing its notifications with `tap --verify`, rotation both ways, Home, `push --verify`,
    dismissing the banner, paste and copy, a screenshot, and Settings → General.
  - The warm parts are 0.74 GB (translation cache) and 1.00 GB (device).

## Fetching runtime files on first use (`stupidsim-linux`, lazy runtime)

A machine set up from the store used to get only the runtime files that traces recorded. An app
that needed anything else installed, but never came to the front and logged nothing useful.
Safari, Maps and the other system apps never opened. Now the rest of the runtime is fetched
the first time something opens it, so any app runs without a recorded manifest.

- **The runtime is an overlay of two layers, mounted at `extracted/` before boot.**
  - On top is `layers/local`: the skeleton and the packs setup fetched (base, the bundle metadata
    pack, any `--app`).
  - Below it is a FUSE file system (`layers/lazy`, `stupidsim-linux lazy-serve`). It answers
    every entry of the whole runtime from an index, and fetches a file's unit into
    `layers/fetched` on its first open.
  - x86Sim's own writes into the runtime (its per-device LaunchAngels directory, the extracted
    `Metal.framework/Metal`) land in `layers/upper`.
  - Files on the top layer never reach FUSE, so the dyld shared cache and everything traced are
    read at kernel speed.
  - Mounting needs root (overlayfs and FUSE). `boot` mounts, or fails naming the command.
- **Darling sees the mount only if it exists before `darlingserver` starts.** x86Sim's Darling
  runs in its own user and mount namespaces, made by copying the host's mount table when its
  server starts (checked through `/proc/<darlingserver>/mountinfo` on the WSL 2 kernel
  6.18.58.1). The guest reaches the runtime through `/Volumes/SystemRoot/<host path>`, which is
  that copied table. So `mount` refuses while a `darlingserver` of the same user is running.
- **The FUSE server is Python's standard library over libfuse 3's high-level API through
  ctypes.** That keeps `stupidsim-linux` a single script with no packages. The struct layouts are
  libfuse 3.14's (Ubuntu 24.04), for x86_64.
  - It is read-only, with `kernel_cache` and day-long entry, attribute and negative timeouts,
    since a runtime never changes.
  - Metadata comes from a SQLite index (`(parent, name)` primary key, so a lookup and a directory
    listing are one indexed query), opened read-only per libfuse thread.
  - During a boot with nothing to fetch it answered 950 `getattr` calls in 0.1 s in total, and
    served no reads (measured with `STUPIDSIM_LAZY_STATS=1`, which logs counts and time per call
    kind every 30 s).
- **Store layout: range-readable blobs** under `runtimes/<runtime>/lazy/`.
  - A unit is the files of the innermost bundle a file is in, or of its directory outside
    bundles. Each `.lproj` is its own unit, so unused languages are never fetched.
  - Units are taken in path order and split at 32 MB uncompressed. Each one is a zstd-compressed
    tar, and zstd's frame checksum makes a damaged range fail to unpack.
  - Units are appended into blobs of at most 4 GiB, since R2 takes at most 5 GiB in one PUT.
  - The index (`index.sqlite.zst`) records each unit's blob, offset and length. One fetch is one
    HTTP range GET piped through `zstd -d | tar -x`, the same tools setup already needs.
  - Built by `store lazy` from a machine with the whole runtime. On iOS 27.2 (24B8117):
    819,952 entries, 588,200 files in 214,058 units, 2 blobs, 8.30 GB, a 9.8 MB index, in
    14 minutes on 20 cores.
- **Failing loudly.** A unit that cannot be fetched fails the open with EIO, and
  `layers/lazy.log` names the unit, the byte range and curl's or tar's error. A unit that
  unpacks to a different number of files than the index lists also fails, as does a file whose
  size differs from the index. Every fetch is logged with its size and time.
- **The base includes what a new machine's first boot opens.** Traced on a lazy machine
  (`layers/opened.txt` after a fresh setup's first boot), it adds 698 files (257 MB) to the 6,158
  of the earlier base: the pack went from 1.78 GB to 1.87 GB.
  - With it, a fresh setup's first boot on the WSL 2 box fetched nothing and took 178 s (238 s
    before).
  - Afterwards the test app, installed with no manifest, came to the front 41 s after launch,
    and its settings opened with `tap --verify`. Safari took 26 s. That was 49 units in all, and
    none failed.
- **Bundle metadata is prefetched as its own pack (`packs/metadata.tar.zst`).**
  - On a new machine's first boot, LaunchServices registered every bundle again: setup's repath
    deleted its database (see "First boot: keeping LaunchServices' database"). Registration reads each
    bundle's `Info.plist` and its `InfoPlist.strings` in every language.
  - With only the FUSE layer below, that first boot fetched 26,642 units one by one (25,656 of
    them for an `InfoPlist.strings`), 0.4 GB compressed and 6 minutes from a local disk.
  - `store lazy` therefore also writes every bundle's metadata as a pack, fetched with the base:
    `Info.plist`, `InfoPlist*` strings and loctables, intent definitions, App Intents metadata
    and `version.json`. That is 79,399 files, 46 MB, 6 MB compressed.
  - With it, the same first boot fetched 691 units, taking 9.3 s of fetching in all.
- **Verified on the WSL 2 box, as root in an empty home directory, from a store directory on
  the same disk** (`STUPIDSIM_LOCAL_STORE`, read through curl's `file://`, which honours ranges):
  - setup took 163 s;
  - the device booted to the home screen;
  - a SwiftUI test app with SwiftData and two package dependencies was installed with **no
    manifest fetched**. It came to the front with its demo data, `tap --label Settings
    --verify` opened its settings, and 34 units were fetched for it;
  - Safari launched and showed its start page, which it never did on a runtime pruned to a
    trace;
  - nothing failed to fetch.
- **Slow boots on the WSL 2 box were its X server, not the lazy runtime.** A boot of the lazy
  runtime took 193–370 s there, against 91 s for the pruned runtime. A device on the whole,
  unmounted runtime was as slow (211–261 s).
  - **Darling's iokitd opens an X display at startup.** Its main thread calls `XOpenDisplay()`
    (`poll ← xcb_connect_to_fd ← XOpenDisplay` in gdb) before it answers any Mach message.
    Every guest process that touches IOKit waits for it, and the rest of the boot queues behind
    those processes. Examples: lsd's main thread, UserEventAgent's alarm plugin ("took 195.148
    s"), securityd and backboardd, and logd's listeners.
  - **x86Sim 0.3.0's iokitd falls back to `:0` when `DISPLAY` is unset.** That is the
    `/tmp/.X11-unix/X0` socket, or TCP `127.0.0.1:6000` without it. Upstream removed the
    fallback in v0.4.0. So `boot` running x86Sim without `DISPLAY` (which it still does: the
    screen comes from simfb) does not avoid the call on 0.3.0.
  - **On the box, nothing answered.** WSLg's X server crash-looped (weston, a segfault in
    `rdp-backend.so` every ~102 s, since its RDP client cannot attach on a machine used only over
    SSH), and its X0 socket accepted and never replied. Without WSLg, the TCP fallback hung
    instead, because WSL's mirrored networking dropped connections to closed loopback ports
    rather than refusing them.
  - **The fix was on the box:** WSLg off (`guiApplications=false`) and NAT networking. The
    connection to port 6000 is then refused in 15 ms, and a boot right after restarting WSL
    reached the home screen in 96 s.
  - **Cloud sessions never waited.** They have no X0 socket, and their network refuses a closed
    port.
  - **The ~33 s silences in launchd's log were not timeouts.** x86Sim's jetsam.py was killing
    daemons idle for 30 s while everything waited.
  - Hiding the untraced launchd plists (overlay whiteouts) was tried along the way and is not
    needed. The installed test app that seemed to vanish then had in fact not been installed
    since a fresh setup.
- **Verified in a fresh Claude Code cloud session** (4 vCPU, 16 GB, store read through R2's S3
  endpoint). It used `STUPIDSIM_LINUX` (`cloud-setup.sh` installs that file instead of the packaged
  `stupidsim-linux`, for testing a branch).
  - Setup took 120 s, the base pack last at 106 s.
  - Boot took 404 s. It fetched 697 units, summing 252 s of fetching: about 0.36 s each from
    R2, against 0.01 s from a local disk, so in the cloud the first boot's fetches are a large
    part of it.
  - Safari came to the front with its start page, and Maps in 27 s with its location prompt.
  - Nothing failed to fetch, and 5.2 GB of memory was in use.
  - With the first boot's files in the base, a second fresh session took 123 s to set up and
    222 s to boot, fetching 7 units on the way. Settings came to the front in 13 s, Safari in 35 s
    and Maps in 25 s, with 70 units fetched in all and none failed.
- **A lazy machine traces without the whole runtime.** The FUSE server appends each file's first
  open to `layers/opened.txt`.
  - `trace begin` on a lazy runtime remounts it with that list emptied.
  - `trace end NAME` writes the manifest from it: the files opened beyond the fetched packs,
    which is what an app's pack should add.
  - Recording a manifest therefore no longer needs the machine with the whole runtime. Only
    packing it does (`store pack --manifest NAME`, one pack without rebuilding the store).
- Machines set up before this change keep the old layout (`extracted/` a plain directory);
  setup refuses such a runtime and asks for it to be removed. `cloud-setup.sh` installs
  `fuse3`.

## Fast setup on throwaway Linux machines (`stupidsim-linux`)

A machine with nothing on it took about 20 minutes and 36 GB to get to a booted x86Sim device:
- 8 minutes downloading the 8.3 GB iOS 27.2 runtime from Apple;
- 7 minutes unpacking it to 20 GB;
- 80 seconds of ahead-of-time translation;
- 3.5 to 5 minutes for a new device's first boot.

Claude Code cloud sessions have about 30 GB of disk, 4 vCPUs and 16 GB of memory. Their network
proxy blocks Apple's CDN unless the environment allows it. Their setup script is cached (as a
file system snapshot) only when it finishes in about five minutes. So the cold path cannot work
there at all. `linux/stupidsim-linux` (Python's standard library, curl, tar and zstd) and
`linux/cloud-setup.sh` make it a few minutes from a private store.

- **Only the runtime files tests read.** `trace begin` sets every runtime file's access time to
  2000-01-01, which makes the file system record the next read (relatime updates an access time
  that is older than the modification time), and boots the device. `trace end <name>` lists the
  files read since. It refuses a noatime mount, which would record nothing.
  - On iOS 27.2 (24B8117) the base was 6,158 of 588,147 files, 5.4 GB, 1.78 GB compressed. It
    covers booting, SpringBoard, the in-device helper, Settings, Spotlight typing, the
    pasteboard, an app install, a notification and rotation, and is mostly the dyld shared cache.
  - A SwiftUI test app with SwiftData and two package dependencies added 111 files, 0.14 GB.
- **A runtime pruned to a trace boots and runs what was traced, and nothing else.** Built from
  hard links to just the files one session read (5.1 GB, 1.8 GB compressed), it cold-booted in the
  same 3 minutes, and the test app, the test host, the SpringBoard tree and the pasteboard all
  worked. Safari, Photos, Calendar, Messages, Files and Maps, which the trace never opened, did not
  launch at all within 25 s; on the whole runtime they opened. An app therefore needs its own
  manifest (`docs/runbooks/app-manifest.md`).
- **x86Sim writes its own files into the runtime.**
  - At boot it writes `LaunchAngels/.x86sim-device-a64-<name>/` and removes it at shutdown. Those
    paths are left out of manifests, and a listed file that has gone is reported and skipped when
    packing.
  - `Metal.framework/Metal`, extracted from the dyld cache on the first boot, stays, and travels
    in the base pack.
- **The warm state is x86Sim's translation cache and a device that has booted once.**
  - The cache is 0.6 GB compressed: the AOT image, its work directory (installing an app updates
    the image from it) and each process's live translations.
  - The device is 1.0 GB, without sockets and os_log's `var/db/uuidtext`. Those tables hold the
    old path in a form `device-repath.py` cannot rewrite, and the device rebuilds them.
  - x86Sim's own `device-repath.py` moves the device's absolute paths to its new place, as x86Sim
    does for its clones, and `mksimdevice.py` rewrites `sim.env` at every boot.
- **The store** is an R2 bucket, readable anonymously at `https://stupidsim-store.stupidtech.net`
  (an R2 custom domain; the bucket is not listable there), so setup needs no credentials. Reads
  go there by default (`STUPIDSIM_PUBLIC_STORE` overrides it); a presigned map or store credentials
  still take precedence. It was private until this change; serving Apple's runtime files publicly
  was the maintainer's decision.
  - Claude Code cloud sessions cannot reach that host: their proxy refuses anything off its
    allowlist (`CONNECT tunnel failed, response 403`), and allows `*.r2.cloudflarestorage.com` and
    GitHub. So `cloud-setup.sh` and `stupidsim-linux` probe the public address once (15 s) and
    otherwise read R2's S3 endpoint, signed with the bucket's read-only key. That key is in the
    code on purpose: the bucket is public anyway, and the key cannot write (verified: PUT 403).
  - The bootstrap is fetched from GitHub
    (`raw.githubusercontent.com/stephancill/stupid-simulator/main/linux/cloud-setup.sh`), which
    every network here allows; a copy also sits at the store's root.
  - Under `runtimes/<runtime>/`: a skeleton (every directory and symlink, and the simruntime's own
    files outside RuntimeRoot), a pack per manifest, the manifests, and the warm parts.
  - `current.json` names the default runtime and the x86Sim version it was built with; setup
    refuses a mismatch. It is uploaded last.
  - Writes (`store publish`) are signed by curl's `--aws-sigv4` with a writer R2 API token scoped
    to the bucket. Anonymous writes are refused.
  - `store presign` makes time-limited SigV4 query links with the standard library, and
    `STUPIDSIM_STORE_URLS` lets setup run from those alone (how the store was tested while private).
- **Setup fetches in parallel and streams.** Each object is piped from curl into `tar --zstd`, so
  no archive is held on disk. A part already present is skipped (`.stupidsim-parts`).
- **Measured from an empty home directory** (a new user on the WSL 2 box, its download from South
  Africa to the ENAM bucket the limit):
  - setup 202 s (installing stupidsim 2 s, x86Sim 40 s, the parts in parallel, the 1.78 GB base
    last at 198 s);
  - boot 91 s;
  - installing the test app 37 s.

  Then `doctor`, the trees, `tap --label Settings --verify`, `wait` and `screenshot` worked.
- **x86Sim's frame ring is found through sim.env.** The `/dev/shm/x86sim-a64-<name>-simfb.ring`
  link is named after the device and not the user. With a second user's device also called
  `agent`, `stupidsim` read the first user's link and could not open it. `X86SimDevice.frameRing`
  now reads `SIMFB_RING` from sim.env, as `boot-a64.sh` does.
- **Booting** (`stupidsim-linux boot`) runs x86Sim's `boot-a64.sh` and waits for the home screen.
  Rendering is Metal on a GPU's Vulkan driver, else lavapipe, else x86Sim's software renderer.
  On WSL the default is lavapipe, since dozen corrupts frames. `cloud-setup.sh` installs lavapipe
  (`mesa-vulkan-drivers`) when it runs as root. It does not boot: Claude Code's setup cache keeps
  files, not processes.
- Adding an iOS version is `docs/runbooks/new-ios-version.md`.
- **Setup unpacks with `tar --no-same-owner`, and refuses a translation cache owned by another
  user.** Booting in a Claude Code cloud session first ran the 16 GB VM (no swap) out of memory
  within a minute: a dozen `xpcproxy_sim` processes held 1.0 to 2.1 GB of private anonymous memory
  each. Setup runs there as root, and GNU tar as root keeps the archive's owner, so the cache
  directory belonged to the uid that built the store. x86Sim's processes could then not create the
  lock and the relocated shared copy (`<key>.aot.<layout>.map`) next to the AOT image, so each one
  read the whole image into private memory. On the WSL box, the same boot with the cache directory
  made unwritable to the booting user reproduced it exactly: +12.5 GB within seconds, 1.2 GB
  private per `xpcproxy_sim`, and no `.map` or `.lock` files. Ruled out on the way: seccomp (the
  cloud VM has none, and `personality(ADDR_NO_RANDOMIZE)` sticks there), and a stale `.map` (the
  store ships none; its name hashes the image's inode and mtime, so a shipped one could never
  match). With ASLR left on (`A64_ENV=X86SIM_A64_NOASLR=0`), apps and backboardd still load the
  image privately: +11.5 GB on the WSL box, 2.6 GB each.
- **`boot` creates `/run/user/<uid>` when it is missing.** x86Sim's `mksimdevice.py` puts the frame
  ring there, and only systemd-logind creates the directory. In the cloud VM the device booted and
  its accessibility tree worked, but simfb had nowhere to write frames, so `screenshot` failed with
  the ring unreadable. When the directory cannot be created (no root, no logind), `boot` fails and
  names the command that fixes it.
- With both fixes, a fresh Claude Code cloud session (4 vCPU, 16 GB, no swap) with
  the test app's manifest set up in 87 s and booted to the home screen in 105 s. The test app
  installed, launched with demo data and showed its tree in 18 s; `tap --label Settings --verify`
  (3 s), `wait --label <a label in the app>` and screenshots worked, with 4.2 GB in use. Settings opened in
  6 s. Without the app's manifest (`STUPIDSIM_APPS` unset) the install still succeeds, but the app
  never comes to the front and leaves no crash report.
- Also measured in the cloud VM: no systemd user manager (so x86Sim's `X86SIM_MEM_MAX` is not
  applied) and no `fusermount`.

## `stupidsim` on Linux, through x86Sim

[x86Sim](https://github.com/x86sim/x86sim) runs Apple's arm64 iOS simulator runtimes unmodified on
x86-64 Linux: it downloads a runtime from Apple's catalogue, runs it on Darling and translates arm64
to x86-64. `stupidsim` now builds on Linux and drives x86Sim's devices with the same commands,
arguments and output as on a Mac. Verified with x86Sim 0.3.0 and the iOS 27.2 runtime (24B8117) on
Ubuntu 24.04 under WSL 2, built with Swift 6.2.4.

- **One interface, two hosts.** Every command now asks a `SimulatorHost` (engine `Host/`) instead of
  making a `SimulatorAdapter` and a `SimctlService` itself. `XcodeSimulatorHost` wraps exactly what
  the commands used before, so nothing changes on a Mac; `X86SimHost` is the Linux one.
  `SimulatorHosts.current()` picks by platform. The orientation lookup moved from the CLI into the
  Mac host. Input sessions, accessibility elements, banners and frames keep their engine types, so
  `tap --label`, `wait`, `--verify` and the gestures needed no Linux code of their own.
- **Input and frames are read directly, not through x86Sim's command line.** x86Sim's simhid takes
  text lines on a Unix socket in the device's data directory (`touch down|move|up x y [edge]`,
  normalized portrait native like `TouchEvent`; `touch2`; `key down|up usage`; `button name
  down|up`; `orientation [name]`, after which it writes the orientation to `data/orientation`).
  simfb publishes every frame to a shared-memory ring, `/dev/shm/x86sim-a64[-<name>]-simfb.ring`
  (layout in `FrameRing.swift`). A device is booted when its socket accepts a connection. Devices
  are the `var/device-a64*` directories in x86Sim's data directory, with `name`, `model`, `runtime`
  and a `sim.env` whose `SIMULATOR_UDID` is the UDID stupidsim prints and takes; the device's name
  is accepted in place of it. Screenshots are the ring's newest frame, encoded as PNG with zlib
  (the `CZlib` target), in about 0.1 s.
- **x86Sim's command line** is used only for what needs the device's own processes: `spawn` (the
  helper below), `push`, and `view`, which opens x86Sim's GTK viewer. It is found through
  `$STUPIDSIM_X86SIM`, else `$XDG_DATA_HOME/stupidsim/x86sim/AppRun`, where the Linux installer
  extracts x86Sim's AppImage. It must be an extracted `AppRun`, and an AppImage is refused: the
  AppImage runtime forks a FUSE helper for every run, Foundation's `Process` on Linux neither reaped
  the AppImage's process nor saw the end of a pipe the helper held, so commands hung, and with that
  fixed (`posix_spawn` and `waitpid`, output in files) each run still left its helper and mount
  behind, 38 after one `push --verify`.
- **stupidsim-guest** (`guest/`) answers what can only be read inside the device: the accessibility
  tree, hit testing, notification banners and the pasteboard. It is an arm64 iOS simulator program,
  built on a Mac by `scripts/build-guest.sh` and committed in `guest/bin`, because Linux has no iOS
  simulator SDK. stupidsim runs it with `x86sim spawn` (about 0.8 s a call) and reads the JSON it
  prints between marker lines, since spawn mixes x86Sim's own lines into the same output.
  - It reads AXRuntime's `AXElement`, the framework VoiceOver and XCTest use, after turning on app
    accessibility and automation (`_AXSApplicationAccessibilitySetEnabled`,
    `_AXSSetAutomationEnabled`). The app in front comes from `+[AXElement
    defaultSystemShellCurrentApplications]`; asked through the system-wide element instead,
    AXRuntime logs that it must be the system shell and answers nothing. `--springboard` reads
    `+defaultSystemShellApplication`.
  - The tree is the app's `explorerElements`, the flat list VoiceOver visits, which is what
    AXPTranslator presents on a Mac. On a SwiftUI test app's feed every element the Mac tree has came back
    with the same label and exactly the same frame. The Mac folds the navigation bar into one
    `Group`, hiding its Search and Settings buttons; the guest lists both, so `tap --label Settings`
    finds them on Linux.
  - `-[AXElement identifier]` answers "0" for every element; the accessibility identifier is
    `axIdentifier`. `-value` answers nil where an element has one ("2 apps" on a home screen
    folder); the value is AXRuntime attribute 2006, read through `-[AXUIElement
    objectWithAXAttribute:]`.
  - Roles come from UIAccessibilityTraits, matched against the Mac translator on a SwiftUI test app, the
    Settings app and the home screen: button, link, image, static text, header (Heading),
    adjustable (Slider), search field and text entry (bits 10 and 18, TextField), and bit 22, a home
    screen icon, which the Mac calls a Button.
  - Hit testing (`ui-tree --at`) is `+[AXElement elementAtCoordinate:withVisualPadding:]`.
  - The banner is the SpringBoard element whose `axIdentifier` is `NotificationShortLookView`, with
    its custom actions' names (More, Dismiss), the same as on a Mac.
  - The pasteboard is UIPasteboard. Its `string` waits for work it queues on the main thread, so it
    runs on a background queue while the main thread runs its run loop. Reading another app's
    pasteboard needs `com.apple.Pasteboard.paste-unchecked`, else it waits for the paste prompt a
    process with no UI cannot answer. The committed helper is signed with it; x86Sim honours it. A
    Mac's simulator refuses to start any program claiming it ("Security policy issue"), so
    `scripts/build-guest.sh --mac-simulator` builds an unentitled copy for trying the helper there.
- **`--verify`** took its three baseline frames back to back. simctl's screenshots took about 0.3 s
  each, which is what spread them over a second; x86Sim's ring answers in milliseconds, so the
  frames missed a story ring's animation and `type` with no field focused "verified". Baseline frames
  are now at least 0.4 s apart and the polling after the input waits 50 ms between frames. On a Mac,
  where a frame takes longer than that, nothing changes.
- **Notification banners.** `push --verify` and `notification show` and `open` work. Dismiss swipes
  the banner up, as a person does: performing an AXRuntime custom action takes an action number it
  does not publish, and probing for it with a wrong one restarted SpringBoard. Expanding (and so
  `notification reply`) is refused on Linux: neither pulling the banner down nor a long press
  expanded it under x86Sim. A payload with `"mutable-content": 1` is refused unless
  `--skip-service-extension` is given, since running the app's Notification Service Extension
  needs a Mac's simulator.
- **The Linux build** is a `#if os(Linux)` branch of `Package.swift` with only the command line, a
  listed set of portable engine sources (anything else is excluded, so a file added upstream never
  breaks it), and a `CoreGraphics` module (`engine/Linux/CoreGraphics`) that re-exports Foundation,
  which has CGPoint, CGSize and CGRect on Linux, so the engine's `import CoreGraphics` lines stand.
  The macOS-only parts of `SimulatorAdapter.swift`, `AccessibilityTree.swift`,
  `NotificationBanner.swift` and `ScreenChange.swift` are inside `#if os(macOS)` or
  `#if canImport(ImageIO)`. Glibc's `stdout` is a mutable global Swift 6 refuses to touch, so the
  CLI flushes with `fflush(nil)`. `scripts/build-linux.sh` builds with the Swift runtime linked
  statically and packages `bin/stupidsim`, `libexec/stupidsim/stupidsim-guest`,
  `share/stupidsim/version` (which `Brand.version` reads, there being no bundle) and `install.sh`,
  which also downloads x86Sim's AppImage, checks it against the release's SHA-256 and extracts it. x86Sim is
  GPL-3.0 and is never bundled or linked: stupidsim only runs it.
- **Seen under x86Sim, not fixed:** a system alert (a notification permission prompt over another
  app) was on screen for 30 s without appearing in either tree, and appeared after the device was
  rotated. `rotate --verify` on an iPhone's home screen reports no change, correctly, since
  SpringBoard stays portrait. With Mesa's dozen (Vulkan over Direct3D 12 in WSL), x86Sim's Metal
  drew on the GPU but corrupted frames; lavapipe (Vulkan on the CPU) drew them correctly.
- **Apple's licence** for Xcode and its simulator runtimes covers Apple-branded computers. x86Sim
  downloads the runtime on the user's machine rather than redistributing it, but running it on
  other hardware is the user's call; the README says so.

## Communication Notification avatars from `push`

- `push` used to print the same "the sender's avatar is not shown" line for every Communication
  Notification, so there was no telling whether the extension attached an image. The helper now
  reports the private `_UNNotificationCommunicationContext`: `isGroup`, `displayName`, `contentURL`,
  `imageName` and `isSystemImage`, each checked with `respondsToSelector:` before use.
- `content.updating(from:)` keeps one avatar, in `contentURL`: an
  `intents-remote-image-proxy:?proxyIdentifier=<id>.png&storageServiceIdentifier=com.apple.Intents.INImageServiceConnection`
  URL whose image is the file `<id>` in the device's `data/Library/Intents/Images`. `push` reads it
  there with ImageIO for its pixel size and type, and `--save-avatar <file>` copies it. Any other
  URL, or a missing or unreadable file, fails with the URL named.
- Which image it keeps: the sender's for a direct message; in a group with two or more other
  recipients the group's (`setImage(_:forParameterNamed: \.speakableGroupName)`) and, with no group
  image, none even when the sender has one; in a "group" with one other recipient, the sender's. The
  report therefore gives the image found rather than saying whose it is.
- The sender's name does not survive the trip from the extension: its `_UNNotificationContact`
  arrives with `displayName` nil and an obfuscated handle, so it is not reported.
- The test host's extension makes a Communication Notification when the payload has a
  `communication` object (sender, `avatar` side, `group`, `groupAvatar` side, `others`), drawing a
  blue sender PNG and a green group PNG so a saved avatar shows which one iOS kept.
- Verified on Xcode 27 (27A266a) with an iOS 27.0 device through the test host's extension: a
  direct message with a 120 px sender image reported and saved 120×120 PNG and `--verify` passed; one
  without reported "no avatar attached" and `--save-avatar` failed before pushing; a group of three
  with a 64 px group image saved the green 64×64 PNG; the same group without a group image reported
  none.

## Running Notification Service Extensions for simulated pushes

- `simctl push` never runs an app's Notification Service Extension. CoreSimulatorBridge turns the
  payload into a finished `UNNotificationRequest` and adds it on the app's behalf, so SpringBoard's
  log goes straight to "Starting add notification pipeline" and skips the remote-notification path
  (apsd to usernotificationsd) where the extension runs.
- `ServiceExtensionHost` hosts the extension itself. A helper written in Objective-C, kept as a
  string in the engine, is compiled with the active Xcode's simulator SDK into
  `~/Library/Caches/net.stupidtech.stupidsimulator/service-extension-host/<hash>/` on first use
  (keyed by the source, SDK path and SDK version), ad hoc signed, and run with `simctl spawn`.
  Shipping it prebuilt would put an iOS simulator binary inside the notarized Mac app.
- The helper does what usernotificationsd does: `+[NSExtension extensionWithIdentifier:error:]`,
  `-beginExtensionRequestWithInputItems:error:`, `-_extensionContextForUUID:` and its
  `_auxiliaryConnection`, then `didReceiveNotificationRequest:withCompletionHandler:` from
  `_UNNotificationServiceExtensionRemoteXPCInterface` on the remote proxy. The request comes from
  `+[UNNotificationRequest requestWithIdentifier:pushPayload:bundleIdentifier:]`, the system's own
  payload conversion. At 25 seconds it sends `serviceExtensionTimeWillExpire` and gives up at 30.
  It prints the serviced content as JSON: alert text, badge, category, thread, target content
  identifier, interruption level, relevance, JSON-safe `userInfo`, attachments, and whether it has a
  communication context.
- The serviced notification cannot be posted as the app. CoreSimulatorBridge may because it holds
  `com.apple.private.usernotifications.notification-simulator`; an ad hoc helper carrying that
  entitlement is refused at spawn (SimXPCErrorDomain 163, "Security policy issue"), and without it
  `-[UNUserNotificationCenter initWithBundleIdentifier:]` adds fail with UNErrorDomain 1. So `push`
  turns the serviced content back into an APNs payload (without `mutable-content`, keeping the
  original's sound) and delivers that through `simctl push`. Attachments and communication avatars
  are reported, not shown.
- `push` runs the extension when the payload has `"mutable-content": 1` and the app's `PlugIns` has an
  `.appex` for `com.apple.usernotifications.service`; `--skip-service-extension` turns it off. The app
  is named to `simctl push` explicitly, from `--bundle-id` or the original payload's `Simulator Target
  Bundle`, since an extension that replaces `userInfo` drops that key from the serviced payload.
- The test host now carries a Notification Service Extension that prefixes titles with "Serviced: "
  and replaces `userInfo` with `["serviced": true]`, built and ad hoc signed by `scripts/build-test-host.sh`. Launched
  with `--request-notifications` it asks for permission and presents banners in front; otherwise it
  does not ask, so the input scripts' screenshots are unchanged.
- Verified on Xcode 27 (27A266a) with an iOS 27.0 device: the test host's banner read "Serviced:
  Extension" after a `mutable-content` push, `--expect "Serviced: ..."` passed, a push without
  `mutable-content` and one with `--skip-service-extension` showed the payload as sent, the
  `Simulator Target Bundle` key worked, and a third-party app's extension ran (it passes unencrypted
  payloads through unchanged). A tester then ran a messaging app's extension on real Web Push
  ciphertext encrypted to a seeded registration: the decrypted sender, room and message reached the
  banner, it reported a Communication Notification, reply and open worked on the serviced banner, and
  an undecryptable payload showed the extension's fallback. With the helper cached a push with `--verify` took 1.7 s; the first
  run, compiling it, 5.4 s. Not checked: an extension that adds attachments or a communication
  context, and the 30 second expiry.

## Notification banners, SpringBoard's tree and hit testing

- `ui-tree` read only `-[AXPTranslator frontmostApplicationWithDisplayId:bridgeDelegateToken:]`, so
  anything another process draws over the app was missing: banners (SpringBoard), Notification
  Center and the lock screen when an app is in front, and the reply field of an expanded
  notification (InputUI). Two more `AXPTranslator` calls, checked before use like the others:
  - `translationApplicationObjectForPid:` reads one guest process. `ui-tree --springboard` passes
    SpringBoard's pid, read from the guest's own `launchctl list` (`com.apple.SpringBoard`), so it
    belongs to that device when several are booted. Guest processes are host processes, so the pid
    is valid on the Mac too.
  - `objectAtPoint:displayId:bridgeDelegateToken:` hit tests a point in the guest's points and
    answers whatever is on top, whichever process draws it. `ui-tree --at x,y` uses it.
- A banner in SpringBoard's tree is an `AXGroup` labelled "Notification" with no children. Hit
  testing its centre answers `NotificationShortLookView`, whose label is the app, when, title,
  subtitle and body joined by ", ", with the custom actions More and Dismiss. Found by that
  identifier rather than the localized group label.
- `stupidsim notification <udid> show|open|expand|dismiss|reply` waits for a banner by its text, then
  acts. Expand and dismiss perform the banner's `NSAccessibilityCustomAction`s through their
  handlers. `accessibilityPerformPress` on the banner returns YES but does nothing, so open taps the
  banner's frame. Each action is checked by the banner leaving the screen. Reply expands, finds the
  InputUI field by hit testing up from the bottom, types, hit tests along the field's row for the
  button, taps it, and checks the field closed.
- `push --verify` now waits for a banner containing the alert's title, subtitle and body (or every
  `--expect`) and prints it, instead of the screen-change check, which passed for any banner.
- Verified on Xcode 27 (27A266a) with an iOS 27.0 device and an app with a text-input reply
  category: show, expand, dismiss and reply (SpringBoard logged the reply action with the typed
  text) from the home screen; open from the home screen cold-launched the app through the default
  action; `--expect` failed with exit 2 on a mismatch and printed the banner. A `mutable-content`
  push did not start the app's Notification Service Extension (it does now; see the section above).
  Not checked: landscape, and a
  category with several actions, where expanding shows buttons rather than the field.
- Taps on notifications seemed not to open the app for two reasons. Banner taps did open it, but
  the app under test crashed on launch (a `nonisolated` async `didReceive` finishing off the main
  thread). In Notification Center and on the lock screen, SpringBoard answers a tap on a row by
  hinting a side swipe instead of running the default action (`shouldHintForDefault hinting notCape
  - doesn'tForceDefault`), and the row's View accessibility action does the same. Swiping the row
  right runs the default action and launches the app. Verified on Xcode 27 (27A266a) with an iOS
  27.0 device.

## Push notifications

- `stupidsim push <udid> [payload] [--bundle-id] [--title --body] [--verify]` and dropping an `.apns`
  file on a device window both go through `SimctlService.push`, which hands the payload to
  `simctl push` on standard input. `.json` drops are not taken as pushes, since most JSON files are
  not payloads.
- simctl validates the payload itself and names the problem, so nothing is checked twice: a missing
  `aps` key, more than 4096 bytes, no bundle identifier and no `Simulator Target Bundle` key. On
  Xcode 27 it also refuses a push with no visible content (a silent `content-available` push, UN
  error 1401), and an app that is not installed fails with "Source is not authorized" (UN error
  2003), which the CLI turns into a question about whether the app is installed.
- `--verify` first used the screen-change check, since the banner is not in the front app's tree. It
  now reads the banner itself; see the section above.
- Verified on Xcode 27 (27A266a) with an iOS 27.0 device: an alert from `--title/--body`, a file with
  a target bundle key and a badge, and standard input were all delivered, and `--verify` saw the
  banner; the not installed and silent cases failed with the errors above. The drop path is unit
  tested for routing but was not exercised by dragging a file by hand.

## One window per simulator across processes

- `DeviceWindowManager` already kept one window per device, but only within its own process, and
  every `stupidsim view` starts its own viewer, as does a second copy of the app (a debug build next
  to the installed one, say). Each could open a window on the same simulator.
- A window now holds an exclusive `flock` on
  `~/Library/Caches/net.stupidtech.stupidsimulator/windows/<UDID>.lock`, taken in `ViewerMain.open`
  before booting or opening any session and released when the window closes or fails to open. The
  kernel drops the lock when the process exits, so a crash never leaves a device unopenable. The file
  holds the owner's pid, used only for the refusal message.
- A refused open fails loudly (`already shown by another stupid simulator window (pid N)`, and
  `stupidsim view` exits 1 when nothing opened) and posts a distributed notification asking the owner
  to bring the window forward, then activates the owner by pid, since a background app cannot activate
  itself on macOS 14+. A boot noticed by two running viewers opens the window in whichever claims
  first; the other only reports it.
- Tests construct managers without claims, so parallel tests and a running copy of the app do not
  lock each other out.
- Verified on Xcode 27 (27A266a) with an iOS 27.0 device: a second `stupidsim view` of the same UDID
  was refused with the first viewer's pid, and the device opened again after the first viewer quit
  and after it was killed with SIGKILL. Bringing the window forward was not checked visually.

## Capture preview card

- Copy put two items on the pasteboard, the temporary file's URL and then the image, so paste
  targets took the first and pasted a path that no longer existed once the capture was filed. A
  screenshot is now copied as a single item with PNG and TIFF data and no URL. A recording, which has
  no picture to copy, is filed first and copied as the file where it landed.
- Screenshots taken while a screenshot card is showing join it as a stack instead of filing it: the
  newest in front, up to two older ones peeking out behind, and a count badge. Copy puts one image
  item per screenshot on the pasteboard, oldest first; Open, Reveal and Delete act on all of them, and
  Save As becomes Save To, which asks for a folder and keeps the names. A recording still gets its own
  card and files whatever was showing, as before. Paste targets that read only the first pasteboard
  item get only the oldest screenshot.
- The card no longer closes under the pointer: its countdown stops while the pointer is over it or
  its menu is open and starts again from the full six seconds when both end. A screenshot joining a
  stack restarts it too.
- Verified on Xcode 27 (27A266a) with an iOS 27.0 device by driving the app with System Events and
  synthetic clicks: three Save Screen presses made one card with a badge of 3, and Copy left three
  items with `public.png` and `public.tiff` on the pasteboard and filed all three captures.
- The card can be dragged. A press now opens the capture on release, so a press that moves 4 points
  becomes a drag instead. The drag files the captures first and carries the file URLs where they
  landed, one dragging item per screenshot, with `.copy` as the only operation. The card closes when
  the drag ends, dropped or not, because its captures are already filed; its countdown is held for
  the drag so it cannot try to file them again. Checked by hand in the app on Xcode 27 (27A266a)
  with an iOS 27.0 device.

## Version through a symlink

Install Command Line Tool links the CLI onto the PATH, and run through that link `Bundle.main`
is the link's folder, so `--version` (and anything else reading the bundle) reported
`0.0.0-dev`. `Brand.runningBundle` finds the app again from the resolved executable
(`<app>/Contents/MacOS/<name>`); a bare source build still reports `0.0.0-dev`. Inherited from
upstream 0.2.0, where `odhub --version` through the link does the same.

## Agent skill

`skills/stupid-simulator/` is the agent skill for this CLI. It replaces two earlier local skills:
an IDB based simulator skill (adapted from Conor Luddy's MIT-licensed ios-simulator-skill, credited
in `skills/stupid-simulator/THIRD_PARTY.md`) and a Vision OCR skill.

- The accessibility tree comes from `stupidsim ui-tree --json`, converted in
  `scripts/common/tree_utils.py` to the element shape the audit, capture and recorder scripts
  expect. The scripts that only wrapped IDB input, and the clipboard script (which `simctl pbcopy`
  under Device Hub silently defeats), were dropped in favour of `stupidsim` commands.
- The audit skips its traits and hint rules when the tree does not report those fields, instead of
  flagging every element.
- `app_state_capture.py` matched the first line containing "iPhone" or "iPad" in `simctl list`,
  so it reported the wrong device; it now matches the UDID in `simctl list -j`. The health check
  counted booted devices the same way and missed custom names.
- OCR: `--normalized` prints the 0 to 1 coordinates `tap` takes. `--dual` was removed: the scale
  only divides coordinates, so the second pass recognized the same text and printed it in pixels.
  The fast recognizer is the default because Vision's accurate recognizer fails on macOS 27
  (Darwin 27.0) with `e5rtError 13` on every compute device; a failed request is now an error
  rather than an empty result. Normalized output forces the C locale, which otherwise printed
  `0,254`.
- `sim_clone_state.py` copies one app's signed-in state between simulators for agents sharing a
  machine: the data container and app group containers by rsync (keeping each target container's
  `.com.apple.mobile_container_manager.metadata.plist`, which ties it to the target's install), and
  every `keychain-2*.db` through SQLite's online backup, which is consistent while the source runs,
  so the source is never shut down or written. The target must be shut down while copying, and
  the app installed on it first: install is what creates the containers. App groups come from the
  installed app's entitlements; a group the target has no container for fails the run rather than
  being skipped silently. Verified on Xcode 27 with an iOS 27.0 iPhone 17 Pro: a cloned app opened
  still signed in.
- A device whose input had stopped working was seen a second time on Xcode 27 (an iPhone 17 on
  iOS 27.0, about an hour after a reboot, with Device Hub and this app attached). Quitting this app
  did not bring input back; rebooting the device did.
- `biometrics.py` enrolls Face ID / Touch ID and answers prompts with BiometricKit's darwin
  notifications through `simctl spawn <udid> notifyutil`, as Simulator.app's Features menu does:
  enrollment sets the state of `com.apple.BiometricKit.enrollmentChanged` (1 or 0) and posts it;
  a match or non-match posts `com.apple.BiometricKit_Sim.pearl.match` / `.nomatch` (Face ID) or
  `fingerTouch.match` / `.nomatch` (Touch ID) while a prompt shows. Passkeys refuse to run on a
  device without enrollment ("Simulator requires enrolled biometrics to use passkeys"). Verified
  on Xcode 27 with an iOS 27.0 iPhone 17 Pro: after enrollment, a passkey was created and later
  used in an `ASWebAuthenticationSession` page, each prompt answered with the match notification.
  Each `notifyutil` call is a `simctl spawn`, about 1 to 5 seconds; the script gives up after 30
  seconds, which a device that had stopped responding hit. An enrollment sent within seconds of
  `sim_temp.py create` booting the device read back as not enrolled, so `--enroll`/`--unenroll`
  set it again up to four times, two seconds apart, and then fail.

## Releases

Releases are cut locally; the full procedure is in [RELEASING.md](../RELEASING.md).
`sign-and-notarize.sh` skips the update feed step while the app carries no `SUFeedURL`.

## Rebrand

- App: `stupid simulator.app` (the name is lowercase everywhere users see it), executable `StupidSimulator`, bundle identifier
  `net.stupidtech.stupidsimulator` (so it installs beside upstream), URL scheme `stupidsim://`.
- CLI: `stupidsim`, and `stupidsim-viewer` for the bare viewer. Only the SwiftPM product names
  changed; the targets, modules and source directories keep upstream's names (`odhub`,
  `ODHubViewerApp`, `OpenDeviceHubEngine`, ...) so upstream commits cherry-pick cleanly. Names users
  see come from `Brand.swift`, `packaging/Info.plist` and the scripts.
- Sparkle's `SUFeedURL` and `SUPublicEDKey` were removed, which turns the updater off entirely (it
  refuses to start without both). Left in, a build of this fork would have accepted upstream's
  signed updates and replaced itself with OpenDeviceHub.
- Release scripts point at `github.com/stephancill/stupid-simulator`. There is no signed release
  or appcast yet.
- Code comments that mention `odhub` were left as they are, again for cherry-picking.
- Icon: `packaging/AppIcon.png` (a drawing on white) replaces upstream's drawn devices.
  `make-icon.swift` places it on Apple's icon grid, an 864 unit plate rounded at 190 in a 1024
  canvas, for the app's iconset and the `icons/` files. The social preview and download button are
  ink on paper to match. The vector `icon.svg` was removed, as it was a copy of upstream's artwork.
  The drawing has a bold line so it still reads at 32 pixels.

## Acting on elements, waiting, and lenient arguments

- Why: 129 agent transcripts (4,245 `stupidsim` calls, late October to mid November 2026) showed
  agents tapping by coordinates in nearly every case, grepping `ui-tree` for a label and cutting
  the `@ x,y` out with `sed` (about 1,700 such pipes, and helper functions rewritten in many
  sessions). An empty grep turned into "Missing value for '--x'". 2,900 commands slept a fixed time
  between steps. Common wrong guesses were `--udid`, no UDID at all, `swipe --from x,y` and
  `screenshot <udid> file.png`. `--hold-milliseconds 120` was passed on most taps because the
  skill advised it for small fields.
- `AccessibilityQuery` (engine) matches elements on the `ui-tree` line format: label or title
  exactly when anything matches exactly, else a case-insensitive substring; `--id` exactly; `--role`
  as printed, ignoring case. The tree's root (`Application "<name>"`) is skipped, because its label
  is the app's name, which the Back button also carries. Resolving ignores off-screen matches
  when any is on screen, collapses matches with the same centre (a cell and its own text), and
  calls more than one an error unless `--index` picks one in tree order. Unit tested.
- `tap --label/--id/--role` polls the tree every 250 ms up to `--timeout` (5 s). A read that fails
  (no app answered while launching) is retried; ambiguity is reported at once, since waiting will
  not resolve it. `wait` polls the same way and exits 2 on timeout, printing the matched lines on
  success. `--springboard` on both searches SpringBoard's tree, for the home screen and its context
  menus.
- `DeviceArgumentNormalizer` (engine, unit tested) rewrites the command line before parsing: for
  the commands that take one simulator first, `--udid X` moves to the first positional; with no UDID
  or `booted` anywhere, `$STUPIDSIM_UDID` or `booted` is inserted. Positional text such as `type`'s
  is never mistaken for a device, since only UUIDs and `booted` count as one. A UUID typed as text
  would be, which no one is expected to do.
  With `-h` or `--help` it inserts nothing and drops `booted`, because the parser resolves the
  device before it handles help, so help failed whenever none or several simulators were booted.
- `tap` holds 120 ms by default (90 missed small search fields on Xcode 27 (27A266a)); `--long` holds
  800 ms. `tap --at x,y`, `swipe --from x,y --to x,y` and a positional `screenshot` path are aliases.
- Verified on Xcode 27 (27A266a) with an iOS 27.0 iPhone 17 Pro under heavy load (load average
  500 to 800): `tap --udid <udid> --label General --role Button` opened General; `wait --label About`
  through `STUPIDSIM_UDID` found it; `tap --label Settings` hit the Back button and passed
  `--verify`; `swipe --from 0.5,0.8 --to 0.5,0.3` passed `--verify` and `wait --label General --gone`
  then passed; `tap --springboard --label Settings --role Button --long` opened the icon's context
  menu. With three simulators booted and no UDID, the command refused and listed them. Under that
  load the first tap's `--verify` reported no change within its 3 s, though the tap had landed,
  because the screen redrew later than that.

## Fast temporary simulators (agent skill)

- A simulator from `simctl create` does its one-time setup on first boot (data migration, caches,
  indexing, asset downloads across a few hundred daemons), which took minutes on a busy Mac.
  `scripts/sim_temp.py create` instead clones a shut-down template per device type and runtime
  (`stupidsim-template <type> <runtime>`) that has booted once; `simctl clone` is an APFS copy. A
  template is made on first use (one slow boot and 30 s of settling) or from an already-booted
  simulator with `template --from`. A lock file keeps two agents from warming the same template.
- Measured on the same machine under the same load: rebooting a simulator that had booted before
  took 95 s to `bootstatus`; a clone of the template took 7 s.
- It warns when `IOS_SIM_MAX_BOOTED` (3) simulators are already booted. Each booted iOS 27 simulator
  ran about 215 processes, and four together used about five of eight cores at idle.
- Claims go in `~/.cache/sim-claims/<udid>` under the nearest `claude`, `opencode` or `node`
  ancestor's pid, so the claim stays alive as long as the agent. Claims written with `$$` or `$PPID`
  named a shell that exited straight after the command. `release` deletes only `tmp-` simulators
  not claimed by another live process, unless `--force`.

### Why several simulators slow each other down

- Measured on an M1 Pro with 16 GB and Xcode 27, iOS 27.0 (24A434): a fresh clone ran about 190
  processes in 1.6 GB of physical footprint (top's memory column, which counts compressed pages);
  simulators that had been up a while used 2.0 to 2.8 GB. With four booted the Mac had under 300 MB
  free, 5 GB in the compressor, a load average of 280 to 560 with the CPU 60% idle (processes
  waiting on page faults), and about 3,600 page-ins a second.
- The runtime is mounted from an lzfse-compressed UDIF image, so each evicted page of it is
  decompressed again by `diskimagesiod` when touched; it ran at about 100% CPU. Memory, not cores,
  is what limits how many simulators run well.
- No guest daemon is worth disabling: 132 launchd jobs shared 1.1 GB, mostly 10 to 20 MB each.
  `launchctl disable` inside a simulator survives its reboots but is not carried by `simctl clone`,
  so a template cannot hold it.
- PosterBoard starts every wallpaper extension (about 15, 280 MB) in the minute or two after boot,
  on fresh clones too. Sending them SIGTERM, PosterBoard started only the one shown again
  (MercuryPosterExtension) and the home screen still drew its wallpaper; 249 to 258 MB came back.
  `sim_temp.py create` does this in a detached `trim --wait`, which waits until the count of
  extensions holds for 15 s (at most `IOS_SIM_POSTER_SETTLE`, 120 s), so create still returns in
  seconds. It fails loudly if PosterBoard itself is gone afterwards.
- CoreSimulator boots each device with `SIGTERMTimeout` 3 and `CrashOnSIGTERMTimeout` in
  `data/var/run/launchd_bootstrap.plist` (CoreSimulator 1171.7). Under load daemons miss the 3 s,
  so each shutdown writes a batch of crash reports (assistantd, intelligencetasksd, chronod, logd,
  ...) that the host's ReportCrash symbolicates. `sim_temp.py` takes a lock around every shutdown so
  agents shut down one at a time.
- `reap` deletes `tmp-` simulators whose claim is missing or names an exited process, and with
  `--all` shuts down (never deletes) other unclaimed booted simulators. A claim can name a shell
  that has already exited while its agent still drives the simulator, so a booted simulator is left
  alone while any host process other than the guest names its UDID (stupidsim, simctl, an agent's
  shell) or for `--min-age` (`IOS_SIM_REAP_MIN_AGE`, 30 min) after `SIMULATOR_BOOT_TIME`.

## Agent oriented CLI

- Every command that takes a UDID also takes `booted`, meaning the one booted simulator. With none
  or several booted it refuses and names them, rather than picking one.
- `screenshot <udid> [-o file]` writes the main display as a PNG and prints the absolute path. It
  reads the main display's unmasked framebuffer surface through a short lived display session
  (`FramebufferCapture`), as do `--verify`'s frames. It used `simctl io screenshot` until the guest
  was found to take the Dynamic Island out of its framebuffer for 200 to 500 ms on every `simctl`
  screenshot, so an agent taking screenshots or verifying input made the island blink in the
  viewer window and in its recordings. Measured on Xcode 27 (27A266a), iOS 27.0, iPhone 17 Pro with
  Settings in front: three `simctl` screenshots blanked the island three times, three framebuffer
  reads none. Because nothing hides it any more, screenshots now show the island as the black pill
  the screen shows; the corners stay square, as `simctl` saved them. The skill's screenshot helpers
  (`sim_ocr.sh`, `screenshot_utils.py`, `app_state_capture.py`, `test_recorder.py`) and
  `scripts/verify-tap.sh` call `stupidsim screenshot` for the same reason.
- `list --json` prints the devices as JSON.
- `--verify` on `tap`, `swipe`, `pinch`, `type`, `button`, `rotate`, `home-swipe` and
  `app-switcher`: CoreSimulator accepts an input message whether or not the guest acts on it, so
  the command's own success says nothing. With `--verify` it takes three screenshots before the
  input (about a second apart in total, so a blinking cursor is caught on and off), masks the pixels
  that changed among them, sends the input, then polls screenshots until at least 16 pixels outside
  the mask differ from the last baseline frame, or `--verify-timeout` (3 s) passes. Exit 0 prints the
  changed pixel count and bounding box, exit 2 means nothing changed, exit 3 means the screen was
  too busy (a quarter of the pixels changing, or the screen turning) to tell.
- Limits of `--verify`: it detects any change, not the intended one. Content still loading on its
  own (search suggestions arriving after a keystroke) can pass a no-op input, and the status bar
  clock ticking over during the wait would too.

## Accessibility tree (upstream PR #88)

Merged `odhub ui-tree` from upstream PR #88 (unmerged upstream at the time of the fork). It reads the
accessibility tree of the front app through `-[SimDevice sendAccessibilityRequestAsync:...]` and
`AccessibilityPlatformTranslation`, and prints each element's centre in the normalized coordinates
`tap` takes. `--json` prints the raw tree with frames in points.

## Display report parsing

`DisplayReport.parse` refused the report of every ordinary iPhone, so `ui-tree` (and the viewer's
orientation reads) failed with "a display's activity is unknown" or "a display has no identity of
its own". Observed on Xcode 27 (27A266a):

- An ordinary phone writes `backlightState` once at the top of the report, not per display, and no
  per display `active`. Only the foldable writes both per display, which is what the parser was
  written against.
- Every phone also lists TVOut, Wireless and (on iOS 27) Resizable displays, none integrated and with
  no state at all.
- iOS 26.3 runtimes write no `uniqueId`; each display only has a `deviceName` (`PurpleMain`,
  `PurpleTVOut`, ...).
- A freshly booted iOS 26.3 device reports the device wide backlight as `off` while its screen is
  lit (`devicectl device info displays` says the same).

The parser now falls back to the device wide backlight for integrated displays, treats a
non-integrated display with no state as inactive, and names a display by `deviceName` when it has no
`uniqueId`. A device's only built in screen is always the active one and always settled; the
backlight is only consulted to choose between a foldable's panels. Two built in screens with no
state are still refused.

## Pasteboard

`paste` reads the value back a quarter of a second after setting it and fails (exit 1) if it
changed. While Device Hub is running it writes the Mac's clipboard over every booted device's
pasteboard straight away, so `simctl pbcopy`, and so `paste`, appeared to work and left the Mac's
clipboard on the device. A viewer with pasteboard sync on does the same. With neither running,
round trips of multi line and non ASCII text are exact.

Quitting Device Hub shuts down every simulator it has open, as Simulator.app did.

Edit > Paste (⌘V) in the viewer copied the Mac's text onto the device's pasteboard and stopped
there. The menu takes ⌘V as a key equivalent before the screen view sees the V, so the guest only
received Command and nothing was pasted. It now pushes the Mac's clipboard through the device's
clipboard connection (`PasteboardSession.send`) and then presses ⌘V in the guest, as Simulator.app
did.

0.4.6 copied with `simctl pbcopy` instead, run synchronously on the main thread. With pasteboard sync
on, the guest's `CoreSimulatorBridge` fetches each pasteboard type from the viewer lazily, and the
viewer answers on its main run loop. While `pbcopy` held the main thread, a fetch went unanswered;
the bridge logged "BUG IN CLIENT OF PASTEBOARD: ... failed to return data it promised", and the
guest's `pasted` stayed blocked on it after the main thread came back. Every app that then focused a
text field hung in `becomeFirstResponder`, which asks `pasted` whether image paste is supported.
Killing `pasted` in the guest (`launchctl kill SIGKILL system/com.apple.pasteboard.pasted`) recovers
the device. Verified on Xcode 27 with iOS 27.0: pasting into Settings search through the
connection filled the field, every guest load got its reply within a millisecond, and `simctl
pbpaste` still answered afterwards.

A copy made on the device never reached the Mac while pasteboard sync was on (the default).
Switching away from the viewer calls `reconcile`, which pushes the Mac's clipboard first when its
change count moved since the bridge last looked, then pulls. The automatic sync carries Mac copies
inside the private interface and never moved that mark, so after any Mac copy every reconcile pushed
the old Mac text over the device copy and pulled it straight back. The viewer now calls
`markMacClipboardCarried` on each open device's connection when it becomes active, so a reconcile
pushes only a copy made inside the viewer (such as a screenshot copied to the clipboard). Verified on
Xcode 27 (27A266a) with an iOS 27.0 device in the app: after a Mac copy, a device copy (`simctl
pbcopy`) reached the Mac on switching to Finder, twice in a row, and a later Mac copy still reached
the device. `testReconcileBringsTheDeviceClipboardBackWhileSyncing` failed before the change and
passes after it.

A screenshot copied from the capture card was then lost on switching away. `reconcile` pushed the
newer Mac copy and pulled straight after, but the push had not finished by then, so the device
answered with its clipboard from before it: the device's older text replaced the image two times
in three. `reconcile` now pushes a newer Mac copy and pulls nothing. The cost is a device copy made
in the viewer after a Mac copy there, which comes back on the next reconcile rather than this one.
Verified on Xcode 27 (27A266a) with an iOS 27.0 device: `testReconcileKeepsAnImageCopiedOnTheMac`
failed twice in a row before the change and passes after it, and the other pasteboard integration
tests still pass. They fail while another viewer with pasteboard sync on is running, because that
viewer writes the Mac's clipboard onto the device too.

## Hardware buttons

`IndigoHIDMessageForButton(eventSource, direction, target)` with upstream's target 0x33 is accepted
and ignored on Xcode 27 (27A266a) with iOS 27.0 and iOS 26.3 phones: `button home` and `button
lock` did nothing, at any hold. Addressed to the touch target (0x32) the same message goes home and
locks the device, three times out of three on both runtimes, with the default 15 ms press. Consumer
usage 0x40 (Menu) on the arbitrary builder also goes home, and is kept in reserve. Siri (event
source 0x400002) was not driven: Baguette reports that Siri presses crash `backboardd`.

Toggle Software Keyboard (⌘K, as in the classic Simulator, and `stupidsim button <udid>
software-keyboard`) presses consumer usage 0xB8 (Eject) on the same consumer page path as the volume
keys. iOS answers Eject by showing or hiding the on-screen keyboard while a text field has focus and
a hardware keyboard is connected; it is the key iOS keyboards and barcode scanners use for this.
Verified on Xcode 27 (27A266a) in Settings search on iOS 27.0 and iOS 26.3: each press flipped the
keyboard, three presses in a row, checked with `ui-tree` (the `shift` and `space` keys appear and
disappear). With no text field focused it does nothing.

## Keyboard input

- `IndigoHIDMessageForKeyboardArbitrary(usage, isDown)` builds a message the guest accepts and then
  ignores on Xcode 27 (27A266a), on iOS 27.0 and iOS 26.3 alike: `odhub type` reported success and
  typed nothing. Keys now go through `IndigoHIDMessageForHIDArbitrary(target, page, usage,
  direction)` on the keyboard usage page (0x07) with the touch target, directions 1 and 2 (the
  approach Baguette uses). Verified typing into Settings search and Safari's address bar on iOS
  27.0. This is the shared input session, so it changes the window's keyboard path too.
- `odhub type` lowercased its input, so capitals were typed as lowercase without warning, and it
  refused any symbol on a shifted key (upstream issue #90). `KeyboardMap.keys(forTyping:)` now maps
  each character on a US layout to a key and whether Shift is held, and `type` presses left Shift
  (0xE1) around shifted keys. Characters with no US key (accents, emoji) are refused.
- `stupidsim type` takes only characters, so there was no way to press Delete, the arrows or a
  shortcut from the command line, although the window could. `stupidsim key` presses keys by name
  (`delete`, `forward-delete`, `return`, `escape`, `tab`, the arrows, `home`, `end`, page keys) or a
  single US layout character, with `cmd`, `shift`, `ctrl` and `option` joined by `+`, through the
  same session as `type`. Command is the HID left GUI usage (0xE3). Verified on Xcode 27 (27A266a)
  with iOS 27.0 in Settings search, checked with `ui-tree`: "Hello" became "Hel" after `delete
  --repeat 2`, "HXel" after `left left` and typing X, and empty after `cmd+a delete`. Not driven on
  iOS 26: no iOS 26 runtime was installed.
- The window forwarded key presses but not modifiers, so Shift never reached the guest. The screen
  view now forwards Shift, Control and Option through `flagsChanged`, reading the device dependent
  flag so each side's key is tracked separately. Command is deliberately not forwarded: the Mac's
  menus own it.

## Known gaps

- A long lived simulator can stop acting on host input altogether (fixed by rebooting it): every message is accepted and
  nothing happens, for touches, keys, rotation and buttons alike. Seen on an iOS 26.3 device that
  had been booted for a long time with OpenDeviceHub and Device Hub both attached; a freshly booted
  iOS 26.3 device took the same taps and typing. So iOS 26 input works through the existing
  `IndigoHIDMessageForMouseNSEvent` path under Xcode 27. (Baguette's IOHIDEvent digitizer path was
  tried and was not needed.)
- Input commands without `--verify` still report success when CoreSimulator accepts the message.
