# Converting to FLAC (macOS only)

Convert > Convert to FLAC and the window body's right-click item re-encode the **current track** as FLAC beside it — the app's only write path. Current-track-only is deliberate: a background row's conversion has no progress surface, and its swap has no playback state to preserve.

The controller half — the playlist swap and the undo round trip — is `Mac/MainWindow/CLAUDE.md`.

**The encoder is CoreAudio's** (`AVAudioFile` with `kAudioFormatFLAC`): no new dependency, nothing for `THIRD-PARTY-NOTICES.md`. ffmpeg was never an option — the app is sandboxed and ships in the App Store.

`FLACConvertRules.h` holds the eligibility and naming rules as static inlines, so the unit tests reach them without compiling the converter or TagLib. Eligibility is WAV and AIFF only: the sniffed `metadata.fileType` decides once it exists; the extension covers the window before the background scan reaches a freshly dropped row.

**TRAP: the buffer's `commonFormat` is the only thing that sets the FLAC's declared source bit depth.** `AVEncoderBitDepthHintKey` and `AVLinearPCMBitDepthKey` are both silently ignored by this encoder. Int16 buffers give a 16-bit FLAC; anything wider gives 24-bit, the format's ceiling. So `encodeSource:` picks the buffer format from the source's own depth (`Int16` when not float and ≤16 bits, `Int32` otherwise), or a 16-bit recording is written as a 24-bit file that is bit-exact but misdescribes itself and is larger. Float is the one lossy case — FLAC stores integers, and every FLAC encoder quantizes float to 24 bits.

## Getting the output past the sandbox

`ENABLE_USER_SELECTED_FILES: readwrite` covers files the user actually opened, not a *new sibling* of one. The converter encodes into the container's tmp, then tries three rungs, cheapest first (`AudioFileConverter+Sandbox`):

1. **A plain move** — works when the grant was a folder.
2. **A coordinated move against an `NSFilePresenter`** whose `primaryPresentedItemURL` is the source — works for a single-file grant.
3. **An `NSSavePanel`** pre-filled with the folder and name — its own grant always works.

`AppSettings.convertAsksWhereToSave` (Settings > Convert) skips straight to the panel rung when a window exists, snapshotted at accept like the delete toggle. Ask-mode also lifts the destination-exists refusal and its menu disable.

All three rungs move the file **on the converter queue, not main**: file coordination blocks until every other presenter of the URL relinquishes it — other processes and the file-provider daemon included, unbounded on an iCloud or network folder — and a cross-volume destination turns even the panel rung's move into a full copy. Only the panel UI itself hops to main.

**TRAP: the related-item rung's sandbox extension lives exactly as long as the presenter registration.** Unregistering after the move leaves a file the app has just written and can no longer *read* — the player fails with `avfaudio error -54` — so successful presenters are kept for the session (`_relatedItemPresenters`), which the app needs anyway: the file is now in the playlist.

**TRAP: inside the related-item coordination block, a handed URL other than the sibling path is a tracked older item** — a previously trashed `foo.flac` — and following it would file the new FLAC in the Trash. The accessor compares standardized paths and falls back to the intended destination.

That rung also needs the flac extension declared in `CFBundleDocumentTypes` with `NSIsRelatedItemType`, separate from the real "Audio Files" entry; `DocumentTypes.declaredTypes` skips related-item entries so the type is not claimed twice.

## Tags, progress and disposal

`FLACTagCopier` carries the source's tag over with TagLib: `setProperties` for the scalars (its `PropertyMap` normalizes ID3 spellings to Vorbis ones, `TBPM` → `BPM`) plus the front-cover picture. Failure is non-fatal — an untagged FLAC is still the user's audio, and every display path falls back to the filename.

`progressHandler` reports the encode on the main thread at about one-percent steps, with the converting track so the owner can tell whether it is on screen. It drives the waveform's brush-through sweep (`WaveformUI/CLAUDE.md`).

`trashSourceIfEnabled:convertedTo:` acts on Convert > Delete Original, off by default and **snapshotted when the conversion is accepted** — a toggle flipped mid-encode applies to the next conversion, never the one in flight. Trash rather than unlink: undoable, recoverable from the Finder. It refuses when the output resolves to the source itself. Failure is logged and otherwise ignored; the conversion succeeded either way. The completion reports where the Trash put the file, which the controller folds into the undo record. **Who calls it, and when, is the controller's** — the player holds the source open until the swap.

Undo is the controller's too, through `NSUndoManager`; the converter contributes only `trashItemAtURL:completion:` and `restoreTrashedItemAtURL:toURL:completion:`. All three disposal calls run on their own serial dispose queue, not the converter queue — an undo never waits out an encode, and a move a cloud folder makes unbounded stays off main; completions land on main. Both moves run inside coordinated writes, because a FLAC only the related-item rung could place lives at a path whose sandbox extension rides the presenter's file coordination — a bare move there is denied. The restore's move refuses to overwrite.

**TRAP: menu validation must never stat the file system.** It runs on the main thread on every menu open, and a stat on an unreachable network mount blocks until the mount times out. `validateConvertMenuItem:forTrack:` reads a cached FLAC-already-exists answer that each validation re-warms off-main — stale by at most one menu open, and safe stale, because the conversion re-checks before writing. The Edit menu's undo items likewise read `NSUndoManager`'s stack alone; an emptied Trash surfaces only when the restore runs.
