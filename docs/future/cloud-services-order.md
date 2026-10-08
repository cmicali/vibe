# Future: which cloud file services to handle next, in order

**Status: planned 2026-10-08, nothing started.** This is the order for the other file sources, with the reason for each place. The plans it points at are the detail: [iCloud Drive](ios-icloud-improvements.md), [streaming from any source](streaming-any-source.md), [Dropbox shared links](dropbox-shared-links.md) and [Google Drive](ios-google-drive.md). Current behavior is in the [Dropbox](../../Vibe/iOS/Dropbox/AGENTS.md), [file-loading](../../Vibe/Audio/Loading/AGENTS.md) and [System](../../Vibe/System/AGENTS.md) docs.

## Where things stand

- **The Mac needs no native client.** Dropbox, iCloud Drive, OneDrive, Google Drive and Box all arrive as File Providers. The materializer downloads a placeholder whole and the open waits for it. Only network shares change anything there (item 2).
- **iOS has one native client, Dropbox**, with its own mirror and streaming. Every other source comes through the Files picker as a provider folder, downloaded whole. Dropbox's own provider listed a folder only once Dropbox had, which is why the native client exists.
- **The streaming model serves one writer today**, the Dropbox download. Every later native client either waits for its generalization or opens whole files.

## The order

### 0. Probe first, no app code

One afternoon on a device decides which services need native work at all.

- Pick a folder from the Google Drive, OneDrive and Box apps through the Files picker. Check whether an unseen nested folder enumerates, whether the grant survives a relaunch, and whether lock-screen playback works. A provider that passes needs nothing more than item 1's polish.
- Check what the Files app's SMB and USB volumes are on iOS: a live mount read in place, or a provider copy. The streaming plan's phase 0 asks the same question.
- Send Google the restricted-scope inquiry for `drive.readonly` now. The answer takes weeks of calendar time and no engineering. Item 5 cannot start without it.

### 1. iCloud Drive on iOS

[Plan](ios-icloud-improvements.md). It already works through the picker. The plan adds a setup entry in the Files tab, cached artwork for files no longer downloaded, and the browser follow-ups. Zero new files and zero new types. The artwork rule applies to every provider folder and to Dropbox placeholders too. This is the largest iPhone audience for the least code.

### 2. Network shares, and the availability that takes any writer

[Plan](streaming-any-source.md). An SMB, NFS or WebDAV mount on the Mac already reads by range, but a read on a sleeping NAS cannot be interrupted. A seek hangs until the volume answers. Phase 1 makes the streaming availability take any writer, with Dropbox the only writer and its behavior unchanged. Phase 2 adds the file read-ahead for playback.

This is infrastructure, not only a feature. Each native client below is then a writer behind an unchanged reader. Phase 0's measurements decide how far past phase 1 to go.

### 3. Dropbox shared links

[Plan](dropbox-shared-links.md). Not a new service, but it extends the stack users already have. Phase 1 is zero new files and folds the client's two path lookups into one. Defer phase 2, the share extension, until someone asks for it. It is a new target with no offsetting removal.

### 4. OneDrive, a native client on iOS

The cheapest second service, from Microsoft's Graph documentation as read, not probed:

- `Files.Read` is a delegated permission with no restricted-scope review.
- Names are unique within a folder, so the mirror's path lookup holds.
- Each item carries an ETag and a content tag that moves only with the bytes. That is the version check.
- The download URL honors `Range`, so tags read by range as Dropbox's do.

That maps onto `DropboxClient` and `DropboxMirror` nearly as they are. This is the right place to turn them into one client and one mirror parameterized by service: the wire encodings and the failure ladder differ, the listing reconciliation, placeholders, budget and eviction do not. Build it before Google Drive even though Google has more users. The model cost is a fraction.

A device probe before any code: sign in, list a nested folder, read a tag by range, download a file, replace it remotely and confirm the content tag moved.

### 5. Google Drive, a native client on iOS

[Study](ios-google-drive.md). Gated on Google's scope answer from item 0. The cost is the identity change the study names: file IDs instead of paths, duplicate names in one folder, and no version pin on a media response. If the Picker's folder grant probe passes, the scope shrinks to a selected Music folder. Whole-file playback first. Streaming only once a head, a tail and a resumed download can be proven to belong to one revision.

### 6. WebDAV, a native client on iOS

Covers Nextcloud, ownCloud, Synology and most self-hosted NAS setups. The Files app does not reach them on iOS. A listing is one `PROPFIND`, a version is an ETag, a read is an HTTP range, and there is no OAuth. It reuses item 4's shape. Order it against item 5 by demand.

## Not recommended

- **Box.** Enterprise-skewed. It fits item 4's shape if ever asked for.
- **Plex, Jellyfin, Subsonic.** Media servers with their own transcoding APIs. A different product.
- **A native client on the Mac for any of these.** The File Provider path covers them.

## The budget, across the list

Items 1, 2 and 3 plan zero new files and zero new types. Item 4 adds a service's client and mirror, and must give back the Dropbox-specific shape of both. Items 5 and 6 reuse item 4's shape and add no second cloud stack. Each item reports its own net lines, new files and new types when it lands.
