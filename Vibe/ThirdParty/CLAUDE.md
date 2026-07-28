# Vendored third-party code

Everything here is code by other authors, vendored in-tree (no package manager — CocoaPods was removed) and compiled as part of the app target: `taglib/`, `PINCache/`, `PINOperation/`, `RSVerticallyCenteredTextFieldCell`. **Don't restyle it.** Adding or removing files means editing `project.yml` and re-running `xcodegen generate`.

- **taglib** (`taglib/`, TagLib 2.2 subset, ~70 of 113 sources): audio metadata extraction. Only the formats the app plays are vendored — MPEG/ID3, MP4, FLAC, RIFF, plus the APE *tag* machinery MPEG files need and `ogg/xiphcomment` for FLAC comments. `TagLib::FileRef` is deliberately not used (its detection references every format parser); `AudioTrackMetadata.mm` has a `TagLibAudioFile` factory that mirrors FileRef's extension→content-sniff detection for the supported formats. When updating TagLib, re-copy the subset and let the linker report anything new.
- **PINCache** + **PINOperation** (`PINCache/`, `PINOperation/`): disk/memory caching for metadata and waveform data. `PINDiskCache.m` carries a per-file `-fobjc-arc-exceptions` compiler flag (the pod's Arc-exception-safe subspec did the same).

Framework-style imports (`<PINCache/...>`) resolve through target `HEADER_SEARCH_PATHS` entries pointing into `Vibe/ThirdParty/`.
