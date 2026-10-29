# Implementation notes

What stupid simulator changes relative to upstream [OpenDeviceHub](https://github.com/Mastersam07/OpenDeviceHub) (forked from `dev` at `e50f07f`,
v0.2.0), and what has been verified where. Newest first.

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
  payloads through unchanged). A tester then ran Stupid Social's extension on real Web Push
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
