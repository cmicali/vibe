# File loading and metadata: behavioral spec

This documents what the file-load / metadata subsystem **does today**, as observable
behavior. Reconciled with the implementation on 2026-10-04, including Dropbox
streaming. Section J preserves the refactor's decisions and distinguishes resolved
defects from **OPEN** follow-ups. Dated measurements are not new verification runs.

The spec deliberately does **not** constrain mechanism. Holds vs. preemption, one
coordinator vs. two, which object owns a timer — all free, so long as every numbered
behavior below survives. File references are to the current implementation for
verification only.

Sections: A definitions · B playback opens · C the foreground/background rule ·
D metadata loading · E artwork · F deliveries and staleness · G lifecycle edges ·
H policy numbers · I platform differences · J open items · K non-goals.

---

## A. Definitions

- **A1. Local / dataless.** A file is *local* when its contents are on disk; *dataless*
  when it is a File Provider or app-owned remote placeholder needing a transfer
  (`NSURLUtil.isDatalessFile:`). Every rule that bounds or suspends downloads binds
  *transfers*; a local file never starts one and is exempt from all of them.
- **A2. Materialization.** Making a standardized path local (a provider or remote
  download, or a no-op for a local file). A remote stream can become readable before
  that operation completes. At most **one materialization operation exists per
  standardized path** at any time; every interested party joins it rather than starting
  a second transfer. This is the single most load-bearing rule in the subsystem.
- **A3. Open.** Producing a usable `AudioFileHandle` for a purpose (playback or
  prefetch; gapless opens nothing, B6). Purposes hold **independent handles** for the same path —
  a handle has one stateful read position, so handles are never shared.
- **A4. Roles.** Work competing for transfers is one of: playback, prefetch, metadata
  for the current track ("priority"), metadata for the playlist sweep ("scan"),
  artwork extraction. Playback and prefetch are *foreground*; the rest are
  *background*.
- **A5. Submission identity.** Every play submission gets a fresh identity. A replayed
  same row reuses the same `AudioTrack` **and** the same URL, so no content-based
  check can tell a stale settlement from a current one; identity is the only correct
  guard (measured: a stale `didStartPlaying:` once resumed the background scan 15 ms
  into a foreground open).

## B. Playback opens

- **B1.** Playing a local file starts sound in tens of milliseconds; nothing in this
  subsystem may add a transfer, a permission prompt, or an unbounded wait to the
  local path.
- **B2.** Playing a dataless file downloads it (one transfer, A2). A provider file
  opens after materialization; a remote stream may open and play before completion.
  An accepted dataless classification shows Loading immediately; an otherwise slow
  open uses the **0.5 s** fallback (`kSlowOpenIndicatorDelaySeconds`). The row's
  transfer bar appears only while its transfer actually runs, not while queued.
  Play/pause during Loading toggles whether the open lands playing or parked;
  seek during Loading retargets the start position.
- **B3. Progress and the deadline.** Download progress is observable (the loading
  bar), and progress feeds liveness: an open is abandoned after **60 s with no
  progress**, extended to **60 s past each positive byte movement**
  (`AudioFileOpenTimeoutMath.h`). A moving transfer is never abandoned; deadlines
  extend, never shorten. Progress is matched by *open identifier*, not path or track,
  so a replay cannot inherit a stale monitor and a retry cannot extend a dead one.
- **B4. Abandonment.** A timed-out open reports a timeout error naming the file, stops
  cleanly (no auto-resume), and the abandoned pick is **not** chased: it returns to
  the sweep as an ordinary candidate at its ordinary rank (see J5 for history).
- **B5. Prefetch.** On every track start the likely successor is pre-opened
  (depth 1). A prefetch transfer must never delay a playback transfer. A same-path
  play consumes the parked prefetch handle; whichever of a racing prefetch/playback
  open succeeds first serves the play, and the loser's park state is retired so the
  current track cannot become its own successor.
- **B6. Gapless.** With the crossfade at minimum (and, under bit-perfect output, the
  formats matching), the parked prefetch handle itself is queued as the current
  voice's successor; there is no second open. The parked handle is already usable,
  including when it reads a still-downloading stream.
- **B7. "On track end" is enforced at prefetch and advance.** Every prefetch site
  asks `successorPrefetchTrack`; under Pause-at-track-end it answers nil. Each shell
  also checks `VibePlaybackShouldAdvanceAtTrackEnd` before advancing, and a splice
  is adopted only while its track remains `Playlist.trackEndSuccessor`. Changing
  Pause, repeat or shuffle re-evaluates the parked successor.
- **B8. Admission is bounded end to end.** Concurrent provider transfers, pending
  transfer work, and live handle runs are all bounded (numbers in H). Transfer
  work may wait only within its explicit pending bound and grace. A seventh distinct
  handle run is refused immediately as "admission exhausted" — it has no queue,
  pending allowance, or grace. A truly never-returning OS call remains one of the
  six live runs until process restart, but consumes no transfer capacity and cannot
  become unbounded worker growth.
- **B9. Stop/Close fires no delegate callback.** It supersedes any in-flight open so
  a Loading track never starts, and never drives auto-advance. Track-end and
  skip-past-end funnel through exactly one settlement each.
- **B10. Classification concurrency is bounded and state-isolated.** Initial
  classifications use eight running and sixteen pending slots. One stalled initial
  probe leaves other running slots free; saturation can make a healthy pending probe
  fail after five seconds as admission exhausted — and for metadata spend D7's
  per-path budget — rather than create an unbounded worker tail. A delayed/readmitted
  dataless refresh begins only after reserving its transfer lane and does not use those
  slots. It has no expiry: a never-returning refresh holds that lane indefinitely,
  including production's one-wide background lane. Neither phase blocks request
  registration or coordinator state.

## C. The foreground/background rule

- **C1. The rule.** While the coordinator has a foreground claim — a playback or
  prefetch waiter, or a readable stream still downloading under a handle it served —
  **metadata-only dataless work yields**. The sweep also defers its remote ranged
  reads. A successful streaming open does not end this hold: the user's transfer
  still needs the bandwidth. The coordinator derives the hold from its claim table.
- **C2. Local work flows through.** While the rule is in force, cache checks, parses
  of local files, and local-file materializations continue unimpeded (A1). On a
  partially downloaded folder, every local row's tags keep landing during a cloud
  open.
- **C3. Same-path join.** A metadata request for the very file playback is
  downloading joins that materialization and waits for completion. Remote tag
  parsing instead uses ranged reads, reusing an active stream's available bytes
  where possible; it does not require a second whole-file download.
- **C4. The hold follows live claims.** Completing or cancelling one request cannot
  release another's foreground work. A stream remains foreground while downloading
  under a served reader; an abandoned stream is cancelled when it has neither
  waiters nor readers. Shells match play settlements by submission identity (A5)
  when starting deferred metadata work; they do not maintain a second transfer hold.
- **C5. Teardown drops the old work.** Close/replacement cancels the old sweep and
  releases its pending work as well as the old open. An old callback cannot release
  a new request's claim or start the discarded playlist's sweep.
- **C6. Preemption at assertion.** Asserting the rule stops a running scan transfer
  (the sweep's own in-flight download is cancelled/yielded, not waited out), and a
  yielded transfer spends no retry budget.
- **C7. The successor is foreground too.** A prefetch waiter or its still-downloading
  served stream enforces C1 just as playback does. Registering it preempts an
  existing metadata-only transfer; a scan cannot keep a successor waiting on its
  own download.

## D. Metadata loading

- **D1. Cache-first, never touching audio.** A row whose metadata is in the disk
  cache populates without reading the audio file — tags, duration, thumbnail. On a
  playlist of placeholders, every cached row lands at disk speed before a single
  download is chosen (the two-stage scan: stage 1 checks every row against the
  cache; only stage 2 may download).
- **D2. The cache key follows the audio file**: `<size>-<mtime_us>-<sha1(resolved path)>`,
  content never hashed; a failed stat yields no key. A changed size, mtime or path
  misses, but a rewrite preserving all three is undetectable. A sidecar image cannot
  move it. A remote install that changes the placeholder's stamp re-keys its tracks.
- **D3. Current track first.** The playing/loading track's tags and art are produced
  ahead of the sweep, at user-initiated priority, whether or not a sweep is running
  (mac header, iOS now-playing, Now Playing integration all read them).
- **D4. The sweep is deferred** until the picked track's open settles, with a **2 s**
  fallback so a wedged open cannot strand the playlist unpopulated forever. A parked
  restore with no play starts the sweep directly; C1 still gates dataless work.
- **D5. Sweep order follows the listener.** Among pending misses: **local files
  first** (their materialization is free), then non-deferred before deferred
  (failed-once sorts last), then neighborhood rank (**next, next+1, previous** in
  play order, including shuffle), then playlist index as the stable tie-break.
  The ordering is re-evaluated on every track change and every submit; selection is one O(n) pass
  (real playlists reach 10⁵ misses — no sorting, no per-entry pre-submission).
- **D6. One scan materialization at a time.** The sweep keeps at most one
  materialization in flight; pending misses stay app-owned, re-rankable records.
  Remote ranged parses bypass the materialization claim and enter the bounded parse
  stage directly. Pending misses must never be pre-submitted to a bounded queue.
  While C1 is in force the sweep submits no dataless record at all — even the
  file playback is downloading, which C3 could reuse; the
  current-track request covers that file, and one rule beats two (J4, deliberate).
- **D7. Retries are result-driven and bounded.** Per path, across lanes: a *yield*
  (suspended by C1) spends nothing; a *failure* spends one of **3 total attempts**
  and re-enters below untried rows; *admission exhaustion* spends one after a
  **0.25–2 s** escalating delay; *success clears the path's spend*. A path that
  exhausts its budget is dropped for the session (until a fresh playlist load).
- **D8. Duplicate rows resolve together.** One URL parses once; every row holding it
  (playlists legitimately repeat files) receives an independent copy — including
  rows that subscribed mid-parse. Waiting rows are held weakly: a discarded
  playlist is never pinned by an in-flight cloud parse.
- **D9. Failed parses produce filename-fallback metadata** — shown, never cached, and
  never permitted to overwrite a racing success. No row stays blank forever.
- **D10. Fresh playlist, fresh sweep.** Opening/replacing a playlist drops the old
  sweep outright: its pending records, its in-flight transfer, and its strong track
  references. Nothing from the old playlist keeps downloading or stays retained —
  the current-track lane's pending work included (J1).
- **D11. An entered TagLib read is uncancellable** and is allowed to finish; parses
  run at most **4** wide; a slow file stalls only its own worker.

## E. Artwork

- **E1. Embedded art beats folder art**; the folder cover (macOS only) fills in only
  after the file conclusively carries none. Folder answers are never persisted (D2).
- **E2. Extraction is tri-state**: art found / conclusively none / read failed.
  Only "conclusively none" opens the folder fallback; a failed read stays unknown
  and retries (at most **3 reads** per display pass, **2 s** per-row backoff).
- **E3. The 128 px thumbnail is for list rows** (mac playlist, iOS library/mini).
  Rows retain compact encoded bytes only; decoded pixels live in one shared
  **16k-entry** LRU that only the display path populates. A cache miss
  never decodes on a drawing path.
- **E4. The archived display rendition** (640 px mac / 1024 px iOS, beside the
  metadata entry, disk-resident, never retained per-row) is both big art surfaces'
  decode source: a track change or page swipe re-shows art without re-reading —
  or re-downloading — the song. Originals within the bound archive verbatim.
  A missing/corrupt rendition falls back to source extraction (one extra hop,
  never a stall, never marks the file's own art undecodable).
- **E5. Art requests are bounded and current-only**: at most 2 running + 5 pending
  across all rows; only source-file extraction may take a transfer (and then obeys
  C1); in-memory decodes never rematerialize. Demotion (row scrolled away) cancels
  parked work and fences running work so a stale decode cannot install.
- **E6. Background work never raises a permission panel.** No active sandbox grant
  means no probe and no cover read (macOS).

## F. Deliveries and staleness

- **F1. Every delivery lands on main**, names one track, and the receiver can — and
  must — drop it by comparing against the current state: waveform, BPM, key,
  metadata, and art deliveries all race track changes. Per-window results match
  `sourceKey` (CUE rows share a URL); file metadata matches by URL.
- **F2. Play settlements are matched by submission identity** (A5), decided at
  delivery time on main — never by track or URL.
- **F3. Metadata installs are atomic and revalidated**: installation and publication
  compare the exact installed object, so a queued stale delivery drops instead of
  double-publishing.

## G. Lifecycle edges (sequences that must stay true)

- **G1. Successful cloud play**: foreground registration (C1) → transfer with
  progress (B3) → usable handle → sound and successor prefetch (C7). Tags can land
  alongside this path (C3). The deferred sweep starts at settlement (D4), but its
  dataless work waits for all foreground claims to end (C4), including streams
  still downloading after sound starts; it then walks the neighborhood (D5).
- **G2. Timeout**: deadline fires (B3) → stopped state + error string (B4) → rule
  lifts once no foreground claim remains → sweep's dataless work resumes; the failed
  pick is an ordinary candidate (B4), and its metadata failure spends budget normally (D7).
- **G3. Rapid next**: each superseded open is cancelled before the next begins;
  stale settlements and their prefetch acknowledgements drop. Old work cannot lift
  the hold belonging to a new claim (C4), and unused streams release their lanes.
- **G4. Same-row replay**: same track, same URL, new submission identity; every
  stale-settlement rule in F2/C4 still holds (A5 is the reason this is hard).
- **G5. Close** (macOS): no transport callbacks (B9); old background work and opens
  are cancelled (C5); the next folder's sweep starts clean.
- **G6. Playlist replacement**: D10, plus the same "old transfers must not compete
  with the new pick" rule as G5. iOS has explicit Clear Playlist and replacement
  paths; backgrounding alone does not close the playlist or stop background audio.
  A restored folder that lands parked starts its sweep without a play settlement.

## H. Policy numbers (current production values, all reviewable)

| Policy | Value | Where |
| --- | --- | --- |
| Slow-open indicator fallback (dataless classification is immediate) | 0.5 s | `AudioPlayer.m` |
| Open no-progress deadline | 60 s | `AudioFileOpenTimeoutMath.h` |
| Open progress-silence deadline | 60 s past last movement | `AudioFileOpenTimeoutMath.h` |
| Foreground transfers (running / pending / grace) | 3 / 1 / 5 s | `AudioLoadingConfiguration.m` |
| Background transfers (running / pending / grace) | 1 / 6 / 10 s | same |
| Initial classification probes (running / pending / grace) | 8 / 16 / 5 s | `AudioFileMaterializationCoordinator.m` |
| Live handle runs (shared production coordinator) | 6 — immediate refusal; no pending/grace/configuration | `AudioFileMaterializationCoordinator.m` |
| Prefetch depth | 1 | `AudioLoadingConfiguration.m` |
| Metadata attempts per path (total) | 3 | same (`metadataRetryCount` 2) |
| Admission-exhausted retry delay | 0.25 s → 2 s escalating | `MetadataRetryRules.h` |
| Parse concurrency | 4 | `AudioLoadingConfiguration.m` |
| Sweep deferral fallback | 2 s | both shells |
| Neighborhood offsets | +1, +2, −1 | `Playlist.neighborhoodTracks` |
| Art requests (running / pending) | 2 / 5 | `ArtworkLoadRegistry` |
| Art admission backoff | 0.1–1 s, 5 steps | same |
| Extraction retries / backoff | 3 reads / 2 s | `AudioTrackArtwork.m` |
| Thumbnail LRU | 16k entries | `AudioTrackArtwork.m` |
| Thumbnail size | 128 px | — |
| Display rendition bound | 640 px mac / 1024 px iOS | `PlatformImage.h` |
| Full-art decode bound | 1024 px | — |
| Metadata/waveform disk budget | 1 GiB per cache, 6-month age limit | `PINCache+VibeAudioCache.m` |

## I. Platform differences

- **I1.** Folder art, key analysis, pitch-fader varispeed and the app's volume stage
  are macOS-only, each switched off at one place (root `AGENTS.md`). BPM detection
  and DJ FX run on both platforms; iOS uses system volume.
- **I2.** File > Close is macOS-only; iOS tears down via Clear Playlist and playlist
  replacement. Background audio keeps its session when the app leaves the foreground.
- **I3.** Display rendition is 640 px on mac, 1024 px on iOS (E4). The iOS
  now-playing page deliberately draws no thumbnail (full/rendition art only).
- **I4.** Metadata/waveform cache size and clear controls are macOS-only. iOS has
  separate Dropbox download storage controls; those files are not these caches.
- **I5.** Analysis rides the waveform decode pass: BPM on both platforms, key on
  macOS only. Tags take precedence through `AudioTrack.bpm` and `.key`; a CUE row
  uses its window's analysis instead of the containing file's tags.

## J. Open items and decisions

- **J1. Priority-lane retention (RESOLVED).** Abandoned playlists formerly retained
  current-track requests. Replacement now cancels the scan and priority work (D10).
- **J2. Unguarded error-path release (RESOLVED).** Late generic errors formerly
  released a shell-maintained foreground hold. The coordinator now derives C1 from
  live claims; a shell error cannot release another open's claim. Play-path
  settlements also check submission identity before reaching the shell (F2).
- **J3. iOS hold leak on folder replacement (RESOLVED).** A parked restore formerly
  left a shell-maintained hold asserted with no play to release it. Replacement
  cancels the old work, the coordinator derives the hold, and a parked restore
  starts metadata directly (G6).
- **J4. Sweep-vs-hold pre-check asymmetry (DECIDED).** The sweep refuses to submit
  any dataless record while C1 is in force — even the very file playback is
  downloading, which C3 could reuse; the current-track request submits
  and joins. **Resolution:** keep the sweep conservative — one rule beats two,
  and the current-track request covers the playing file. Now documented in D6.
- **J5. Abandoned-pick chasing (DECIDED, recorded).** An earlier design re-ranked a
  still-moving abandoned pick to the front of the sweep. Retired: under
  extend-on-movement deadlines (B3) any abandoned transfer has been silent for its
  full 60 s, so there is no "still moving" case; scenario S12b pins not-chased.
- **J6. Artwork "desired queue" (REMOVED).** A third parking layer (7-deep) above
  the art scheduler's own pending queue, added for uncancellable stale reads
  crowding out newly visible iOS pages — but only ~3 art surfaces are ever
  simultaneously wanted. **Resolution:** deleted during the simplification. The
  simulator pager check against a stuck fake provider was run at deletion; the
  intended on-device iPhone check is still not recorded as run.
- **J7. Stacked open admission (DECIDED, superseded by J8).** Handle opens were
  bounded by a second scheduler whose limits duplicated the transfer lane's.
  The original resolution made one lane slot span transfer and handle open, and
  resized the foreground lane 2 → 3. That spanning lifetime coupled two different
  resources and is retired by J8.
- **J8. Transfer/open lifetime separation (defect → DECIDED; supersedes J7).** A
  never-returning prefetch or gapless open (then an `AVAudioFile` call; the gapless
  open no longer exists) carried the sole background transfer slot forever, permanently starving dataless metadata and prefetch work.
  **Resolution:** every transfer slot ends when its stage-1 materialization settles.
  Streaming now overlaps stage 2 with a still-running transfer; the slot remains
  attached to that transfer until completion or failure, never to the handle-open
  lifetime. Independently, at most 6 distinct
  `(purpose, standardized path)` handle runs may be live per coordinator. Production
  uses the shared coordinator, making that ceiling process-wide in the app. An existing
  key rebinds before the ceiling is checked; a new seventh run is refused immediately
  with the existing admission-exhausted result before materialization starts. The
  ceiling is the private `_handleRuns.count`, conservatively derived from one player's
  two queue-confined open sources (playback and prefetch) plus room for four stranded
  calls in aggregate. It is purpose-blind: prefetch can consume all six and cause a
  later playback key to be refused. That refusal contributes to the existing
  `requestsAdmissionExhausted` outcome counter; there is no queue, pending allowance,
  grace, configuration value, duplicate counter, or watchdog. A run remains a member
  through an uncancellable open and any rebound restart until it actually finishes.
  Another player or open source, or a multi-flight source, requires re-deriving the
  ceiling and its tests. Foreground and background transfer limits remain 3 and 1.
- **J9. Running-stage materialization deadline (defect → OPEN).** Once stage 1 is
  `Running`, pending admission expiry no longer reaches it. Local reads now hold no
  transfer lane, so a stalled SMB, NFS or disk read strands only its worker. A
  dataless provider operation or a delayed classification refresh can still hold
  its lane indefinitely; metadata and artwork callers have no deadline that
  guarantees cancellation. The remaining fix needs explicit provider, caller-deadline
  and retry policy; see the
  [bug record](https://github.com/cmicali/vibe/issues/96).
- **J10. Deferred readability items (OPEN, no behavior at stake).** Two were set
  aside by the file-load refactor: `AudioTrackArtwork`'s extraction-state
  booleans could be one enum, but `_embeddedExtractionInFlight` survived
  demotion while its siblings reset, so the mapping needs its own state-space
  pass first; and the artwork retry ladder is unlike the coordinator, which
  settles rather than retries — K4 permits leaving it.

## K. Non-goals — what this spec deliberately does not constrain

- **K1.** How many coordinator objects exist, or where the C1 rule lives (hold
  object, refcount, role preemption — mechanism is free).
- **K2.** Whether the current-track lane is a separate lane or a rank-0 record.
- **K3.** Which queue any decision runs on, so long as F1's main-thread delivery
  and B1's non-blocking local path hold.
- **K4.** The internal shape of retry bookkeeping, so long as D7's observable
  budgets hold.
- **K5.** Debug/stress instrumentation (fake cloud, trace events, scenario suite) —
  it evolves with the implementation. The acceptance test for C, D, and G is
  the whole `cloud-scenarios.py` registry passing (the `vibe-stress` skill
  names the clean report), not a fixed list of scenarios.
