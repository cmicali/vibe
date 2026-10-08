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

## Other editors: CLion and clangd

Editors other than Xcode read `compile_commands.json`, clang's compilation database. Generate it at the repo root:

```bash
make compile-commands
```

It covers both apps and `VibeTests` in Debug, and takes about 30 seconds. Rerun it after adding or renaming a file, and after `make clean`. clangd-based editors, such as VS Code with the clangd extension or Zed, need nothing more.

**CLion.** Use File > Open, pick `compile_commands.json`, and choose **Open as Project**. If an `.idea` folder is already there, move it aside first. CLion reuses an existing project instead of asking.

Never open Vibe as a Makefile project. CLion's Makefile mode runs `make clean` when it loads. That deletes `build/` and `Vibe.xcodeproj`, and it still finds nothing to index.

Mark these folders as Excluded (right-click > Mark Directory as > Excluded): `build`, `Vibe.xcodeproj`, `debug`, `.claude/worktrees`, and `Assets/test_audio_files`. `.claude/worktrees` holds full copies of the repo. Indexing it duplicates every symbol.

To build and debug from CLion, set up three things:

1. In Settings > Tools > External Tools, add a tool that runs `make` with the arguments `build CONFIG=Debug`, in the working directory `$ProjectFileDir$`.
2. In Settings > Build, Execution, Deployment > Custom Build Targets, add a target whose Build step is that tool. Leave Clean empty, since `make clean` deletes the generated project.
3. In Run > Edit Configurations, add a Custom Build Application. Pick that target, and set the executable to `build/DerivedData/Build/Products/Debug/Vibe.app/Contents/MacOS/Vibe`.

Debug then builds the app and launches it under LLDB.

CLion's default engine has only basic Objective-C support, and none for Objective-C++. Highlighting and navigation in `.m` files are limited, and `.mm` files are worse. The Classic engine plugin has full support. clangd-based editors support both languages fully.

## Requirements

- macOS 13 or later, or iOS 26 or later, to run; **Xcode 26 or later** to build (the app builds against the macOS 26 SDK and back-deploys)
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
