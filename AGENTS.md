# AGENTS.md

stupid simulator is a fork of [OpenDeviceHub](https://github.com/Mastersam07/OpenDeviceHub): a native
macOS app that shows iOS simulators in their own windows on Xcode 27+ (where Simulator.app was
replaced by Device Hub), plus a command line tool, `stupidsim`, for driving simulators from scripts
and agents.

## Before making changes

- Read [docs/implementation-notes.md](docs/implementation-notes.md). It records what this fork changed
  from upstream, why, and what was verified on which Xcode and runtime.
- Read [ROADMAP.md](ROADMAP.md) and the README's **Current limitations** for planned work.
- Upstream is the `upstream` git remote. Check it for fixes before writing your own, and keep
  internal module and type names (`OpenDeviceHubEngine`, `OpenDeviceHubViewer`, ...) unchanged so
  upstream commits still cherry-pick cleanly. Branding lives in `Brand.swift`, `packaging/` and the
  scripts.

## Releasing

- Follow [RELEASING.md](RELEASING.md) for every release: version and changelog, the local sign,
  notarize and package run, the checks before publishing, `gh release create`, and verifying the
  download. Ask before publishing a release; it is public.

## Before committing

- Update [docs/implementation-notes.md](docs/implementation-notes.md) with any change to behaviour,
  private API usage, or what has been verified. Never put personal information in it; assume it is
  public.
- Use conventional commits (`feat:`, `fix:`, `chore:`, ...).

## Stack

- Swift 6 package in `engine/` (SwiftPM, AppKit, Metal), macOS 14+, Apple silicon, Xcode 27.
- `swift-argument-parser` for the CLI, Sparkle for app updates.
- Private frameworks (CoreSimulator, SimulatorKit, CoreSimDeviceIO, SimPasteboardPlus) are loaded at
  runtime from the active Xcode. Every private symbol is checked before use and fails with a named
  error, never silently.

## Build and test

- Build: `scripts/build.sh` (not plain `swift build`; it stamps the SDK version AppKit needs). The
  CLI lands at `engine/.build/debug/stupidsim`.
- Unit tests: `swift test --package-path engine`.
- Integration tests need a booted simulator and are gated behind `ODH_INTEGRATION`.
- App bundle: `scripts/build-app.sh debug`.
- After changing input code, verify on a real booted simulator: check the effect with `ui-tree`, a
  screenshot or `--verify`, not the command's exit status. Quit Device Hub before testing the pasteboard (it overwrites device pasteboards), and
  note that quitting it shuts down the simulators it has open.

## Coding style

- Match the surrounding code: comments explain why and name the Xcode build a private detail was
  verified on (for example "Verified on Xcode 27 (27A266a)").
- Prefer failing loudly over falling back. Do not report success for input the guest may have
  ignored.
- Tests use Swift Testing (`@Test`) for new suites; older suites use XCTest.
- Reference third-party code by cloning it into the git-ignored `third-party/` directory. Credit
  adapted code in `THIRD_PARTY_NOTICES.md`.
