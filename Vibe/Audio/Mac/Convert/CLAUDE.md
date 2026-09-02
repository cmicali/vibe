# Converting to FLAC (macOS only)

Convert > Convert to FLAC and the window body's right-click item re-encode the **current track** as FLAC beside it — the app's only write path. Current-track-only is deliberate: a background row's conversion has no progress surface, and its swap has no playback state to preserve.

The controller half — the playlist swap and the undo round trip — is `Mac/MainWindow/CLAUDE.md`.

**The encoder is CoreAudio's** (`AVAudioFile` with `kAudioFormatFLAC`): no new dependency, nothing for `THIRD-PARTY-NOTICES.md`. ffmpeg was never an option — the app is sandboxed and ships in the App Store.

`FLACConvertRules.h` holds the preliminary eligibility and naming rules as static inlines, so the unit tests reach them without compiling the converter or TagLib. Eligibility is WAV and AIFF only: the sniffed `metadata.fileType` decides once it exists; the extension keeps the menu available before the background scan reaches a freshly dropped row. Acceptance always performs a RIFF/FORM header sniff on the converter queue.

**TRAP: the buffer's `commonFormat` is the only thing that sets the FLAC's declared source bit depth.** `AVEncoderBitDepthHintKey` and `AVLinearPCMBitDepthKey` are both silently ignored by this encoder. Int16 buffers give a 16-bit FLAC; anything wider gives 24-bit, the format's ceiling. So `encodeSource:` picks the buffer format from the source's own depth (`Int16` when not float and ≤16 bits, `Int32` otherwise), or a 16-bit recording is written as a 24-bit file that is bit-exact but misdescribes itself and is larger. Float is the one lossy case — FLAC stores integers, and every FLAC encoder quantizes float to 24 bits.

## Getting the output past the sandbox

`ENABLE_USER_SELECTED_FILES: readwrite` covers files the user actually opened, not a *new sibling* of one. The converter encodes into the container's tmp, then tries three rungs, cheapest first (`AudioFileConverter+Sandbox`):

1. **A plain move** — works when the grant was a folder.
2. **A coordinated move against an `NSFilePresenter`** whose `primaryPresentedItemURL` is the source — works for a single-file grant.
3. **An `NSSavePanel`** pre-filled with the folder and name — its own grant always works.

`AppSettings.convertAsksWhereToSave` (Settings > Convert) skips straight to the panel rung when a window exists, snapshotted at accept like the delete toggle. Ask-mode also lifts the destination-exists refusal and its menu disable.

All three rungs move the file **on the converter queue, not main**: file coordination blocks until every other presenter of the URL relinquishes it — other processes and the file-provider daemon included, unbounded on an iCloud or network folder — and a cross-volume destination turns even the panel rung's move into a full copy. Only the panel UI itself hops to main.

The panel rung refuses a selection that names the source itself — including a symlink, case alias or hard link — before its atomic replace. Its off-main `NSURL+FileIdentity` check resolves paths and compares current device/inode identity; do not move that blocking check onto the panel callback. A WAV container can legitimately arrive under a `.flac` filename and ask-mode permits replacing an existing destination, so extension and menu checks alone cannot guarantee the two URLs differ. The controller keeps a same-path guard as the final defense before it creates an undo record or disposes either file.

**TRAP: the related-item rung's sandbox extension lives exactly as long as the presenter registration.** Unregistering after the move leaves a file the app has just written and can no longer *read* — the player fails with `avfaudio error -54` — so successful presenters are kept for the session (`_relatedItemPresenters`), which the app needs anyway: the file is now in the playlist.

**TRAP: inside the related-item coordination block, a handed URL other than the sibling path is a tracked older item** — a previously trashed `foo.flac` — and following it would file the new FLAC in the Trash. The accessor compares standardized paths and falls back to the intended destination.

That rung also needs the flac extension declared in `CFBundleDocumentTypes` with `NSIsRelatedItemType`, separate from the real "Audio Files" entry; `DocumentTypes.declaredTypes` skips related-item entries so the type is not claimed twice.

## Cancelling, Quit and the temp sweep

`cancelConversionWithCompletion:` sets a flag the encode loop polls once per buffer; the temp is removed and the request completes with `NSUserCancelledError` — the same decision-not-failure a dismissed save panel reports, so the controller resets the sweep and neither beeps nor logs. A conversion already past its encode — copying tags, placing the file, or a save panel waiting for its answer — runs to its own completion; the cancel only parks its completion until then. It has two callers. `AppDelegate.applicationShouldTerminate:`: a Quit mid-encode answers `NSTerminateLater`, cancels, and replies from the converter's completion, so the temp file is gone before the process exits — bounded by one buffer during an encode, by the move during a placement. And Convert > Cancel Conversion, which is the Convert to FLAC item itself, retitled and re-aimed at `MainPlayerController.cancelConversion:` by menu validation while `isConverting` — the progress surface is the waveform sweep, which has no place for a button (`Mac/Menu/CLAUDE.md`); a click landing after the conversion settled reaches the not-running no-op.

What a crash or a kill leaves behind — `vibe-convert-<uuid>.flac` in the container's tmp — is swept at launch from `init`, on the converter queue rather than the dispose queue: the encode runs on that same serial queue, so the sweep is done before the first conversion can create the temp it would otherwise remove.

## Tags, progress and disposal

`FLACTagCopier` carries the source's tag over with TagLib: `setProperties` for the scalars (its `PropertyMap` normalizes ID3 spellings to Vorbis ones, `TBPM` → `BPM`) plus the front-cover picture. It revalidates and opens the header-sniffed container rather than trusting the extension or cached metadata. Failure is fatal to the conversion: the temporary FLAC is removed and the original remains in place, so enabling Delete Original can never turn a tag-copy failure into metadata loss.

The encode must reach the source's declared frame count and the finished FLAC must reopen with that same count before tag copying or placement. A zero-frame read before the declared end is truncation, not EOF success; the temporary output is removed and the source remains untouched.

Placement gets one final positive audio validation before success reaches the controller. It runs off-main on the disposal queue through `-[NSURL validateAudioFileIsReadableAndHasContent]`, the fd-safe proof that this process opened a regular nonempty file, CoreAudio accepted its container and it reports at least one audio packet. This method belongs only to conversion's destructive handoff; regular playback and waveform opens retain `failsAudioOpenPreflight` unchanged. If a provider or external move makes the placed FLAC unavailable in that gap, the source and playlist stay untouched. The placed path is preserved and its full absolute path is logged: a save-panel placement may have replaced a user file, and even a silent placement can be externally replaced before cleanup, so provenance is not sufficient authority to delete whatever is there now.

`progressHandler` reports the encode on the main thread at about one-percent steps, with the converting track so the owner can tell whether it is on screen. It drives the waveform's brush-through sweep (`WaveformUI/CLAUDE.md`).

`trashSourceIfEnabled:convertedTo:` acts on Convert > Delete Original, off by default and **snapshotted when the conversion is accepted** — a toggle flipped mid-encode applies to the next conversion, never the one in flight. Trash rather than unlink: undoable, recoverable from the Finder. It refuses when the output resolves to the source itself. Failure is logged and otherwise ignored; the conversion succeeded either way. Its completion carries a `VibeTrashOutcome` independently of the optional Trash URL: a successful move with no returned location is still moved, never collapsed into “the source stayed put.” **Who calls it, and when, is the controller's** — the player holds the source open until the swap.

Undo is the controller's too, through `NSUndoManager`; the converter contributes `trashItemAtURL:completion:`, `restoreTrashedItemAtURL:toURL:completion:` and the positive `verifyPlayableFileAtURL:completion:` gate. All disposal and verification calls run on their own serial dispose queue, not the converter queue — an undo never waits out an encode, and a move or read a cloud folder makes unbounded stays off main; completions land on main. Both moves run inside coordinated writes, because a FLAC only the related-item rung could place lives at a path whose sandbox extension rides the presenter's file coordination — a bare move there is denied. The restore's move refuses to overwrite. The verifier is deliberately positive: `!failsAudioOpenPreflight` is inconclusive when the descriptor could not open, while a destructive handoff requires proof that it did and that the accepted container carries audio packets.

**TRAP: menu validation must never stat the file system.** It runs on the main thread on every menu open, and a stat on an unreachable network mount blocks until the mount times out. `validateConvertMenuItem:forTrack:` reads a cached FLAC-already-exists answer that each validation re-warms off-main — stale by at most one menu open, and safe stale, because the conversion re-checks before writing. The Edit menu's undo items likewise read `NSUndoManager`'s stack alone; an emptied Trash surfaces only when the restore runs.
