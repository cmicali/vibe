# Google Drive (iOS)

Google Drive access uses the Drive v3 REST API over `NSURLSession`, with no SDK. The account is the user's My Drive. What every account shares, the sign-in, the Keychain, the failure ladder, the lazy mirror and its traps, is `../Account/AGENTS.md`. This doc holds what is Drive's own. `docs/future/ios-google-drive.md` is the study it was built from, with the scope review still to do.

| File | Owns |
| --- | --- |
| `GoogleDriveClient` | Drive's endpoints and answers: the authorize and token addresses, the GET call (`getPath:query:completion:`), the media request, the lookup before each media request, the identity call and the revoke. It subclasses `OAuthAccountClient`. |
| `GoogleDriveMirror` | My Drive as local files: listing by folder id, the local slots, search with its ancestry, and the stamp that keeps the cache key honest. It subclasses `AccountMirror`. |
| `GoogleDriveRules.h` | The Drive decisions with no network or disk: the addresses and queries, the error reading, entry reading, local names and slots, and the stamp. Tested (`GoogleDriveRulesTests`). |

Tests drive both classes over `DropboxStubProtocol` and a temp root (`GoogleDriveMirrorTests`, which uses `DropboxMirrorTestCase.h`'s helpers).

## The account

**The client id is `VibeGoogleDriveClientID` in the generated Info.plist** (`project.yml`). It is an iOS OAuth client made in Google Cloud for the app's bundle id. It is not a secret: an installed app uses PKCE and no client secret. **An empty id hides Google Drive in a Release build** (`GoogleDriveMirror.isConfigured`, read by `AccountMirror.mirrors`). A Debug build always lists it, for the fake. The redirect scheme is the client id reversed, and the redirect URI is `<scheme>:/oauth2redirect`. Google registers both with the client, so nothing in Info.plist names them.

**The scope is `drive.readonly`, which Google restricts.** A browser of the whole account cannot work from picked files alone. A public release needs Google's verification of that scope first (`docs/future/ios-google-drive.md`, Permission). A project in testing mode issues refresh tokens that expire after seven days. The refresh is then refused as `invalid_grant`, and the account unlinks.

**Google's token answer does not name the account.** So a sign-in reads `about?fields=user(…)` before it links. The account id is the user's `permissionId`, which is stable and opaque and names the mirror's directory. The name shown is the email address, else the display name. The refresh token lives under the Keychain service `com.commonwealthrecordings.Vibe.googledrive`.

**Google's failures differ from Dropbox's.** An expired token is a 401, the base's default. A throttle is a 429, a 5xx, or a 403 whose reason is `rateLimitExceeded` or `userRateLimitExceeded` (`VibeGoogleDriveIsThrottle`). Any other 403 is the file's or the policy's. It fails that call and leaves the account linked. Revocation posts the refresh token to `oauth2.googleapis.com/revoke` and needs no access token. The warm-up sends `files/root?fields=id` on each session.

## Downloads

**A media request is `files/<id>?alt=media`, and it states no version.** So before each request the client looks the file up (`lookUpFileID:fresh:completion:`). The lookup reads the size, `md5Checksum`, `headRevisionId` and `modifiedTime`. The version is `md5Checksum`, else `headRevisionId` (`VibeGoogleDriveVersionOf`). A transfer's metadata takes the response's size and the lookup's version and date. **The version is set only when the response's size equals the lookup's size.** Without a version, bytes are never resumed or joined to a tail. With one, `HTTPTransferClient`'s pin and the store's tail window work as they do for Dropbox (`Loading/Net/AGENTS.md`). A resend that finds another version fails with `VibeAccountErrorFileChanged`.

**The lookup is single-flight per file id.** A first attempt reuses a lookup under five seconds old (`kLookupReuseSeconds`). A download and its tail read start together, and a tag parse reads about three ranges in a second, so they share one lookup. A resend always looks again. **TRAP: the version is the lookup's, never the answer's.** A file changed between a lookup and its own request is labelled with the old version, and nothing catches that. The window is one round trip. A same-size change inside it could join two versions in one part file.

**TRAP: every media request sends `Accept-Encoding: identity`.** With none named the session asks for gzip, and a range's offsets would stop matching the file's bytes.

## The mirror

`Library/Application Support/Google Drive/<permissionId>/`. Its budget is saved under `VibeiOSGoogleDriveDownloadBudget`. Only My Drive is mirrored. Shared drives, Shared with Me and shortcuts are not. **A file is mirrored only when it states a size** (`VibeGoogleDriveEntryIsMirrored`). A shortcut and a Google Docs file state none, and their media download is refused.

- **A Drive item is its id, never its name.** Names repeat within a folder, and a name can hold `/`. Every request names an id. Each directory's index (the store's xattr) is `{"id": <folder id>, "files": {<index key>: {"id", "version"}}}`. A folder's record has no version. A download goes by the id its folder's listing recorded (`remoteTargetForURL:error:`). A relisting goes by the directory's recorded id.
- **A local name is a slot** (`VibeGoogleDriveSlots`). A file keeps its slot while the slot still fits its Drive name. So a listing's order never moves a copy suffix to another file, and a duplicate name takes `Song (2).mp3`. New entries take their slots in id order, so one listing names them the same way twice. `/` and NUL become `-`, leading dots go, and a name is cut to `kVibeGoogleDriveNameMaxBytes` with its extension kept (`VibeGoogleDriveLocalBaseName`). **The suffix shows in the browser and in a row's title when the file has no title tag.**
- **The version decides whether a file changed, never the date.** A client may keep `modifiedTime` across a new upload. A file is current when its size and its recorded version match the listing. A changed file goes back to a placeholder. **The stamp keeps the cache key honest** (`VibeGoogleDriveStamp`). The cache key is size plus mtime. A changed file takes Drive's date unless that would not move it past what it held. It is then dated one second past its old mtime. The stamp only grows per file, so no version reuses another's key.
- **Downloaded bytes of the recorded version keep the placeholder's mtime.** Bytes of another version, uploaded since the listing, take a new stamp and record their version (`modificationTimeOfMetadata:forURL:`). **TRAP: that hook syncs onto the disk queue from the client's delivery queue.** Nothing on the disk queue may wait on the client, or the two deadlock.
- **A directory no listing made has no id.** Its refresh lists its parent first, which makes it with its id when Drive holds it, and so on up to the nearest listed directory. So a playlist naming another folder, and a restored bookmark, still open.
- **A listing is reconciled only whole.** Every page is fetched, past a short or empty page, until no `nextPageToken`. An `incompleteSearch` answer fails the listing, and nothing is deleted.

**Search is Drive's `name contains`, which matches the start of each word in a name.** It asks one page of 100 and keeps at most 50 folders and playable files, never a CUE sheet. Each hit's folders are then looked up to My Drive's root, at most 32 deep, and each folder once per account. A hit whose folders never reach My Drive is left out. Opening a hit makes its folders by id, then lists the folder holding it (`localURLForEntry:completion:`). Search's identity for a file is its id, so the playlist's files are left out of the results.

**The simulator needs no account.** `set_fake_google_drive <directory>` (`Vibe/Debug/iOS/VibeFakeGoogleDrive`) puts that directory under the client as My Drive, over the same HTTP boundary the tests stub. Each item's id is made from its path. `fake_google_drive_fault` scripts a stall, a drop, a version change, a throttle, an expired token, a slow rate and latency. `dump_google_drive` reads the account and which playlist tracks are placeholders. The real sign-in is Google's web sheet, which only a human fills.
