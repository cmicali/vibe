# Future: which cloud file services to handle next, in order

**Status: Partly built.** Items 1, 2 and 3 are partly built, and each links to its plan's remaining part. Items 4 and 5 are not built. Current behavior is in `Vibe/Loading/iOS/Dropbox/AGENTS.md`, `vibe-libs/files/FileLoading/AGENTS.md` and `Vibe/Loading/Net/AGENTS.md`.

## Where things stand

- **The Mac needs no native client.** Dropbox, iCloud Drive, OneDrive, Google Drive and Box all arrive as File Providers. The materializer downloads a placeholder whole and the open waits for it. Network shares read by range and read ahead.
- **iOS has one native client, Dropbox,** with its own mirror and streaming. Every other source comes through the Files picker as a provider folder, downloaded whole. An SMB volume from the Files app is a live network mount, read in place.
- **Single shared files from Dropbox, Google Drive and iCloud Drive play through Open URL** on both platforms, with no account.
- **Recheck Google Drive's Files integration before building a client.** Earlier device checks failed to open its files and folders. That result does not establish the behavior of later provider versions.

## The order

### 0. Probes still to run

- **USB on iOS.** What a USB drive picked in the Files app is. A Debug build launched with `--dataless-diag` logs each picked directory's mount and dataless verdict (the `vibe-debug` skill's on-device log section).
- **Google's restricted-scope inquiry for `drive.readonly`.** Item 4 assumes Google approves it. Ask about the scope before committing to the client.
- **A sleeping server on iOS.** On the Mac a dropped server stalled playback silently before the read-ahead. iOS was not tried.

### 1. iCloud Drive on iOS

Add Folder… names iCloud Drive, and cached artwork shows for files not downloaded. What remains is a device check and the browser follow-ups ([plan](ios-icloud-improvements.md)).

### 2. Network shares

The availability takes any writer, and a network mount reads ahead. What remains is in the [streaming plan](streaming-any-source.md). Each native client below is a writer behind an unchanged reader.

### 3. Links

[Vibe links](share-links.md): the app half is built as Open URL. The link service, its landing page and universal links remain. [Dropbox shared folder links](dropbox-shared-links.md) need a signed-in account. Defer their share extension until someone asks, since it is a new target with no offsetting removal.

### 4. Google Drive, a native client on iOS

[Study](ios-google-drive.md). It assumes `drive.readonly`, so the client browses the whole account. The cost is identity: file ids instead of paths, duplicate names in one folder, and no version pin on a media response. Whole-file playback first. Streaming only once a head, a tail and a resumed download can be proven to belong to one revision.

The shared HTTP client and placeholder store already exist (`HTTPTransferClient`, `RemotePlaceholderStore`), and Dropbox and Open URL subclass both. Drive follows that shape. Dropbox's index already records each file's id for its download. Drive's names are not unique in a folder, so its index must also map each local filename to a file id.

### 5. WebDAV, a native client on iOS

Covers Nextcloud, ownCloud, Synology and most self-hosted NAS setups. The Files app does not reach them on iOS. A listing is one `PROPFIND`, a version is an ETag, a read is an HTTP range, and there is no OAuth. It reuses item 4's shape. Order it by demand.

## Deferred

OneDrive and Box wait until after item 5.

- **OneDrive.** The cheapest service once item 4 exists. From Microsoft's Graph documentation, not probed: `Files.Read` is a delegated permission with no restricted-scope review. Names are unique in a folder. Each item carries a content tag that moves only with the bytes. The download URL honors `Range`. Before any code, run the Files-picker checks on its app: whether an unseen nested folder lists, whether the grant survives a relaunch, and whether lock-screen playback works. If it fails them, probe the API on a device.
- **Box.** Enterprise-skewed. It fits item 4's shape if asked for.

## Not recommended

- **Plex, Jellyfin, Subsonic.** Media servers with their own transcoding APIs. A different product.
- **A native client on the Mac for any of these.** The File Provider path covers them.

## Budget

Item 4 adds a service's client and store. Item 5 and the deferred services reuse its shape and add no second cloud stack. Each item reports its own net lines, new files and new types when it lands.
