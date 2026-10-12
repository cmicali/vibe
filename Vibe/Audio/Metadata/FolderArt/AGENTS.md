# Folder art

The sidecar-cover fallback. `FolderArtResolver` is discovery and the two image caches. `FolderArtEntry` is everything known about one directory, mutated only under the resolver's lock. `FolderArtFileIO` is the two POSIX calls on a candidate. `FolderArtRules.h` is what a cover may be called, shared with `NSURLUtil`'s walk. The guarantee (embedded beats folder, per directory, lazy, never persisted, no probe without an active grant) is root `AGENTS.md`'s. This is its implementation half.

**It is consulted only after `AudioTrackArtwork` knows the file carries no embedded art, and only on macOS.** The resolver builds for both targets, but iOS leaves the artwork's handle nil.

**Discovery pays for no listing of its own.** A folder open donates the listing `NSURLUtil.expandDirectory:` already made (`noteListedDirectories:…`), so every walked directory settles with no I/O. A multi-file open marks its directories for one lazy listing each (`preferListingForDirectories:`). A lone file probes only the three commonest lowercase names (`kVibeFolderArtStatProbeCount`). Every other spelling in `FolderArtRules.h` is matched only against a listing. Settling records a path and opens nothing. The file is read only when a track needs pixels, and that one read yields both the thumbnail and the display decode.

**No active sandbox grant means no probe and no read**, or background work raises a permission panel. An unresolved folder settles "without grant". A known cover whose scope ended keeps its donated path and parks reads until a grant change (`readBlockedWithoutGrant`).

**The lock covers `_directories` and nothing else, and is never held across a stat, read or decode.** Main takes it on every cell draw, and a cover on a sleeping disk or a dataless placeholder blocks for seconds. The main-thread accessors only read. Bounds: 4,096 directories, trimmed in one batch to 3,072, never evicting an in-flight (`busy`) entry. Decoded pixels live in `NSCache`: 64 thumbnails and four display images. A cover that exists but fails to read three times settles as none.

**`FolderArtDidResolveNotification` fires for "none" as well as a cover**, because the header keeps the previous track's art up while the answer is pending. The shell coalesces it (`Mac/MainWindow/AGENTS.md`).

**TRAP: `O_NONBLOCK` belongs on the cover file's `open` and nowhere else** (`FolderArtFileIO.m`). It keeps a FIFO or device named `cover.jpg` from wedging the open, since `S_ISREG` is known only after it. Left on across the reads, a file whose bytes are not resident answers `EAGAIN`, which says nothing about the image.

**TRAP: neither normal invalidation is a full wipe.** `folderArtSettingDidChange` drops the decoded images and keeps every settled answer. The setting governs whether the fallback is consulted, not what a folder contains, and a wipe would demote donated covers to the three probes. `invalidateDirectoriesSettledWithoutGrant` forgets only no-grant answers and re-arms read-blocked paths. Opening a folder adds its grant milliseconds later, so a wipe would discard the covers that same open harvested. `invalidate` is test-only.

**TRAP: the resolver caches `AppSettings.useFolderArt`.** Only init, `folderArtSettingDidChange` and the test-only `invalidate` refresh the cached value. Every writer must request `VibeSettingsLiveEffectFolderArt`, whose mapping calls `folderArtSettingDidChange`. A direct defaults write is not observed.
