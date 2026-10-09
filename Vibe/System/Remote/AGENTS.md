# Remote files over HTTP

Files the app fetches itself over HTTP, rather than through a file provider. Both apps compile this directory. It is Foundation-only.

| File | Owns |
| --- | --- |
| `HTTPTransferClient` | the streamed download, the ranged read, and the probe. The resends, the kept part, and the version pin |
| `HTTPTransferClientInternal.h` | the hooks a subclass overrides, and the seams the tests and the debug channel use (`useSessionConfiguration:`, `retryDelayScale`) |
| `HTTPTransferRules.h` | the retry delay, the connection errors, and the size and version a response's headers state. Tested (`HTTPTransferRulesTests`) |
| `RemotePlaceholderStore` | remote files as local placeholders under one root: the placeholder and the install, the directory index, the fetch that streams, the ranged read, the download budget, and the backend it installs. Tested (`RemotePlaceholderStoreTests`) |
| `RemotePlaceholderStoreInternal.h` | the hooks a subclass overrides, and what a subclass and the tests reach: the disk queue, the index, the downloads, and the budget |
| `LinkStore` | Open URL's links: one directory per link, its record, the probe that opens it, and the pruning. Tested (`LinkStoreTests`, and `AudioPlayerRenderLinkTests` for playback) |
| `LinkRules.h` | the address rule, the audio check, the names, the share-link rewrite that asks each host's file, what a drop opens, the pruning choice, and the failures. Tested (`LinkRulesTests`) |
| `DropboxLinkRules.h`, `GoogleDriveLinkRules.h` | one host's share links each. No other link code names a host. Tested (`DropboxLinkRulesTests`, `GoogleDriveLinkRulesTests`) |

`DropboxClient` subclasses the client, and `DropboxMirror` subclasses the store (`iOS/Dropbox/AGENTS.md`). `LinkStore` subclasses the store over the plain client (below).

**TRAP: a subclass's internal header imports `HTTPTransferClientInternal.h` and never redeclares its seams** (`DropboxClientInternal.h`). A redeclaration that cannot see the base's gets an ivar of its own. It starts at 0, not 1, and every retry wait would read it.

## The client

**The defaults are plain HTTP.** A target is an `NSURL`, fetched with a `GET`. The size is a 206's Content-Range total, or a 200's Content-Length when no Content-Encoding is set. The version is a strong ETag, else Last-Modified. A weak ETag (`W/` or `w/`) counts as absent, since it promises equivalent bytes, not the same ones. `VibeHTTPVersionFromHeaders` is the one weak-ETag rule. A subclass changes any of this through the hooks in `HTTPTransferClientInternal.h`. Each hook gets the transfer's own `state` dictionary, which lives across its attempts and which the base never reads. `DropboxClient` keeps its access token and the refresh flag there.

**TRAP: every default request asks for `Accept-Encoding: identity`.** With no such header, `NSURLSession` asks for gzip and inflates the answer. A range's offsets then stop matching the file's bytes.

**Two sessions.** Downloads and probes stream on a delegate session of their own. Ranged reads and a subclass's calls run on the other, so a tag read never queues behind a download's disk writes. The client is the delegate of both. A subclass's call is answered whole by its own handler.

**TRAP: a delegate session retains its delegate until it is invalidated.** The client lives as long as the app. Only a session that `useSessionConfiguration:` replaces is invalidated.

**`allowsURL` is asked of every request and every redirect.** It gets the URL that redirected, nil for a request, and the URL to be requested. A request it refuses is never sent. A redirect it refuses completes its task with the 3xx itself, and the transfer fails with `VibeHTTPErrorRefusedURL`.

**A cancel settles a transfer at once when no task is in flight for it** (`cancelTransfer:`). A task is in flight until its completion has reached the delegate. That covers a transfer waiting on the request hook, such as Dropbox's token refresh, or on a retry's delay. The lane the caller holds is freed now (`System/AGENTS.md`).

**TRAP: a cancel never touches a download's file.** The step that ended the last task may still be reading it. The next step sees the cancel and closes the file. A cancel that closed it raced that step.

**TRAP: a transfer is adopted and entered in the delegate's table under one lock** (`adoptTask:forTransfer:`). A cancel between the two left a task whose completion found no transfer, so the download never finished. The table is keyed by the task object, because the two sessions number their tasks apart.

**A part file is made once per transfer, at its first accepted response, and only ever appended to.** A descriptor opened on it keeps seeing one inode grow. A resend asks for `Range: bytes=<written>-` and appends. A 200 to that is the whole file, and its prefix is skipped. A 206 starts where its Content-Range says (`VibeHTTPContentRangeStart`). Bytes before the offset are skipped, as a 200's are. One naming no range is taken at its word. A 206 from past the offset would leave a gap. It fails the transfer with `VibeHTTPErrorBadRange`, or starts a kept part over. A dropped connection is resent at most twice in a row with no byte between.

**TRAP: a resend answers whatever version is current.** Every response's version must therefore equal the first one's. A first response with no version is never resumed. A mismatch fails the transfer with `VibeHTTPErrorVersionChanged` and deletes the part. One answer is the same file under another ETag: the first response's size and Last-Modified, both stated (`VibeHTTPIsSameFileUnderAnotherETag`). A CDN's edges can each tag one file with an ETag of their own. The resend then continues, and the client logs it. Only the default metadata carries `lastModified`, so the Dropbox client never meets this case. A kept part holds only its version, so another ETag starts it over.

**A transfer the link ended keeps its part** (`keepsPartAfterError:`: a cancel, or a connection lost past the resend bound). The part is tagged with its version in the xattr `com.commonwealthrecordings.Vibe.rev`. The name stays, so parts kept by the Dropbox client still resume. The next download of that destination continues from its last byte. An answer naming another version, or a 416 because the current version is shorter than the part, starts the transfer over, whole (`restart`). A 416 whose Content-Range total is the part's length, under the part's version, is the whole file. The download completes with the bytes kept. A part with no version tag is replaced. Anything the transfer's own answer ended deletes the part, since the same bytes would only fail again.

**The first response's size is the file's length.** A transfer dropped after its last byte is complete, since `bytes=<size>-` would answer 416. One ending at any other length fails with `VibeHTTPErrorLengthMismatch` and deletes the part.

**A ranged read streams through the delegate and stops at its bytes** (`readTarget:…`). It cancels its own task once it holds them. A server that ignores the range answers 200 with the whole file, and the read keeps only the bytes asked for. It never holds the file in memory. A 206 from another byte than the one asked for fails with `VibeHTTPErrorBadRange`. A failure status goes through `handleFailureStatus:…` like any other. **A probe is a read of the first bytes on the download session** (`probeTarget:length:`). Its completion also carries the response.

**A log line never names a whole link** (`descriptionOfTarget:`). A query or user info can carry a key. The default names a URL by its host and last path component. `DropboxClient` names its path.

## The placeholder store

**A placeholder is a sparse file of the remote size and mtime with no permissions** (`writePlaceholderAtURL:…`, `NSURLUtil`'s remote placeholder). Its stat is the real one, and a direct open fails rather than reading zeros. It is written whole and renamed into place. Downloaded bytes are renamed into place too (`installPart:…`). No reader ever sees either half made. **The install's mtime keeps the cache key.** The key is size, mtime, and path (`NSURL+Hash`), so the cached tags and waveform match the downloaded file. The default mtime is the placeholder's. `DropboxMirror` takes its response's `server_modified`.

**The store makes its root once and keeps it out of backups** (`prepareRoot`). It is a cache of what the server holds. `containsURL:` says whether a file lies under the root, from its path alone.

**Each directory carries an index in an xattr**, named at init. It is on the directory, because a placeholder's attributes are as unreadable as its bytes. Its contents are the subclass's. The store caches parsed indexes in memory, since a ranged read asks for one per block, and rewrites one only when it changed. A removed directory takes its cached index with it (`forgetCachedIndexes`).

**The hooks say which remote file a placeholder stands for and how to read its answers** (`RemotePlaceholderStoreInternal.h`). `remoteTargetForURL:error:` is the target the client fetches. The download and the ranged read go through `downloadTarget:…` and `readTarget:…`, which call the client by default. `versionOfMetadata:` is the client's by default. `readsByRangeAtURL:` NO means no tail read. A ranged read then answers only from a live stream that holds the whole range. Any other fails with `ENOTSUP` and sends no request. The tags come once the file is local. `budgetRootURL` is where the budget counts. `downloadsDidChangeWithTotal:` is told each new total.

**The fetch streams into a hidden part file** (`NSURLUtil remotePlaceholderPartURL:`). The part file's own rules are the client's (above). The fetch publishes it while it writes it (`availabilityForURL:`, the streaming lookup, `System/AGENTS.md`): a `CloudFileAvailability` per transfer, keyed by the file's comparable path. It is made at the first accepted response, with that response's size. That is the version being downloaded, which may differ from the placeholder's. It is kept across every resend. A response naming no size streams nothing and downloads whole. The fetch's `onReadable` fires once, past 256 KB of head and short of the size. A file that completes first never fires it.

**A stream reads its tail once, beside the download.** The window is sized by `VibeAudioFileTailWindowBytes` (`Audio/Loading/AudioFileOpenRules.h`). It is a ranged read on the call session, of the same target, at the same moment. It lands about when the head does. It is installed as the availability's tail window, from which the handle reads past the download's edge. Readable does not wait for it. A failed tail read logs one line and leaves the window absent. Reads there wait for the download. The finish cancels a tail read still running.

**TRAP: a read of the target answers whatever version is current.** The window is therefore installed only by whichever answer lands second. It is installed only when the ranged answer names the download's version, and the download's size is the placeholder's its offset came from. A version missing on either side drops it (`installTail:…`). Installed unchecked, another version's tail would decode as this one's.

**TRAP: finished after the install, forgotten after the finish.** A reader whose part open missed the rename waits for the finish, then opens the URL. A failure's part is deleted or kept by the client. Either way that same wait turns into the failure, never a missing file or a short read.

**The fetch's cancel keeps the part.** The coordinator cancels when nothing reads the stream any more (`Audio/Loading/AGENTS.md`). A stall's replay then continues the download where it stopped.

**Tags are read by range, never by download** (`readPlaceholderAtURL:…`, installed as the read `CloudFileMaterializer`'s `remoteReadForURL:` answers). **A file streaming now is read from its stream first** (`streamedBytesOfURL:…`). A range in its first MB or its tail window waits up to 3 s for the stream to hold it. Any other range takes the part file's prefix below the bytes noted. The server is asked only for the rest. A read past 30 s is given up, and the parse fails, to be retried by a later scan.

**Past the download budget the oldest downloads go back to placeholders**, oldest first by download time, never the file just fetched. Size and mtime are kept, so the cache key still matches when the file comes back. A smaller budget applies at once. Remove Downloads does the same to every download. A player still reading an evicted file keeps its open descriptor. A playlist file is never counted as a download.

**`installAsRemoteBackend` registers the store for its root** (`CloudFileMaterializer setRemoteRoot:…`): the fetch, the ranged read, and the streaming lookup. A shell calls it at launch, before anything opens a file under the root. **TRAP: a store with no root installs nothing.** Application Support can fail to resolve. A nil root would remove every backend, another store's too, once Release compiles out `setRemoteRoot:`'s assert.

## Links

**Open URL plays an http or https link as a placeholder of this store** (`LinkStore`). It uses the plain client, with no subclass. Its root is `<Application Support>/Links`, kept out of backups. Each root has its own backend (`System/AGENTS.md`).

**Both apps install it at launch, before anything can open a file under it.** The mac installs it first in `applicationWillFinishLaunching:`, before the restore. iOS installs it in `application:didFinishLaunchingWithOptions:`, after the Dropbox mirror and before the scene restores a playlist.

**The shared client's session is ephemeral.** It has no URL cache and ignores local cache data. `waitsForConnectivity` is off, since a waiting request holds a materialization lane. `allowsURL` is `VibeLinkRequestIsAllowed`, on the link and on every redirect. It applies the address rule to each. A redirect from a public host never reaches the local network, whatever the scheme. A public page could otherwise send requests to a device at home. A redirect can also leave the local network, and a stub cannot test App Transport Security.

**The address rule is `VibeLinkURLAcceptance`.** It answers the `VibeLinkError` a refusal fails with, and None for an address Vibe fetches. https reaches any host. Plain http reaches only a local host (`VibeLinkHostIsLocal`). That is `localhost`, a name ending in `.local`, `.localhost`, or `.test`, an unqualified name, or an address in 10/8, 172.16/12, 192.168/16, 169.254/16, 127/8, 0/8, ::1, ::, fc00::/7, or fe80::/10. Plain http to any other host is insecure. Any other scheme, or no host, is invalid. App Transport Security's `NSAllowsLocalNetworking`, in both apps' Info.plist, draws the same line. Whether it lets a private IP literal through over plain http has not been measured on a real host.

**TRAP: an IPv4 address is parsed as the resolver parses it** (`inet_aton`). `134744072` and `0x8.8.8.8` are 8.8.8.8, not unqualified names. Read as a name, a bare number would let plain http reach any public address.

**TRAP: 0/8 and `::` are the unspecified addresses, and a connection to one reaches this machine.** They count as local. Counted as public, a public page could redirect Vibe to a service on the Mac itself.

**TRAP: a zone id belongs only to an IPv6 literal** (`fe80::1%en0`). A `%` anywhere else, or a NUL, makes the host not local. Cut there like a zone id, `pi%.example.com` would pass as the unqualified name `pi`.

**One directory per link.** Its name is the first 16 hex digits of the SHA-1 of the normalized URL (`VibeLinkDirectoryName`). Normalized means the scheme and host lowercased and the fragment dropped. The directory holds one file, the placeholder or the download. The same link opened again reuses the directory and its file. Two links never share a name.

**The file name is `VibeLinkFileName`.** It is the link's last path component, percent-decoded, when that has a playable extension. Otherwise the Content-Disposition file name wins, when there is one. The extension the audio check chose is forced on. Cleaning swaps `/` and `:` for `-`, and drops control characters, the bidi controls, and leading dots. An override would show a name's end reversed. The name is cut to 200 UTF-8 bytes. It is `Link.<extension>` when nothing survives.

**The record is the directory's index** (`com.commonwealthrecordings.vibe.link`). It is JSON: `{url, etag, lastModified, version, size, modified, contentType, ranges, host, opened}`. `url` is what the client fetches, after the share-link rewrite. `modified` is the mtime the file takes. `ranges` says whether the server answers a Range. `opened` is when the link was last opened. A header the answer lacked is left out. The xattr is read from disk, so each field is checked. A record with a field of the wrong type is no record (`recordOfDirectory:`). A shell reads a link's host by its file (`hostOfLinkFileURL:`), and asks the store whether a file is a link (`containsURL:`). iOS names a link in Recents by its host.

**`resolveURLString:completion:` opens a link in five steps.** It runs off main and completes on main.
1. The address rule. A refusal fails before any request.
2. The share-link rewrite (`VibeLinkDirectDownloadURL`, below).
3. A probe of the first 16 bytes. It is a `GET`, since Dropbox answers `HEAD` with JSON. A 206 gives the size from its Content-Range, and `ranges` is YES. A 200 gives it from its Content-Length, and `ranges` is NO.
4. The audio check and the extension (`VibeLinkAudioExtension`). The first bytes come first: `ID3` or an MPEG sync, ADTS, `fLaC`, `RIFF…WAVE`, `FORM…AIFF` or `AIFC`, the W64 GUID, `OggS`, `ftyp`, or `caff`. Then the URL's extension, the Content-Disposition file name's, and the Content-Type. When the bytes name a family, such as Ogg, MP4, or WAV, the URL's or the file name's extension picks the member. HTML the bytes do not claim is not audio. The check gets the link's own URL, not the redirect's, since a CDN's path carries no name. It runs before a missing size fails the link. A sign-in page often has no length, and it is still not audio. With no size, icy headers or chunked audio are a live stream, and anything else has no size.
5. The record and the placeholder. The size is the probe's. The mtime is Last-Modified, else the probe's time. The cache key then stays the same across the install.

**The probe has a deadline** (`VibeLinkProbeTimeout`). It runs from the request to the first bytes, and redirects and resends count toward it. A public host gets 15 s. A public server that sends nothing for that long is down for practical purposes. A local host gets 30 s. It may be a NAS spinning up its disks. It may sit behind the system's local-network prompt, which holds the first request while the user reads it. A probe past its deadline fails as its host's network failure: unreachable, or the local network's. A link with a download still opens it. The deadline is the store's own timer, not the request's timeout. The session's timeout restarts at every byte, so a server that trickles would never meet it. `probeTimeoutScale` shortens it for the tests.

**The user can cancel a resolve.** `resolveURLString:completion:` returns a block that cancels, on main. A resolve not yet completed then completes before the block returns, with `VibeLinkErrorCancelled`, and nothing lands after it. Past the completion the block does nothing. The disk queue decides which of the answer, the deadline, and the cancel came first. The other two then do nothing. A cancel before the answer writes no record and no placeholder. `messageForError:brief:` answers nil for a cancel, so neither shell shows anything.

**A failure is a `VibeLinkErrorDomain` error whose code is a `VibeLinkError`** (`LinkStore.h`). The `VibeLinkErrorOf…` functions in `LinkRules.h` choose the code.
- A refused address fails with the address rule's own answer.
- A status of 401 or 403 is denied, and 404 or 410 is not found. Any other status is the server's failure, a 2xx other than 200 or 206 included. The status rides under `VibeHTTPErrorStatusCodeKey`.
- A request with no response is insecure when App Transport Security refused it. A cancel shows nothing (`VibeLinkErrorCancelled`). Any other failure is the local network's when the host is local, and unreachable otherwise. A denied local-network permission fails as the local network's.
- A refused redirect is insecure.
- A missing size is a live stream or no size, and bytes that are not audio are not audio.

The cause rides under `NSUnderlyingErrorKey`. A disk failure is passed through as its POSIX error. `+[LinkStore messageForError:brief:]` turns the code into its string, the server's with its status. iOS shows the `link.error` sentence in an alert. The mac shows the short `link.status` string in its header (`brief`). An error outside the domain reads as unreachable.

**Two hosts' share links are rewritten to their bytes** (`VibeLinkDirectDownloadURL`). **Each host's rules live in its own file, and no other link code names a host.** The rewrite asks each file in turn and fetches any other link as typed. `DropboxLinkRules.h` gives a Dropbox file link (`/scl/fi/…`, `/s/…`) `dl=1`, and keeps its other query items, `rlkey` among them. `GoogleDriveLinkRules.h` makes a Google Drive file link (`/file/d/<id>/…`, or the `id` item of `/open` or `/uc`) into `drive.usercontent.google.com/download?id=<id>&export=download&confirm=t`. `confirm=t` skips the virus-scan page a large file gets. Its `resourcekey` is kept, since older shares need it. A folder link, an empty id, or an id outside `[A-Za-z0-9_-]` is left as it is. The path is split before percent-decoding. An encoded `/` then cannot shorten an id. A new host is a new file and one more step in the rewrite. `docs/future/share-links.md` has the probes.

**Dropbox answers what a link needs** (measured on a shared AIFF). `dl=1` answers one 302 to `<id>.dl.dropboxusercontent.com`. A range there gets a 206 with Content-Range and an ETag, and the ETag is the version. Its Content-Disposition says `filename=unspecified`. The name then comes from the link's own path, which has a playable extension.

**Google Drive answers what a link needs** (measured on a shared WAV). A range gets a 206 with Content-Range. It sends Last-Modified and no ETag. Last-Modified is then the version. The path ends in `download` and names nothing. The name comes from Content-Disposition. A private or over-quota file answers an HTML page. It fails as denied on a 403, and as not audio on a 200. Drive's `/u/<n>/` paths and `docs.google.com` links are not rewritten.

**An open again keeps what is still current.** The same version and size keep the file, placeholder or download, and touch `opened`. The file's own size and mtime must be the record's too. A record changed while its file streamed describes bytes the placeholder does not. Once the stream ends, the next open writes a fresh placeholder. Another version writes a new placeholder. A link with no version is fetched again, since nothing proves its download current. A link that cannot be reached still opens its download, when it has one.

**TRAP: a file being fetched now keeps its placeholder** (`isFetchingURL:`). That holds from the fetch's start, before its first response makes a stream. The fetch's install renames its bytes over whatever stands at the URL, and its readers hold the part file. A placeholder under a new name would leave that install a second file in the directory. Only the record changes. The install then sets the record back to what it downloaded.

**TRAP: the install keeps the record's mtime only while the download is the record's file** (`modificationTimeOfMetadata:forURL:`). The cache key is made from that mtime. A download of another version takes its own Last-Modified, else the time now, and the record follows it. A record left describing other bytes would send the download back to a placeholder at the next open, or fail its tag reads.

**TRAP: the mtime hook syncs onto the disk queue from the client's delivery queue.** Nothing on the disk queue may wait on the client, or the two deadlock.

**A tag read checks the record.** An answer of another size, or of another version, fails with `VibeHTTPErrorVersionChanged`, and the parse is retried later. A record with no version is checked by its size alone.

**The CDN case is one rule in three places** (`VibeHTTPIsSameFileUnderAnotherETag`). The client applies it to a resend (above). The store applies it to an open again and to a tag read. An answer under another ETag with the record's size and Last-Modified, both stated, is the same file. Each acceptance is logged. The tail window compares versions only. Under another ETag it is dropped, and reads there wait for the download.

**A server without ranges downloads whole.** It gets no tail read and no ranged tag read. Its tags come once the file is local. A resend still asks for a range, and a 200 to it skips the bytes written.

**The budget is `kVibeLinkDownloadBudgetBytes`, 2 GB, with no setting.** The store's eviction applies (above).

**Pruning deletes each link not opened for 30 days that nothing keeps** (`pruneKeepingTracks:recentURLs:`, `VibeLinkDirectoriesToPrune`). A directory with no record counts as long unopened. A shell calls it once per launch, after the launch's restore. It keeps the playlist's rows as the launch restored them and the recent items. The store reads them off main, and only once it finds a link. On the mac those are the recent documents. On iOS they are Recents. **A saved M3U naming a pruned link finds that entry missing.**

**A link can arrive by a drop on the mac's window** (`Mac/App/AGENTS.md`). What a drop holds is decided here, as plain data, so the tests need no pasteboard. `VibeDropURLsOfItems` reads each pasteboard item's strings by type: a file URL wins, then a URL, then text. A URL or text counts only when it is one http or https link (`VibeLinkIsWebLink`). A `.webloc` is a file, and its link is the `URL` key of its property list, XML or binary (`VibeLinkURLOfWebloc`). `VibeDropOpenOrder` swaps each `.webloc` for its link and keeps each link once, by its normalized URL. Files are never merged. Files and links keep drop order. iOS has no drop target.

**The debug channel serves links from a directory** (`VibeFakeHTTP`, `Debug/AGENTS.md`). It replaces the shared client's sessions through `useSessionConfiguration:`. `open_url` resolves a link through each shell's own Open URL road. On the mac, `file_drag_drop` drops a link as a browser's text.
