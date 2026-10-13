# Loading: from a path to a readable file

Everything between a path and a usable `AudioFileHandle`, which the audio core owns. Both apps compile this directory.

`Claim/` decides which open runs, and when. `Transfer/` moves the bytes and reports how far they have come. `PlaceholderFiles` stays at the root, because both groups and the metadata scan ask it.

| File | Owns |
| --- | --- |
| `PlaceholderFiles` | which files are placeholders: the dataless test and the remote placeholder rule. |
| `Claim/AudioFileMaterializationCoordinator` | the claim, stage 1, and the snapshot |
| `Claim/AudioFileMaterializationCoordinator+HandleOpen.m` | stage 2: the handle runs and the six-run ceiling. Its public call, `openURL:…`, is declared in the header's `(HandleOpen)` category |
| `Claim/AudioFileMaterializationCoordinatorInternal.h` | the class extension both files share: the claim, waiter and handle-run records and every ivar. It also holds the test seams and stage 2's cross-file calls |
| `Claim/AudioFileMaterializationTokens` | the request and open tokens. Each delivers its completion at most once, and its cancel detaches it from the coordinator |
| `Claim/AudioWorkScheduler`, `Claim/AudioWorkAdmissionRules.h` | admission |
| `Claim/AudioLoadingConfiguration` | the immutable limits and the open-timeout seam |
| `Claim/AudioFileOpenRules.h`, `Claim/AudioFileOpenTimeoutMath.h` | the decisions. Among them are the tail window a stream fetches for an open that reads a file's end, and `VibeMountReadsAhead`, which files read ahead |
| `Transfer/CloudTransferRegistry` | which files are on the wire |
| `Transfer/DownloadProgressMonitor`, `Transfer/DownloadProgressSourceAdapters`, `Transfer/DownloadProgressRules.h` | how far one transfer has come, for the registry |
| `Transfer/CloudFileMaterializer` | the abortable download of a placeholder, a provider's or a remote one |
| `Transfer/CloudFileAvailability` | how much of a file is readable while a writer fetches it |
| `Transfer/NetworkReadAhead` | the read-ahead of a file on a network mount: its thread, its blocks, its retries and its orphans. It is a writer of a `CloudFileAvailability` |
| `Net/` | files the app fetches itself over HTTP. Its doc is `Net/AGENTS.md` |
| `iOS/Dropbox/` | the Dropbox account and its local mirror. Only the iOS app compiles it. Its doc is `iOS/Dropbox/AGENTS.md` |

The player's side of an open is `Audio/AGENTS.md`'s: the deadline, progress identity and prefetch. The sweep's retries against the foreground hold are `Audio/Metadata/AGENTS.md`'s. `docs/file-loading-spec.md` states the observable behavior across all of them. Where the two overlap, the spec is the authority for behavior and its policy numbers. This file is the authority for how the code works. Three root `AGENTS.md` guarantees are implemented here: the foreground open outranks background downloads, the six-run handle ceiling, and a row shows the loading bar only while a transfer is running.

## Placeholder files

**`PlaceholderFiles` answers whether a file is here.** `isDatalessFile:` is the one verdict every background reader asks before it reads.

**TRAP: `isDatalessFile:` is `SF_DATALESS` alone, never an `NSURL` resource value.** NSURL memoizes those per instance, so a placeholder would read "not downloaded" for its `AudioTrack`'s whole life.

**The one other dataless verdict is the remote placeholder**, and only under a root that a remote backend installs (The remote fetch, below). A regular file its owner may not read (`VibeFileModeIsRemotePlaceholder`) stands for a remote file of its size and mtime. Its stat is real, so listing, sorting and the cache key treat it as the file. Any direct open fails rather than reading zeros, so the waveform loader and TagLib open without asking. `remotePlaceholderPartURL:` names the hidden sibling its bytes stream into. The path is tested before any stat, so a file under no root pays nothing. Under no root an unreadable file is merely unreadable. Both apps install the Links root at launch, so a root is always installed.

## One claim, two stages

**A file's journey from dataless placeholder to handle is one path-keyed claim in two stages.** Stage 1 is the one operation that can make a standardized path local. Playback, Prefetch and the two metadata roles affect admission, never identity. Stage 2 is the purpose-keyed handle runs riding it. There is one current handle waiter per `(purpose, path)`. Playback and prefetch therefore keep independent handles and delivery while they share the path's transfer. Only a stage-1 Ready or readable claim dispatches a handle open. Yielded, AdmissionExhausted and Failed become terminal outer errors without touching CoreAudio.

`AudioFileOpenRules.h` holds the decisions. `VibeAudioFileOpenBeginDelivery` and `VibeAudioFileOpenDetachDelivery` are the two sides of the race for the one Waiting transition. Whichever changes it first owns the outcome. `VibeStandardizedAudioOpenPath` is the one spelling every claim is keyed by. It uses `VibeComparablePath`, with no filesystem I/O. **TRAP: `URLByStandardizingPath` stats a path that starts with `/private` or holds `..`**, so it can stall the player or state queue before the bounded probe begins. Every path an iOS provider hands over starts with `/private`. Compare spelling alone.

**The stage-1 state queue owns in-memory claim state and performs no filesystem or provider I/O.** A first waiter synchronously installs a `Probing` claim. Then one private `AudioWorkScheduler` classifies the path off the queue. Same-path waiters join and share the probe. A fresh answer starts an immediately admitted claim. A dataless claim that had to wait, or was readmitted, reserves its lane and enters `Refreshing`. It re-probes in that admitted worker, and becomes `Running` only when the state queue accepts the fresh answer. The successful paths are `Probing → Running` and `Probing → Pending → Refreshing → Running`. Dataless readmission routes through `Pending` or `Refreshing` the same way.

**A fresh local answer is the run's answer.** An initial probe's settles the claim Ready in the next state turn, with no operation, lane or worker. A start refresh's settles it from that worker, without running the operation it made. A local verdict carried from an earlier run is not fresh. It runs an operation that probes again, since the file may have been evicted since. Object identity drops a result from a cancelled or replaced probe. A ready operation records the path local before any cancellation or rebind restart decision.

The accepted dataless verdict is reported through `onDataless` at most once per open token. It arrives on the token's completion queue, and only while delivery is still waiting. Joining an already-classified claim reports it too, and so does rebinding a handle run. Rebinding cancels the superseded token, which drops its queued callback.

**A remote transfer is readable before it is complete, and readable is a field of `Running`, not a state.** The operation's `onReadable` comes from a placeholder store's fetch (`Net/AGENTS.md`). A provider never calls it. It runs on the client's shared delivery queue, and from there only hops to the state queue (its `TRAP:`). There `claimBecameReadable:` matches the run by generation. It drops a readable whose transfer already finished, which the lookup answers nil for. Otherwise it keeps the run's `CloudFileAvailability`, which marks the claim readable. It serves every playback and prefetch waiter as a Ready would. A handle run's open is dispatched in that same turn, never through its token. The claim stays `Running`, and its metadata waiters wait for complete. A playback or prefetch waiter that joins a readable claim is served on the next state turn, once its run holds its token. Complete then settles the claim Ready and delivers to nobody new. A failure settles the remaining waiters Failed, and the availability fails the delivered handles' reads with the transfer's error.

**A readable stream is held by what it served, counted in one place: the availability's holders** (`addReader`). Each open dispatched while readable holds it from dispatch until its result is delivered on the state queue. Each handle it returned holds it from its open until its dealloc (`holdStream`, sent on the open's worker before the open lets go). The count therefore never dips to zero across the handoff. `onLastReaderGone` asks again, and reaches the state queue behind the turn that delivered, so a rebound run's waiter is installed first. Only served handles hold. Any other reader of the part file, such as the waveform's, rides the stream and fails with it (`Audio/Waveform/AGENTS.md`).

That count stands in for the served waiters wherever a playback or prefetch waiter counted (`claimServesForeground:`). The foreground hold stays raised, so the sweep's ranged reads stay off the wire while the user's stream downloads. A metadata waiter may still join. A run with no waiter and no reader is cancelled (`cancelRunIfAbandoned:`, the one place where a last waiter leaving cancels too). A skip away from a stream therefore stops its download and frees its lane. A metadata waiter still on the claim keeps it running.

**The eight initial-probe slots are process-wide, and their exhaustion is a bounded failure by design.** Production can present about eleven distinct claims at once: playback, prefetch, the scan and priority metadata slots, and seven artwork requests. Eight wedged probes can make a later healthy path expire after the five-second grace. That settles as `AdmissionExhausted`, spends one of metadata's three per-path attempts, and can drop the path from the current scan. It replaces an unbounded tail of uncancellable system calls. Refresh probes do not use the slots. A never-returning refresh stays state-isolated, but holds its reserved transfer lane, the one-wide background lane included.

## Admission has two lifetimes

**A transfer lane ends when its materialization run settles. The handle-run ceiling is a separate lifetime.** For a stream the run settles when the download completes or fails, not when its handles open. A readable claim keeps its lane and its registry entry while the handles it served read the part file. A lane can therefore be held for the whole download under a playing track. The lane counts bound transfers, not opens. The abandoned-stream cancel keeps a rapid skipper from filling the interactive lane with downloads nobody hears.

**Each coordinator permits at most six live handle runs.** Production shares one coordinator, so the bound is process-wide. It is the root guarantee's two-source bound plus room for four stranded opens. A run ends when its open returns. A streaming run leaves the ceiling at delivery, and its transfer runs on. A streaming open never strands, since a cancel ends its waits. A read-ahead open never strands either. Its syscalls run on its handle's own thread, and every wait it makes can be interrupted (The network-mount read-ahead, below). What can still strand a run is a whole-file open on a local volume, a provider's file included, and the QuickTime reader's URL open. A symlinked path, and any path the mount table cannot place, takes the direct road and can strand a run. A read-ahead thread that a dead mount strands is bounded apart from the runs. At eight orphans, a new read-ahead open waits until one exits. That wait can be interrupted too.

An existing `(purpose, path)` run is looked up and rebound before the ceiling is checked. Saturation therefore never duplicates or rejects work in flight. A seventh key is refused at once with `VibeAudioFileOpenErrorAdmissionExhausted`, counted in `requestsAdmissionExhausted`, before materialization starts. The ceiling is a private, purpose-blind safety bound over `_handleRuns.count`, not loading policy. It has no queue, grace, configuration value or per-handle counter. Prefetch can exhaust it and get a later playback key refused. Waveform work keeps its own fixed-slot schedulers.

**Transfer-lane admission is the coordinator's own** (`admitClaim:…`). Running claims count against the lane's maximum. Pending claims count against the pending bound, with a deadline at the grace. A file already local starts at once outside the lanes, so only dataless claims are bounded. **Only a dataless run holds a lane slot** (`holdsLane`). A start refresh that finds its file local hands the reserved slot back. Nothing times a running read out. A counted local read stalled on a network share or a sleeping disk would hold the one-wide background lane for as long as it blocked, and every cloud row's metadata would expire behind it. `AudioWorkAdmissionRules.h`, tested, is the scheduler's. `VibeAudioWorkAdmission` and `VibeAudioWorkAdmissionExpired` are what `AudioWorkScheduler` reads, here for the dataless probe. Transfer exhaustion and the handle-run refusal both map to `VibeAudioFileOpenErrorAdmissionExhausted`. The file never began, which is not that file's playback timeout.

**A run stays registered until its handle open really returns.** A timeout or a superseding request detaches the outer delivery and the materialization waiter. A handle open already begun keeps its run until it returns. A cancellation before stage 2 removes it.

**A whole-file open is uncancellable, since it makes no waits. A streaming open and a read-ahead open are cancellable at every wait.** The cancel sets the run's `openInterrupted`, and the open's `interrupted:` block answers it. For a stream the cancel also calls the availability's `wakeWaiters`, so its wait asks the block at once. A read-ahead's wait needs no wake. It asks the block again every 0.25 s. Either open, parked waiting for bytes, then returns with an interruption that reaches no one. The waiter was detached, or a rebound one gets a fresh run. That is how the player's open deadline stops a stalled stream or a stalled read-ahead. Rebind and the abandoned-then-rebound restart keep the same dictionary membership, so repeated retries cannot multiply stranded workers. A never-returning whole-file call stays one of the six until process restart, but it holds no transfer slot.

**Cancelling is the only way to stop waiting, and it cannot be separated from marking an admitted handle-open run abandoned.** `finishHandleRun:…` tells "nobody was waiting" from "this file would not open" by the run's cancelled mark alone. A waiter cleared without the mark would let the first be delivered to a later same-purpose, same-path waiter as a nil file with no error. Every caller reads that as the file failing. Before the handle open is dispatched, cancellation simply detaches the central request and removes the outer claim. A completion therefore always carries a file or a reason there is none.

**A run that installs another version than its placeholder stood for re-keys every track.** The production operation compares the file's `cacheKey` before and after the run. A remote file downloads as it is now: a Dropbox file re-uploaded since its folder was listed, or a link changed since its open. When the key moved, the operation sends `AudioTrack.invalidateMemoizedCacheKeys`. No waveform or metadata is then filed under, or served from, the old version's entry. A waveform keyed while its file streamed is filed under the old key and orphaned, never served for the new version.

## The transfer registry

**`CloudTransferRegistry` is the coordinator's publication surface for "which files are on the wire", and only a dataless verdict publishes.** A fresh initial answer governs an immediately admitted run. A delayed or readmitted dataless claim publishes from its `Refreshing` worker's fresh answer. `Running` plus `dataless` means begin was published, so `finishClaim:` pairs the end without a second flag, readable or not. A stream's row therefore shows the bar until the download ends. A local run, and a claim queued behind lane capacity, publish nothing. That is what makes the lanes bound the row indicators as they bound the transfers.

**It is the one home of "this file is loading, this far", and it watches each transferring path once.** It is main-thread. Each entry has one `DownloadProgressMonitor`, whose fraction is the best source for the backend (below). Its observers are weak and many: each shell's row list and its player model. `cloudTransferRegistryDidChange:` is coalesced per main turn, and fires on begin, end and a shown fraction's change. The optional `didMoveTransferForPath:` is the monitor's uncoalesced movement feed, keyed by the transfer's standardized path. Each shell matches it against its loading open's path, standardized once at `didBeginLoading:`. It forwards a match to `noteOpenProgressForOpenRequestIdentifier:` with that open's identifier (`Audio/AGENTS.md`).

**TRAP: no consumer runs a monitor of its own.** A second monitor on the playing file means the registry standing aside for it. A stream starts long before its download ends, so ending that monitor at the start freezes the playing row's fraction for the rest of the download. Row wiring is `Playlist/Mac/AGENTS.md`'s and `iOS/AGENTS.md`'s.

## DownloadProgressMonitor

Best-effort download progress for a file being materialized, for `CloudTransferRegistry`. Every loading indicator on both platforms reads the registry: a shimmer while indeterminate, a fill once a fraction is known. Main thread only. **It observes and must never trigger a download.** The player's open is what fetches.

**The registry starts the only one per transferring path, through `+monitorForURL:movement:handler:`**, and cancels it at the transfer's end. The two-step init and start it wraps is private (`DownloadProgressMonitorInternal.h`).

**Three sources, and the best wins.**
- Everywhere, a poll of the dataless file's allocated size against its logical size.
- An iCloud `NSMetadataQuery`, when the item is in iCloud's index.
- On macOS, the File Provider `NSProgress` publication. It is exact when the provider publishes, and supersedes the poll. iOS has no consumer-side progress API for third-party providers, so those files have only the poll. The header records why.

**A remote placeholder's poll reads its transfer instead**: `CloudFileAvailability.writtenBytes` against the size being downloaded. Its bytes reach the placeholder only in the install's one rename. The size being downloaded can differ from the placeholder's, after a re-upload since the listing.

`DownloadProgressMonitor` owns only source precedence, movement and whole-percent coalescing. The private classes in `DownloadProgressSourceAdapters` each own one system lifecycle: the timer, the metadata query, or the File Provider subscription and KVO. Each owns its whole cancellation path. A new observation mechanism goes behind the same fraction callback, never as another lifecycle in the monitor. `DownloadProgressSourceAdaptersInternal.h` narrows the host-less seam to iCloud query construction and File Provider subscriber registration. The tests drive every other path. Only the OS finding a cross-process publication is a live-app check.

**An `NSProgress` unpublish is not completion.** It also covers an abandoned operation or a disappearing provider. It detaches that exact source and lets the poll verify the file. Only a reported 100% or a materialized file publishes completion.

**The UI fraction is whole-percent coalesced. Transfer liveness is not.** Only a finite, strictly positive raw increase is movement. An initial zero, a repeat, a backward step, a negative value and NaN never extend the player's deadline. The fake source passes zero through the same rule. `DownloadProgressRules.h`, header-only and tested, holds both decisions: `VibeDownloadProgressIsMovement` for liveness, and `VibeDownloadPollShouldPublish` for the poll.

**The poll reports positive partial fractions. It marks the file materialized only when `SF_DATALESS` is clear and allocated bytes reach the logical size.** Every measured provider flags its placeholders: Dropbox on both platforms, and iCloud Drive. The allocated-size check guards providers that do not. With no positive fraction the poll reports nothing.

**The query starts for every transfer except a remote placeholder's**, decided from the path alone (`VibePathIsUnderRemotePlaceholderRoot`). Only a dataless file transfers, and it is a File Provider item or a remote placeholder. Main reads no resource value to decide.

**TRAP: `NSURLIsUbiquitousItemKey` is not an iCloud test.** Every File Provider item answers YES, a Dropbox file included. Only the `NSMetadataQuery` settles it. The query stops on an item iCloud does not index, rather than idling for the length of the download.

`Vibe/Debug/Simulators/VibeFakeCloud` stands in for the provider's reporting too. Its seam **replaces** the sources above. Under a fake transfer the file on disk is genuinely local, so the poll would answer a final 100% on its first tick. `DownloadProgressMonitor+Debug.h` carries the rule.

## CloudFileMaterializer

Pulls a placeholder down to disk as an explicit, **abortable** step. Background only: it blocks for a transfer, and coordinating on main deadlocks against the app's own presenters.

It exists because an ordinary read cannot be interrupted. Opening a dataless file blocks in the kernel until the provider finishes, whatever the app decides meanwhile. TagLib's read and `AudioFileHandle`'s whole-file open both do. `NSFileCoordinator`'s `-cancel` is the one documented way out. So the download is coordinated here, not left inside whatever opens the file next.

Its sole production caller is `AudioFileMaterializationCoordinator`. The coordinator wraps each admitted path-wide run in a fresh materializer. Playback, prefetch and metadata attach role-bearing waiters to the one standardized-path claim. Consumers cancel their own request tokens. Three things reach the materializer's cancel: the last waiter leaving, a stream's last reader leaving, and a central metadata yield. Nothing else mints one.

**Cancellation has one spelling here**, `VibeMaterializationCancelledError` (`NSCocoaErrorDomain` / `NSUserCancelledError`, which `NSFileCoordinator` also returns for its own `-cancel`). Above this class, the coordinator's result is the policy surface: Ready, Yielded, AdmissionExhausted or Failed. Callers never infer retries from the underlying error.

**Every transfer hands `-cancel` one block** (`installCancelTransfer:token:`): the coordinator's, the remote fetch's and the debug fake's. It is installed only while its token is current. A cancel that came first is run by the caller at once.

**A fresh `NSFileCoordinator` per download.** Cancelling poisons one for good, so reusing it would turn the first abort into a permanent refusal. `materializeURL:` builds one per call.

**TRAP: cancelling stops us waiting.** Whether the provider abandons the transfer is its business. A replicated extension's `NSProgress` may be cancelled once nothing waits on it, but nothing promises that. The cancel frees the lane and the thread at once, not the bandwidth.

### The remote fetch

**Stage 1 has two kinds of backend.** A provider's placeholder goes through `NSFileCoordinator`. A remote placeholder goes to the remote fetch installed for its root. The Links store is one on both platforms. The Dropbox mirror is one on iOS. The coordinator cannot tell them apart and must not. Both are a dataless verdict and a blocking, cancellable operation. Readable is a callback either may make, and only the remote one does.

**A placeholder store installs its backend with `installAsRemoteBackend`** (`Net/AGENTS.md`), at launch, before any open. That calls `setRemoteRoot:fetch:read:availability:`, whose header states the root rules. A file goes to the backend of the longest root holding it. The mac installs the Links store. iOS installs the Dropbox mirror and the Links store (`iOS/Dropbox/AGENTS.md`). Every change also sets `PlaceholderFiles`' remote placeholder roots, so the dataless verdict and the backend that answers it cannot disagree. An unreadable file under no root is never sent to a backend. It is merely unreadable.

A backend has three blocks (`CloudFileMaterializer.h` states each one's contract).
- **The fetch** blocks the worker until the bytes have replaced the placeholder. **Unlike the provider path, its cancel stops the transfer**, not just the wait. A fetch that can be read before it completes also calls `onReadable`, at most once, from its own thread. `materializeURL:token:onReadable:error:` hands the caller's block straight through. The claim, its lane, the foreground hold and the loading bar run on until the fetch completes (One claim, two stages, above).
- **The read** reads a placeholder's bytes by range for the tag parse (`Audio/Metadata/AGENTS.md`). Opening a folder then costs its tags, not its files. `remoteReadForURL:` answers the read of the file's backend, nil under no root.
- **The availability**, the streaming lookup, answers a `CloudFileAvailability` for a file whose transfer is writing its part file now. A file it answers nil for opens whole in `AudioFileHandle` (`Audio/AGENTS.md`). It may answer nil only once the object it handed out has finished, since a reader that looked it up may be waiting on it. Every placeholder store installs one.

### CloudFileAvailability

**It says how much of a file is readable while a writer fetches it.** `CloudFileAvailability.h` states every call's contract. There are two writers.
- A transfer writes a part file from byte 0. Its size is known before the first byte. It notes bytes only after writing them. It may also hold one **tail window**: bytes past the download's edge that it read ahead (`Net/AGENTS.md`). The window always lies wholly past the bytes written, so no read mixes the two. A range straddling its start waits for the disk.
- A writer with no part file fetches by range into blocks held in memory (`initWithoutPartFile`). The one such writer is the read-ahead on a network mount (The network-mount read-ahead, below). It drives itself from `waitForWorkUntil:wanted:length:readerPosition:` and asks `heldEndAt:`, never a wait, what is already held. A wait would move the reader's position.

Each writer finishes once. Complete readies every range on the disk. An error fails every wait, bytes already read included. **TRAP: a writer with no part file always finishes with an error.** Complete would send readers to a disk it never wrote, and `finishWithError:` asserts it.

**Waits run on worker threads only.** Nothing the render reaches touches the availability. A wait ends on its range, on the finish, on the reader's own `interrupted` block, or on an optional deadline. `wakeWaiters` makes every wait ask its block again. `readyBytesAt:length:` never waits. A placeholder store's tag reads take a streaming file's bytes that way.

**TRAP: every block is dropped under the lock a reader copies under.** A wait a block answered has then copied before the block goes.

**Holders are counted** (`addReader`): each handle served from the part, and an open about to become one (One claim, two stages, above). `onLastReaderGone` tells whoever runs the transfer that nobody wants it. That is how the coordinator cancels a stream skipped away from. A read-ahead's availability has no holders.

## The network-mount read-ahead

**`NetworkReadAhead` reads a file on a network mount ahead of its handle.** `AudioFileHandle` is its one caller. The handle's side is `Audio/AGENTS.md`'s: when an open reads ahead, and how its reads wait. The handle makes five calls: whether the file reads ahead, wait for room, start, close, and the handle is gone. `AudioFileHandle+Debug.h` is the seam (`Debug/AGENTS.md`). Its category forwards to this file's debug hooks.

**Whether a file reads ahead comes from the kernel's mount table.** `VibeNetworkReadAheadApplies` reads it with `getfsstat(MNT_NOWAIT)` and never stats the path, since a dead mount holds a stat for its timeout. `VibeMountReadsAhead` (`AudioFileOpenRules.h`) takes the mount with the longest prefix of the path, comparing spellings only as `VibeAliasFreePath` writes them. A mount without `MNT_LOCAL` is a network one. An unreadable table, a symlinked path, or a path no mount holds takes the direct road.

**The read-ahead is one thread per handle**, named `com.vibe.readahead`, at a fixed User Initiated QoS, since a prefetch opens at Utility and then becomes the voice. It is the only thread that enters the kernel for the file. It opens the file with the direct road's flags, for the reason in `Audio/AGENTS.md`'s TRAP. It checks the file, and notes its size in an availability with no part file (CloudFileAvailability, above).

It then fetches 256 KB blocks. A range a blocked wait wants comes first, rounded out to whole blocks and started past any bytes already held. Otherwise it fetches ahead of the reader, up to 8 MB. An open that succeeds puts the reader back at the head (`noteReaderPosition:`), or an open that read the tail last would leave nothing fetched ahead of the audio. After each block it drops what lies more than one block behind the reader or past the 8 MB. The block behind serves an MP3 seek's preroll and dr_flac's bisection, and the file's first and last blocks are always kept. A handle holds about 9 MB this way, and a track on a share has up to three handles: the playing one, the parked prefetch and the waveform's.

**A read the server fails never fails the availability, unless the file changed meanwhile.** The thread logs the first failure in a row, waits about 1 s, reopens the file and tries again, until its handle is gone. A reopened file whose size or mtime differs fails the availability with `ESTALE`, since its bytes would mix with the old file's blocks. The inode is not compared, since some SMB servers renumber a file across a reconnect. A server back within the stall's span plays on by itself. **TRAP: a read of 0 bytes below the size is the file's end only when `fstat` says the file is now that short.** A network mount can read 0 bytes while it reconnects. Any other 0 is a failed read, logged as EIO and retried, since taken as the end it ends the track early. The thread records a real end once (`noteShortenedEnd:`).

**The handle's dealloc closes the availability**, with a "closed" error. The thread exits once its current syscall returns, and closes its descriptor. A dead mount can hold that syscall for minutes, and a slow share for a while. Until it returns the thread is an orphan, counted process-wide. **Once eight are orphaned, a new read-ahead open waits** for one to exit, asking its `interrupted` block every 0.25 s. The open deadline still bounds it. The handle-open ceiling counts these threads apart from its six runs (Admission has two lifetimes, above). `Read-ahead:` log lines mark each thread's start, its first failed read and its end.

- **TRAP: the thread retains the availability only, never the handle**, so the handle's dealloc can finish the availability and end the thread.
- **TRAP: the thread never holds the availability's lock across `open`, `pread` or `close`.** The player queue takes that lock through `interruptReads` and `wakeWaiters`.
- **TRAP: the thread never finishes its availability with nil.** Complete would send its readers to a disk it never wrote.
- **TRAP: the orphan count moves only under its own lock, at the handle's dealloc and at the thread's exit.** A thread still running at the dealloc is an orphan until it exits, and no other thread ever is. The two edges share one flags cell, and the second edge frees it.

## Why the monitor and the materializer are not merged

They look like one thing and are opposites in the two ways that matter. The monitor **observes and must never trigger** a download, and is main-thread only. The materializer **causes** one, can abort it, and must never run on main. Merged, "never triggers" and "triggers" would sit behind one name. The real overlap, whether the file is here yet, already lives in one place: `PlaceholderFiles.isDatalessFile:`.

## Configuration

**`AudioLoadingConfiguration` is immutable once built, and its diagnostic surface is for tests and the debug channel only.** The safe tuning surface is the background lane width, the local parse concurrency and the prefetch depth. The interactive lanes, pending bounds, grace, retry count and `openTimeouts` are diagnostic. `Vibe/Debug/Seams/`'s category and the test suite replace them. Production code never does.
