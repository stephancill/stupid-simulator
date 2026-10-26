# Implementation notes

What stupid simulator changes relative to upstream [OpenDeviceHub](https://github.com/Mastersam07/OpenDeviceHub) (forked from `dev` at `e50f07f`,
v0.2.0), and what has been verified where. Newest first.

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
- A device whose input had stopped working was seen a second time on Xcode 27 (an iPhone 17 on
  iOS 27.0, about an hour after a reboot, with Device Hub and this app attached). Quitting this app
  did not bring input back; rebooting the device did.

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

## Agent oriented CLI

- Every command that takes a UDID also takes `booted`, meaning the one booted simulator. With none
  or several booted it refuses and names them, rather than picking one.
- `screenshot <udid> [-o file]` writes the main display as a PNG through `simctl io screenshot` and
  prints the absolute path. (`simctl` writes a file literally named `-` when given `-`, so it cannot
  write to standard output.)
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
