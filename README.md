# Pashari

A menu bar screenshot app for macOS, written in Swift.

> **Status:** early development. Nothing is released yet.

## Planned for v0.1

- Capture: area, window, full screen
- Floating thumbnail after each capture (copy, save, annotate, drag and drop)
- Annotation editor

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

Then build and run the `Pashari` scheme.

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
