# Third-party notices

Vibe itself is licensed under Apache 2.0 (see `LICENSE`). It has no package
manager: every third-party component is vendored under `Vibe/ThirdParty/` and
compiled directly into both app targets, so all of it ships inside each binary and
all of it is covered here.

## Summary

| Component | Location | Used under |
| --- | --- | --- |
| TagLib | `Vibe/ThirdParty/taglib/` | Mozilla Public License 1.1 (see the election below) |
| UTF8-CPP | `Vibe/ThirdParty/taglib/toolkit/utf8-cpp.*` | Boost-style permissive |
| PINCache | `Vibe/ThirdParty/PINCache/` | Apache License 2.0 |
| PINOperation | `Vibe/ThirdParty/PINOperation/` | Apache License 2.0 |
| r8brain-free-src | `Vibe/ThirdParty/r8brain/` | MIT |
| PFFFT (double) | `Vibe/ThirdParty/r8brain/fft/` | FFTPACK (BSD-style) |
| dr_mp3 | `Vibe/ThirdParty/dr_mp3/` | MIT No Attribution (or public domain, at the recipient's choice) |
| dr_flac | `Vibe/ThirdParty/dr_flac/` | MIT No Attribution (or public domain, at the recipient's choice); modified |

## TagLib — and why the election matters

TagLib is **dual-licensed**: each source file offers the GNU Lesser General
Public License 2.1 *or* the Mozilla Public License 1.1, at the recipient's
choice. 149 of the 153 vendored source files carry both notices; the remaining
four are `taglib_config.h`, `id3v2.h` (trivial configuration and umbrella
headers with no license block of their own) and the two UTF8-CPP headers,
which are separately licensed and covered below.

**Vibe elects the Mozilla Public License 1.1.**

This is deliberate, not incidental. TagLib is *statically* compiled into the
app targets, and the LGPL's static-linking obligation — supplying object files
or otherwise letting a user relink the application against a modified TagLib —
cannot be satisfied through App Store distribution, on the Mac or on iOS. MPL 1.1 is file-level
copyleft: it governs the TagLib files themselves and does not reach the
proprietary code they are linked with, so it permits exactly this arrangement.
The dual license exists to make that election possible.

The obligation the election carries: **modifications to TagLib's own source
files must be published under MPL 1.1.** Keeping the vendored copy unmodified,
or confining changes to Vibe's own files, keeps this trivially satisfied.

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

Licensed under the Apache License, Version 2.0. The full text ships with each
component, at `Vibe/ThirdParty/PINCache/LICENSE.txt` and
`Vibe/ThirdParty/PINOperation/LICENSE.txt`. Neither upstream project ships a
`NOTICE` file, so no additional attribution text is required beyond this
entry.

Because Vibe is itself Apache 2.0, these two impose no obligation the project's
own license does not already carry.

## r8brain-free-src

Sample rate converter designed by Aleksey Vaneev of Voxengo.

Copyright (c) 2013-2026 Aleksey Vaneev. Licensed under the MIT License; the
full text ships at `Vibe/ThirdParty/r8brain/LICENSE.txt` (upstream's `LICENSE`,
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

## dr_flac

FLAC audio decoder by David Reid. Copyright 2023 David Reid. Offered as
public domain (the Unlicense) or under the MIT No Attribution license, at the
recipient's choice; Vibe uses it under MIT No Attribution. Both texts are at
the end of `Vibe/ThirdParty/dr_flac/dr_flac.h`. The vendored copy carries
Vibe's own fixes (`Vibe/ThirdParty/AGENTS.md`), which that license permits
without condition.
