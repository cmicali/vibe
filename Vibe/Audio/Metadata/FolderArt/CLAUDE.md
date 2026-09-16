# Folder art

The sidecar-cover fallback: `FolderArtResolver` (discovery and the two image caches), `FolderArtEntry` (everything known about one directory, mutated only under the resolver's lock), `FolderArtFileIO` (the two POSIX calls on a candidate) and `FolderArtRules.h` (what a cover may be called, shared with `NSURLUtil`'s walk). The root guarantee — embedded beats folder, per directory, lazy, never persisted, no probe without an active grant — is root `CLAUDE.md`'s; this is its implementation half.

**It is consulted only after `AudioTrackArtwork` knows the file carries no embedded art**, and only on macOS: the resolver builds for both targets, but iOS leaves the artwork's handle nil. Its answer never enters the metadata cache — that cache is keyed by the audio file's size and mtime, which a sidecar cannot move.

**Discovery pays for no listing of its own.** A folder open donates the listing `NSURLUtil.expandDirectory:` already produced (`noteListedDirectories:…`), so every walked directory settles for no I/O. A multi-file open marks its directories for one lazy listing each (`preferListingForDirectories:`). A lone file probes only the three commonest lowercase names (`kVibeFolderArtStatProbeCount`); every other spelling in `FolderArtRules.h` is matched only against a listing. Settling records a path and opens nothing: the file is read and decoded only when a track needs pixels, and that one read yields both the thumbnail and the display decode.

**No active sandbox grant means no probe and no read**, or background work raises a permission panel. An unresolved folder settles "without grant"; a known cover whose scope ended keeps its donated path and parks reads until a grant change (`readBlockedWithoutGrant`).

**The lock covers `_directories` and nothing else, and is never held across a stat, read or decode** — the main thread takes it on every cell draw, and a cover on a sleeping disk or a dataless placeholder blocks for seconds. The main-thread accessors are reads; only background paths mutate or trim the history. Bounds: 4,096 directories trimmed in one batch to 3,072, in-flight (`busy`) entries never evicted; decoded pixels in `NSCache`, 64 thumbnails and four display images; a demonstrably present cover that fails to read three times settles as none.

**`FolderArtDidResolveNotification` fires for "none" as well as a cover**, because the header keeps the previous track's art up while the answer is pending. The shell coalesces it (`Mac/MainWindow/CLAUDE.md`).

**TRAP: `O_NONBLOCK` belongs on the cover file's `open` and nowhere else** (`FolderArtFileIO.m`). It keeps a FIFO or device named `cover.jpg` from wedging the resolver on the open itself — `S_ISREG` cannot be tested until it returns — and must not be left across the reads, where a regular file whose bytes are not resident answers `EAGAIN` and says nothing about the image.

**TRAP: neither normal invalidation is a full wipe.** `folderArtSettingDidChange` drops the decoded images and keeps every settled answer — the setting governs whether the fallback is consulted, not what a folder contains, and a wipe would demote donated covers to the three stat probes. `invalidateDirectoriesSettledWithoutGrant` forgets only no-grant answers and re-arms read-blocked paths; opening a folder auto-adds its grant milliseconds later, so a wipe would discard the covers that same open harvested. `invalidate` is test and diagnostic surface only.

**TRAP: the resolver caches `AppSettings.useFolderArt`.** Initialization and `folderArtSettingDidChange` refresh the atomic value; background readers never write it back, so an older read cannot undo a newer setting. Every writer must request `VibeSettingsLiveEffectFolderArt`, whose mapping calls it; a direct defaults write is not observed.
