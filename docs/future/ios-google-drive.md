# Future: Google Drive on iOS

**Status: Not built.** A single shared Google Drive file already plays through Open URL (`GoogleDriveLinkRules.h`, `Loading/Net/AGENTS.md`). This study is a native Files-tab source for a whole Drive library. No Google account, Cloud project or authenticated API request has been exercised.

## Recommendation

**A native client is feasible, on the same local-file playback model as Dropbox.** The work is account authorization, remote identity, listing reconciliation and shell integration. It needs no new decoder, player or audio transport. Start with a short spike before committing to Dropbox parity.

**The Files route does not work.** Picking from Google Drive's File Provider in the Files picker kept showing an error, and files and folders would not open. So a native client is the only way to play a Drive library on iOS.

**This plan assumes Google approves `drive.readonly`.** The inquiry has not been sent. Two questions decide the rest:

1. **Identity.** Drive allows duplicate names in one folder. The Dropbox mirror cannot represent that safely.
2. **Streaming.** Ranges are supported. But a head, a tail and a resumed download fetched separately need a proven way to belong to one content version. Whole-file playback is the first milestone if that proof is missing.

## What carries over

`Loading/Net/` already holds the shared mechanics (`Loading/Net/AGENTS.md`). `HTTPTransferClient` is the streamed download, the ranged read, the resends, the kept part and the version pin. `RemotePlaceholderStore` is placeholders under one root, the directory index, the fetch that streams, the ranged read, the download budget and the backend it installs. `CloudFileMaterializer` already takes several remote roots and sends a file to the backend of the longest root holding it. `DropboxClient` and `DropboxMirror` subclass the two, and so do `LinkClient` and `LinkStore`.

A Drive client and store follow that shape. Its subclass hooks hold the OAuth configuration, request construction, metadata extraction and failure ladder. The Dropbox pair adds `ASWebAuthenticationSession`, PKCE, Keychain refresh-token storage, one refresh claim, account-generation checks and cancellable retries. Factor those out of `DropboxClient` rather than copy them. A Drive pair is two new types, so it needs a complexity-budget exception argued on its own terms.

`AudioFileMaterializationCoordinator` and `CloudTransferRegistry` give playback priority, admission, cancellation and loading progress. Drive must enter the same paths. `FolderSession`, the browser, Search, Favorites and Settings have established places for a source. Their Dropbox-only lookups must find the store that owns a URL.

## Permission

**Scope.** Browsing an existing library needs `https://www.googleapis.com/auth/drive.readonly`. `drive.metadata.readonly` gives no audio bytes. Full `drive` grants writes. `drive.file` covers only app-created or picked items. Both broad read scopes are restricted ([scopes](https://developers.google.com/workspace/drive/api/guides/api-specific-auth)).

**Verification.** Restricted scopes are limited to listed app categories, and a music player is not listed. Google's minimum-scope guidance allows `drive.readonly` when a file browser cannot reasonably use per-file selection ([guidance](https://support.google.com/cloud/answer/13807380?hl=en)). The concrete limitation: opening an album folder, resolving its playlists, and finding later additions. Prepare a homepage, privacy policy, verified domain, scope justification and a demo of connect, browse, play and disconnect. Do not promise a paid security audit or an exemption from one. Ask for a determination for a device-only design, with tokens, names, tags, art and audio kept between Google and the device ([verification](https://developers.google.com/identity/protocols/oauth2/production-readiness/restricted-scope-verification), [assessment](https://support.google.com/cloud/answer/13465431)). Review takes weeks, so start it early.

**The mobile Picker is the fallback only if Google refuses.** It grants `drive.file` for picked files. Whether picking a folder grants the files inside it is undocumented, so a probe must settle it first ([Picker](https://developers.google.com/workspace/drive/picker/guides/desktop-mobile-picker)).

## Account

- Create an **iOS OAuth client** for Vibe's bundle id. The installed-app flow supports PKCE and a custom-scheme redirect, with no client secret ([installed-app OAuth](https://developers.google.com/identity/protocols/oauth2/native-app)). Use `ASWebAuthenticationSession` and `NSURLSession`, as the Dropbox client does. Register the callback in `project.yml`.
- Use a separate Keychain identity. Key the store on an opaque account id, not an email. `about.get`'s `permissionId` is the candidate to verify.
- A testing-mode OAuth project's refresh tokens expire after seven days. Expiry, revocation and org policy must lead to a clear reconnect state, never endless retries.
- It is an optional connection to a file source, not a Vibe account, so App Review guideline 4.8 does not apply. Say so in the review notes.

## API surface

Use authenticated REST, never Drive web-page links.

| Need | Request |
| --- | --- |
| Account | `GET /drive/v3/about?fields=user` |
| List a folder | `GET /drive/v3/files` with `q="'<folderId>' in parents and trashed = false"`, `spaces=drive`, explicit fields and paging. `root` is My Drive. |
| Resolve an item | `GET /drive/v3/files/<fileId>?fields=…`, keeping parent ids |
| Download or read a range | `GET /drive/v3/files/<fileId>?alt=media`, with `Range` |
| Search | `files.list` with a name query, then the extension filter |
| Incremental refresh, later | `changes.getStartPageToken`, `changes.list` |

- Request only the fields used. Filter through `PlayableExtensions`, keeping `.cue`, `.m3u` and `.m3u8`. Never filter on `audio/*` alone.
- Accumulate every page before reconciling. Follow `nextPageToken` past a short or empty page. A rejected token restarts the listing. `incompleteSearch` means results are missing. A failed or incomplete listing keeps the cached directory and deletes nothing.
- **Search differs from Dropbox.** `name contains` matches prefixes. `fullText contains` matches tokens. Label the scope Google Drive and measure whether prefix search is enough. A parent query selects direct children only, so verify a hit's ancestry, bounded and cached, before offering it.

## Identity is the largest model change

Drive items have ids and parent references, and names are not unique in a folder. `version` moves for non-content changes too. `headRevisionId` and the checksums describe content. Clients can set `modifiedTime`. So Dropbox's case-folded path lookup and size-plus-mtime comparison are not enough ([file resource](https://developers.google.com/workspace/drive/api/reference/rest/v3/files)).

Keep four things apart:

- **Remote identity:** provider, account id and file id. Requests always use the id, never a name read back from disk.
- **Local slot:** a safe filename recorded against the id. Persist collision suffixes, so listing order cannot rename a cached file. Cover duplicates, case-only differences, Unicode normalization, separators, dot components, long names and part-file collisions.
- **Display name:** Google's name. An internal suffix must never become a track's title. `AudioTrack.displayTitle` stays the one title decision.
- **Content identity:** revision or checksum and size, kept apart from the remote modification date.

These can be richer entries in the existing directory index. A CUE or M3U entry that names two different Drive files is ambiguous. Report it rather than play either.

**TRAP: a version check in the store does not invalidate Vibe's caches.** `NSURL+Hash.cacheKey` reads the local size, mtime and resolved path. A same-size replacement with a preserved remote date would reuse old tags, art, waveform and analysis. Pick one strategy in the spike, such as a local mtime stamp that changes with each content revision and survives placeholder, download and eviction. Check its effect on date sorting.

Renames and moves affect Favorites, Recents and session bookmarks. Decide whether a slot survives a rename, or whether a stale bookmark re-resolves by remote id. Do not relocate the Dropbox tree, whose URLs are persisted.

## Downloading and streaming

Drive supports `Range` on binary downloads. Dropbox carries its `rev` in each content response. Drive's metadata response does not establish the version of a later media response. `revisions.get?alt=media` needs the revision marked Keep Forever, which is a write, so do not rely on it ([downloads](https://developers.google.com/workspace/drive/api/guides/manage-downloads)).

The probe must find out whether a media response carries a strong validator and honors a conditional range across an edit. Test a `206`, an ignored range answering `200`, invalid ranges, redirects, token refresh and a same-size replacement mid-transfer.

**Until then, download whole and validate before the file becomes readable.** Compare the expected size and the content checksum, recheck metadata, then install atomically. Compute the checksum while writing. A changed version is a failed fetch. Restart an interrupted download rather than append. Ranged tag reads are allowed only if metadata checks before and after the parse reject a changed version, and a rejected parse never enters the cache.

Once consistency is proven, use the existing availability, tail window, interruptible reads and transfer registry. Never join a tail from one revision with a head from another.

## Scope and limits

**First release:** My Drive folders and supported audio, CUE and M3U, Open and Add, Favorites, Recents and restore, cached offline playback, storage controls, and Drive beside Dropbox. One Google account. A budget per provider.

**Deferred:** shared drives, Shared with Me, public-link import, several Google accounts, uploads and full sync. Shortcuts need a first-release decision: resolve them, or show them as unsupported. Their target ids join dedupe and cycle detection. Link-shared targets may need resource keys sent in `X-Goog-Drive-Resource-Keys` ([resource keys](https://developers.google.com/workspace/drive/api/guides/resource-keys)). Shared drives need `supportsAllDrives` and `driveId` scoping ([shared drives](https://developers.google.com/workspace/drive/api/guides/enable-shareddrives)).

**Quotas.** Google's 2026 limits are per project and per user, with a daily egress threshold and announced billing ([limits](https://developers.google.com/workspace/drive/api/guides/limits)). Verify the project's actual limits before release. Keep listings lazy and foreground priority first. Build no account-wide scan by default.

**Errors.** Some `403`s are rate limits and others are permissions or policy. A `404` can mean no access. Refresh once for an expired credential. Back off with jitter for limits and 5xx. Surface file and policy failures without unlinking the account. `capabilities.canDownload` avoids futile plays ([errors](https://developers.google.com/workspace/drive/api/guides/handle-errors)).

**Background.** Keep Dropbox's distinction between background audio and a suspended app. Test next-track fetches, token refresh, file protection and network recovery on a locked device. Do not promise unattended downloads after suspension.

## Sequence

1. **Google side.** Create the Cloud project and a test iOS client. Send the scope inquiry. Recheck quotas.
2. **Prove content and identity.** Range responses and replacement races. Duplicate and normalized names, CUE and M3U, same-size edits with preserved dates, moves and renames. Decide the slot mapping, the cache stamp and whole-file versus streaming.
3. **Ship whole-file playback.** Keep Dropbox covered while adding the Drive pair, browsing, verified downloads, restore, settings and search.
4. **Add streaming when the probe justifies it.** Measure latency and egress against whole-file playback and Dropbox on the same files and network.

Host-less tests extend the stubbed-`NSURLProtocol` suites (`RemotePlaceholderStoreTests`, `DropboxMirrorTests`): paging and partial failure, account changes mid-refresh, cancellation during backoff, duplicate names, checksum mismatch, stale-cache prevention, eviction, disconnected roots and two providers at once. Running-app checks belong in the debug channel, with fake network scenarios so CI needs no Google credentials. Lock-screen playback needs a device.
