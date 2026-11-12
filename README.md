# Pashari

A menu bar screenshot app for macOS, written in Swift.

> **Status:** early development. Nothing is released yet.

## Features (v0.1, in progress)

- Capture an area, a window or the full screen, from the menu bar or with
  global hotkeys
- A floating thumbnail after each capture: copy, save, annotate, drag it
  into another app, or close it
- An annotation editor: arrow, rectangle, ellipse, line, pen, multi-line
  text, numbered badges, blur, crop, with undo and redo
  - Select a mark to move or delete it
  - Hold Shift for straight lines, squares and circles
- Saves PNG files at full Retina resolution, to the Desktop or a folder of
  your choice
- Names files like `pashari-20260728-bnan.png`: the date, then the time of
  day as four letters, so sorting by name keeps them in the order taken

Default hotkeys (change them under Settings):

| Action             | Hotkey |
| ------------------ | ------ |
| Capture area       | ⌃⌥4    |
| Capture window     | ⌃⌥5    |
| Capture fullscreen | ⌃⌥3    |

Settings opens from the menu bar icon. If the icon is hidden, for example
behind the notch, open Pashari again from Spotlight or the Finder and
Settings appears.

## Requirements

- macOS 14 or later
- Xcode 26 or later
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

## Building

The Xcode project is not checked in. It is generated from `project.yml`:

```sh
xcodegen generate
open Pashari.xcodeproj
```

Then build and run the `Pashari` scheme. From the command line:

```sh
xcodebuild -scheme Pashari build
xcodebuild -scheme Pashari test
```

The first capture asks for the Screen Recording permission. Grant it in
System Settings, then quit and reopen Pashari.

### Signing

By default the app is signed ad-hoc ("Sign to Run Locally"), so it builds
without an Apple ID.

macOS ties the Screen Recording permission to the code signature, and an
ad-hoc signature changes on every build, so you would have to grant the
permission again after each build. To avoid that, sign with your own
development certificate:

```sh
cp Config/Local.xcconfig.example Config/Local.xcconfig
```

and put your team ID in `Config/Local.xcconfig`. That file is git-ignored.

## License

[MIT](LICENSE)
