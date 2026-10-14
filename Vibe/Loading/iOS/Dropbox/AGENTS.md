# Dropbox (iOS)

Dropbox access uses its HTTP API. This lets the app browse and search without relying on the Files provider's local listing. There is no SDK: a handful of endpoints over `NSURLSession`, all Objective-C. This directory has no UI. What every account shares, the sign-in, the Keychain, the failure ladder, the lazy mirror and its traps, is `../Account/AGENTS.md`. This doc holds what is Dropbox's own.

| File | Owns |
| --- | --- |
| `DropboxClient` | Dropbox's endpoints and answers: the authorize and token addresses, the JSON call (`callEndpoint:arguments:completion:`), the `files/download` and `sharing/get_shared_link_file` requests, the `Dropbox-API-Result` reading, the identity call and the revoke. It subclasses `OAuthAccountClient`. |
| `DropboxMirror` | The Dropbox account as local files: listing reconciliation by path, search, the path mapping, and the Dropbox half of a shared folder link. It subclasses `AccountMirror`. This class names each placeholder's Dropbox `id` and reads Dropbox's answers. |
| `DropboxRules.h` | The Dropbox decisions with no network or disk: the addresses, the wire encodings, entry reading, the version check, and the path helpers. Tested. |

Tests drive both classes over a stubbed `NSURLProtocol` and a temp root (`DropboxMirrorTestCase` and its subclasses).

## The account

**The app key is `VibeDropboxAppKey` in the generated Info.plist** (`project.yml`). It is not a secret: PKCE needs none, and Dropbox grants every app the `db-<key>://2/token` redirect without registration. Scopes: `account_info.read files.metadata.read files.content.read sharing.read`. `sharing.read` opens shared folder links (below). The app needs **Full Dropbox** access to browse existing music outside its dedicated app folder.

**Check production status in the App Console before a release.** It is external account state, not a build setting. With additional users enabled, development apps can link up to 500 users. Reaching 50 starts a two-week deadline to obtain production approval. Dropbox can then freeze new links until approval. Applications may be submitted earlier. Review normally starts at 50 users. See the [Dropbox production-approval guide](https://www.dropbox.com/developers/reference/developer-guide#production-approval).

**A scope the app lacks answers 400 with plain text, not JSON**, naming the scope. That is a scope the App Console has not enabled. A scope the grant lacks answers 401 `missing_scope` (Shared folder links, below). The client logs that body, and a sign-in logs the scopes it was granted. A scope enabled in the App Console reaches only grants made after it, so sign in again.

**Dropbox's token answer names the account**, so a sign-in links at once and reads the name after. Only a 401 `expired_access_token` refreshes. A refresh answered 400 `invalid_grant` means the grant was revoked on dropbox.com, and it unlinks. Dropbox throttles with a 429, which the base resends.

**The warm-up sends each session one `files/download` naming no file.** Dropbox refuses it at once. It opens the connection to `content.dropboxapi.com`. A session's connections are its own, and the download and its tail ride different sessions.

## The mirror

`Library/Application Support/Dropbox/<account id>/`. Its budget is saved under `VibeiOSDropboxDownloadBudget`. **A folder made on the way to a search hit takes the hit's `path_display`**, never `path_lower`, or the browser and the playlist title name it in lowercase.

- **Size plus mtime is the version.** A placeholder takes the entry's `server_modified`. Dropbox moves `server_modified` on every upload. Downloaded bytes take the mtime from their own response's `Dropbox-API-Result`, so the next listing sees them as current. A version that differs goes back to a placeholder, and a departed entry is deleted.
- **Each directory's index holds its own Dropbox path and each file's Dropbox `id`.** A download goes by `id:…`, which also survives a rename (`remoteTargetForURL:error:`). A relisting goes by the directory's recorded path. A path derived from a URL is the fallback for a directory no listing recorded.
- **TRAP: only the last component of a `path_display` is guaranteed its case.** So a component is matched case-insensitively against what is on disk (`VibeDropboxLocalName`) before one is made, and two spellings of one folder land in one directory. The match lists the directory rather than probing. On a case-insensitive volume an `lstat` of another spelling succeeds, and the URL would carry that spelling.
- **The fetch streams into a hidden part file**, and the progress poll reads the transfer's own written count. A Dropbox row's loading bar is therefore a real percentage. The fetch, its stream and its tail window are the store's.
- **The part file's rules are `HTTPTransferClient`'s** (`Loading/Net/AGENTS.md`): made once, only appended to, resent from its last byte, pinned to its first response's version, and kept when the link ended the transfer. For Dropbox the version is the `Dropbox-API-Result` `rev`, and the size is its `size`. A download by `id` answers whatever version is current, so the pin stops two revs splicing into one file. A mismatch fails the transfer with `VibeAccountErrorFileChanged`, and a length other than `size` with `VibeAccountErrorAPI`. `keepsPartAfterError:` keeps the part for a cancel (how a stall lets a stream go) and for a connection lost past the resend bound.
- **A Dropbox stream's tail is read by id, like its download.** The store installs the tail window only when both answers name the same rev (`Loading/Net/AGENTS.md`). The tail read starts with the download, not after its first response. So a file that needs its tail to open opens from the head. Examples are an MP3's last 128 bytes, an M4A with `moov` last, a FLAC with no length, and an AIFF or WAV with a tag after its audio. A longer index-last M4A, or a tag larger than the window, waits for its download.
- **TagLib reads tags by range.** The rule and a streaming file's shortcut are the store's. The metadata scan parses a placeholder through TagLib reading `files/download` with a `Range` header, about three requests a file with its artwork. Playback and prefetch can download the whole file. Metadata also needs the whole file for CoreAudio formats outside `PlayableExtensions.tagParsed` (w64 and caf). A row that lost its art rendition reads it by the same rule (`PlaceholderFiles readsRemotePlaceholderByRange:`). One known gap: a FLAC whose STREAMINFO has no length parses with no duration, since the fallback that measures it opens the file.
- **An evicted track keeps its cached waveform.** The card draws it while parked (`Vibe/iOS/Player/AGENTS.md`).

## Shared folder links

**A Dropbox folder link opened while signed in is listed through the account.** The road is `AccountMirror`'s (`../Account/AGENTS.md`). This class is its Dropbox half. `sharing/get_shared_link_metadata` names the folder (`lookUpSharedFolderLink:completion:`). `files/list_folder` with `shared_link` lists it one level per call. A file downloads through `sharing/get_shared_link_file` by `{url, path}`, with the failure ladder, resume and version pin of a download by id.

**A link's directory index adds `link`.** Its `path`, and each file's entry, are paths below the link as the listing spelled them. A listing through a link names no path of its own. An id in it is the owner's, which the listener cannot fetch by. `refreshDirectoryAtURL:completion:` lists a directory under `linksURL` by the link and path its index records. `dropboxPathForURL:` answers nil there.

**A grant from before `sharing.read` lacks it.** Dropbox then answers 401 `missing_scope`, which fails the call and never unlinks (`VibeDropboxIsMissingScope`, the ladder's trap in `../Account/AGENTS.md`). Open URL then falls back to `LinkStore`'s road with no account (`Loading/Net/AGENTS.md`), as it does for any failure here. Sign in again to use this road. **Enable `sharing.read` in the App Console before this ships**, or every new sign-in asks for a scope the app lacks.

**The simulator needs no account.** `set_fake_dropbox <directory>` (`Vibe/Debug/iOS/VibeFakeDropbox`) puts that directory under the client as the account, over the same HTTP boundary the tests stub. Every case this doc's traps describe is a scripted tree there. A shared folder link there, `https://www.dropbox.com/scl/fo/<name>/<any>`, is the account's top-level folder `<name>`. `fake_dropbox_fault` scripts the streaming cases, and `vibe-debug`'s `dropbox-streaming.sh` runs them as scenarios. `dump_dropbox` reads the account and which playlist tracks are placeholders. The real sign-in is Dropbox's web sheet, which only a human fills.
