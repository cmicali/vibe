# Vendored third-party code

Everything here is other authors' code, vendored in-tree — there is no package manager, and CocoaPods is gone — and compiled as part of the app target: `taglib/`, `PINCache/`, `PINOperation/` and `RSVerticallyCenteredTextFieldCell`. **Do not restyle it.** Adding or removing a file means editing `project.yml` and re-running `xcodegen generate`.

- **taglib** (`taglib/`, a TagLib 2.2 subset of roughly 70 of its 113 sources) extracts audio metadata. Only the formats the app plays are vendored: MPEG and ID3, MP4, FLAC and RIFF, plus the APE *tag* machinery MPEG files need and `ogg/xiphcomment` for FLAC comments. `TagLib::FileRef` is deliberately unused, since its detection references every format parser; instead `AudioTrackMetadata.mm` has a `TagLibAudioFile` factory that mirrors FileRef's extension-then-content-sniff detection for the supported formats. When updating TagLib, re-copy the subset and let the linker report anything new.
- **PINCache** and **PINOperation** (`PINCache/`, `PINOperation/`) provide disk and memory caching for metadata and waveform data. `PINDiskCache.m` carries a per-file `-fobjc-arc-exceptions` compiler flag, as the pod's ARC-exception-safe subspec did.

Framework-style imports such as `<PINCache/...>` resolve through target `HEADER_SEARCH_PATHS` entries pointing into `Vibe/ThirdParty/`.
