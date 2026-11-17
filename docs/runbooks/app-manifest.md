# Recording an app's runtime manifest

On Linux an agent's machine gets only part of the iOS runtime: the base every session needs, plus
what each app it tests needs. An app's part is a manifest, a list of runtime files, recorded by
using the app on a machine that has the whole runtime and noting which files it read. An app
whose manifest is missing a file it needs does not fail politely: on a runtime missing the files
an app reads, the app never launches. So record the flows the agent will test, and record again
when the app starts using a new framework (maps, web views, the camera, Health, a share sheet).

## Steps

On the machine with the whole runtime (see [new-ios-version.md](new-ios-version.md)):

```sh
A=~/.local/share/stupidsim/x86sim/AppRun
export X86SIM_DEVICE=~/.local/share/x86sim/var/device-a64-agent
$A x86sim install MyApp.app                       # an arm64 iOS simulator build
stupidsim-linux trace begin --device agent        # marks every runtime file unread, then boots
$A x86sim launch com.example.myapp
# use every screen and feature the agent will test, through stupidsim: taps, typing, the
# system sheets the app opens (share, photo picker, permissions), notifications
stupidsim-linux trace end myapp --device agent --base base
$A x86sim uninstall com.example.myapp             # the template stays free of apps
```

`trace end` writes `~/.local/share/stupidsim/manifests/<runtime>/myapp.txt` with the files read
that are not already in the base, and prints how many and how large. Then rebuild and publish
the store with `--manifest myapp` added (step 6 of the new version runbook), and give the agent's
environment `STUPIDSIM_APPS="myapp"`.

## Notes

- A manifest is a list of the runtime's own file paths and nothing of the app's. The packs
  built from it hold Apple's files, which is why the store is private.
- Using the app with stupidsim during the trace also records what stupidsim's in-device helper
  reads, and that belongs in the base anyway.
- The same name can be recorded again; the newer list replaces the older one when the store is
  rebuilt.
