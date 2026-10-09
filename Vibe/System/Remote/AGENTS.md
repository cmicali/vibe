# Remote files over HTTP

Files the app fetches itself over HTTP, rather than through a file provider. Both apps compile this directory. It is Foundation-only.

| File | Owns |
| --- | --- |
| `HTTPTransferClient` | the streamed download, the ranged read and the probe. The resends, the kept part and the version pin |
| `HTTPTransferClientInternal.h` | the hooks a subclass overrides, and the seams the tests and the debug channel use (`useSessionConfiguration:`, `retryDelayScale`) |
| `HTTPTransferRules.h` | the retry delay, the connection errors, and the size and version a response's headers state. Tested (`HTTPTransferRulesTests`) |

`DropboxClient` subclasses the client (`iOS/Dropbox/AGENTS.md`). The placeholder store is still `DropboxMirror`'s. It moves here next, as `RemotePlaceholderStore`.

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
