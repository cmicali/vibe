# Loading: the app's own transfers

**The file-open path lives in vibe-libs' `files/FileLoading`.** That is the claim and its two stages, the handle-run ceiling, the transfer registry, the progress monitor, the materializer, the availability, the network-mount read-ahead, and the placeholder checks. Its debug seams and the fake cloud moved with it. Its doc, `vibe-libs/files/FileLoading/AGENTS.md`, is the authority for how that code works. Both app targets list its template. A change to it lands in vibe-libs first, then in Vibe's pin. The audio core owns the handle it serves, `AudioFileHandle`.

**What stays here is what only Vibe needs.** Both apps compile this directory.

| Directory | Owns |
| --- | --- |
| `Net/` | files the app fetches itself over HTTP: the transfer client, the remote placeholder store, and the link store. The client, the store, and the link rules move to vibe-libs when another app needs them. The link store stays. Its doc is `Net/AGENTS.md` |
| `iOS/Dropbox/` | the Dropbox account and its local mirror. Only the iOS app compiles it. Its doc is `iOS/Dropbox/AGENTS.md` |

The player's side of an open is `Audio/AGENTS.md`'s: the deadline, progress identity, and prefetch. The sweep's retries against the foreground hold are `Audio/Metadata/AGENTS.md`'s. `docs/file-loading-spec.md` states the observable behavior across all of them. Where it and the piece's doc overlap, the spec is the authority for behavior and its policy numbers. The piece's doc is the authority for how the code works. Three root `AGENTS.md` guarantees are implemented in the piece: the foreground open outranks background downloads, the six-run handle ceiling, and a row shows the loading bar only while a transfer is running.

**Each placeholder store is a remote backend.** It installs itself at launch, before any open, with `installAsRemoteBackend` (`Net/AGENTS.md`). The mac installs the Links store. iOS installs the Dropbox mirror and the Links store (`iOS/Dropbox/AGENTS.md`). The piece sends each remote placeholder to the backend of the longest root holding it.

**The fake cloud is installed by the debug channel** (`Debug/AGENTS.md`). The cloud-loading scenario suite and its oracle tests drive it there (the `vibe-stress` skill). They are Vibe's harness, so they stay here.
