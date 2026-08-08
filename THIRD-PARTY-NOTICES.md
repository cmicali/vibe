# Third-party notices

Vibe itself is licensed under Apache 2.0 (see `LICENSE`). It has no package
manager: every third-party component is vendored under `Vibe/ThirdParty/` and
compiled directly into the app target, so all of it ships inside the binary and
all of it is covered here.

## Summary

| Component | Location | Used under |
| --- | --- | --- |
| TagLib | `Vibe/ThirdParty/taglib/` | Mozilla Public License 1.1 (see the election below) |
| UTF8-CPP | `Vibe/ThirdParty/taglib/toolkit/utf8-cpp.*` | Boost-style permissive |
| PINCache | `Vibe/ThirdParty/PINCache/` | Apache License 2.0 |
| PINOperation | `Vibe/ThirdParty/PINOperation/` | Apache License 2.0 |

## TagLib — and why the election matters

TagLib is **dual-licensed**: each source file offers the GNU Lesser General
Public License 2.1 *or* the Mozilla Public License 1.1, at the recipient's
choice. 149 of the 153 vendored source files carry both notices; the remaining
four are `taglib_config.h`, `id3v2.h` (trivial configuration and umbrella
headers with no license block of their own) and the two UTF8-CPP headers,
which are separately licensed and covered below.

**Vibe elects the Mozilla Public License 1.1.**

This is deliberate, not incidental. TagLib is *statically* compiled into the
app target, and the LGPL's static-linking obligation — supplying object files
or otherwise letting a user relink the application against a modified TagLib —
cannot be satisfied through Mac App Store distribution. MPL 1.1 is file-level
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
