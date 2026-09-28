# Vendored third-party code

Other authors' code, vendored in-tree — there is no package manager — and compiled into **both** app targets: `taglib/`, `PINCache/`, `PINOperation/`. **Do not restyle it.** Adding or removing a file means editing `project.yml` and re-running `xcodegen generate`.

Every component must be listed in `THIRD-PARTY-NOTICES.md` at the repo root with the license it is used under. **TagLib is dual-licensed (LGPL 2.1 or MPL 1.1) and Vibe elects MPL 1.1** — that election is load-bearing, because TagLib is statically compiled into the app and the LGPL's static-linking obligation is incompatible with App Store distribution. Read that file before touching `taglib/`.

- **taglib** (a subset of TagLib 2.2) extracts audio metadata. Only the formats the app plays are vendored: `mpeg/` and ID3, `mp4/`, `flac/`, `riff/`, plus the APE *tag* machinery MPEG files need and `ogg/xiphcomment` for FLAC comments. `TagLib::FileRef` is deliberately unused, since its detection references every format parser; `AudioTrackMetadata.mm` has a `TagLibAudioFile` factory that mirrors FileRef's extension-then-content-sniff detection for the supported formats. When updating, re-copy the subset and let the linker report anything new.
- **PINCache** and **PINOperation** provide disk and memory caching for metadata and waveform data. `PINDiskCache.m` is excluded from the recursive `ThirdParty` entry and re-added with a per-file `-fobjc-arc-exceptions` flag, as the pod's ARC-exception-safe subspec did. `make check-layout` whitelists that exclude, along with the `.xcprivacy`, `.txt` and `LICENSE.MPL` ones that keep license and privacy files out of the bundle — this directory is the only place file-level excludes are allowed at all.

`ThirdParty/` is excluded from `make analyze` and from every other check in the repo, on the same grounds: it is not ours to fix.

Framework-style imports such as `<PINCache/...>` resolve through the shared `vibe-header-paths` setting group in `project.yml`, which both app targets use so a second platform cannot drift from the first.
