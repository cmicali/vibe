# Converting to FLAC (macOS only)

Convert > Convert to FLAC and the window body's right-click item re-encode the **current track** as FLAC beside it. This is the app's audio-file conversion path. Current-track-only is deliberate: a background row's conversion has no progress surface, and its swap has no playback state to preserve. The controller half, the playlist swap and undo UI settlement, is `Mac/MainWindow/Convert/AGENTS.md`.

**The encoder is CoreAudio's** (`AudioFileHandle`'s writing side, an ExtAudioFile created as `kAudioFileFLACType`), so there is no new dependency. The app is sandboxed and ships in the App Store, so ffmpeg is not an option.

`FLACConvertRules.h` holds the eligibility and naming rules. The tests also compile the converter itself, replacing only its file-operation boundaries and keeping TagLib out. Eligibility is WAV and AIFF only. The sniffed `metadata.fileType` decides once it exists, and the extension keeps the menu available before the scan reaches a freshly dropped row. Acceptance always sniffs the RIFF/FORM header on the converter queue.

**The FLAC's declared source bit depth is the file format's flag** (`kAppleLosslessFormatFlag_16BitSourceData` or the 24-bit one). It is 16 for a non-float source of ≤16 bits and 24 otherwise. Otherwise a 16-bit recording is written as a bit-exact but larger 24-bit file that misdescribes itself. **The source is read once, as float32, and the encoder quantizes it to that depth.** Float32 holds every integer up to 24 bits exactly, and the encoder rounds to the nearest step without dither, so those sources round-trip bit for bit (`testSixteenBitSourceRoundTripsExactlyAsASixteenBitFLAC`, `testTwentyFourBitSourceRoundTripsExactlyAsATwentyFourBitFLAC`). The 24-bit test has a little-endian (sowt) AIFF-C twin, which only dr_wav reads right (`openWAV`'s `TRAP:`). Float and 32-bit integer sources are the lossy cases: rounded to 24 bits, within one step, and saturated at full scale. **TRAP: fed Int32 buffers, the encoder wraps a positive full-scale sample to negative full scale.** That hits the top 128 codes of a 32-bit integer, and a float's +1.0 and overs through Apple's Int32 read (`testFloatSourceBecomesATwentyFourBitFLACWithinAQuantum`).

## Getting the output past the sandbox

`ENABLE_USER_SELECTED_FILES: readwrite` covers files the user opened, not a *new sibling* of one. The converter encodes into the container's tmp, then tries three rungs, cheapest first (`AudioFileConverter+Sandbox`):

1. **A plain move.** It works when the grant was a folder.
2. **A coordinated move against an `NSFilePresenter`** whose `primaryPresentedItemURL` is the source. It works for a single-file grant.
3. **An `NSSavePanel`** pre-filled with the folder and name. The chosen URL carries a write grant. The move can still fail.

`AppSettings.convertAsksWhereToSave` (Settings > Files) goes straight to the panel when a window exists. It is snapshotted at accept, like the delete toggle. Ask-mode also lifts the destination-exists refusal and its menu disable.

All three rungs move the file **on the converter queue, not main.** File coordination blocks until every other presenter relinquishes the URL, which is unbounded on an iCloud or network folder. A cross-volume destination turns even the panel's move into a full copy. Only the panel UI hops to main.

The panel rung refuses a selection that names the source itself, a symlink, case alias or hard link included, before its atomic replace. Its off-main `NSURL+FileIdentity` check compares current device/inode identity. Do not move that blocking check onto the panel callback. A WAV can arrive under a `.flac` name, and ask-mode permits replacing an existing file, so extension checks cannot guarantee the two URLs differ. The controller keeps a same-path guard before it creates an undo record or disposes either file.

**TRAP: the related-item rung's sandbox extension lives exactly as long as the presenter registration.** Unregistered after the move, the app can no longer *read* the file it just wrote, and the player's open fails. So successful presenters are kept for the session (`_relatedItemPresenters`).

**TRAP: inside the related-item coordination block, a handed URL other than the sibling path is a tracked older item**, such as a previously trashed `foo.flac`. Following it would file the new FLAC in the Trash. The accessor compares standardized paths and falls back to the intended destination.

That rung also needs the flac extension declared in `CFBundleDocumentTypes` with `NSIsRelatedItemType`, apart from the real "Audio Files" entry. `DocumentTypes.declaredTypes` skips related-item entries so the type is not claimed twice.

## Cancelling, Quit and the temp sweep

`cancelConversionWithCompletion:` sets a flag the encode loop polls once per buffer. The temp is removed and the request completes with `NSUserCancelledError`, the same decision-not-failure a dismissed save panel reports, so the controller neither beeps nor logs. A conversion past its encode (copying tags, placing the file, or a save panel waiting) runs to its own completion, and the cancel parks until then. It has two callers:

- `AppDelegate.applicationShouldTerminate:`. A Quit mid-encode answers `NSTerminateLater`, cancels, and replies from the converter's completion, so the temp file is gone before the process exits.
- Convert > Cancel Conversion. It is the Convert to FLAC item itself, retitled and re-aimed at `MainPlayerController.cancelConversion:` by menu validation while `isConverting` (`Mac/Menu/AGENTS.md`). A click after the conversion settled reaches a no-op.

**TRAP: settlement and progress reach main through the run loop's block queue (`CFRunLoopPerformBlock`), never the main dispatch queue.** A Quit issued from a main-queue block waits for the cancel inside that block, where libdispatch never drains the main queue (`Mac/App/AGENTS.md`). Progress shares the queue, so no report lands after the settlement's sweep reset.

Settlement detaches the request's cancel waiters **before** calling its completion, then delivers them. A completion may accept another conversion and add its own waiter, which the old request must never consume.

A crash or kill can leave `vibe-convert-<uuid>.flac` in the container's tmp. `init` sweeps it on the converter queue, which the encode also runs on, so the sweep is done before the first conversion creates a temp.

## Tags, progress and disposal

`FLACTagCopier` copies TagLib's supported scalar properties to Vorbis comments and copies one picture. It prefers the front cover and otherwise keeps the first nonempty picture. Unsupported tag fields are omitted. It opens the header-sniffed container rather than trusting the extension or cached metadata. A failure is fatal to the conversion: the temp is removed and the original stays, so Delete Original can never turn a tag-copy failure into metadata loss.

The encode must reach the source's declared frame count, and the finished FLAC must reopen with that count, before tags or placement. A zero-frame read before the declared end is truncation, not EOF. The temp is removed and the source is untouched.

Placement gets one final positive validation before success reaches the controller. It runs off main on the disposal queue (`playableFileAtURL:`): one `AudioFileHandle` open that decodes at least one frame. If the placed FLAC becomes unavailable in that gap, the source and playlist stay untouched. The placed path is kept and logged in full. A save-panel placement may have replaced a user file, so provenance is not authority to delete what is there now.

`progressHandler` reports the encode on main at about one-percent steps, with the converting track. It drives the waveform's sweep (`WaveformUI/Renderers/AGENTS.md`).

`AudioFileConverter+Disposal` holds the source's trash, undo and redo, and the trash, restore and verify primitives under them. It shares its ivars with the core through `AudioFileConverterInternal.h`.

`trashSourceIfEnabled:convertedTo:` acts on Convert > Delete Original After Convert (also Settings > Files), off by default and **snapshotted when the conversion is accepted**. It trashes rather than unlinks, so it is undoable. It refuses when the output resolves to the source. A failure is logged and otherwise ignored. Its completion carries a `VibeTrashOutcome` apart from the optional Trash URL: a move with no returned location is still moved. **Who calls it, and when, is the controller's**, since the player holds the source open until the swap.

`trashItemAtURL:completion:` and `restoreTrashedItemAtURL:toURL:completion:` also serve the playlist's Move to Trash (`Mac/MainWindow/AGENTS.md`). The dispose queue runs at user-initiated QoS, because the user waits on every move.

`registerUndoForConversion:undoManager:swap:completion:` owns both directions of the file round trip on the window's `NSUndoManager`, using `VibeFLACConversionRecord`. The shell supplies only the row swap and UI settlement. The shared inverse restores the replacement from its Trash URL, verifies it, swaps, then trashes the retired file. Redo restores the FLAC rather than re-encoding, and re-trashes the source only when `sourceWasTrashed` says the conversion did. A disposal failure still commits a verified swap. A missing restore URL fails closed. A retired file already gone from its expected path makes the inverse a no-op, so an unrelated file now at that path is safe.

**TRAP: each invocation registers its opposite synchronously, before both the async move and the in-flight refusal.** Registered in an async completion, it lands on the wrong stack. Skipped on refusal, the popped action is lost. `isUndoRedoInFlight` is shared across all records and clears before settlement. `FLACDisposalRulesTests` drives the real manager and converter with held callbacks, failures included.

All disposal and verification run on their own serial dispose queue, not the converter queue, so an undo never waits out an encode. Completions land on main. Both moves run inside coordinated writes, because a FLAC placed by the related-item rung has a sandbox extension that rides the presenter's coordination. The restore's move refuses to overwrite. The verifier is positive: a destructive handoff needs proof that the file opened and carries audio.

**TRAP: menu validation must never stat the file system.** It runs on main on every menu open, and a stat on an unreachable network mount blocks until the mount times out. `validateConvertMenuItem:forTrack:` reads a cached FLAC-already-exists answer that each validation re-warms off main. The answer stays stale until its worker finishes. The conversion re-checks before writing. The Edit menu's undo items likewise read `NSUndoManager`'s stack alone.
