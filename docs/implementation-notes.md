# Implementation notes

What Stupid Simulator changes relative to upstream OpenDeviceHub (forked from `dev` at `e50f07f`,
v0.2.0), and what has been verified where. Newest first.

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
- The window forwarded key presses but not modifiers, so Shift never reached the guest. The screen
  view now forwards Shift, Control and Option through `flagsChanged`, reading the device dependent
  flag so each side's key is tracked separately. Command is deliberately not forwarded: the Mac's
  menus own it.

## Known gaps

- A long lived simulator can stop acting on host input altogether: every message is accepted and
  nothing happens, for touches, keys, rotation and buttons alike. Seen on an iOS 26.3 device that
  had been booted for a long time with OpenDeviceHub and Device Hub both attached; a freshly booted
  iOS 26.3 device took the same taps and typing. So iOS 26 input works through the existing
  `IndigoHIDMessageForMouseNSEvent` path under Xcode 27. (Baguette's IOHIDEvent digitizer path was
  tried and was not needed.)
- `button home` and `button lock` did nothing on iOS 27.0 in testing, while `home-swipe` worked.
- Input commands without `--verify` still report success when CoreSimulator accepts the message.
