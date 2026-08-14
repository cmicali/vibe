# Build provenance: which build produced this log?

Read alongside the Logs section of the `vibe-debug` skill.

`applicationDidFinishLaunching` logs a build-provenance block through `AppDelegate.logBuildInfo`, so a log excerpt identifies the exact build it came from: version and config, git commit, branch and dirty flag, link time, compiler, arch and -O level, the codegen build settings, SDK and Xcode, and the host OS.

`NSBundle+BuildInfo` reads all of it back from the binary: the `DT*` keys Xcode injects into Info.plist, a `VibeBuild` settings dictionary declared in `project.yml` — Xcode expands `$(SETTING)` inside it, nested dicts included — clang macros, and the executable's mtime for the link time. Only the git fields need build-time help. The `Generate Git Info` pre-build script phase (`scripts/generate-git-info.sh`) writes `build/generated/VibeGitInfo.h`, which is gitignored under `build/` and sits on the target's `HEADER_SEARCH_PATHS`. It is rewritten only when the git state actually changes, so it does not force recompiles, and it falls back to "unknown" in a tree with no git. Reading `.git` from a script phase is why the target sets `ENABLE_USER_SCRIPT_SANDBOXING: NO`.

The two arch fields differ on a universal Release build, and both are correct: the compiler line names the slice that is running, the flags line the whole requested `ARCHS` set. The literal clang argv is not recoverable at runtime — it exists only in the build log.
