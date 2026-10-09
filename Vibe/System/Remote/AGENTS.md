# Remote files over HTTP

Files the app fetches itself over HTTP, rather than through a file provider. Both apps compile this directory. It is Foundation-only.

| File | Owns |
| --- | --- |
| `HTTPTransferClient` | the streamed download, the ranged read and the probe. The resends, the kept part and the version pin |
| `HTTPTransferClientInternal.h` | the hooks a subclass overrides, and the seams the tests and the debug channel use (`useSessionConfiguration:`, `retryDelayScale`) |
| `HTTPTransferRules.h` | the retry delay, the connection errors, and the size and version a response's headers state. Tested (`HTTPTransferRulesTests`) |
| `RemotePlaceholderStore` | remote files as local placeholders under one root: the placeholder and the install, the directory index, the fetch that streams, the ranged read, the download budget, and the backend it installs. Tested (`RemotePlaceholderStoreTests`) |
| `RemotePlaceholderStoreInternal.h` | the hooks a subclass overrides, and what a subclass and the tests reach: the disk queue, the index, the downloads and the budget |

`DropboxClient` subclasses the client, and `DropboxMirror` subclasses the store (`iOS/Dropbox/AGENTS.md`).

**TRAP: a subclass's internal header imports `HTTPTransferClientInternal.h` and never redeclares its seams** (`DropboxClientInternal.h`). A redeclaration that cannot see the base's gets an ivar of its own. It starts at 0, not 1, and every retry wait would read it.

## The client

**The defaults are plain HTTP.** A target is an `NSURL`, fetched with a `GET`. The size is a 206's Content-Range total, or a 200's Content-Length when no Content-Encoding is set. The version is a strong ETag, else Last-Modified. A weak ETag (`W/`) counts as absent, since it promises equivalent bytes, not the same ones. A subclass changes any of this through the hooks in `HTTPTransferClientInternal.h`. Each hook gets the transfer's own `state` dictionary, which lives across its attempts and which the base never reads. `DropboxClient` keeps its access token and the refresh flag there.

**TRAP: every default request asks for `Accept-Encoding: identity`.** With no such header, `NSURLSession` asks for gzip and inflates the answer. A range's offsets then stop matching the file's bytes.

**Two sessions.** Downloads and probes stream on a delegate session of their own. Calls and ranged reads are answered whole on the other, so a tag read never queues behind a download's disk writes. The client is the delegate of both. The call session needs it only for the redirect check.

**TRAP: a delegate session retains its delegate until it is invalidated.** The client lives as long as the app. Only a session that `useSessionConfiguration:` replaces is invalidated.

**`allowsURL` is asked of every request and every redirect.** A request it refuses is never sent. A redirect it refuses completes its task with the 3xx itself, and the transfer fails with `VibeHTTPErrorRefusedURL`.

**A cancel settles a transfer at once when no task is in flight for it** (`cancelTransfer:`). That covers a transfer waiting on the request hook, such as Dropbox's token refresh, or on a retry's delay. The lane the caller holds is freed now (`System/AGENTS.md`).

**TRAP: a transfer is adopted and entered in the delegate's table under one lock** (`adoptTask:forTransfer:`). A cancel between the two left a task whose completion found no transfer, so the download never finished. The table is keyed by the task object, because the two sessions number their tasks apart.

**A part file is made once per transfer, at its first accepted response, and only ever appended to.** A descriptor opened on it keeps seeing one inode grow. A resend asks for `Range: bytes=<written>-` and appends. A 200 to that is the whole file, and its prefix is skipped. A dropped connection is resent at most twice in a row with no byte between.

**TRAP: a resend answers whatever version is current.** Every response's version must therefore equal the first one's. A first response with no version is never resumed. A mismatch fails the transfer with `VibeHTTPErrorVersionChanged` and deletes the part.

**A transfer the link ended keeps its part** (`keepsPartAfterError:`: a cancel, or a connection lost past the resend bound). The part is tagged with its version in the xattr `com.commonwealthrecordings.Vibe.rev`. The name stays, so parts kept by the Dropbox client still resume. The next download of that destination continues from its last byte. An answer naming another version, or a 416 because the current version is shorter than the part, starts the transfer over, whole (`restart`). A part with no version tag is replaced. Anything the transfer's own answer ended deletes the part, since the same bytes would only fail again.

**The first response's size is the file's length.** A transfer dropped after its last byte is complete, since `bytes=<size>-` would answer 416. One ending at any other length fails with `VibeHTTPErrorLengthMismatch` and deletes the part.

**A probe reads the first bytes and the headers** (`probeTarget:length:`). It is a ranged `GET` on the download session. It cancels its own task once it holds the bytes. A server that ignores the range answers 200, and the probe keeps only the bytes asked for. A failure status goes through `handleFailureStatus:…` like any other.

## The placeholder store

**A placeholder is a sparse file of the remote size and mtime with no permissions** (`VibeWritePlaceholder`, `NSURLUtil`'s remote placeholder). Its stat is the real one, and a direct open fails rather than reading zeros. It is written whole and renamed into place. Downloaded bytes are renamed into place too (`VibeInstallPart`). No reader ever sees either half made. **The install's mtime keeps the cache key.** The key is size, mtime and path (`NSURL+Hash`), so the cached tags and waveform match the downloaded file. The default mtime is the placeholder's. `DropboxMirror` takes its response's `server_modified`.

**Each directory carries an index in an xattr**, named at init. It is on the directory, because a placeholder's attributes are as unreadable as its bytes. Its contents are the subclass's. The store caches parsed indexes in memory, since a ranged read asks for one per block, and rewrites one only when it changed. A removed directory takes its cached index with it (`forgetCachedIndexes`).

**The hooks say which remote file a placeholder stands for and how to read its answers** (`RemotePlaceholderStoreInternal.h`). `remoteTargetForURL:error:` is the target the client fetches. The download and the ranged read go through `downloadTarget:…` and `readTarget:…`, which call the client by default. `versionOfMetadata:` is the client's by default. `readsByRangeAtURL:` NO means no tail read and no ranged read: the tags come once the file is local. `budgetRootURL` is where the budget counts. `downloadsDidChangeWithTotal:` is told each new total.

**The fetch streams into a hidden part file** (`NSURLUtil remotePlaceholderPartURL:`). The part file's own rules are the client's (above). The fetch publishes it while it writes it (`availabilityForURL:`, the streaming lookup, `System/AGENTS.md`): a `CloudFileAvailability` per transfer, keyed by the file's comparable path. It is made at the first accepted response, with that response's size. That is the version being downloaded, which may differ from the placeholder's. It is kept across every resend. A response naming no size streams nothing and downloads whole. The fetch's `onReadable` fires once, past 256 KB of head and short of the size. A file that completes first never fires it.

**A stream reads its tail once, beside the download.** The window is sized by `VibeAudioFileTailWindowBytes` (`Audio/Loading/AudioFileOpenRules.h`). It is a ranged read on the call session, of the same target, at the same moment. It lands about when the head does. It is installed as the availability's tail window, from which the handle reads past the download's edge. Readable does not wait for it. A failed tail read logs one line and leaves the window absent. Reads there wait for the download. The finish cancels a tail read still running.

**TRAP: a read of the target answers whatever version is current.** The window is therefore installed only by whichever answer lands second. It is installed only when the ranged answer names the download's version, and the download's size is the placeholder's its offset came from. A version missing on either side drops it (`installTail:…`). Installed unchecked, another version's tail would decode as this one's.

**TRAP: finished after the install, forgotten after the finish.** A reader whose part open missed the rename waits for the finish, then opens the URL. A failure's part is deleted or kept by the client. Either way that same wait turns into the failure, never a missing file or a short read.

**The fetch's cancel keeps the part.** The coordinator cancels when nothing reads the stream any more (`Audio/Loading/AGENTS.md`). A stall's replay then continues the download where it stopped.

**Tags are read by range, never by download** (`readPlaceholderAtURL:…`, installed as `CloudFileMaterializer.remoteRead`). **A file streaming now is read from its stream first** (`streamedBytesOfURL:…`). A range in its first MB or its tail window waits up to 3 s for the stream to hold it. Any other range takes the part file's prefix below the bytes noted. The server is asked only for the rest. A read past 30 s is given up, and the parse fails, to be retried by a later scan.

**Past the download budget the oldest downloads go back to placeholders**, oldest first by download time, never the file just fetched. Size and mtime are kept, so the cache key still matches when the file comes back. A smaller budget applies at once. Remove Downloads does the same to every download. A player still reading an evicted file keeps its open descriptor. A playlist file is never counted as a download.

**`installAsRemoteBackend` registers the store for its root** (`CloudFileMaterializer setRemoteRoot:…`): the fetch, the ranged read and the streaming lookup. A shell calls it at launch, before anything opens a file under the root.
