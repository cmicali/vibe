# File-load refactor: implementation plan

Working plan for simplifying the file-load/metadata subsystem against
`docs/file-loading-spec.md` (the authority — every phase must keep all of A–I,
and delivers the J resolutions it names). Each phase is a separate commit (or
few), leaves the app shippable, and is accepted by `make test` + the cloud
scenario suite + a stress pass before the next begins.

## Review outcomes (what changed from the audit's draft plan)

1. **Phase order flipped: lane unification now comes first.** The audit proposed
   internalizing the C1 rule first. But the priority lane's park/retry machinery
   is *driven by the hold-release edge* — internalizing the rule first would
   mean feeding a synthetic release edge to machinery scheduled for deletion one
   phase later. Unifying the lanes first makes every metadata retry ride the
   sweep's record list, after which the rule needs no release edge at all
   (records re-pick on the sweep's existing bounded 1 s clock).
2. **The rule's internalized form is pull + preemption, not a refcount.**
   (a) The sweep asks the coordinator "is a foreground transfer active?" before
   submitting a dataless record (D6/J4 — one synchronous read, no pushed state).
   (b) The coordinator yields running/pending metadata-dataless claims whenever
   a *foreground claim registers* (C6), and prefetch registration preempts the
   same way — which is what makes C7 hold with no ordering handshake: even if
   the sweep's clock beats `prefetchTrack:` to the lane by a millisecond, the
   prefetch's registration yields it back out.
3. **One noted deviation from C1's letter** (flagged for review, not silently
   taken): suspension becomes effective at the playback *claim's registration*,
   which trails play *submission* by ~1 ms of queue hops. In that window the
   sweep's clock could in principle start one transfer; the foreground
   registration immediately yields it (no budget spent, C6/D7). No scenario or
   oracle can observe the difference — S4a (rapid plays, zero contention) is the
   acceptance test. G3's "one continuous suspension" is satisfied observably:
   the 1 s re-pick clock means the sweep cannot flap between rapid nexts.
4. **`loadMetadataNow:` before any sweep exists creates a single-track sweep.**
   D3 requires the current track's tags even when the deferred sweep hasn't
   started and the first attempt fails; the retry must live in a record, and
   records live in loaders. So a pre-sweep `loadMetadataNow:` builds a normal
   loader over `@[track]`; the real playlist sweep later replaces it wholesale
   (D10), and the row re-resolves from cache. No standing mini-lane state.
5. **Thumbnail LRU (user spec edit, E3/H): 16k entries.** Entries are
   fixed-size (~64 KiB decoded), so a byte cap would just silently redefine
   the count (512 MiB ≡ 8k entries) — implemented as 16,384 entries verbatim
   instead, plus an iOS memory-warning flush: the explicit LRU has no
   NSCache-style pressure eviction, irrelevant at 8 MiB and not at the new
   ~1 GiB worst case (reached only by displaying 16k distinct rows' thumbnails
   in one session). **Flagged:** edit H if a smaller count is wanted.

## Phase 0 — quick wins (immediate)

- Thumbnail LRU 128/8 MiB → 16,384 entries / 512 MiB backstop
  (`AudioTrackArtwork.m`). Spec: E3, H.

## Phase 1 — one lane: the current track becomes a priority record

**Deletes** the priority lane as a construct: its parked set, its
`dispatch_after` retry loops, the retirement machinery (`_retiring`,
`retireWithCompletion:`, `_retiredPriorityLoaders`, both hold fan-out loops),
the second callback queue, the `VibeMetadataLane` enum, the dead
`cacheCheckEntry:` priority arm, and the three priority-specific rule
functions. ~360 lines, 8 fields. Delivers **J1** structurally (D10 covers
everything by construction).

**Mechanism.**
- `MetadataScanEntry` gains `priority` (and keeps `deferred`, `local`,
  a `yieldedWhileHeld` mark — see below). Priority records:
  - are picked by their own single in-flight slot, concurrent with the scan's
    slot (D6's "one scan transfer" is unchanged; D3's "ahead of the sweep" is
    the second slot, not a queue jump);
  - bypass the stage-1 barrier (D1's barrier still gates scan picks);
  - submit while C1 is in force (they join or pass through per C3/A1 — the
    coordinator decides, as today);
  - parse at `NSQualityOfServiceUserInitiated` / high queue priority on the
    shared 4-wide parse queue (D3). Trade noted: a priority parse can wait for
    one slot behind wedged scan parses; previously it had its own queue. D11
    bounds the damage to one slot's wait.
- Yield handling becomes record edges (replacing park/clear/retry actions):
  yielded while held → record stays pending, marked, re-picked at hold
  release; yielded and the file is local → re-pick now; yielded and still
  dataless with the hold down → **demote**: clear the priority bit, the row
  becomes an ordinary sweep candidate at its rank (same semantics d75d33b
  landed, now expressed on one record).
- Failure/AdmissionExhausted spend the shared per-path budget (D7) through the
  *same* completion path as scan records — the duplicated priority predicates
  in `MetadataRetryRules.h` are deleted; the yield-edge decision becomes one
  new tested rule function.
- `loadMetadataNow:` = ensure a record exists for the track (creating a
  single-track loader if none — review outcome 4), set its priority bit, kick.
- `AudioTrackMetadataCache` drops `_priorityLoader` entirely; configuration
  changes simply apply to the next loader.
- `dump_cloud_health.priorityLane` reshapes to record counts (pending /
  in-flight / yielded / deferred); the stress harness gains
  `priorityLane.pending` as a growth oracle (the counter whose absence hid the
  37-entry strand).

**Spec coverage:** D3, D6, D7, D10/J1, C3, G1–G6 unchanged externally.
**Acceptance:** `make test` (rules tests reshaped), scenarios S1–S12 all green,
a `--profile cloud` stress run, plus new **S14 "the priority lane drains"**:
play storm + playlist replacement on dataless placeholders → priority records
drain to zero and the priority request rate stops growing after settle.

## Phase 2 — the C1 rule moves inside the coordinator

**Deletes** the hold as an exported concept: coordinator hold token/count and
`acquireMetadataHold`, the cache's flag + `setBackgroundMaterializationHeld:`,
both shells' `_foregroundHoldGeneration` + all assert/release sites,
`willSubmitPlayForTrack:` (both directions), `ForegroundContentHoldRules.h`,
`prefetchTrack:whenClaimed:` + the acknowledgement state machine
(`AudioPrefetchRules.h`'s ack family, ~130 lines in `+Gapless.m`), and the
open coordinator's `registered:`/`whenClaimedOnQueue:` claim-observer
machinery. ~550–650 lines. Delivers **J2 and J3 by construction**: release is
internal to claim settlement (which knows its identity — C4 total on every
edge), and there is nothing left for an iOS folder replacement to leak.

**Mechanism.**
- Coordinator derives `foregroundTransferActive` from its own claim table
  (any live Playback/Prefetch-role claim with an unsettled operation) and
  exposes it as one synchronous query.
- Admission: metadata-dataless claims yield while foreground is active (the
  existing three hold checks become one predicate swap); foreground claim
  registration edge-triggers the yield sweep (review outcome 2b).
- The sweep's submit gate (D6/J4) reads the query instead of a pushed flag;
  yielded/gated records re-pick on the existing 1 s clock, which also replaces
  the hold-release kick from phase 1.
- The shells keep only what is genuinely theirs: playlist + cursor
  (`setNeighborhoodAroundIndex:`), the deferred-sweep start (D4's edges are
  `didStartPlaying:`/error/2 s — unchanged), and `loadMetadataNow:` calls.
- Suspension now also spans the successor prefetch's own download (foreground
  claim live). Behavioral delta: scan misses yield-and-wait instead of parking
  in the background pending queue behind the prefetch — they no longer burn
  admission grace/budget against a transfer they cannot beat (D7-friendly;
  today they can AdmissionExhaust behind a slow prefetch).

**Spec coverage:** C1–C7, G1–G6, J2, J3.
**Acceptance:** scenarios S1–S12 + S4-family especially; **new S15**: inject a
stale no-URL error during a fresh play's submission window (needs a small debug
verb) → suspension survives (J2). J3: iOS simulator check — open folder A
parked, open folder B, sweep runs. Stress `--profile cloud` full run.

## Phase 3 — one coordinator: transfer + open as a two-stage claim

**Merges** `AudioFileOpenCoordinator` into `AudioFileMaterializationCoordinator`:
one claim per standardized path, stage 1 = transfer (roles/lanes as today),
stage 2 = purpose-keyed `AVAudioFile` opens (playback/prefetch/gapless keep
independent handles, A3); gapless enters at stage 2 only (B6). Deletes the
second state queue, token class, claim table, generation, and the
result-translation layer (~250–300 lines; 6 of the 15 queue hops per open).
Delivers **J7**: the open-scheduler stage bound is absorbed into the claim —
one slot spans transfer + open, foreground lane resized 2 → 3, all bounds in
`AudioLoadingConfiguration` (H table updated).

**Preserved seams:** the injected `fileOpener` (host-less tests), operation
factory, dataless probe, clock. `CloudFileMaterializer`,
`DownloadProgressMonitor`, `PlaybackRequestCoordinator` untouched.
**Spec coverage:** A2, A3, B5, B6, B8/J7, C4.
**Acceptance:** merged unit suite (open + materialization tests, ~1,700 lines
to converge), S1–S12, stress cloud + loading profiles.

## Phase 4 — artwork cleanup

- Delete the desired queue (third parking layer) per **J6** — gated on an
  on-device iOS pager check against a stuck fake provider before landing.
- Collapse the six embedded-extraction booleans into one 5-state enum
  (readability only; 36 tests pin behavior).
- Fold the artwork admission-retry ladder into the coordinator's retry intent
  if phase 3 makes it natural; otherwise leave (K4 permits either).

**Spec coverage:** E2, E5, J6.
**Acceptance:** `AudioTrackArtworkLoadTests`, artwork stress profile, the
on-device pager check.

## Cross-cutting

- **Docs ride each phase**: `Audio/CLAUDE.md`, `Audio/Metadata/CLAUDE.md`, and
  the root guarantees section are updated in the same commit that changes the
  behavior they describe; the spec's H table updates when J7 lands.
- **Instrumentation follows** (K5): `dump_cloud_health` keys, stress oracles,
  and scenario helpers evolve with each phase; S14/S15 are added where named.
- **Rollback**: phases are independent commits; any phase can be reverted
  without unwinding the ones before it.

## Progress

- [ ] Phase 0 — thumbnail LRU
- [ ] Phase 1 — one lane
- [ ] Phase 2 — rule internalized
- [ ] Phase 3 — one coordinator
- [ ] Phase 4 — artwork
