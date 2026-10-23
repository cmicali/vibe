# Net: Open URL's links

Open URL's link store, the one piece of the app's HTTP side that is Vibe's own. Both apps compile this directory. It is Foundation-only.

| File | Owns |
| --- | --- |
| `LinkStore` | Open URL's links: one directory per link, its record, the probe that opens it, the budget, and the pruning. Tested (`LinkStoreTests`, `LinkStoreHostTests`, and `AudioPlayerRenderLinkTests` for playback) |

**The rest of the HTTP side is vibe-libs'.** Each piece's doc is the authority for how its code works. Both app targets list the three templates. A change to them lands in vibe-libs first, then in Vibe's pin.
- `files/HTTP` (`vibe-libs/files/HTTP/AGENTS.md`): `HTTPTransferClient`, the streamed download, the ranged read, and the probe, with the resends, the kept part, and the version pin. `DropboxClient` subclasses it (`../iOS/Dropbox/AGENTS.md`).
- `files/RemoteFiles` (`vibe-libs/files/RemoteFiles/AGENTS.md`): `RemotePlaceholderStore`, remote files as placeholders under one root, the fetch that streams, the ranged tag read, the download budget, and the backend it installs. `LinkStore` and `DropboxMirror` subclass it.
- `files/ShareLinks` (`vibe-libs/files/ShareLinks/AGENTS.md`): `LinkClient`, the link error, the address rule, the audio check, the names, the share-link rewrites and iCloud's lookup, what a drop or a paste opens, and the fake web server the debug channel installs.

## The link store

**Open URL plays an http or https link as a remote placeholder** (`LinkStore`, a `RemotePlaceholderStore`). Its client is `LinkClient`. That is the plain client for every link but an iCloud Drive share (below). Its root is `<Application Support>/Links`, kept out of backups. Each root has its own backend (vibe-libs' `files/FileLoading/AGENTS.md`).

**Both apps install it at launch, before anything can open a file under it.** The mac installs it first in `applicationWillFinishLaunching:`, before the restore. iOS installs it in `application:didFinishLaunchingWithOptions:`, after the Dropbox mirror and before the scene restores a playlist.

**The shared client's session is ephemeral.** It has no URL cache and ignores local cache data. `waitsForConnectivity` is off, since a waiting request holds a materialization lane. `allowsURL` is `VibeLinkRequestIsAllowed`, on the link and on every redirect. The address rule and its traps are ShareLinks'. Both apps set `NSAllowsLocalNetworking`. ATS applies its own rules after the address rule. Private IP literals and special-use domain names still need live-host verification.

**Each link is stored by its normalized URL's hash** (`VibeLinkDirectoryName`). The directory holds the placeholder or download and may hold its hidden part file. Opening the same normalized URL reuses the directory.

**The file name is `VibeLinkFileName`**, given `PlayableExtensions.lookup`. Its rules are ShareLinks'.

**The record is the directory's index** (`com.commonwealthrecordings.vibe.link`). It is JSON: `{url, etag, lastModified, version, size, modified, contentType, ranges, host, opened}`. `url` is what the client fetches, after the share-link rewrite. `modified` is the mtime the file takes. `ranges` says whether the server answers a Range. `opened` is when the link was last opened. A header the answer lacked is left out. The xattr is read from disk, so each field is checked. A record with a field of the wrong type is no record (`recordOfDirectory:`). A shell reads a link's host by its file (`hostOfLinkFileURL:`), and asks the store whether a file is a link (`containsURL:`). iOS names a link in Recents by its host.

**`resolveURLString:completion:` opens a link in five steps.** It runs off main and completes on main.
1. The address rule. A refusal fails before any request.
2. The share-link rewrite (`VibeLinkDirectDownloadURL`, below).
3. A probe of the first 16 bytes. It is a `GET`, never a `HEAD`, since a host can answer `HEAD` with something other than the file. A 206 gives the size from its Content-Range, and `ranges` is YES. A 200 gives it from its Content-Length, and `ranges` is NO.
4. The audio check and the extension (`VibeLinkAudioExtension`). The first bytes come first: `ID3` or an MPEG sync, ADTS, `fLaC`, `RIFF…WAVE`, `FORM…AIFF` or `AIFC`, the W64 GUID, `OggS`, `ftyp`, or `caff`. Then the URL's extension, the Content-Disposition file name's, and the Content-Type. When the bytes name a family, such as Ogg, MP4, or WAV, the URL's or the file name's extension picks the member. HTML the bytes do not claim is not audio. The check gets the link's own URL, not the redirect's, since a CDN's path carries no name. It runs before a missing size fails the link. A sign-in page often has no length, and it is still not audio. With no size, icy headers or chunked audio are a live stream, and anything else has no size.
5. The record and the placeholder. The size is the probe's. The mtime is Last-Modified, else the probe's time. The cache key then stays the same across the install.

**The probe has a deadline** (`VibeLinkProbeTimeout`). It runs from the request to the first bytes, and redirects and resends count toward it. A public host gets 15 s. A public server that sends nothing for that long is down for practical purposes. A local host gets 30 s. It may be a NAS spinning up its disks. It may sit behind the system's local-network prompt, which holds the first request while the user reads it. A probe past its deadline fails as its host's network failure: unreachable, or the local network's. A link with a download still opens it. The deadline is the store's own timer, not the request's timeout. The session's timeout restarts at every byte, so a server that trickles would never meet it. `probeTimeoutScale` shortens it for the tests.

**The user can cancel a resolve.** `resolveURLString:completion:` returns a block that cancels, on main. A resolve not yet completed then completes before the block returns, with `VibeLinkErrorCancelled`, and nothing lands after it. Past the completion the block does nothing. The disk queue decides which of the answer, the deadline, and the cancel came first. The other two then do nothing. A cancel before the answer writes no record and no placeholder. `VibeLinkMessageForError` (`Common/StringRules.h`) answers nil for a cancel, so neither shell shows anything.

**A failure is a `VibeLinkErrorDomain` error whose code is a `VibeLinkError`** (ShareLinks' `LinkClient.h`). ShareLinks' rules choose the code. A refused address fails with the address rule's own answer, and a refused redirect is insecure. A denied local-network permission fails as the local network's.

The cause rides under `NSUnderlyingErrorKey`. A disk failure is passed through as its POSIX error. `VibeLinkMessageForError` (`Common/StringRules.h`) turns the code into its string, the server's with its status. iOS shows the `link.error` sentence in an alert. The mac shows the short `link.status` string in its header (`brief`). An error outside the domain reads as unreachable.

**A share link is rewritten to the address of its bytes** before the probe (`VibeLinkDirectDownloadURL`). An iCloud Drive link is looked up before each request instead, by `LinkClient`. The rules, and what each host answers, are ShareLinks'. `docs/future/share-links.md` has the probes. For the store, an iCloud link adds three things.
- The record holds the share link, never a signed address.
- The version is the lookup's checksum, and the mtime and name are the lookup's. The cache key then stays the same across a relaunch and a fresh lookup. A lookup that cannot connect is the link's network failure, so a downloaded share still opens offline.
- An open again within a lookup's 10 minutes sees the checksum that lookup saw.

**An open again keeps what is still current.** The same version and size keep the file, placeholder or download, and touch `opened`. The file's own size and mtime must be the record's too. A record changed while its file streamed describes bytes the placeholder does not. Once the stream ends, the next open writes a fresh placeholder. Another version writes a new placeholder. A link with no version is fetched again, since nothing proves its download current. A link that cannot be reached still opens its download, when it has one.

**TRAP: a file being fetched now keeps its placeholder** (`isFetchingURL:`). That holds from the fetch's start, before its first response makes a stream. The fetch's install renames its bytes over whatever stands at the URL, and its readers hold the part file. A placeholder under a new name would leave that install a second file in the directory. Only the record changes. The install then sets the record back to what it downloaded.

**TRAP: the install keeps the record's mtime only while the download is the record's file** (`modificationTimeOfMetadata:forURL:`). The cache key is made from that mtime. A download of another version takes its own Last-Modified, else the time now, and the record follows it. A record left describing other bytes would send the download back to a placeholder at the next open, or fail its tag reads.

**TRAP: the mtime hook syncs onto the disk queue from the client's delivery queue.** Nothing on the disk queue may wait on the client, or the two deadlock.

**A tag read checks the record.** An answer of another size, or of another version, fails with `VibeHTTPErrorVersionChanged`, and the parse is retried later. A record with no version is checked by its size alone.

**The CDN case is one rule in three places** (`VibeHTTPIsSameFileUnderAnotherETag`). The client applies it to a resend (`files/HTTP`). The store applies it to an open again and to a tag read. An answer under another ETag with the record's size and Last-Modified, both stated, is the same file. Each acceptance is logged. The tail window compares versions only. Under another ETag it is dropped, and reads there wait for the download.

**A server without ranges downloads whole.** It gets no tail read and no ranged tag read. Its tags come once the file is local. A resend still asks for a range, and a 200 to it skips the bytes written.

**The budget is `kVibeLinkDownloadBudgetBytes`, 2 GB, with no setting.** The store's eviction applies (`files/RemoteFiles`). It is `LinkStore.m`'s, not ShareLinks'.

**Pruning deletes each link not opened for 30 days that nothing keeps** (`pruneKeepingTracks:recentURLs:`, `VibeLinkDirectoriesToPrune`). A directory with no record counts as long unopened. A shell calls it once per launch, after the launch's restore. It keeps the playlist's rows as the launch restored them and the recent items. The store reads them off main, and only once it finds a link. On the mac those are the recent documents. On iOS they are Recents. **A saved M3U naming a pruned link finds that entry missing.**

**A link can arrive by a drop on the mac's window** (`Mac/App/AGENTS.md`). What a drop or a paste holds, and the order a drop opens in, are ShareLinks' `LinkDropRules.h`. iOS has no drop target. Its paste row opens the first web link (`VibePasteLinkOfItems`).

**The debug channel serves links from a directory** (ShareLinks' `VibeFakeHTTP`, `Debug/AGENTS.md`). It replaces the shared client's sessions through `useSessionConfiguration:`. It answers iCloud's lookup too. `https://www.icloud.com/iclouddrive/<name>` is the entry at its root named `<name>` without its extension, and a directory there is a folder share. The `expiry` fault shortens each address's life. `open_url` resolves a link through each shell's own Open URL road. On the mac, `file_drag_drop` drops a link as a browser's text.
