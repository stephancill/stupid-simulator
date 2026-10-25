---
name: stupid-simulator
description: Drive and inspect iOS simulators on Xcode 27+ (Device Hub era) with the stupidsim CLI from stupid simulator - read the accessibility tree, tap, swipe, type (capitals and symbols), press Home/Lock, rotate, take screenshots, and verify that input actually landed with --verify. Also OCR for web content the tree cannot see, plus scripts for simulator lifecycle, app launch, permissions, push, location, appearance, status bar, logs, hang detection, app containers, accessibility audits, visual diffs, Xcode build/test and localization. Use for any iOS simulator testing, UI automation, screenshot, or debugging task, including when an app's UI must be checked after a code change.
---

# stupid simulator

`stupidsim` is the command line half of [stupid simulator](https://github.com/stephancill/stupid-simulator),
a Simulator.app replacement for Xcode 27. It talks to the simulators Xcode installs through
CoreSimulator, so it needs no IDB, no AXe and no window. `simctl` and `devicectl` still do lifecycle
and device settings; the `scripts/` here wrap them with token-light output.

## Setup

```bash
stupidsim --version        # 0.3.1 or later
stupidsim doctor           # every private symbol it needs, resolved from the active Xcode
bash scripts/sim_health_check.sh
```

If `stupidsim` is missing: install the app from
https://github.com/stephancill/stupid-simulator/releases, then **stupid simulator → Install Command
Line Tool**. It also runs straight from `/Applications/stupid simulator.app/Contents/MacOS/stupidsim`.
Scripts find it through `$STUPIDSIM`, then `PATH`, then that path.

## The loop: read, act, verify

```bash
stupidsim list --json                          # UDIDs, names, runtimes, states
stupidsim ui-tree <udid> --labelled            # what is on screen, each with tap coordinates
stupidsim tap <udid> --x 0.50 --y 0.46 --verify
stupidsim ui-tree <udid> --labelled            # confirm you are where you meant to be
```

- **Every device argument takes `booted`** when exactly one simulator is booted. With several booted
  it refuses and lists them, rather than guessing. Pass the UDID then.
- **Coordinates are fractions of the screen**, 0 at the top-left and 1 at the bottom-right, never
  points or pixels. `ui-tree` prints each element's centre in exactly that form (`Button "General"
  id=com.apple.settings.general @ 0.50,0.46`), already corrected for the device's rotation.
- **`--verify` on every input you depend on.** CoreSimulator accepts input messages whether or not
  the device acts on them, so a plain `tap` saying "tapped" proves nothing. With `--verify` the
  command exits 0 only when the screen changes (it prints how many pixels and where), 2 when it did
  not change, 3 when the screen was already changing too much to tell. It masks a blinking cursor,
  but content that changes on its own (suggestions loading, the clock ticking over) can pass a
  no-op input, so confirm important steps with `ui-tree`.
- **Prefer `ui-tree` over screenshots.** A labelled tree is a few hundred tokens; a screenshot is
  thousands. Use `stupidsim screenshot <udid> -o file.png` for visual checks and bug reports.

### Commands

| Need | Command |
|---|---|
| Accessibility tree | `stupidsim ui-tree <udid> [--labelled] [--json]` (`--json` frames are in points) |
| Tap | `stupidsim tap <udid> --x X --y Y [--hold-milliseconds 120] [--verify]` |
| Swipe / scroll | `stupidsim swipe <udid> --from-x 0.5 --from-y 0.75 --to-x 0.5 --to-y 0.3 [--verify]` |
| Pinch | `stupidsim pinch <udid> --from 0.2 --to 0.7 [--x --y --angle]` |
| Type | `stupidsim type <udid> 'Hello@example.com #1!' [--verify]` |
| Home, Lock, volume | `stupidsim button <udid> home\|lock\|volume-up\|volume-down [--verify]` |
| Show/hide on-screen keyboard | `stupidsim button <udid> software-keyboard` (needs a focused text field) |
| Home gesture, app switcher | `stupidsim home-swipe <udid>`, `stupidsim app-switcher <udid>` |
| Rotate | `stupidsim rotate <udid> portrait\|landscapeLeft\|landscapeRight\|portraitUpsideDown` |
| Pasteboard | `stupidsim paste <udid> 'text'` (reads it back, fails if overwritten), `stupidsim copy <udid>` |
| Screenshot | `stupidsim screenshot <udid> [-o file.png]` (prints the path) |
| Windows for people | `stupidsim view <udid>` or open the app |

## What we learned the hard way

- **Small fields can miss a 90 ms tap.** If a text field does not focus (Settings' and Safari's
  bottom search bars), tap again with `--hold-milliseconds 120`. Check focus in `ui-tree`: a focused
  field usually changes identifier or frame (Safari's address field goes from `TabBarItemTitle` to
  `URL`).
- **Typing goes to whatever is focused**, as a hardware keyboard on a US layout. Capitals and the
  shifted symbols (`!@#$%^&*()_+{}|:"~<>?`) work. Accented letters and emoji are refused rather than
  mistyped. Put those on the pasteboard with `paste` and paste them inside the app instead. iOS may
  auto-capitalize the first letter, as on a real keyboard.
- **When every input fails `--verify` on one device but works on another, restart that device**
  (`xcrun simctl shutdown <udid> && xcrun simctl boot <udid>`). A long-running simulator can stop
  acting on host input entirely (taps, keys, buttons, rotation) while still accepting every
  message. The trigger is not known; force-quitting a viewer that holds the device is one suspect.
  A reboot has fixed it every time.
- **Device Hub overwrites device pasteboards.** While it runs it writes the Mac's clipboard over
  every booted simulator's pasteboard, so `simctl pbcopy` silently fails. `stupidsim paste` detects
  this and exits 1. Quit Device Hub to use the pasteboard, but note the next point.
- **Quitting Device Hub shuts down every simulator it has open**, as Simulator.app did. Ask before
  quitting it on someone's machine. `defaults write com.apple.dt.Devices shutdownStartedDevicesOnQuit
  -bool false` (with Device Hub quit) stops that.
- **`ui-tree` needs an app in front.** On a locked device or straight after boot it fails with "no
  app answered". Unlock (`button home`) or launch an app (`xcrun simctl launch <udid> <bundle-id>`),
  then retry.
- **Wait for launches to settle** before reading the screen. `simctl launch` returns before the
  first frame; a second or two of sleep, or polling `ui-tree`, avoids reading the previous app.
- **Building with `stupid-app`** (the stupid-app-cli skill): `stupid-app run --simulator --udid
  <udid>` builds, installs and launches through `simctl` and opens no window, so it pairs with
  `stupidsim` as is, and a running stupid simulator app gives the device a window. It returns as soon
  as the app launches, before its first frame: wait or poll `ui-tree` for the app's name before
  acting.
- **`simctl openurl` can time out** on a device still settling after boot (`Operation timed out`).
  Wait and retry.

## When the tree is not enough: OCR

Safari web content, WKWebView and extension popups are often missing from the tree. Read them with
Vision OCR and tap what it finds:

```bash
scripts/ocr/sim_ocr.sh <udid> --normalized --grep 'Sign in'
#   0.512 0.731  Sign in
stupidsim tap <udid> --x 0.512 --y 0.731 --verify
```

- `--normalized` prints the same 0 to 1 coordinates `tap` takes. Without it, coordinates are points.
- Re-run OCR right before each tap; positions move when content does.
- `--regions` adds `REGION x y kind` boxes for unlabelled buttons and panels, `--meta` adds the
  frame hash and white fraction (a mostly white frame with no words is a blank or dimmed screen,
  not an OCR failure), and `--last FILE` prints only text that changed since the last snapshot.
- The fast recognizer is the default: on macOS 27 Vision's accurate recognizer fails with
  `e5rtError ... 13` on every compute device. `--accurate` opts in and fails loudly when it breaks.
  Fast misses some text; fall back to `ui-tree` coordinates or `--regions` when a label is missing.
- OCR coordinates follow the screenshot, which follows the device's rotation. Tap from OCR in
  portrait, or rotate back first.
- The helper compiles from `scripts/ocr/ocr.swift` on first use (and again when it changes).

## Scripts for everything around the screen

Run any with `--help`. Most take `--udid` (default: the booted simulator) and `--json`.

| Area | Script | Does |
|---|---|---|
| Environment | `sim_health_check.sh` | Xcode, simctl, stupidsim and `stupidsim doctor`, Python, booted devices |
| Discovery | `sim_list.py`, `simulator_selector.py` | Token-light device lists (`--suggest`, `--get-details`), pick or boot the best simulator |
| Lifecycle | `simctl_boot.py`, `simctl_shutdown.py`, `simctl_create.py`, `simctl_erase.py`, `simctl_delete.py` | By UDID or name, batch with `--all` / `--type`, `--wait-ready`. Delete asks unless `--yes` |
| Apps | `app_launcher.py` | `--launch`, `--terminate`, `--restart`, `--install`, `--uninstall`, `--open-url`, `--list`, `--state`, launch `--args` and `--env KEY=VALUE` |
| Device state | `appearance.py`, `status_bar.py`, `location.py` | Dark mode, Dynamic Type, locale/region; status bar presets (`--preset clean` gives 9:41); fixed coordinates, cities, GPX scenarios |
| Permissions, push | `privacy_manager.py`, `push_notification.py` | Grant/revoke/reset 13 services; simple or JSON push payloads |
| Inspection | `accessibility_audit.py`, `app_state_capture.py`, `test_recorder.py`, `visual_diff.py` | Audit the tree, bug-report snapshots (screenshot, tree, logs, device), step-by-step test reports, screenshot diffs |
| App data | `container.py`, `model_inspector.py` | Files, UserDefaults and Core Data stores in the sandbox; Core Data / SwiftData models from source |
| Logs, hangs | `log_monitor.py`, `hang_watcher.py` | Filtered, deduplicated logs; hang sessions with `--start`, `--stop SID`, `--get-details SID`, `--diff A B` |
| Build | `build_and_test.py` | xcodebuild build/test with parsed errors and xcresults |
| Localization | `localization_audit.py` | Missing keys and placeholder mismatches in `.xcstrings` / `.strings` |

`accessibility_audit.py` checks labels, identifiers, touch targets and nesting. `ui-tree` does not
report traits or hints, so those rules are skipped rather than flagged on every element. Hang
sessions and caches live under `~/.stupid-simulator/`. Limits are tuned with the `IOS_SIM_*`
environment variables each script's `--help` names (for example `IOS_SIM_BOOT_TIMEOUT=600` for slow
machines).

## Xcode 27 and Device Hub

- Simulator.app is gone; Device Hub (`Xcode.app/Contents/Applications/DeviceHub.app`, bundle
  `com.apple.dt.Devices`) replaced it. `open -a Simulator` does nothing. Simulators boot and run
  headless through `simctl`; stupid simulator or Device Hub are only needed for a window.
- `devicectl` handles device settings headless, for simulators and real devices alike:

  ```bash
  xcrun devicectl device orientation get|set|rotate --device <udid> [landscapeLeft|right]
  xcrun devicectl device settings appearance --device <udid> --mode dark
  xcrun devicectl device simulate statusBar preset screenshot --device <udid>
  xcrun devicectl device info displays --device <udid>
  ```

  It has no touch input; that is what `stupidsim` is for.
- IDB's `idb ui` fails on Xcode 27 because SimulatorKit moved to
  `Xcode.app/Contents/SharedFrameworks/`. `stupidsim` covers what it was used for, so it is not
  needed.
- To stop Xcode opening Device Hub when you press Run, quit Xcode and run
  `defaults write com.apple.dt.Xcode DVTiPhoneSimulatorAlwaysLaunchInCoreSimulatorSession -bool true`.

## Credits

The `scripts/` are adapted from Conor Luddy's MIT-licensed
[ios-simulator-skill](https://github.com/conorluddy/ios-simulator-skill); see `THIRD_PARTY.md`.
