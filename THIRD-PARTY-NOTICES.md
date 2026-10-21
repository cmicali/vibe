# Third-party notices

Vibe is licensed under Apache 2.0 (see `LICENSE`). Its third-party sources
are vendored in vibe-libs, the submodule at `vibe-libs/`. Each library is a
piece under `vibe-libs/third_party/`, with its license beside its sources,
and both app targets compile it in. `vibe-libs/THIRD-PARTY-NOTICES.md` has
each library's full notice. Sparkle is a prebuilt framework in
`Vibe/ThirdParty/`, in the direct-download Mac app only.

## Summary

| Component | Location | Used under |
| --- | --- | --- |
| TagLib | `vibe-libs/third_party/taglib/` | Mozilla Public License 1.1 (see the election below) |
| UTF8-CPP | `vibe-libs/third_party/taglib/toolkit/utf8-cpp.*` | Boost-style permissive |
| PINCache | `vibe-libs/third_party/PINCache/` | Apache License 2.0; modified |
| PINOperation | `vibe-libs/third_party/PINOperation/` | Apache License 2.0; modified |
| r8brain-free-src | `vibe-libs/third_party/r8brain/` | MIT |
| PFFFT (double) | `vibe-libs/third_party/r8brain/fft/` | FFTPACK (BSD-style) |
| dr_mp3 | `vibe-libs/third_party/dr_mp3/` | MIT No Attribution (or public domain, at the recipient's choice); modified |
| dr_flac | `vibe-libs/third_party/dr_flac/` | MIT No Attribution (or public domain, at the recipient's choice); modified |
| dr_wav | `vibe-libs/third_party/dr_wav/` | MIT No Attribution (or public domain, at the recipient's choice); modified |
| libogg | `vibe-libs/third_party/ogg/` | BSD 3-Clause |
| libvorbis | `vibe-libs/third_party/vorbis/` | BSD 3-Clause |
| Sparkle | `Vibe/ThirdParty/Sparkle/` | MIT, with its bundled components' permissive notices |

## The libraries in vibe-libs

Each library's copyright, notice, and license text are in
`vibe-libs/THIRD-PARTY-NOTICES.md`, and beside its sources in
`vibe-libs/third_party/`. Each piece's `AGENTS.md` lists what is modified.
Two terms are Vibe's own choice:

- **Vibe elects the Mozilla Public License 1.1 for TagLib.** TagLib is
  dual-licensed under it and the GNU Lesser General Public License 2.1. Its
  full text is `vibe-libs/third_party/taglib/LICENSE.MPL`, as MPL 1.1 §3.6
  requires.
- **Vibe uses dr_mp3, dr_flac, and dr_wav under MIT No Attribution.** Each is
  also offered as public domain. Their copies carry fixes of Vibe's own, which
  that license permits without condition.

r8brain-free-src's author asks for this credit line in the documentation of
software that uses it: Sample rate converter designed by Aleksey Vaneev of
Voxengo.

## Sparkle

The software update framework, embedded only in the direct-download Mac app;
the Mac App Store build does not contain it. Copyright 2006-2013 Andy
Matuschak, 2009-2013 Elgato Systems GmbH, 2011-2014 Kornel Lesiński,
2015-2017 Mayur Pawashe, 2014 C.W. Betts, 2014 Petroules Corporation, and
2014 Big Nerd Ranch. MIT license. Vendored unmodified as the prebuilt
release. It bundles bsdiff 4.3 (Colin Percival, BSD 2-clause), sais-lite
(Yuta Mori, MIT) and orlp/ed25519 (Orson Peters, zlib). Sparkle's license and
all three notices are `Vibe/ThirdParty/Sparkle/LICENSE.txt`.
