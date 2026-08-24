# File loading and metadata: behavioral spec

This documents what the file-load / metadata subsystem **does today**, as observable
behavior, so the behavior can be reviewed and agreed on before the implementation is
simplified. Every item is a requirement the new implementation must keep unless it is
struck or edited here. Items marked **OPEN** are places where current behavior is
inconsistent, buggy, or a judgment call — each states the current behavior and a
proposed resolution; edit or strike as needed.

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
  when it is a file-provider placeholder whose read would trigger a provider transfer
  (`NSURLUtil.isDatalessFile:`). Every rule that bounds or suspends downloads binds
  *transfers*; a local file never starts one and is exempt from all of them.
- **A2. Materialization.** Making a standardized path local (a provider download, or a
  no-op for a local file). At most **one materialization operation exists per
  standardized path** at any time; every interested party joins it rather than starting
  a second transfer. This is the single most load-bearing rule in the subsystem.
- **A3. Open.** Producing a usable `AVAudioFile` handle for a purpose (playback,
  prefetch, gapless). Purposes hold **independent handles** for the same path —
  `AVAudioFile` has one stateful read position, so handles are never shared.
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
- **B2.** Playing a dataless file downloads it (one transfer, A2) and then opens it.
  The UI shows a Loading state if the open takes longer than **0.5 s**
  (`kSlowOpenIndicatorDelaySeconds`). Play/pause during Loading toggles whether the
  open lands playing or parked; seek during Loading retargets the start position.
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
- **B6. Gapless.** With the crossfade at minimum and formats matching, the successor
  is also scheduled as a queued segment on the current node from a **private second
  handle** (never the parked instance a play would consume). Gapless bypasses
  materialization: the parked file already proved the bytes local.
- **B7. Successor prefetch is where "On track end" is enforced.** Every prefetch site
  asks one function for the track to park; under Pause-at-track-end it answers nil,
  and with nothing parked no splice can advance the audio by itself.
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

- **C1. The rule.** From play submission until that play's open settles (success,
  error, or supersession), **no background work may start a provider transfer.**
  The scarce resource on a provider folder is the transfer; the user's open gets it.
- **C2. Local work flows through.** While the rule is in force, cache checks, parses
  of local files, and local-file materializations continue unimpeded (A1). On a
  partially downloaded folder, every local row's tags keep landing during a cloud
  open.
- **C3. Same-path join.** A metadata request for the very file playback is
  downloading joins that transfer (A2) and parses when it lands — the playing
  track's tags must not wait for the successor handshake, and the file must never
  download twice.
- **C4. Release is exactly-once per submission.** The rule lifts when the open
  settles — and only the *current* submission's settlement may lift it. A stale
  settlement (superseded play, replayed row, late error) must not lift a rule a
  newer play has re-asserted (A5). Under rapid next-next-next, N submissions
  produce one continuous suspension lifted once, by the last settlement.
- **C5. Release order on teardown.** When a Close/replacement tears down both the
  open and the sweep, background work must not start transfers into the dying
  open's window: pending background work is dropped **before** the rule lifts.
- **C6. Preemption at assertion.** Asserting the rule stops a running scan transfer
  (the sweep's own in-flight download is cancelled/yielded, not waited out), and a
  yielded transfer spends no retry budget.
- **C7. The successor outranks the resumed sweep.** When the rule lifts after a
  successful play, the successor prefetch's transfer must be admitted ahead of the
  resumed scan (the prefetch, being foreground, preempts and suspends competing
  metadata work by the same C1 mechanism); the sweep must not steal the lane the
  moment it reopens.

## D. Metadata loading

- **D1. Cache-first, never touching audio.** A row whose metadata is in the disk
  cache populates without reading the audio file — tags, duration, thumbnail. On a
  playlist of placeholders, every cached row lands at disk speed before a single
  download is chosen (the two-stage scan: stage 1 checks every row against the
  cache; only stage 2 may download).
- **D2. The cache key follows the audio file**: `<size>-<mtime_us>-<sha1(path)>`,
  content never hashed. A rewrite or move misses; a sidecar image cannot move it.
- **D3. Current track first.** The playing/loading track's tags and art are produced
  ahead of the sweep, at user-initiated priority, whether or not a sweep is running
  (mac header, iOS now-playing, Now Playing integration all read them).
- **D4. The sweep is deferred** until the picked track's open settles, with a **2 s**
  fallback so a wedged open cannot strand the playlist unpopulated forever.
- **D5. Sweep order follows the listener.** Among pending misses: **local files
  first** (their materialization is free), then non-deferred before deferred
  (failed-once sorts last), then neighborhood rank (**next, next+1, previous** of
  the current row), then playlist index as the stable tie-break. The ordering is
  re-evaluated on every track change and every submit; selection is one O(n) pass
  (real playlists reach 10⁵ misses — no sorting, no per-entry pre-submission).
- **D6. One scan transfer at a time.** The sweep keeps at most one materialization
  in flight; everything else stays an app-owned, re-rankable record. (Pending
  records must never be pre-submitted to a bounded queue — see H for why.)
  While C1 is in force the sweep submits no dataless record at all — even the
  file playback is downloading, which C3 would let join for free; the
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
  **16k-entry ** LRU that only the display path populates. A cache miss
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
  metadata, and art deliveries all race track changes.
- **F2. Play settlements are matched by submission identity** (A5), decided at
  delivery time on main — never by track or URL.
- **F3. Metadata installs are atomic and revalidated**: installation and publication
  compare the exact installed object, so a queued stale delivery drops instead of
  double-publishing.

## G. Lifecycle edges (sequences that must stay true)

- **G1. Successful cloud play**: rule asserts at submission (C1) → transfer with
  progress (B3) → current track's tags join/land (C3) → sound → successor prefetch
  admitted (C7) → rule lifts once (C4) → deferred sweep starts (D4) → sweep walks
  the neighborhood (D5).
- **G2. Timeout**: deadline fires (B3) → stopped state + error string (B4) → rule
  lifts once → sweep starts; the failed pick is an ordinary candidate (B4), and its
  metadata failure spends budget normally (D7).
- **G3. Rapid next**: N submissions, one continuous suspension (C4); each
  superseded open is cancelled before the next begins; stale settlements and their
  prefetch acknowledgements all drop; exactly one release at the end.
- **G4. Same-row replay**: same track, same URL, new submission identity; every
  stale-settlement rule in F2/C4 still holds (A5 is the reason this is hard).
- **G5. Close** (macOS): no callbacks (B9); pending background work dropped before
  the rule lifts (C5); nothing left held — the next folder's sweep starts clean.
- **G6. Playlist replacement**: D10, plus the same "old transfers must not compete
  with the new pick" ordering as G5. On iOS, replacement is also the Close edge:
  any in-force C1 suspension lifts here — a folder that lands parked submits no
  play, so no settlement would ever lift it otherwise (J3).

## H. Policy numbers (current production values, all reviewable)

| Policy | Value | Where |
| --- | --- | --- |
| Slow-open indicator threshold | 0.5 s | `AudioPlayer.m:72` |
| Open no-progress deadline | 60 s | `AudioFileOpenTimeoutMath.h:15` |
| Open progress-silence deadline | 60 s past last movement | `AudioFileOpenTimeoutMath.h:16` |
| Foreground transfers (running / pending / grace) | 3 / 1 / 5 s | `AudioLoadingConfiguration.m` |
| Background transfers (running / pending / grace) | 1 / 6 / 10 s | same |
| Initial classification probes (running / pending / grace) | 8 / 16 / 5 s | `AudioFileMaterializationCoordinator.m` |
| Live handle runs (shared production coordinator) | 6 — immediate refusal; no pending/grace/configuration | `AudioFileMaterializationCoordinator.m` |
| Prefetch depth | 1 | same |
| Metadata attempts per path (total) | 3 | same (`metadataRetryCount` 2) |
| Admission-exhausted retry delay | 0.25 s → 2 s escalating | `MetadataRetryRules.h` |
| Parse concurrency | 4 | `AudioLoadingConfiguration.m` |
| Sweep deferral fallback | 2 s | both shells |
| Neighborhood offsets | +1, +2, −1 | `AudioTrackMetadataCache.m:223` |
| Art requests (running / pending) | 2 / 5 | `ArtworkLoadRegistry` |
| Art admission backoff | 0.1–1 s, 5 steps | same |
| Extraction retries / backoff | 3 reads / 2 s | `AudioTrackArtwork.m` |
| Thumbnail LRU | 16k entries | `AudioTrackArtwork.m` |
| Thumbnail size | 128 px | — |
| Display rendition bound | 640 px mac / 1024 px iOS | `PlatformImage.h` |
| Full-art decode bound | 1024 px | — |
| Metadata/waveform disk budget | 512 MiB | `PINCache+VibeAudioCache.m` |

## I. Platform differences

- **I1.** Folder art, BPM/key analysis, and the DJ FX graph are macOS-only, each
  switched off at one place (root `CLAUDE.md`); iOS reads no preference it cannot
  act on.
- **I2.** File > Close is macOS-only; iOS tears down via playlist replacement and
  backgrounding, and every G5 guarantee must hold on those edges instead (see J3).
- **I3.** Display rendition is 640 px on mac, 1024 px on iOS (E4). The iOS
  now-playing page deliberately draws no thumbnail (full/rendition art only).
- **I4.** Settings surface (cache size/clear) is macOS-only.
- **I5.** Analysis (BPM/key) rides the waveform decode pass and is macOS-only; on
  iOS the tagged value is the whole answer.

## J. Open items and decisions

- **J1. Priority-lane retention (defect → DECIDED).** Replayed/replaced playlists
  accumulate per-track state in the current-track lane; entries from abandoned
  playlists keep downloading until their budget runs out. **Resolution:** D10
  applies to the current-track lane too — replacement drops its pending work.
  (Structural in the simplification: the current track becomes a rank-0 record in
  the one sweep, so replacement drops everything by construction.)
- **J2. Unguarded error-path release (defect → DECIDED).** The timeout/error path
  lifts the C1 rule without checking submission identity; a late generic error
  (device loss, seek failure — errors that carry no URL) landing between a new
  play's submission and its Loading state can lift the rule the new play just
  asserted. iOS has no stopped-state guard at all on this path. **Resolution:**
  C4 binds *every* release edge, not just the acknowledgement edge — free in the
  simplified shape, where release is internal to settlement.
- **J3. iOS hold leak on folder replacement (defect → DECIDED).** Opening a folder
  that lands parked (the `restored` branch — no play submitted) never lifts a
  previously asserted C1 rule, suspending the new folder's sweep indefinitely.
  **Resolution:** G6 lifts the rule on iOS playlist replacement (now normative
  in G6).
- **J4. Sweep-vs-hold pre-check asymmetry (DECIDED).** The sweep refuses to submit
  any dataless record while C1 is in force — even the very file playback is
  downloading, which C3 would let join for free; the current-track lane submits
  and joins. **Resolution:** keep the sweep conservative — one rule beats two,
  and the current-track request covers the playing file. Now documented in D6.
- **J5. Abandoned-pick chasing (DECIDED, recorded).** An earlier design re-ranked a
  still-moving abandoned pick to the front of the sweep. Retired: under
  extend-on-movement deadlines (B3) any abandoned transfer has been silent for its
  full 60 s, so there is no "still moving" case; scenario S12b pins not-chased.
- **J6. Artwork "desired queue" (DECIDED).** A third parking layer (7-deep) above
  the art scheduler's own pending queue, added for uncancellable stale reads
  crowding out newly visible iOS pages — but only ~3 art surfaces are ever
  simultaneously wanted. **Resolution:** delete during the simplification,
  gated on an on-device iOS pager check against a stuck fake provider (the one
  failure mode with no host-less test).
- **J7. Stacked open admission (DECIDED, superseded by J8).** Handle opens were
  bounded by a second scheduler whose limits duplicated the transfer lane's.
  The original resolution made one lane slot span transfer and handle open, and
  resized the foreground lane 2 → 3. That spanning lifetime coupled two different
  resources and is retired by J8.
- **J8. Transfer/open lifetime separation (defect → DECIDED; supersedes J7).** A
  never-returning prefetch or gapless `AVAudioFile` call carried the sole background
  transfer slot forever, permanently starving dataless metadata and prefetch work.
  **Resolution:** every transfer slot ends when its stage-1 materialization settles;
  no slot is carried into stage 2. Independently, at most 6 distinct
  `(purpose, standardized path)` handle runs may be live per coordinator. Production
  uses the shared coordinator, making that ceiling process-wide in the app. An existing
  key rebinds before the ceiling is checked; a new seventh run is refused immediately
  with the existing admission-exhausted result before materialization starts. The
  ceiling is the private `_handleRuns.count`, conservatively derived from one player's
  three queue-confined open sources plus room for three stranded calls in aggregate.
  It is purpose-blind: prefetch or gapless can consume all six and cause a later
  playback key to be refused. That refusal contributes to the existing
  `requestsAdmissionExhausted` outcome counter; there is no queue, pending allowance,
  grace, configuration value, duplicate counter, or watchdog. A run remains a member
  through an uncancellable open and any rebound restart until it actually finishes.
  Another player or open source, or a multi-flight source, requires re-deriving the
  ceiling and its tests. Foreground and background transfer limits remain 3 and 1.
- **J9. Running-stage materialization deadline (defect → OPEN).** Once stage 1 is
  `Running`, pending admission expiry no longer reaches it. A coordinated read stalled
  on SMB, NFS, or a sleeping external disk can hold its transfer lane indefinitely;
  metadata and artwork callers have no deadline that guarantees cancellation. A fix
  needs explicit slow-volume, caller-deadline, and retry policy; see the
  [bug record](bugs/no-deadline-on-a-running-materialization.md).

## K. Non-goals — what this spec deliberately does not constrain

- **K1.** How many coordinator objects exist, or where the C1 rule lives (hold
  object, refcount, role preemption — mechanism is free).
- **K2.** Whether the current-track lane is a separate lane or a rank-0 record.
- **K3.** Which queue any decision runs on, so long as F1's main-thread delivery
  and B1's non-blocking local path hold.
- **K4.** The internal shape of retry bookkeeping, so long as D7's observable
  budgets hold.
- **K5.** Debug/stress instrumentation (fake cloud, trace events, scenario suite) —
  it evolves with the implementation, though the scenarios named in this spec
  (S1–S12) remain the acceptance tests for C, D, and G.
