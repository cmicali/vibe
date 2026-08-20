# Contributing to Vibe

Bug fixes and localization work are always welcome! 

Please add a quick issue for small items, PR for larger.

## Before you build: the project file is generated

`Vibe.xcodeproj` is **not** checked in. XcodeGen generates it from `project.yml`, so a fresh clone has no project to open. Regenerate it after cloning, after every pull, and after every edit to `project.yml`:

```bash
make setup       # brew bundle — installs xcodegen, jq, gh
make project     # xcodegen generate
open Vibe.xcodeproj
```

Build and run the `Vibe` scheme with ⌘R, or from the command line:

```bash
make build                 # Release
make build CONFIG=Debug    # Debug — required for the debug command channel
make test                  # unit tests
```

The app lands at `build/DerivedData/Build/Products/<config>/Vibe.app`. `make clean` removes that and the generated project.

## Requirements

- macOS 13 or later to run; **Xcode 26 or later** to build (the app builds against the macOS 26 SDK and back-deploys)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen), from `make setup`

## Tests

`make test` runs the suite in `Tests/`. Please add tests if you are changing or adding things. 

## Localization

Every user-facing string lives in `Vibe/Common/VibeStrings.h` and is used through its `STR_*` macro — no English at the call site. **Run `make strings` after touching any UI string**; CI runs `make check-strings` and fails on a stale catalog. Adding a string, adding a language, and testing one are covered in [docs/localization.md](docs/localization.md).

## Reporting bugs

Report via github issues with as much detail as you can. 

Security issues go through [SECURITY.md](SECURITY.md), not a public issue.

## License

By contributing you agree that your contributions are licensed under the [Apache License 2.0](LICENSE), the same as the rest of the project.
