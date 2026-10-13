# Third-party notices

Vibe is licensed under Apache 2.0 (see `LICENSE`). Third-party sources are
vendored under `Vibe/ThirdParty/` and compiled into both app targets.
Sparkle is a prebuilt framework in the direct-download Mac app only.

## Summary

| Component | Location | Used under |
| --- | --- | --- |
| TagLib | `Vibe/ThirdParty/taglib/` | Mozilla Public License 1.1 (see the election below) |
| UTF8-CPP | `Vibe/ThirdParty/taglib/toolkit/utf8-cpp.*` | Boost-style permissive |
| PINCache | `Vibe/ThirdParty/PINCache/` | Apache License 2.0; modified |
| PINOperation | `Vibe/ThirdParty/PINOperation/` | Apache License 2.0; modified |
| r8brain-free-src | `Vibe/ThirdParty/r8brain/` | MIT |
| PFFFT (double) | `Vibe/ThirdParty/r8brain/fft/` | FFTPACK (BSD-style) |
| dr_mp3 | `Vibe/ThirdParty/dr_mp3/` | MIT No Attribution (or public domain, at the recipient's choice); modified |
| dr_flac | `Vibe/ThirdParty/dr_flac/` | MIT No Attribution (or public domain, at the recipient's choice); modified |
| dr_wav | `Vibe/ThirdParty/dr_wav/` | MIT No Attribution (or public domain, at the recipient's choice); modified |
| Sparkle | `Vibe/ThirdParty/Sparkle/` | MIT, with its bundled components' permissive notices |

## TagLib

TagLib is **dual-licensed**: each source file offers the GNU Lesser General
Public License 2.1 *or* the Mozilla Public License 1.1, at the recipient's
choice. 172 of the 176 vendored source files carry both notices; the remaining
four are `taglib_config.h`, `id3v2.h` (trivial configuration and umbrella
headers with no license block of their own) and the two UTF8-CPP headers,
which are separately licensed and covered below.

**Vibe elects the Mozilla Public License 1.1.**

Copyright (C) 2002-2008 Scott Wheeler and the TagLib contributors.
License text: <https://www.mozilla.org/MPL/1.1/>

MPL 1.1 §3.6 requires the license text to accompany the distribution. The full
text is vendored at `Vibe/ThirdParty/taglib/LICENSE.MPL`.

## UTF8-CPP

`Vibe/ThirdParty/taglib/toolkit/utf8-cpp.checked.h` and `utf8-cpp.core.h` are
not TagLib's own code and are not covered by TagLib's dual license. They carry
a Boost-Software-License-style permissive grant requiring only that the
copyright notice and license text be retained, which vendoring the files
unmodified satisfies.

Copyright 2006 Nemanja Trifunovic.

## PINCache and PINOperation

Copyright (c) 2015 Pinterest. All rights reserved.
Copyright (c) 2013 Tumblr, Inc.

Licensed under the Apache License, Version 2.0. The source copies include the full text at `Vibe/ThirdParty/PINCache/LICENSE.txt` and
`Vibe/ThirdParty/PINOperation/LICENSE.txt`. Vibe modifies `PINCache/PINDiskCache.m` and
`PINOperation/PINOperationQueue.m`. Each change is marked `Vibe:` in its file
(`Vibe/ThirdParty/AGENTS.md`).

## r8brain-free-src

Sample rate converter designed by Aleksey Vaneev of Voxengo.

Copyright (c) 2013-2026 Aleksey Vaneev. Licensed under the MIT License; the
full text is vendored at `Vibe/ThirdParty/r8brain/LICENSE.txt` (upstream's `LICENSE`,
renamed so the build leaves it out of the bundles). The author asks for the
credit line above in the documentation of software that uses it.

## PFFFT (double precision)

`Vibe/ThirdParty/r8brain/fft/pffft_double.*`, `pffft_priv_impl.h` and
`simd/` are the FFT r8brain-free-src runs on here (`R8B_PFFFT_DOUBLE`).

Copyright (c) 2013 Julien Pommier. Copyright (c) 2020 Hayati Ayguen.
Copyright (c) 2020 Dario Mambro. Based on FFTPACKv4 by Paul Swarztrauber,
NCAR, released under the FFTPACKv5 license: redistribution in source and
binary forms is permitted provided the copyright notices, the conditions and
the disclaimer are retained (source) or reproduced in the documentation
(binary), and the names of NCAR, UCAR and their contributors are not used to
endorse the product. The full notice is at the head of
`Vibe/ThirdParty/r8brain/fft/pffft_double.c`.

## dr_mp3

MPEG audio decoder by David Reid, based on minimp3 by Lion (lieff). Copyright
2023 David Reid. Offered as public domain (the Unlicense) or under the MIT
No Attribution license, at the recipient's choice; Vibe uses it under MIT
No Attribution. Both texts are at the end of
`Vibe/ThirdParty/dr_mp3/dr_mp3.h`. minimp3, the decoder it carries, is CC0.
The vendored copy carries Vibe's own fixes (`Vibe/ThirdParty/AGENTS.md`),
which that license permits without condition.

## dr_flac

FLAC audio decoder by David Reid. Copyright 2023 David Reid. Offered as
public domain (the Unlicense) or under the MIT No Attribution license, at the
recipient's choice; Vibe uses it under MIT No Attribution. Both texts are at
the end of `Vibe/ThirdParty/dr_flac/dr_flac.h`. The vendored copy carries
Vibe's own fixes (`Vibe/ThirdParty/AGENTS.md`), which that license permits
without condition.

## dr_wav

WAV and AIFF audio decoder by David Reid. Copyright 2023 David Reid. Offered
as public domain (the Unlicense) or under the MIT No Attribution license, at
the recipient's choice; Vibe uses it under MIT No Attribution. Both texts are
at the end of `Vibe/ThirdParty/dr_wav/dr_wav.h`. The vendored copy carries
Vibe's own fixes and additions (`Vibe/ThirdParty/AGENTS.md`), which that
license permits without condition.

## Sparkle

The software update framework, embedded only in the direct-download Mac app;
the Mac App Store build does not contain it. Copyright 2006-2013 Andy
Matuschak, 2009-2013 Elgato Systems GmbH, 2011-2014 Kornel Lesiński,
2015-2017 Mayur Pawashe, 2014 C.W. Betts, 2014 Petroules Corporation, and
2014 Big Nerd Ranch. MIT license. Vendored unmodified as the prebuilt
release. It bundles bsdiff 4.3 (Colin Percival, BSD 2-clause), sais-lite
(Yuta Mori, MIT) and orlp/ed25519 (Orson Peters, zlib). Sparkle's license and
all three notices are `Vibe/ThirdParty/Sparkle/LICENSE.txt`.
