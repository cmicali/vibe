# Future: which cloud file services to handle next, in order

**Status: planned 2026-10-08. Item 0 is partly done, and its results are under item 0.** The only app code built is item 0's debug-only probe log. This is the order for the other file sources, with the reason for each place. The plans it points at are the detail: [iCloud Drive](ios-icloud-improvements.md), [streaming from any source](streaming-any-source.md), [Dropbox shared links](dropbox-shared-links.md), [Vibe links](share-links.md) and [Google Drive](ios-google-drive.md). Current behavior is in the [Dropbox](../../Vibe/iOS/Dropbox/AGENTS.md), [file-loading](../../Vibe/Loading/AGENTS.md) docs.

## Where things stand

- **The Mac needs no native client.** Dropbox, iCloud Drive, OneDrive, Google Drive and Box all arrive as File Providers. The materializer downloads a placeholder whole and the open waits for it. Only network shares change anything there (item 2).
- **iOS has one native client, Dropbox**, with its own mirror and streaming. Every other source comes through the Files picker as a provider folder, downloaded whole. Dropbox's own provider listed a folder only once Dropbox had, which is why the native client exists.
- **The streaming model serves one writer today**, the Dropbox download. Every later native client either waits for its generalization or opens whole files.

## The order

### 0. Probe first, no app code

One afternoon on a device decides which services need native work at all.

- Pick a folder from the Google Drive app through the Files picker. Check whether an unseen nested folder enumerates, whether the grant survives a relaunch, and whether lock-screen playback works. A provider that passes needs nothing more than item 1's polish.
- Check what the Files app's SMB and USB volumes are on iOS: a live mount read in place, or a provider copy. The streaming plan's phase 0 asks the same question. A Debug build launched with `--dataless-diag` logs each picked directory's mount and dataless verdict (the `vibe-debug` skill's on-device log section).
- Send Google the restricted-scope inquiry for `drive.readonly` now. Item 4 assumes Google approves it. Verification still takes weeks of calendar time, so start it early. It needs no engineering.

**Results, 2026-10-08.** The Files-picker probe ran on the maintainer's iPhone. Each provider got a `Probe` folder made from a computer, so the phone had never listed it.

| Probe | Result |
| --- | --- |
| Google Drive | Failed every check. Picking from it kept showing an error message, and files and folders would not open. So nothing listed, played, survived a relaunch, or played on the lock screen. The playlist check was never reached. It behaved much worse than Dropbox's own provider. |
| OneDrive and Box | Deferred. They are the lowest priority (Deferred, below). |
| SMB on the Mac | Healthy, it plays with no read-ahead: opens about 30 ms and cold seeks about 150 ms slower than local, no underruns. A dropped server stalls the audio silently: 12 s of underrun while the player still said playing. A main-thread `stat` at every track start blocked the UI for up to 430 ms. Detail in the [streaming plan](streaming-any-source.md)'s phase 0. |
| SMB on iOS | A live network mount, not a provider copy. The folder listed and played. The open took 87 ms. Detail in the [streaming plan](streaming-any-source.md)'s measured facts. |
| USB on iOS | Not run, since no drive was at hand. Rerun with `--dataless-diag`. |
| Google scope inquiry | Not sent. |

**What the results change.** Google Drive on iOS has no Files route to fall back on. A native client (item 4) is the only way to play from it. So item 4's scope assumption carries the whole feature.

SMB on iOS reads in place over the wire, as it does on the Mac. So item 2's read-ahead serves both platforms, not only the Mac. On the Mac a dropped server stalls playback with no buffering state and no error, so phase 1's availability and phase 2's read-ahead are worth building there. A sleeping server probably does the same on iOS. That was not tried.

### 1. iCloud Drive on iOS

[Plan](ios-icloud-improvements.md). It already works through the picker. The plan adds a setup step in the Files tab, cached artwork for files no longer downloaded, and the browser follow-ups. Zero new files and zero new types. The artwork rule applies to every provider folder and to Dropbox placeholders too. This is the largest iPhone audience for the least code.

**Built 2026-10-08: Add Folder… names iCloud Drive and opens the granted folder, and cached artwork shows for files not downloaded.** Each landed with zero new files and zero new types. A real iCloud eviction is still to check on a device. The browser follow-ups wait on product decisions.

### 2. Network shares, and the availability that takes any writer

[Plan](streaming-any-source.md). An SMB, NFS or WebDAV mount on the Mac already reads by range, but a read on a sleeping NAS cannot be interrupted. A seek hangs until the volume answers. Phase 1 makes the streaming availability take any writer, with Dropbox the only writer and its behavior unchanged. Phase 2 adds the file read-ahead for playback.

This is infrastructure, not only a feature. Each native client below is then a writer behind an unchanged reader. Phase 0's measurements decide how far past phase 1 to go.

### 3. Links

Two plans, one shape. [Vibe links](share-links.md) plays a single file reached by a plain HTTP URL, with no account, on both platforms. Its app half is built as Open URL (`Loading/Net/AGENTS.md`). It moved the streamed download and the ranged read out of `DropboxClient` into one shared HTTP transfer. It turned the remote backend from one root into a registration per root. Items 4 and 5 need both of those, which is why this plan went first. [Dropbox shared links](dropbox-shared-links.md) is folder links through a signed-in account. Its phase 1 is zero new files and folds the client's two path lookups into one. Defer its phase 2, the share extension, until someone asks for it. It is a new target with no offsetting removal.

### 4. Google Drive, a native client on iOS

[Study](ios-google-drive.md). It assumes Google approves `drive.readonly` (item 0), so the client browses the whole account. The cost is the identity change the study names: file IDs instead of paths, duplicate names in one folder, and no version pin on a media response. Whole-file playback first. Streaming only once a head, a tail and a resumed download can be proven to belong to one revision.

This is the place to turn `DropboxClient` and `DropboxMirror` into one client and one mirror parameterized by service. The wire encodings and the failure ladder differ. The listing reconciliation, placeholders, budget and eviction do not. Google is the harder second service for this, since its identity is a file ID and Dropbox's is a path. So the shared mirror keys on a remote ID, and Dropbox's path is its ID.

### 5. WebDAV, a native client on iOS

Covers Nextcloud, ownCloud, Synology and most self-hosted NAS setups. The Files app does not reach them on iOS. A listing is one `PROPFIND`, a version is an ETag, a read is an HTTP range, and there is no OAuth. It reuses item 4's shared client and mirror. Order it by demand.

## Deferred

OneDrive and Box are the maintainer's lowest priority, so their probes and clients wait until after item 5.

- **OneDrive.** The cheapest service to add once item 4's shared client and mirror exist. From Microsoft's Graph documentation as read, not probed: `Files.Read` is a delegated permission with no restricted-scope review. Names are unique within a folder. Each item carries a content tag that moves only with the bytes. The download URL honors `Range`. Before any code, run item 0's Files-picker checks on its app. If it fails them, probe the API on a device: sign in, list a nested folder, read a tag by range, download a file, replace it remotely and confirm the content tag moved.
- **Box.** Enterprise-skewed. It fits item 4's shape if ever asked for.

## Not recommended

- **Plex, Jellyfin, Subsonic.** Media servers with their own transcoding APIs. A different product.
- **A native client on the Mac for any of these.** The File Provider path covers them.

## The budget, across the list

Items 1 and 2 plan zero new files and zero new types. Item 3's budget is in each of its two plans. Item 4 adds a service's client and mirror, and must give back the Dropbox-specific shape of both. Item 5 and the deferred services reuse item 4's shape and add no second cloud stack. Each item reports its own net lines, new files and new types when it lands.
