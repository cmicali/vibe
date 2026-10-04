# Google Drive on iOS: feasibility and implementation research

Researched 2026-10-04 against repository revision `0ee9e8bc` and the official documentation linked below. This is a proposal, not an implementation. No Google account, Cloud project, device integration, or authenticated API request was exercised. Behaviors needing a live probe are identified explicitly.

## Recommendation

**Google Drive is technically feasible as another native Files-tab source, using the same local-file playback model as Dropbox.** The work is chiefly account authorization, remote identity, mirror reconciliation, and shell integration. It should not require another decoder, player, or audio transport.

Proceed with a short feasibility spike before committing to full Dropbox parity. Three decisions determine the scope:

1. **Permission:** full library browsing points to `drive.readonly`, which requires Google's restricted-scope review. Establish whether Google accepts Vibe's use case. Also probe the newly documented mobile Picker as a narrower alternative; selecting a folder must not be assumed to authorize its descendants.
2. **Identity:** Drive permits duplicate names within one folder. The current Dropbox mirror cannot represent that safely without changes.
3. **Streaming:** byte ranges are supported, but separately fetched head, tail, and resumed bytes need a proven way to belong to the same content version. Whole-file playback is a viable first milestone if that proof is unavailable.

The scope and API facts behind these conclusions are documented in [Drive authorization](https://developers.google.com/workspace/drive/api/guides/api-specific-auth), the [file resource](https://developers.google.com/workspace/drive/api/reference/rest/v3/files), and [downloads](https://developers.google.com/workspace/drive/api/guides/manage-downloads). The implementation recommendations are deductions from those facts and Vibe's code.

## What Dropbox already gives us

The relevant baseline is the current implementation, including streaming, rather than the older plans in this directory. See [Dropbox's subsystem documentation](../../Vibe/iOS/Dropbox/AGENTS.md), the [iOS shell](../../Vibe/iOS/AGENTS.md), and [the materializer](../../Vibe/System/AGENTS.md).

| Existing owner | What can carry over |
| --- | --- |
| `DropboxClient` | `ASWebAuthenticationSession`, PKCE, Keychain refresh-token storage, one refresh claim, account-generation checks, cancellable retries, separate request and download sessions. Google needs its own request and error interpretation. |
| `DropboxMirror` | Lazy directory listings, unreadable sparse placeholders, directory indexes, sidecar downloads, atomic installation, download accounting and eviction. Remote identity and version comparison need to change. |
| `CloudFileMaterializer` / `CloudFileAvailability` | Fetch, ranged-read and availability blocks; a growing part file; interruptible reads; a tail window. These already avoid provider-specific logic in the decoder. |
| `AudioFileMaterializationCoordinator` / `CloudTransferRegistry` | Playback priority, shared work, admission limits, cancellation, and the single source of loading progress. Drive must enter these same paths. |
| `FolderSession` | Open/Add, playlist expansion, local URLs, restore, and asynchronous-open staleness. Its Dropbox-specific lookups need to recognize another mirror. |
| Browser, Search, Favorites and Settings | Established places for a source, connection controls, cached directories, remote search, storage budget, and disconnect behavior. |

Dropbox currently uses no SDK. Its client and mirror alone total 2,145 implementation lines; copying them would duplicate the most failure-sensitive machinery. The opportunity is to share their existing mechanics while keeping each service's wire format explicit.

## Permission and product choices

### Existing Files-provider route

Apple documents Google Drive as a service users can enable in Files after installing its app. Vibe's existing Browse Files route is therefore the first thing to test on a device. Folder selection, retained access, cold listings and lock-screen behavior need separate verification; appearing in Files does not establish all of them. [Apple's Files instructions](https://support.apple.com/en-us/102238)

This is useful as a baseline and fallback. It does not give Vibe control of Drive's remote search, transfer progress, or ranged downloads. The Dropbox integration was built precisely because its Files provider did not reliably enumerate unseen folders; that history warrants testing Google's provider, not assuming it has the same defect.

### Full browsing through Drive API v3

For an in-app browser over an existing music library, the relevant scope is `https://www.googleapis.com/auth/drive.readonly`. `drive.metadata.readonly` cannot supply audio bytes; full `drive` would grant unnecessary writes. `drive.file` grants access to app-created or individually authorized items, not a documented account-wide read grant. Both broad read scopes are restricted. [Scope definitions](https://developers.google.com/workspace/drive/api/guides/api-specific-auth)

Google limits restricted scopes to specified application categories, including backup/sync and productivity/education. **A music player is not explicitly listed.** Vibe can explain its user-directed browsing and local playback, but approval is unresolved. Ask Google to assess the actual workflow before treating public distribution as feasible. [Eligible application types](https://developers.google.com/workspace/drive/api/guides/api-specific-auth#qualifications_for_restricted_scopes)

Google's minimum-scope guidance specifically allows a justification for `drive.readonly` when an app's file browser cannot reasonably use per-file selection. Document the concrete limitation: opening an album folder, resolving its playlists, and discovering later additions. A preference for custom UI alone is a weaker case. [Minimum-scope guidance](https://support.google.com/cloud/answer/13807380?hl=en)

Prepare a public homepage, privacy policy, verified domain, scope justification, and a demonstration of connection, browsing, playback and disconnection. Google's restricted-scope guide ties annual security assessment to access through a third-party server; its Help Center describes the requirement more broadly. **Do not promise either a mandatory paid audit or an automatic device-only exemption.** Seek a determination for the proposed architecture. Keep tokens, filenames, tags, art and audio between Google and the device; a future proxy, analytics payload or uploaded diagnostic may change that assessment. Review can take weeks, separately from engineering. [Verification guide](https://developers.google.com/identity/protocols/oauth2/production-readiness/restricted-scope-verification), [security-assessment overview](https://support.google.com/cloud/answer/13465431)

### Selected files through the mobile Picker

Google now documents a browser-based desktop/mobile Picker, with a page updated September 29, 2026. The authorization request adds `prompt=consent` and `trigger_onepick=true`; options include multiple selection and folder selection. The callback carries selected file IDs. This flow permits only `drive.file`, without additional scopes in that request. It is no longer accurate to dismiss Picker as only a JavaScript widget for websites. [Mobile Picker integration](https://developers.google.com/workspace/drive/picker/guides/desktop-mobile-picker)

**Folder selection is not a documented promise of recursive authorization.** Probe an existing folder, its existing children, nested folders, and a file added after consent, using a fresh grant that has never held a broader scope. Also verify the iOS callback and cancellation flow. Until demonstrated and confirmed, describe this option as selected-file access, with CUE/M3U dependencies requiring their own access. The consent scope can allow modification of selected files even though Vibe would only read them. [Picker overview](https://developers.google.com/workspace/drive/picker/guides/overview), [per-file scope](https://support.google.com/cloud/answer/13807380?hl=en)

A successful folder-access probe could make a user-selected Music folder preferable to full-account access. Otherwise Picker is a smaller import/select product, and does not satisfy full Dropbox-style browsing and account-wide search.

## Account integration

Enable Drive API in a Google Cloud project and create an **iOS OAuth client** for Vibe's actual bundle identifier. The installed-app flow supports PKCE and an iOS custom-scheme redirect; an iOS client does not use a client secret. Google recommends its Sign-In SDK, but also documents the protocol. The first spike can use `ASWebAuthenticationSession` and `NSURLSession`, following the existing client, with fresh state, S256 PKCE, exact redirect validation and granted-scope checks. Register Google's callback through `project.yml` and regenerate the project; do not copy Dropbox's special callback convention. No embedded credential form or backend is needed for this design. [Installed-app OAuth](https://developers.google.com/identity/protocols/oauth2/native-app)

Preserve the existing Keychain accessibility, before-first-unlock handling, refresh claim, cancellation while refreshing, and late-account-response protection. Use a separate Keychain identity for Google. Store an opaque account ID rather than an email address as the mirror's identity: `about.get` exposes the current user, whose `permissionId` is a candidate to verify during the spike. Email and display name are labels. [About resource](https://developers.google.com/workspace/drive/api/reference/rest/v3/about), [Drive user resource](https://developers.google.com/workspace/drive/api/reference/rest/v3/User)

A testing-mode external OAuth project issues refresh tokens that expire after seven days for Drive scopes. Expiry, revocation and organization policy must lead to a clear reconnect state, not endless retries. This is a development constraint, not evidence that production Drive connections inherently last a week. [Token lifecycle](https://developers.google.com/identity/protocols/oauth2#expiration)

Keep this an optional connection to a file source. Apple's login-service rule concerns authentication of the app's primary account; this design does not introduce a Vibe account. Explain that distinction in review notes and reassess if the product changes. [App Review guideline 4.8](https://developer.apple.com/app-store/review/guidelines/#login-services)

## API surface

Use authenticated REST requests rather than Drive web-page download links. The initial client needs a small API surface:

| Need | Request / behavior |
| --- | --- |
| Account identity | `GET /drive/v3/about?fields=user` |
| List a folder | `GET /drive/v3/files`, with `q="'<folderId>' in parents and trashed = false"`, `spaces=drive`, explicit fields and pagination. Start at the `root` alias for My Drive. |
| Resolve an item | `GET /drive/v3/files/<fileId>?fields=...`; retain parent IDs so search hits can resolve into the mirror. |
| Download or read a range | `GET /drive/v3/files/<fileId>?alt=media`, optionally with `Range`. |
| Remote name search | `files.list` with a name query, then Vibe's extension filtering. |
| Later incremental refresh | `changes.getStartPageToken` and `changes.list`; unnecessary for the first lazy mirror. |

These map to [folder/search queries](https://developers.google.com/workspace/drive/api/guides/search-files), [file listing](https://developers.google.com/workspace/drive/api/reference/rest/v3/files/list), [media downloads](https://developers.google.com/workspace/drive/api/guides/manage-downloads), and [change retrieval](https://developers.google.com/workspace/drive/api/guides/manage-changes).

Request only the fields used: identity, name, MIME type, parents, size, modification time, content revision/checksum, version, trash state and download capability; include shortcut and resource-key fields when those features are enabled. Filter audio through `PlayableExtensions`, and keep `.cue`, `.m3u` and `.m3u8`. Do not filter solely on `audio/*`: an uploaded audio or playlist file can have an unhelpful MIME type. Google Docs/Sheets/Slides are not audio sources and need no export path.

Accumulate all pages before destructive reconciliation. Follow `nextPageToken` even after a short or empty page; a rejected page token requires a restart. `incompleteSearch` means results are missing. A failure or incomplete listing must preserve the cached directory rather than delete its apparently absent entries. Pagination is not a transactional snapshot, so concurrent remote edits also need a refresh/retry policy. [Listing semantics](https://developers.google.com/workspace/drive/api/reference/rest/v3/files/list)

**Search is not identical to Dropbox's.** Drive's `name contains` performs prefix matching; `fullText contains` matches tokens, not arbitrary substrings or Vibe's parsed music tags. Keep the current debounce, result cap and generation checks, escape query values, and label the scope Google Drive. Measure whether prefix search is acceptable; substring search over the entire account would require a separate index. [Query operators](https://developers.google.com/workspace/drive/api/guides/ref-search-terms)

Keep search consistent with the release's supported roots. A user corpus is not simply the My Drive tree, and a parent-membership query selects direct children rather than an entire subtree. For a My Drive-only first release, verify ancestry before offering a hit; cache those parent lookups and bound them. A selected-folder variant needs the same check against its granted roots. An inaccessible ancestor must produce an explicit limitation, not an invented local path. [Search examples](https://developers.google.com/workspace/drive/api/guides/search-files), [search corpora](https://developers.google.com/workspace/drive/api/reference/rest/v3/files/list)

## Mirror identity is the largest model change

Drive items have IDs and parent references; their names are not unique within a directory. `version` increases for server changes, including changes beyond content, while `headRevisionId` and checksums describe binary content. `modifiedTime` can be set by clients. Consequently Dropbox's case-folded path lookup and size-plus-mtime comparison are insufficient. [File semantics](https://developers.google.com/workspace/drive/api/reference/rest/v3/files)

The proposed mirror should keep these concerns separate:

- **Remote identity:** provider, account ID and file ID. Network requests always use the ID, never a filename reconstructed from disk.
- **Local slot:** a safe filesystem component recorded against that ID. Preserve ordinary names where possible; persist collision disambiguation so listing order cannot rename a cached file. Cover duplicate names, case-only differences, Unicode normalization, separators, dot components, long names and collision with part files.
- **Display name:** Google's original name, with enough UI disambiguation for duplicates. An internal suffix must not become the fallback song title accidentally; `AudioTrack.displayTitle` remains the one title decision.
- **Content identity:** revision/checksum and size, distinct from display changes. Retain the remote modification date separately from any local cache stamp.

This can start as richer entries in the existing directory index, not a new database. Ordinary sibling layouts should remain readable by the playlist readers. For a renamed, moved or disambiguated target, CUE/M3U path resolution needs the mapping between remote names and local slots. A reference that names two different Drive files is ambiguous: report it instead of playing an arbitrary one. Embedded FLAC CUEs retain their existing same-file behavior.

**A mirror version check alone does not invalidate Vibe's caches.** [`NSURL+Hash.cacheKey`](../../Vibe/Util/Categories/NSURL+Hash.m) reads local size, mtime and resolved path. A same-size replacement with a preserved remote modification date could otherwise reuse old tags, art, waveform and analysis. The spike must select and test one cache strategy: for example, a persisted local mtime stamp that changes for each new content revision and stays identical through placeholder/download/eviction. Check the stamp's effect on date sorting. Keep this adaptation at mirror installation rather than adding a remote lookup to every cache-key calculation.

Renames and moves also affect Favorites, Recents and session bookmarks. Decide whether to preserve local slots across renames or re-resolve saved remote IDs when a bookmark goes stale. Merely saying that downloads use IDs does not solve restoration. Do not relocate the existing Dropbox tree casually: its URLs are already persisted.

## Downloading, metadata and streaming

Drive explicitly supports `Range` for binary downloads. That fits both TagLib's ranged reads and the current growing-file transport. However, Dropbox carries `rev` in each content response, which the client compares across retries and the independent tail request. Drive's separate metadata response does not establish the version of a later media response.

There is a tempting but incomplete substitute: `revisions.get?alt=media`. Google's download guide says downloadable historical binary revisions must be marked **Keep Forever**. Setting that is a write and is incompatible with the proposed read-only product. Do not require it or assume every `headRevisionId` is downloadable this way. [Range and revision download rules](https://developers.google.com/workspace/drive/api/guides/manage-downloads)

The live probe must determine whether media responses expose a usable strong validator and honor a conditional range request across edits. Do not assume an ETag from metadata also validates media, or that a v2 recipe applies to v3. Test `206`, an ignored range returning `200`, invalid ranges, redirects, authentication refresh and a same-size replacement during a transfer.

Until that is established, the conservative milestone is **one complete download, validated before it becomes readable**: compare expected size and a supplied content checksum, recheck metadata, then install atomically. Compute any checksum while writing, not by adding content hashing to `NSURL.cacheKey`. Missing validation data or a changed version is a failed/retried fetch, not permission to publish uncertain bytes. Restart interrupted downloads rather than append potentially different content.

Ranged metadata can be enabled separately if metadata checks before and after the complete parse reliably reject a changed version; the rejected parse must never enter the cache. Otherwise defer tags until the full file is local. This has a visible cost for large folders, which the first milestone should state plainly.

Once response consistency is proven, use the existing availability, readable threshold, format-specific tail window, interrupted-read behavior and transfer registry. Finish an availability before removing it, retain the part inode across accepted retries, and never combine a tail from one revision with a head from another. The planned [streaming from any source](streaming-any-source.md) is related work, not a prerequisite: Drive can supply the existing writer interface.

## Integration without a second cloud stack

The repository's default feature budget is zero new files and zero new types. This proposal does not authorize an exception for a `GoogleDriveClient`/`GoogleDriveMirror` copy or a provider framework. Start by generalizing the two existing owners, using per-provider instances and small branches where requests, entries and errors genuinely differ. Neutral renames can accompany that change, with existing Dropbox persistence migrated only when necessary.

| Existing location | Required change |
| --- | --- |
| `Vibe/iOS/Dropbox/DropboxClient.*` | Provider-specific OAuth configuration, request construction, metadata extraction and failure interpretation; shared token, cancellation and transfer mechanics. |
| `Vibe/iOS/Dropbox/DropboxMirror.*` and `DropboxRules.h` | Provider/account identity, entry mapping, Drive-safe names and content versions; one implementation of reconciliation, sidecar claims, installation and eviction. |
| `Vibe/iOS/VibeiOSAppDelegate.m`, `CloudFileMaterializer`, `NSURLUtil` | Replace the single-root assumption with exact registered mirror roots and dispatch fetch/read/availability to the owning mirror. |
| `FolderSession`, `BrowserViewController`, `PlaybackController` | Resolve the mirror owning a URL for listing, folder expansion, recursion, restore and disconnect. Preserve Open/Add request tokens and whole-playlist clearing when it reaches a disconnected account. |
| `SearchViewController` | A separate Drive scope and result section using the existing remote-search lifecycle; resolve hits by ID and list their parent before opening. |
| `FilesSettingsViewController` | A Google account section with connect/disconnect, usage and cache controls. Start with one Google account alongside one Dropbox account and a budget per provider. |
| `project.yml`, `VibeStrings.h`, existing tests and debug channel | Client configuration and callback; localized source/error strings and `make strings`; extend existing network stubs and debug scenarios. |

**Calling `setRemoteRoot:fetch:read:availability:` twice will not work**: it replaces process-wide blocks and the one placeholder root. Nor should the root simply become all of Application Support, where unrelated unreadable files could be classified as remote placeholders. A small collection of exact roots in the existing owners is sufficient; it need not become a service registry.

The consolidating pass should remove Dropbox-only singleton lookups from provider-independent shell behavior and leave one account/retry/download/cache lifecycle. If the simple branches become demonstrably unworkable, request a specific exception before introducing types. The research itself adds only this requested document and changes no implementation.

## Scope, operational limits and failure behavior

**Initial product scope:** My Drive folders and supported binary audio; ordinary CUE/M3U dependencies; Open/Add; Favorites/Recents/restore; cached offline playback; storage controls; Google Drive and Dropbox linked together. A file marked as downloaded remains subject to cache eviction, as with Dropbox; this is not a new guaranteed-offline pinning feature.

Defer shared drives, a Shared with Me surface, public-link import, multiple Google accounts, uploads and full synchronization. Shortcuts need an explicit first-release decision: either resolve them correctly or show them as unsupported, rather than treating the shortcut as audio. Their target IDs must participate in dedupe and recursive-walk cycle detection. Link-shared targets may require resource keys, including `shortcutDetails.targetResourceKey`, sent through `X-Goog-Drive-Resource-Keys`. [Resource-key handling](https://developers.google.com/workspace/drive/api/guides/resource-keys)

Shared drives are a separate extension, not a synonym for files somebody shared with the user. They need drive discovery, `supportsAllDrives`, appropriate `includeItemsFromAllDrives`, and queries scoped by `driveId`/`corpora=drive`. Avoid an unbounded `allDrives` search and account for organization restrictions. [Shared-drive support](https://developers.google.com/workspace/drive/api/guides/enable-shareddrives)

**Quotas changed in 2026.** For new projects, Google's current page lists 1,000,000 quota units/minute/project, 325,000/minute/user/project, a 1 TB/day/project egress threshold, and 400,000,000 daily units before the announced billing threshold. Methods consume different units. The page says pricing details will follow with notice; do not budget this as permanently free or use the old 12,000-requests/minute figure. Verify the actual project's limits and billing terms before release. [Current Drive limits](https://developers.google.com/workspace/drive/api/guides/limits), [2026 rollout](https://developers.google.com/workspace/tools-safety)

For scale, 1,000 listeners each fetching 1 GB/day is approximately 1 TB/day before retries and metadata. This is an illustrative calculation, not a measured workload. Measure first-play latency, bytes and requests per folder, background metadata traffic, cache hit rate and total egress. Keep lazy listings and foreground priority; do not build an account-wide scan by default.

Google reports rate limits through some `403` reasons as well as `429`, while other `403`s mean permissions or policy. A `404` can mean missing access as well as a missing file. Adapt the failure ladder to structured reasons: refresh once for an expired credential, back off with jitter for transient limits/5xx, and surface file/policy failures without unlinking the account. `capabilities.canDownload` should prevent futile playback attempts, with the download response still authoritative. [Error handling](https://developers.google.com/workspace/drive/api/guides/handle-errors), [file capabilities](https://developers.google.com/workspace/drive/api/reference/rest/v3/files)

Retain Dropbox's distinction between active background audio and an idle suspended app. The existing download delegate is not a background-sync service. Test next-track fetches, token refresh, file protection and network recovery on a locked physical device; do not promise unattended library downloads after suspension or force-quit. Keep credentials and remote content out of diagnostic uploads, and test that disconnect removes only that provider's account data.

## Proposed sequence and acceptance checks

1. **Resolve the external gates.** Obtain a test iOS client; compare Files-provider behavior, restricted-scope browsing, and a clean Picker grant. Capture the folder-descendant result and request Google's determination of scope eligibility and assessment requirements. Recheck project quotas. Deliver a permission/product decision, not a partially wired sign-in button.
2. **Prove content and identity.** Exercise range responses and replacement races; test duplicate and normalized names, CUE/M3U dependencies, same-size edits with preserved dates, and moves/renames. Decide the local mapping, cache stamp and whole-file-versus-streaming boundary before broad shell changes.
3. **Unify the existing owners and ship the smaller path.** Keep Dropbox behavior covered while adding a Drive instance, exact-root dispatch, native browsing, verified downloads, restore and settings. Add remote search with its documented matching limits. No account-wide sync or new audio path.
4. **Add streaming when justified by the probe.** Port only the verified consistency mechanism into the existing transfer path. Measure latency and egress against whole-file playback and Dropbox, using the same files and network conditions.

Host-less tests should extend the existing stubbed-`NSURLProtocol` mirror/client suites: paging and partial failures; account changes during refresh/download; cancellation during backoff; duplicate names and ID mapping; revision/checksum mismatch; stale cache prevention; eviction; disconnected roots; and simultaneous providers. Read [Tests/AGENTS.md](../../Tests/AGENTS.md) before implementation.

Running-app checks belong in the debug channel: browse an unseen nested folder, Open/Add while another listing is pending, resolve a search hit, reopen Favorites and Recents, restore offline, revoke permissions, disconnect during playback, and prove a Drive failure leaves Dropbox usable. Extend the existing fake network scenarios so CI needs no Google credentials. A signed simulator verifies persisted Keychain state; a physical device verifies lock-screen playback and networking.

For implementation, run the applicable unit/audio suites, both platform builds, layout/vocabulary/string checks and Release analysis, with the repository's debug and performance skills for live checks and cost measurements. For this research-only change, code compilation and audio tests provide no additional evidence: validate the document's links, source claims and repository references instead.

**Decision after the spike:** proceed with full native browsing if Google accepts the scope and identity/cache behavior is sound; prefer selected-folder access if the new Picker can demonstrably supply it; offer whole-file playback first if safe streaming remains unresolved. None of those choices needs a second player.
