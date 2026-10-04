# Build provenance: which build produced this log?

Read alongside the Logs section of the `vibe-debug` skill.

Both app delegates log a build-provenance block at launch through `VibeLogBuildProvenance()` (`NSBundle+BuildInfo`), so a log excerpt identifies the exact build it came from: the `Source:` line (git commit, branch and dirty flag) and the `Built:` line (the link time), beside the "started" line that carries version and configuration.

`NSBundle+BuildInfo` reads all of it back from the binary: the version keys in Info.plist, the `DEBUG` macro for the configuration, and the executable's mtime for the link time. Only the git fields need build-time help. The `Generate Git Info` pre-build script phase (`scripts/generate-git-info.sh`) writes `build/generated/VibeGitInfo.h`, which is gitignored under `build/` and sits on the target's `HEADER_SEARCH_PATHS`. It is rewritten only when the git state actually changes, so it does not force recompiles, and it falls back to "unknown" in a tree with no git. Reading `.git` from a script phase is why the target sets `ENABLE_USER_SCRIPT_SANDBOXING: NO`.

The compiler, its flags and the SDK are not in the binary; they are in the build log.

A running Debug build answers the same fields over the channel: `dump_build` (`references/mac-verbs.md`), with its pid and bundle path, so a reply names the instance that gave it.
