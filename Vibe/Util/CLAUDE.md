# Util

Code with **no feature**. That is the whole admission test, and it is stricter than it sounds: if you can name the feature a file serves, it belongs in that feature's directory however utility-shaped it looks.

## What is here

**Top level (shared):**
- `NSURLUtil` — the disk walk (below).
- `Formatters` — display formatters (duration, spelled duration). A singleton.
- `UIUpdateTimer` — the occlusion-gated playback ticker: two gates and a rate, with no knowledge of the window or the player that set them, which is why both platforms' screens drive it. Tested.
- `UIUpdateMath.h` — `VibeUIUpdateHzForPlayhead`, the seam that scales the tick rate to the playhead's on-screen speed. Tested.
- `HelperMacros.h` — control-state and main-thread shorthands, `clampMin`. It reaches every translation unit through the `.pch`, so anything added there is paid for everywhere.
- `VibeWeakProxy` — a Foundation-only forwarding proxy that breaks the retain cycle a `CADisplayLink` or `NSTimer` target creates. Shared because the class is platform-free, and used from shared code: `EqualizerIndicatorView` aims its level poller through one on both platforms, whichever of the two pollers it holds, as does the iOS `PlayerViewController`'s scroll display link.

**`Categories/` (portable):** `NSURL+Hash` (the cache key — see the root `CLAUDE.md`), `NSURL+AudioOpen`, `NSURL+FileIdentity`, `NSBundle+BuildInfo`, `NSString+CPPStrings`, `NSString+FormLabel`.

`NSString+FormLabel`'s `vibeFormLabel` drops a settings string's form-layout colon ("Output:", French "Sortie :"). The catalogs keep the colon, because that is the form most of the mac's panes draw; a grouped row — the mac's cards, every row on the iOS settings screens — puts the value in its own column and wants the bare noun. Both platforms ask here rather than each trimming its own way, so one rule covers the French no-break space and the fullwidth colon CJK uses.

**`Mac/` (AppKit)** and **`iOS/` (UIKit)** each have their own `CLAUDE.md`. Neither target names the other's subdirectory — see the root `CLAUDE.md` on the directory being the platform boundary.

`NSImage+Util`'s **`dominantColor`** is a thin forward to `Common/PlatformImage.h`'s `VibeDominantColorOfImage`, shared with iOS so the two platforms cannot drift on what a cover's color is. It stays a category because that is how a mac call site asks an `NSImage` for it.

`NSBundle+BuildInfo` also vends **`VibeLogBuildProvenance()`**, the launch banner both app delegates print, so a log excerpt identifies its build the same way on either platform.

## NSURLUtil is the disk walk, and it stays ignorant on purpose

`NSURLUtil` expands whatever the user opened — a file, a folder, a playlist file — into an ordered list of audio URLs, on background workers, never the main thread. Two things it discovers along the way are wanted elsewhere, and it reports both through **handler blocks the app installs at launch** rather than calling anyone:

- `setPlaylistFolderGrantHandler:` — the grant a playlist file needs when its entries live somewhere unreadable (`Mac/App/`'s `FolderAccessManager+GrantPanel`).
- `setWalkedDirectoriesHandler:` and `setBulkOpenDirectoriesHandler:` — the folders it listed and the covers it saw in them, which the folder-art resolver takes for free rather than paying for its own I/O (`Audio/Metadata/`).

**Unset handlers mean the walk still works and simply throws the extra facts away**, which is what the tests install. That is the point of the indirection: a walk that called an app singleton behind a user setting, a sandbox grant and a modal panel could not be exercised in a test, and this one is, including a fuzz suite.

**The folder-open order is the same rule taking a parameter instead of a handler.** `Settings > Files > When opening a folder` (`AppSettings.folderOpenSort`, a `VibeFolderOpenSort` from `Common/FolderOpenSort.h`) decides whether a folder's audio lands sorted by name, newest-modified first, or in the order the file system enumerated. `expandAndFilterList:sortedBy:completion:` and `audioFilesInDirectory:sortedBy:` therefore **take** the answer: each shell reads the setting on main with the rest of its open snapshot — `AppDelegate.openURLsWithRestoredAccess:token:`, `FolderSession.adoptURL:` and its two siblings — so one open cannot straddle a Settings change, and the walk stays exercisable with no defaults store. A handler would have done as well; a parameter is simpler for a value that is read once per open. Newest-first prefetches `NSURLContentModificationDateKey` in the enumeration and decorates the list once rather than reading inside the comparator, and breaks equal dates — a whole folder copied in one go — by the name comparator.

**"Keep folder order" is arbitrary on a local volume and meaningful on a file provider.** The enumerator answers in APFS hash order, which is effectively random; a provider answers in its own listing order, which is what the choice exists for. Only the top-level order the user gave is preserved unconditionally: a multi-file drop keeps its pasteboard order and a playlist file keeps its list order, whatever the setting says.

So the rule is narrower than "imports nothing from a feature": **what `Util/` may not call is anything stateful** — a singleton, a setting, a grant, a panel. Stateless code is fair game wherever it lives, so `NSURLUtil.m` imports `PlaylistFile` (a `+`-only parser) and `FolderArtRules.h` (`static inline`, no linkage) directly. Neither can make the walk untestable.

`NSURLUtilInternal.h` exposes the synchronous expansion steps so a test can drive one walk without the four-wide queue and the main-thread hop standing between every assertion and what the walk yielded. Do not import it outside `NSURLUtil.m` and its tests.

The playable extension set is `Common/PlayableExtensions`, not this file: the walk's filter tests membership in it and `PlaylistFile`'s entry-recovery walks the same spellings in order, so neither can grow a format the other has not got. OGG is not in it.

## Traps

**TRAP: ask `NSURL.failsAudioOpenPreflight` before every `AVAudioFile` open.** `AVAudioFile` — and `ExtAudioFileOpenURL` and `AudioFileOpenURL` under it — leaks a file descriptor on every *failed* open. The open fails, the descriptor stays, and nothing reclaims it, and enough attempts exhaust the process's soft limit. Emptiness is **not** the whole test: the leak triggers on any file the kernel opens but the parser then refuses, a truncated download or a tag table promising more bytes than the file holds included, and a partial download is the common case in a real library. All three URL-based open APIs leak identically, so no URL-based preflight can help — `failsAudioOpenPreflight` is the fd-safe refusal probe, because it opens a descriptor this process owns and closes and hands that to `AudioFileOpenWithCallbacks`. Keep its deliberately inconclusive open/fstat failures and parser-only answer unchanged: playback, prefetch, gapless and waveform loading on both platforms depend on that established behavior. FLAC conversion's destructive handoff alone uses `validateAudioFileIsReadableAndHasContent`, a positive proof that the descriptor opened, CoreAudio accepted the container and it carries audio packets. Its descriptor handling is intentionally separate from `failsAudioOpenPreflight`; the two methods reuse only the pre-existing read callbacks, so a conversion change cannot alter the regular audio-open control flow. `isEmptyOrDirectory` is the cheap stat-only half, for list filtering rather than for guarding an open.

**TRAP: the emptiness test under both is `st_size`, never `st_blocks` or `NSURLFileAllocatedSizeKey`.** An evicted iCloud or Dropbox file is dataless — true logical size, zero allocated blocks — so an allocation-based test would reject every cloud-hosted track. `stat()` reads that metadata locally and never materializes the file.

## Categories

Behavior added to a foreign class is a category, never a free function taking that class as its first argument. A category on an AppKit class belongs in `Mac/`, a portable one in `Categories/`; a category on one of the app's own classes belongs beside that class. The deliberate exceptions are `Common/PlatformImage.h`'s and `PlatformColor.h`'s free functions, where the class involved differs per target — see the root `CLAUDE.md`'s Vocabulary section.
