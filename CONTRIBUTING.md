# Contributing to Vibe

Bug fixes and localization work are always welcome!

Please open an issue for a small item and a pull request for a larger one.

New to the code? [docs/architecture.md](docs/architecture.md) maps the directories and follows a file from open to sound.

## Building

Requirements and generating the Xcode project are in the [README](README.md#development). From the command line:

```bash
make build                 # Release
make build CONFIG=Debug    # Debug, which the debug command channel needs
make test                  # unit tests
make help                  # every target, with what it does
```

The app lands at `build/DerivedData/Build/Products/<config>/Vibe.app`. `make clean` removes `build/` and the generated project.

## Other editors: CLion and clangd

Editors other than Xcode read `compile_commands.json`, clang's compilation database. Generate it at the repo root:

```bash
make compile-commands
```

It covers both apps and `VibeTests` in Debug. Rerun it after adding or renaming a file, and after an Xcode update. Its build lives in `.cache/CompileCommands`, so `make clean` leaves it alone. clangd-based editors use this database for compiler flags and include paths.

**CLion.** Use File > Open, pick `compile_commands.json`, and choose **Open as Project**. If an `.idea` folder is already there, move it aside first. CLion reuses an existing project instead of asking.

Use the compilation database project. CLion's Makefile loading can run the clean target. Here, `make clean` deletes `build/` and `Vibe.xcodeproj`.

Mark these folders as Excluded (right-click > Mark Directory as > Excluded): `build`, `.cache`, `Vibe.xcodeproj`, `debug`, `.claude/worktrees`, and `Assets/test_audio_files`. `.claude/worktrees` holds full copies of the repo. Indexing it duplicates every symbol.

To build and debug from CLion, set up three things:

1. In Settings > Tools > External Tools, add a tool that runs `make` with the arguments `build CONFIG=Debug`, in the working directory `$ProjectFileDir$`.
2. In Settings > Build, Execution, Deployment > Custom Build Targets, add a target whose Build step is that tool. Leave Clean empty, since `make clean` deletes the generated project.
3. In Run > Edit Configurations, add a Custom Build Application. Pick that target, and set the executable to `build/DerivedData/Build/Products/Debug/Vibe.app/Contents/MacOS/Vibe`.

Debug then builds the app and launches it under LLDB.

CLion's full Objective-C and Objective-C++ support requires its Classic engine plugin. See [JetBrains' engine guide](https://www.jetbrains.com/help/clion/working-with-source-code.html) for the current support and installation steps.

## Tests

`make test` runs the host-less unit and orchestration tests and the cloud-runner oracles. `make test-audio` checks the real player and FX with full PCM comparisons and signal-quality checks. Read [Tests/AGENTS.md](Tests/AGENTS.md) before adding tests. Checks that need a running app belong in the debug command channel.

## Localization

Every user-facing string lives in `Vibe/Common/VibeStrings.h` and is used through its `STR_*` macro. Call sites hold no English. **Run `make strings` after touching any UI string.** CI runs `make check-strings` and fails on a stale catalog. [docs/localization.md](docs/localization.md) covers adding a string, adding a language and testing one.

## Reporting bugs

Report bugs through GitHub issues, with as much detail as you can.

Security issues go through [SECURITY.md](SECURITY.md), not a public issue.

## License

By contributing you agree that your contributions are licensed under the [Apache License 2.0](LICENSE), the same as the rest of the project.
