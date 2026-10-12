# Util

**Code with no feature.** That is the whole admission test, and it is stricter than it sounds. If you can name the feature a file serves, it belongs in that feature's directory, however utility-shaped it looks. `Mac/` (AppKit) and `iOS/` (UIKit) have their own `AGENTS.md`.

**`Util/` may not call anything stateful**: a singleton, a setting, a grant or a panel. Stateless code is fair game wherever it lives. `HelperMacros.h` reaches every translation unit through the `.pch`, so anything added there is paid for everywhere.

Two placements are not what the file names suggest.
- `NSURL+Hash` also carries `NSData (Hash)`'s `sha1Hex`. It is the one spelling of the hex SHA-1 that the cache key's path hash and `AppTheme`'s content-addressed artwork names share. It sits under the URL's name because the two are one rule. It is one of the two categories `Common/` reaches for. The other is `Mac/NSView+DarkMode`'s `NSAppearance (DarkMode)`.
- `NSString+FormLabel`'s `vibeFormLabel` drops a settings string's form-layout colon ("Output:", French "Sortie :"). **The catalogs keep the colon**, because that is the form most mac panes draw. A grouped row asks here for the bare noun: the mac's cards and every iOS settings row. One rule then covers the French no-break space and CJK's fullwidth colon.

## FilePaths spells a path for comparison

**`VibeComparablePath` is path identity from the string alone.** It standardizes the spelling and drops the aliases `VibeAliasFreePath` drops: `/private` before `/tmp`, `/var` and `/etc`, and the data volume's firmlink. It never stats, so any thread may ask about any path. Its `TRAP:` says why.

## Formatters joins every info line

**`infoLineFromFields:` is the one join behind the codec line and the tempo line, and the only place the ` | ` separator is written.** It drops empty fields and joins the rest, so a caller hands over what it has. `tempoLineWithBPM:keyText:` builds the tempo and key line through it, for both shells. What each passes in is its own doc's. **The key is always the last field**, since the mac colors it as the line's suffix.

## Traps

**Every audio file is opened through `AudioFileHandle` (`Audio/`). `NSURL+Emptiness` is `isEmptyOrDirectory` alone**, the stat-only test for list filtering. Its rule is `VibeStatIsEmptyOrDirectory`, for the folder walk, which has a stat in hand. There is no preflight. A handle that fails to open leaks nothing, because the descriptor is this process's own (`AudioFileHandle.h`, `Audio/AGENTS.md`).

**TRAP: the emptiness test is `st_size`, never `st_blocks` or `NSURLFileAllocatedSizeKey`.** A dataless cloud file has its true size but zero allocated blocks, so an allocation test would reject every cloud track. `stat()` never materializes the file.

## Categories

**Behavior added to a foreign class is a category, never a free function taking that class as its first argument.** A category on an AppKit or UIKit class belongs in `Mac/` or `iOS/`. A portable one belongs in `Categories/`, and one on the app's own classes beside that class. The deliberate exceptions are `Common/PlatformImage.h`'s and `PlatformColor.h`'s free functions, where the class differs per target (root `AGENTS.md`, Vocabulary).

## StallWatch samples stuck threads

**`StallWatch` is the beta stall log's watchdogs and stack sampler.** It reads no player state. The player starts the watchers and suspends the queue's one while it has nothing that can stall (`Audio/AGENTS.md`, diagnostics). It also samples the output's IO thread through `VibeFindThread` and `VibeSampleStack`. Everything but the scene flag is compiled only under `VIBE_VERBOSE_LOGGING`.
