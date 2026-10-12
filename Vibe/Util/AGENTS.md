# Util

**Code with no feature.** That is the whole admission test, and it is stricter than it sounds. If you can name the feature a file serves, it belongs in that feature's directory, however utility-shaped it looks. `Mac/` (AppKit) and `iOS/` (UIKit) have their own `AGENTS.md`.

**`Util/` may not call anything stateful**: a singleton, a setting, a grant or a panel. Stateless code is fair game wherever it lives. `NSURLUtil.m` imports `PlaylistFile` (a `+`-only parser) and `FolderArtRules.h` (`static inline`) directly, and neither makes the walk untestable. `HelperMacros.h` reaches every translation unit through the `.pch`, so anything added there is paid for everywhere.

Two placements are not what the file names suggest.
- `NSURL+Hash` also carries `NSData (Hash)`'s `sha1Hex`. It is the one spelling of the hex SHA-1 that the cache key's path hash and `AppTheme`'s content-addressed artwork names share. It sits under the URL's name because the two are one rule. It is the one thing here that `Common/` reaches for.
- `NSString+FormLabel`'s `vibeFormLabel` drops a settings string's form-layout colon ("Output:", French "Sortie :"). **The catalogs keep the colon**, because that is the form most mac panes draw. A grouped row asks here for the bare noun: the mac's cards and every iOS settings row. One rule then covers the French no-break space and CJK's fullwidth colon.

## NSURLUtil is the disk walk, and it stays ignorant on purpose

`NSURLUtil` expands whatever the user opened (a file, a folder, a playlist file) into an ordered list of rows. A row is an `AudioTrack`: a file whole, or a CUE sheet's window of one (`Playlist/AGENTS.md`). It runs on background workers, never the main thread. **It calls no one. What it discovers is reported through handler blocks the app installs at launch.**
- `setPlaylistFolderGrantHandler:`: the grant a playlist file's unreadable entries need (`Mac/App/`'s `FolderAccessManager+GrantPanel`).
- `setWalkedDirectoriesHandler:` and `setBulkOpenDirectoriesHandler:`: the folders it listed and the covers it saw. The folder-art resolver takes them rather than paying for its own I/O (`Audio/Metadata/`).

**Unset handlers mean the walk still works and throws the extra facts away.** That is what the tests install. A walk that called a singleton behind a setting, a grant and a modal panel could not be tested, and this one is, fuzz suite included. `NSURLUtilInternal.h` exposes the synchronous expansion steps for those tests. Do not import it outside `NSURLUtil.m` and them.

**The folder-open order is a parameter, not a setting read.** `expandAndFilterList:sortedBy:completion:` and `rowsInDirectory:sortedBy:` take a `VibeFolderOpenSort` (`Common/FolderOpenSort.h`). Each shell reads it on main with the rest of its open snapshot (root `AGENTS.md`). One open then cannot straddle a Settings change, and the walk stays testable with no defaults store. Newest-first prefetches `NSURLContentModificationDateKey` in the enumeration. Name breaks equal dates, as for a folder copied in one go. "Unsorted" is APFS hash order on a local volume, effectively random. It is meaningful only on a file provider, whose listing order is what the choice exists for. **TRAP: decorate the dates and names once, never read them in the comparator** (the file's `TRAP:` says why).

**A symbolic link to a folder is a folder, and the walk is the only thing that can say so.** **TRAP: `NSURLIsDirectoryKey` is lstat-shaped**, and `NSFileManager` neither accepts a link as a walk root (ENOTDIR) nor descends into one it meets. Left alone, a dragged `~/Music/NAS` link would end the open in the empty state. `VibeResolvedDirectoryPath` resolves with `realpath(3)`. `URLByResolvingSymlinksInPath` would not do, since it leaves a `/private` prefix as it found it. The walk keeps its own work list of roots. Each directory link becomes another root, held back until the current enumeration finishes, so it can be tested against everything that enumeration covered. **The answer is spelled as the target, not the link**, so the tracks and the walked-directories handler name one folder. A `covered` set of every directory passed through ends a link cycle. With `skipDescendants`, it also keeps a link into an already-listed subtree from listing it twice. A link to a file stays a file. A **dangling** link is dropped. The emptiness filter answers NO to anything it cannot stat, so that a sandbox denial reaches the real open. A broken `Song.mp3` link would otherwise become an unplayable row.

**Every file's rows are minted by `rowsForFile:`, the only place a walk reads an audio file's contents.** A FLAC of 100 MB or more, a whole album or mix, is opened for an embedded sheet (`PlaylistFile cueRowsEmbeddedInFLACAtURL:`). A cloud placeholder is not, since the read would download it. Neither is one a sidecar sheet claimed. The size comes prefetched with the walk's other resource keys, so the gate costs a network volume no stat per file. The emptiness filter uses that size too. The walk drops an empty file itself (a link by its target's stat), and `expandAndFilterList:` stats only the rows no walk listed. `rowsInDirectory:sortedBy:`, the iOS listing, judges its entries through the same function (`VibeListedFileIsEmpty`), dangling links included.

The playable extension set is `Common/PlayableExtensions`. The walk's filter and `PlaylistFile`'s entry recovery both read it, so neither can grow a format the other lacks.

## Formatters joins every info line

**`infoLineFromFields:` is the one join behind the codec line and the tempo line, and the only place the ` | ` separator is written.** It drops empty fields and joins the rest, so a caller hands over what it has. `tempoLineWithBPM:keyText:` builds the tempo and key line through it, for both shells. What each passes in is its own doc's. **The key is always the last field**, since the mac colors it as the line's suffix.

## Traps

**Every audio file is opened through `AudioFileHandle` (`Audio/`). `NSURL+AudioOpen` is `isEmptyOrDirectory` alone**, the stat-only test for list filtering. Its rule is `VibeStatIsEmptyOrDirectory`, for the folder walk, which has a stat in hand. There is no preflight. A handle that fails to open leaks nothing, because the descriptor is this process's own (`AudioFileHandle.h`, `Audio/AGENTS.md`).

**TRAP: the emptiness test is `st_size`, never `st_blocks` or `NSURLFileAllocatedSizeKey`.** A dataless cloud file has its true size but zero allocated blocks, so an allocation test would reject every cloud track. `stat()` never materializes the file.

**TRAP: `isDatalessFile:` is `SF_DATALESS` alone, never an `NSURL` resource value.** NSURL memoizes those per instance, so a placeholder would read "not downloaded" for its `AudioTrack`'s whole life.

**The one other dataless verdict is the remote placeholder**, and only under a root that a remote backend installs (`Loading/AGENTS.md`). A regular file its owner may not read (`VibeFileModeIsRemotePlaceholder`) stands for a remote file of its size and mtime. Its stat is real, so listing, sorting and the cache key treat it as the file. Any direct open fails rather than reading zeros, so the waveform loader and TagLib open without asking. `remotePlaceholderPartURL:` names the hidden sibling its bytes stream into. The path is tested before any stat, so a file under no root pays nothing. Under no root an unreadable file is merely unreadable. Both apps install the Links root at launch, so a root is always installed.

**TRAP: a playlist entry that is a remote placeholder counts as readable before `access(2)` is asked.** Its mode denies its owner, and `access(2)` reads that as a sandbox denial. Asked the other way round, an M3U naming a placeholder raises a grant panel (`expandPlaylistFile:`).

## Categories

**Behavior added to a foreign class is a category, never a free function taking that class as its first argument.** A category on an AppKit or UIKit class belongs in `Mac/` or `iOS/`. A portable one belongs in `Categories/`, and one on the app's own classes beside that class. The deliberate exceptions are `Common/PlatformImage.h`'s and `PlatformColor.h`'s free functions, where the class differs per target (root `AGENTS.md`, Vocabulary).

## StallWatch samples stuck threads

**`StallWatch` is the beta stall log's watchdogs and stack sampler.** It reads no player state. The player starts the watchers and suspends the queue's one while it has nothing that can stall (`Audio/AGENTS.md`, diagnostics). It also samples the output's IO thread through `VibeFindThread` and `VibeSampleStack`. Everything but the scene flag is compiled only under `VIBE_VERBOSE_LOGGING`.
