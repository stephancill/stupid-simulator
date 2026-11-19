# Changelog

The appcast generator reads this file. Each release is a `## <version>` heading, and everything
under it until the next heading becomes that version's release notes in the update feed.

## 0.8.4

- `--verify` on Linux no longer waits 0.8 s before every input when the screen is still. x86Sim
  publishes a frame only when the screen changes, so a screen with no new frame for a second needs
  no watching first. A verified tap by label took 1.2–1.3 s on the test machine, down from 2.0–2.1
  s, and a verified scroll 0.23 s, down from 1.03 s.

## 0.8.3

- Linux boots no longer wait a fixed 90 s. x86Sim's boot script sleeps that long before it returns
  unless told otherwise, so every boot took at least 90 s however early the home screen came up.
  In a 4-vCPU cloud session a first boot now takes 52 s (was 99 s) and a reboot 32 s (was 97 s).

## 0.8.2

- A new cloud machine's first boot no longer re-registers every app bundle with LaunchServices
  (about 50 s on the test machine). The store's device template is now made at the path a cloud
  session uses, so setup leaves it in place instead of moving it, which deleted LaunchServices'
  database. Measured on the test machine: first boot 103 s, down from 152 s.
- Machines at another path move the template as before. stupidsim 0.8.1 and earlier cannot set up
  a new device from the new template (x86Sim's repath refuses it): update to 0.8.2.

## 0.8.1

- Corrected notes on why boots were slow on a WSL 2 machine: x86Sim 0.3.0 fell back to X display
  `:0` even without `DISPLAY`, and the machine's broken X server and mirrored networking hung that
  connection. No change in behaviour.

## 0.8.0

- On Linux, stupidsim uses x86Sim 0.5.0 (was 0.3.0). It brings upstream's fixes, among them
  ScreenTimeAgent no longer spinning at ~90% CPU on a first boot, and a boot that no longer tries
  to open an X display.
- `stupidsim-linux` installs x86Sim's Darling into `/opt/x86sim` (x86Sim's "system" mode), as
  root, at setup and boot. x86Sim 0.5.0's user-namespace mode could not start Darling on Ubuntu
  24.04 under WSL 2. A cloud session's setup runs as root and needs nothing new. Elsewhere, setup
  prints the one `sudo` command to run.
- The runtime store keeps each x86Sim version's translation cache and device template apart, so
  machines on 0.7.0 keep working. A machine set up by 0.7.0 downloads x86Sim 0.5.0 and its
  translation cache on its next setup.
- `stupidsim-linux store warm` builds only an x86Sim version's parts of the store.

## 0.7.0

- On Linux, any app runs without a recorded runtime manifest. Setup still fetches the files a
  boot needs, and every other iOS runtime file is now fetched from the store the first time
  something opens it. Safari, Maps and the other system apps open too. Each fetch is logged in
  `layers/lazy.log` under the runtime, and a file that cannot be fetched fails to open with the
  reason logged there.
- Booting on Linux mounts the runtime (an overlay over a FUSE file system), which needs root and
  libfuse 3; `cloud-setup.sh` installs `fuse3`. A runtime set up by an earlier version must be
  removed and set up again; setup says so.
- A new machine's first boot fetches nothing beyond setup: the base now includes everything that
  boot opens.
- Boot no longer waits for an X display. Under WSL a boot took up to four minutes longer, while
  Darling's iokitd tried to reach WSLg's X server.
- `stupidsim-linux trace` works on a machine that fetches the runtime on demand, so recording an
  app's manifest no longer needs a machine with the whole runtime. `store pack` rebuilds one pack,
  and `store lazy` builds the on-demand store.

## 0.6.0

- `stupidsim` runs on Linux. It drives the iOS simulators of [x86Sim](https://github.com/x86sim/x86sim),
  which runs Apple's simulator runtimes on x86-64 Linux, with the same commands, arguments and
  output as on a Mac: the accessibility tree, taps by label, `wait`, typing, keys, buttons,
  gestures, rotation, screenshots, the pasteboard, pushes and notification banners, and `--verify`.
  `stupidsim-<version>-linux-x86_64.tar.gz` installs it and fetches x86Sim. Expanding and replying
  to a notification are not available there yet.
- A throwaway Linux machine, such as a Claude Code cloud session or a CI runner, gets a booted iOS
  simulator in about three minutes with one command and no credentials:
  `curl -fsSL https://raw.githubusercontent.com/stephancill/stupid-simulator/main/linux/cloud-setup.sh | bash`,
  then `stupidsim-linux boot`. It fetches only the runtime files tests read, x86Sim's translation
  cache and a device that has booted once, instead of 20 minutes and 36 GB from Apple. Measured in
  a Claude Code cloud session (4 vCPU, 16 GB): setup 90 s, boot 105 s, an app on screen 18 s after
  launch, 4.2 GB in use. The agent skill describes it.
- The Dynamic Island no longer blinks in the viewer window and in recordings while an agent takes
  screenshots or verifies input. `stupidsim screenshot` and `--verify` used `simctl io screenshot`,
  which makes the device hide the island while it captures. They now read the screen directly, so
  screenshots show the island as it appears on screen. The agent skill's OCR and screenshot scripts
  go through `stupidsim screenshot` too.
- The agent skill's `sim_temp.py status` shows how much memory each booted simulator uses, and
  `sim_temp.py reap` deletes temporary simulators whose agent has exited. New temporary simulators
  stop the wallpaper extensions they are not showing, about 250 MB each, and shutdowns take turns, so
  several simulators running at once slow each other down less.
- The agent skill's `biometrics.py` tries again when the device ignores a Face ID or Touch ID
  enrollment, and fails if it still does not take.

## 0.5.0

- `stupidsim tap --label Save` taps an element by what `ui-tree` prints, instead of coordinates
  copied out of it. `--id`, `--role` and `--index` narrow it down. It waits for the element to
  appear, and fails with the matches, or with what is on screen, rather than tapping the wrong thing.
- `stupidsim wait --label Saved` waits for an element to appear, or with `--gone` to leave, in place
  of a fixed `sleep`.
- The simulator can be left out (it defaults to `$STUPIDSIM_UDID`, then the only booted one) or given
  as `--udid`. `tap --at x,y`, `swipe --from x,y --to x,y` and `screenshot <udid> file.png` work too.
- Taps hold for 120 ms instead of 90, which small fields sometimes missed. `tap --long` holds for a
  long press.
- The agent skill's `sim_temp.py` makes temporary simulators by cloning a template that has already
  booted once, which skips the slow first boot, and claims and cleans them up.

## 0.4.9

- The screenshot card can be dragged into Finder, Messages, a browser or anywhere else that takes a
  file. The drag saves the screenshot first and drops the saved file.
- A screenshot copied from the card stays on the clipboard after switching to another app. With
  pasteboard sync on, switching away used to bring the device's older clipboard back over it.

## 0.4.8

- Copying on the device and pasting on the Mac now works. With pasteboard sync on, switching away
  from the viewer pushed the Mac's older clipboard over the device's copy.
- `stupidsim push` says whether a Communication Notification carries an avatar, with its size and
  type, where it used to print the same line either way. `--save-avatar <file>` copies the avatar
  out so it can be looked at; the simulator still shows the app icon on the banner.

## 0.4.7

- ⌘V no longer freezes the device. 0.4.6 copied with `simctl pbcopy` on the main thread, which could
  leave the device's pasteboard waiting on the viewer forever, so every text field hung when it took
  focus. ⌘V now sends the Mac's clipboard over the viewer's own pasteboard connection. A device
  already stuck recovers when restarted.

## 0.4.6

- ⌘V in a device window pastes the Mac's clipboard text into the focused field, as Simulator.app
  did. It used to put the text on the device's pasteboard and paste nothing.

## 0.4.5

- `stupidsim push` runs the app's Notification Service Extension when the payload has
  `"mutable-content": 1`, as a device does, and the banner shows what it made: title, subtitle,
  body, thread, category, badge and `userInfo`. It reports attachments and Communication
  Notifications, which cannot be shown. `--skip-service-extension` sends the payload as it is.

## 0.4.4

- `stupidsim notification` reads the banner a simulator is showing and acts on it by its text, not
  its position: `show`, `open`, `expand`, `dismiss`, and `reply` to type and send a text reply.
- `stupidsim push --verify` checks the banner shows the alert's text, or every `--expect`, and
  prints it.
- `stupidsim ui-tree --springboard` reads Notification Center, the lock screen and the home screen
  while an app is in front, and `ui-tree --at x,y` reads whatever is on top at a point, such as a
  notification's reply field.

## 0.4.3

- `stupidsim push` sends a push notification to an app, from a payload file, standard input, or
  `--title` and `--body`. With `--verify` it fails unless a banner appears.
- Dropping an `.apns` payload with a `Simulator Target Bundle` key onto a device window sends it as
  a push notification.

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
