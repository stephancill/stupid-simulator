# Changelog

The appcast generator reads this file. Each release is a `## <version>` heading, and everything
under it until the next heading becomes that version's release notes in the update feed.

## 0.4.2

- A simulator opens in at most one window, even across `stupidsim view` runs and several copies of
  the app. Asking for one that is already shown brings its window forward instead, and
  `stupidsim view` says which process has it.

## 0.4.1

- `stupidsim key` presses keys by name: Delete, Return, Escape, Tab, the arrows and shortcuts such
  as `cmd+a`, which `stupidsim type` could not send.

## 0.4.0

- Toggle Software Keyboard (⌘K) in I/O ▸ Keyboard shows or hides the on-screen keyboard while a text
  field has focus, as in the classic Simulator. `stupidsim button <udid> software-keyboard` does the
  same from the command line.
- Copy on a screenshot preview copies the image, not the file's path.
- Screenshots taken in a row stack on one preview card with a count. Copy puts all of them on the
  pasteboard, and Open, Reveal in Finder, Delete and Save To act on the whole stack.
- The preview card stays while the pointer is on it or its menu is open, instead of closing under
  you after six seconds.

## 0.3.2

- `stupidsim --version` reports the app's version when run through the link Install Command Line
  Tool puts on your PATH, instead of `0.0.0-dev`.
- `stupidsim ui-tree` explains what to do when no app is in front (a device still starting, or
  locked) instead of claiming the feature is missing from Xcode.
- An agent skill, `skills/stupid-simulator`, for driving simulators with `stupidsim` from coding
  agents.

## 0.3.1

- A bolder app icon that stays legible at small sizes.

## 0.3.0

The first release of stupid simulator, a fork of OpenDeviceHub 0.2.0.

- Renamed to stupid simulator, with its own icon, bundle identifier and `stupidsim` command line
  tool, so it installs beside OpenDeviceHub. In-app updates are off until this fork has its own
  signed feed.
- Typing works: keys reach the device on Xcode 27, `stupidsim type` holds Shift for capitals and
  symbols instead of lowercasing or refusing them, and the window forwards Shift, Control and Option.
- Home and Lock work, from the command line and from the buttons on the device's body.
- `stupidsim ui-tree` prints the accessibility tree of the app in front, with the coordinates `tap`
  takes. It works on ordinary iPhones and iOS 26 runtimes, whose display reports were refused before.
- `--verify` on every input command fails unless the screen changes, so a script or an agent can
  tell input that landed from input the device ignored.
- `stupidsim paste` reads the pasteboard back and fails when Device Hub or pasteboard sync has
  overwritten it.
- `stupidsim screenshot`, `stupidsim list --json`, and `booted` in place of a UDID.

## 0.2.0

- The camera control works on every iPhone that has one, not only the iPhone Duo, and Device,
  Camera Control presses it. The item appears only for devices with the button. The simulator has
  no camera, so the device takes a screenshot.
- Choosing cover, half open or fully open on the iPhone Duo folds it smoothly to that angle instead
  of jumping, unless Reduce Motion is on. The device stays inside the window in every pose,
  standing ones included.
- The iPhone Duo's window moves to the screen the device is using sooner after a fold.
- Recording the iPhone Duo records the screen it is using, follows it through a fold, and keeps the
  picture the right way up.
- A window opens the way its device is already turned, instead of assuming it is upright.
- Restarting a device no longer leaves its window half connected. The iPhone Duo's fold buttons,
  cover screen and touches come back with the fold it was showing, and the clipboard sync picks up
  again.
- Device, Shut Down shuts a simulator down from the menu.
- Every menu action acts on the simulator in front, not on every open one, and ticks such as Stay
  On Top, Slow Animations and Connect Hardware Keyboard show that simulator's own setting.
- Favorite locations: save named coordinates in Settings and choose them from Features, Location.
- Screenshots and recordings each have their own folder in Settings, starting from the folder you
  had already chosen, and Save Screen can put the picture on the clipboard instead of in a file.
- Clipboard sync can be turned on or off in Settings as well as from the Edit menu, and the two stay
  in step.
- The screen shown while a device is shut down or starting stays inside its rounded corners.
- The Settings window can be resized, and scrolls.
- The disk image opens as an installer window: drag the app onto Applications. The mounted disk
  shows the app's icon.

Shut Down, favorite locations and the capture and clipboard settings were contributed by
@stephen-zeng.

## 0.1.0

First release.

- Click the icon and a simulator opens: whatever is already running, or the one shown last. Pick any
  other from the Dock icon or File, Open Simulator, and a device booted anywhere else gets a window
  too.
- One window per simulator, with the device body drawn around the screen and its buttons clickable.
- The iPhone Duo is shown as the foldable it is: the body bends with the hinge, cover, half open
  and fully open are a click away, the window follows whichever screen the device is using, and
  touch, scroll, home, the app switcher, rotation, screenshots and the buttons on the body all work
  on it.
- Point Accurate, Pixel Accurate, Physical Size and Fit, plus full screen and windows that remember
  where they were.
- Click to tap, drag, two finger pinch and rotate, keyboard input, hardware buttons, and the swipe
  up from the bottom edge that goes home or opens the app switcher.
- Rotation, screenshots, screen recording, drag and drop onto a device, and the clipboard kept in
  step with the Mac: copies carry over on their own, and a copy made inside a device is there when
  you switch to another app.
- A window follows its device: it shows when the device has shut down, offers a reboot, and
  reattaches on its own when the device comes back.
- A capture shows itself beside the window before it is filed, so you can open, copy, save or discard
  it. Left alone it saves itself, to a folder you choose.
- Create a simulator without leaving the app: name, device type and OS version, where the two lists
  follow each other so a device no installed runtime can run is never offered.
- Device controls beyond the buttons: restart, erase, text size, increased contrast, an iCloud sync,
  and a location from a scenario or your own coordinates.
- Keyboard choices: send keys to the device or keep them, connect the Mac keyboard as the device's
  hardware keyboard, and match the device's keyboard language to the Mac's.
- Settings for what closing a window does, what launching opens, where captures go, whether device
  links open here, and updates.
- The menu bar follows the simulator it replaces: the same menus in the same order, the same
  shortcuts, and the standard macOS ones that were missing. The zoom shortcuts are Apple's now,
  ⌘1 Physical Size, ⌘2 Point Accurate, ⌘3 Pixel Accurate, ⌘4 Fit Screen, which changes three of the
  four this app used before.
- The `odhub` command line tool beside the app, for listing devices and driving input from a script.
  One menu item puts it on your PATH, without a password on most machines.
- If Xcode is missing or its simulator frameworks will not load, the app says what is missing and
  what to do about it instead of failing silently.
