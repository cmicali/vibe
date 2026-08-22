# Deferred understandability changes

This document is the implementation backlog for the selected Section C audit
findings, plus the items found while revalidating them.

Revalidated against `162cf0c` (2026-08-22), **implemented 2026-08-22**. Line
numbers, quoted comment text and symbol names below are as of that
revalidation, and drifted as soon as the first item landed; every item was
located by comment text or symbol name rather than by line. The original
C-identifiers are retained so each item could be selected independently; C6 and
C9 were not selected for this backlog and are absent. C11 and C12 were found
while revalidating.

Scope is the macOS app and the shared code it consumes, plus the subsystem
documentation that describes it.

## What landed

One commit per item, so any of them bisects alone.

| Item | Priority | Commit |
| --- | --- | --- |
| C11 — retired materialization hold in iOS docs | Medium | `a912933` |
| C12 — stale symbol names in subsystem docs | Low | `cbb5155` |
| C2 — historical narratives | Low | `c670e49` |
| C5 — "lock-free" getters | Low | `6822158` |
| C8 — codec/FX alpha comments | Low | `63a5787` |
| C7 — playlist fallback extensions | Low | `c376d70` |
| C3 — menu validation | Medium | `8ac4664` |
| C4 — playback-state writer model | Medium | `d7fa14c` |
| C1 — `playOnQueue:` phases | Medium | `7c514b4` |
| C10 — About mail link | Low | `c6c1925`, `b99d0fa` |

## Where it landed differently from the plan

- **C10's preferred route does not work, and the item's own fallback is the
  only one that does.** A standard attributed AppKit link in a tightly sized
  field cannot satisfy "Full Keyboard Access can focus it, and Return/Space
  opens the mail URL": AppKit gives a link inside static text no key-view
  participation. `VibeLinkLabel` was therefore extracted and given a complete
  accessible link. Recorded so nobody retries the standard control.
- **C10 needed a follow-up.** The About window is reused
  (`releasedWhenClosed = NO`), so a focused link stayed first responder across a
  close and reopened with its focus ring already drawn. `windowWillClose:` now
  clears first responder. Found by hand, not by the tests — see below.
- **C12's first name was deleted rather than corrected.** `_pendingStartPaused`
  named a private ivar the sentence did not need, so the parenthetical went
  instead of being renamed to `_loadingStartPaused`. The optional doc-symbol
  checker was weighed and not adopted: its allowlist would have grown faster
  than the findings.
- **C4 has two helpers, not one.** `finishPlaybackOnQueue` writes `_state` and
  `_node` in a single lock acquisition; folding it into the plain unpublish
  would have opened a window where the two disagree, which is a behavior change
  made to reduce helper count.
- **C7's alternates are ordered lossless-first**, which the item did not
  specify. The order decides which replacement wins when a folder holds several,
  so it needed a stated reason rather than an inherited accident; it also keeps
  the existing order-pinning test green.
- **Three items had one more instance than their evidence listed**, each fixed
  with the rest: C5's `AudioPlayer.h` `(State)` preamble ("None of these
  blocks"), C8's stale "unlike the BPM label below" (the BPM label is also at
  alpha 1), and C2's `isDatalessFile:` cost note, kept without its benchmark
  numbers.

## What was not verified

- **`make build-ios` and the VibeiOS half of `make analyze` never ran**: no iOS
  simulator runtime is installed on the machine this was implemented on (the
  iOS 26.5 SDK is present, the platform is not), so
  `generic/platform=iOS Simulator` matches no destination. The shared-source
  items — C2, C5, C7, C4, C1 — are unverified against the iOS target.
- **C3's `show_in_finder`** lives only on the window context menu, and opening a
  real context menu blocks the debug channel. Its code is unchanged apart from
  being moved, and its domain is verified through `menu_play` and `menu_close`.
- **C10's live keyboard and VoiceOver behavior.** Injected input reaches the
  main player window, not the About window, and the app would not hold
  activation, so Tab-into-About could not be scripted. The unit tests pin the
  contract those two consume; the reopen bug above is what that gap cost.

## C1 — `playOnQueue:` hides an ordering-sensitive state transition inside one large method

**Priority:** Medium

### Current issue

`AudioPlayer`'s queue-confined play transition is one 179-line method. Its
length is not merely cosmetic: it interleaves several independently meaningful
phases whose order is part of playback correctness:

- terminally retiring the superseded playback context's prefetch request;
- rebinding a repeated play to an existing Loading request;
- preempting fades and retiring a possible gapless splice;
- snapshotting and retiring the outgoing node/varispeed chain;
- calculating the incoming and outgoing fade behavior;
- creating the incoming varispeed and publishing Loading state;
- superseding the previous open and reconciling prefetch ownership;
- consuming an already-prefetched file; and
- admitting a new open and arming its timeout and slow-load timers.

The phases can be reconstructed from the comments, but they are not visible in
the method's structure. A maintenance change near the middle can therefore
move or bypass state mutations whose dependency is hundreds of lines away.

The ordering hazard is not hypothetical: the very first statement is
`terminallyRetirePrefetchRequestOnQueue`, and its comment has to explain that
it must precede the same-path rebind that returns early ~15 lines later. That
is exactly the kind of constraint a named phase boundary would carry for free.

### Evidence

- `Vibe/Audio/AudioPlayer.m:486-664` —
  `playOnQueue:intent:declick:submittedPlayIdentifier:`. The next method,
  `finishPlayOnQueueWithFile:error:openRequestId:`, starts at line 667.
- `Vibe/Audio/AudioPlayer.m:490-494` — the retire-before-rebind ordering note.
- `Vibe/Audio/AudioPlayer.m:496-499` — why the rebind is attempted only inside
  Loading (`rebindTrack:` mutates the request it matches).
- The method has early returns for both same-request rebinding and the
  prefetched-file fast path, in addition to the normal asynchronous-open path.

### Implementation direction

Keep `playOnQueue:` as the queue-confined orchestration point, but extract
side-effect-cohesive private helpers in `AudioPlayer.m`. The top-level method
should read as a short sequence of named phases, with early returns remaining
obvious. Suitable boundaries are the existing-loading rebind, outgoing-chain
retirement/transition preparation, prefetch consumption, and open/timer
submission.

Do not add another category merely to reduce the line count. A category would
expand `AudioPlayerInternal.h`'s shared private surface without creating a new
ownership boundary. Ordering comments should remain at the call boundary that
depends on them; line-by-line narration can disappear once method names carry
the intent.

### Acceptance criteria

- `playOnQueue:` reads as a small number of named, ordered phases.
- Every mutation remains on the player queue and the existing state-lock
  boundaries are unchanged unless separately justified.
- The prefetch retirement still precedes the same-path rebind's early return.
- The same-file Loading rebind remains a true no-op for graph/open work.
- The prefetched-file fast path still publishes Loading before finishing the
  request and never arms open timers.
- A superseded open, a same-path prefetch race, a slow open, and an open timeout
  retain their current callback and cleanup behavior.
- Existing playback, prefetch, request-identity, fade, and scheduler tests pass.

### Likely files

- `Vibe/Audio/AudioPlayer.m`
- Relevant tests under `Tests/` only if an existing behavioral case is not
  already covered.

## C2 — Historical debugging narratives obscure the present contracts

**Priority:** Low

### Current issue

Comments preserve the history of a fix rather than stating the current rule a
maintainer must keep:

- `isDatalessFile:` carries a 29-line preamble containing an abandoned `NSURL`
  resource-value design, a device measurement transcript, benchmark numbers,
  and the symptoms observed while debugging it.
- `playWillStartHandler` explains where the callback used to fire and narrates
  why the old implementation failed.

Both comments contain valuable constraints, but those constraints are buried
inside change history. This conflicts with the repository rule that comments
state non-obvious current behavior, threading/order requirements, or traps;
implementation history belongs in version control.

A third, milder instance shares the shape: `seekToProgress:`'s parked branch
spends four lines on what it used to call and why that was wrong, before
landing on the one durable sentence ("a scrub is a request to move the
playhead and nothing else").

### Evidence

- `Vibe/Util/NSURLUtil.m:104-132` — the preamble above `+ isDatalessFile:`
  (line 133). Lines 106-126 are the abandoned design, the measurement and the
  bug story; 128-132 is the durable forward-looking part.
- `Vibe/Playlist/Mac/PlaylistController.h:37-50` — the `playWillStartHandler`
  comment. Lines 43-49 are the account of the old behavior.
- `Vibe/iOS/PlaybackController.m:414-417` — the milder third instance.

### Implementation direction

Replace each narrative with a terse, present-tense contract:

- For dataless detection, retain that one `stat` and `SF_DATALESS` are the
  authoritative check, and keep the forward-looking paragraph about a provider
  whose placeholders carry no flag — that one says what to do next, not what
  was done. If the per-instance caching behavior of `NSURL` resource values is
  important enough to prevent recurrence, preserve it as a short `TRAP:` or in
  `Vibe/Util/CLAUDE.md`, without the experiment log and benchmark transcript.
- For `playWillStartHandler`, state when it fires, that it precedes the
  asynchronous open, and that the common `play` funnel covers every playback
  entry point. Remove the account of what the code used to do.
- For the scrub branch, keep the rule and drop the account of the old call.

No runtime behavior should change under this item.

### Acceptance criteria

- The comments answer "what must remain true?" without describing an abandoned
  implementation, a past bug, or how the change was verified.
- The reason not to use cached `NSURL` resource values remains discoverable.
- The forward-looking "if a provider ever does appear" guidance survives.
- The handler's timing and all-entry-point coverage remain unambiguous.
- No source behavior, public API, or test expectation changes.

### Likely files

- `Vibe/Util/NSURLUtil.m`
- `Vibe/Util/CLAUDE.md`, only if the durable trap belongs there
- `Vibe/Playlist/Mac/PlaylistController.h`
- `Vibe/iOS/PlaybackController.m`

## C3 — Menu validation is monolithic and silently enables unknown identifiers

**Priority:** Medium

### Current issue

`MainPlayerController` validates most of the app's menu surface through one
139-line `if`/`else if` chain over 26 identifier literals. The chain mixes
several different jobs:

- setting preference and view checkmarks;
- updating dynamic titles and symbols;
- validating playlist transport and seek actions;
- mirroring live FX state;
- delegating conversion validation; and
- forwarding Undo/Redo state from `NSUndoManager`.

Branches that only update presentation fall through to a final `YES`, while
branches with conditional enablement return early. The same final `YES` also
silently enables every unrecognized identifier. Adding, removing, or mistyping
a controller-targeted menu identifier can therefore bypass required validation
without an obvious failure.

The identifier literals have no single home. `view_size_small` is written as a
string in three files — the builder that creates it, the validator's `hasPrefix:`
test, and the width lookup that consumes it — so a rename is a three-site
grep with no compiler help.

### Evidence

- `Vibe/Mac/MainWindow/MainPlayerController+Menus.m:20-158` —
  `validateMenuItem:`; the unconditional `return YES;` is line 158.
- `Vibe/Mac/Menu/MainMenuBuilder.m:296-298` — the `view_size_*` literals.
- `Vibe/Mac/MainWindow/MainPlayerController+Window.m:193,196` — the same
  literals again, in `contentWidthForSizeIdentifier:`.
- `Vibe/Mac/MainWindow/MainPlayerController+Menus.m:169-196` —
  `menuNeedsUpdate:` mints the dynamic `waveform_style_*` family, targets them
  at this controller, and sets `item.enabled = YES` directly; they reach the
  validator's fall-through with no branch of their own.
- `Vibe/Playlist/Mac/PlaylistController.m:537-547` is the deliberate
  delegation boundary and is small enough to leave alone.

### Implementation direction

Split validation into small domain-specific decisions, while retaining one
`validateMenuItem:` entry point. A helper result must distinguish "recognized
and always enabled" from "not recognized"; a plain `BOOL` cannot express that
distinction safely.

Give every builder-owned identifier an explicit disposition. Explicitly cover
the always-enabled preference/FX items and the dynamic `waveform_style_*`
family. Unknown items targeted at this controller should be disabled in
release behavior and made visible during development with a Debug assertion or
log. Identifier ownership should be centralized or otherwise shared with the
builder closely enough that coverage can be audited without searching a long
string chain — a shared constants header consumed by builder, validator and
`contentWidthForSizeIdentifier:` is the smallest thing that achieves it.

Preserve the deliberate delegation boundaries: playlist row-menu items are
validated by `PlaylistController`, Output has its own menu controller, and the
converter remains the authority for Convert to FLAC enablement and retitling.
`menu_convert_to_flac`'s hidden-when-disabled behavior is load-bearing for the
context menus and must survive.

### Acceptance criteria

- Every static and dynamic menu identifier targeting `MainPlayerController`
  has one explicit validation policy.
- Unknown targeted identifiers no longer default silently to enabled.
- Existing checkmarks, titles, images, hidden state, and enablement remain
  unchanged.
- The top-level validator makes its validation domains visible without reading
  every identifier branch.
- Tests cover identifier classification and the unknown-identifier policy
  through a pure decision seam where practical.
- Runtime verification covers the main menu, window context menu, waveform
  style submenu, Undo/Redo titles, and the enabled states at an empty playlist,
  during Loading, while playing/paused, and at both playlist ends.

### Likely files

- `Vibe/Mac/MainWindow/MainPlayerController+Menus.m`
- `Vibe/Mac/Menu/MainMenuBuilder.m` or a shared identifier declaration if that
  is the cleanest way to make ownership explicit
- `Vibe/Mac/MainWindow/MainPlayerController+Window.m`
- `Tests/`, if a pure identifier-classification seam is introduced

## C4 — Playback-state documentation contradicts the actual writer model

**Priority:** Medium — **partially fixed; scope reduced**

### What has since been fixed

Two of the four originally cited sites now document the model honestly:

- `Vibe/Audio/AudioPlayer.m:1445-1448` now says outright that "a few sites
  write `_state` or `_node` alone under the lock without coming through here",
  and states the condition that makes it safe (they never move the position
  fields).
- `Vibe/Audio/AudioPlayerInternal.h:206-217` now explains `_lastValidPosition`
  as an ivar precisely because "the position getter is a second writer".

### Remaining issue

Two sites still open with an unqualified "single writer" and then contradict
themselves, and the permitted partial writers are still anonymous — the
honest paragraph at `AudioPlayer.m:1445` says "a few sites" without naming
them, so there is no way to audit the set.

Four call sites now repeat the same three-line node-unpublish sequence
verbatim (`lock`, `_node = nil`, `unlock`), which is exactly the named helper
the original item proposed and is also what would make the set enumerable.

### Evidence

- `Vibe/Audio/AudioPlayer+State.m:14-18` — claims a single writer and then
  names `_lastValidPosition` as a second writer.
- `Vibe/Audio/AudioPlayer.m:1440-1448` — "The single writer for the whole
  playback and position state", contradicted seven lines later.
- `Vibe/Audio/AudioPlayer+State.m:132-148` — the epoch-guarded cache
  writeback.
- The duplicated node-unpublish blocks, all correctly under `_stateLock`:
  - `Vibe/Audio/AudioPlayer.m:568-570` (play's outgoing-chain retirement);
  - `Vibe/Audio/AudioPlayer.m:895-899` (`finishPlaybackOnQueue`, which writes
    `_state` and `_node` together and deliberately leaves position alone);
  - `Vibe/Audio/AudioPlayer.m:1007-1010` (stop);
  - `Vibe/Audio/Mac/Devices/AudioPlayer+Devices.m:175-181` (device switch).
- `Vibe/Audio/CLAUDE.md:17` — "`AudioPlayer.m` … is the single writer of the
  state it publishes" is about the *file*, not the method, and is accurate.
  Do not sweep it up.

### Implementation direction

Document the model that the code actually enforces:

- the player queue owns engine and playback-state transitions;
- `_stateLock` protects the UI-facing snapshot;
- `publishPlaybackState:` is the atomic **full-tuple publisher**, ensuring that
  getters do not observe a new state with old position fields; and
- a short, enumerated set of partial writers may unpublish a node, publish a
  terminal state that intentionally preserves position fields, or refresh the
  last-valid-position cache under the epoch guard.

Introduce a named private helper for node unpublication and use it at all four
sites; that turns "a few sites" into a call-site list a grep can produce. Do
not force a full publisher call into a path whose deliberate purpose is to
leave the position tuple untouched.

### Acceptance criteria

- No unqualified "single writer" claim remains where multiple writers exist.
- The distinction between full-tuple publication and permitted partial writes
  is stated once and reflected consistently in the source and subsystem docs.
- Every permitted partial writer is discoverable by name or is documented next
  to the protected state.
- Direct partial writes still hold `_stateLock`; position writeback still
  verifies the snapshotted epoch.
- `finishPlaybackOnQueue`'s deliberate position preservation is unchanged.
- No behavior change is introduced solely to make an inaccurate comment true.

### Likely files

- `Vibe/Audio/AudioPlayer.m`
- `Vibe/Audio/AudioPlayer+State.m`
- `Vibe/Audio/AudioPlayerInternal.h`
- `Vibe/Audio/Mac/Devices/AudioPlayer+Devices.m`
- `Vibe/Audio/CLAUDE.md`

## C5 — Player getters are described as lock-free even though they take `_stateLock`

**Priority:** Low

### Current issue

The public header calls `position` and `gaplessArmed` lock-free. The
implementation confirms that these accessors do take `os_unfair_lock`:
`position` takes it for the initial snapshot and again for guarded cache
writeback, and `isGaplessArmed` takes it for its mirror read. The subsystem
doc goes further and says these getters "never block".

The intended property is useful but differently named: these getters are
synchronous and do not marshal work onto the player queue. They can still wait
briefly to acquire `_stateLock`. Calling them lock-free — or saying they never
block — overstates the guarantee and could invite use from a lock-held or
real-time context where even brief contention matters.

### Evidence

False player-state wording:

- `Vibe/Audio/AudioPlayer.h:179` — `position`, "Lock-free".
- `Vibe/Audio/AudioPlayer.h:184` — `gaplessArmed`, "lock-free".
- `Vibe/Audio/AudioPlayer+State.m:105` — "this getter is deliberately
  lock-free", inside `position`, which took the lock at line 81.
- `Vibe/Audio/AudioPlayer+Gapless.m:19` — "the lock-free mirror".
- `Vibe/Audio/AudioPlayerInternal.h:141` — "the lock-free isGaplessArmed".
- `Vibe/Audio/Mac/Devices/AudioPlayer+Devices.m:176-177` — "The position
  getter reads `_node` lock-free on the main thread".
- `Vibe/Audio/CLAUDE.md:34` — "read under an `os_unfair_lock` and never
  block", which is self-contradictory in one sentence.
- `Vibe/Audio/CLAUDE.md:78` — "`isGaplessArmed` (lock-free)".

The implementations: `Vibe/Audio/AudioPlayer+State.m:79-88` (snapshot under
the lock), `132-148` (guarded writeback), `154-159` (`isGaplessArmed`).

**Genuinely lock-free, and out of scope — do not rename these:**

- `Vibe/Audio/AudioPlayer.h:63` / `Vibe/Audio/Levels/AudioLevelPublisher.m:77`
  — `copyBandLevels:` is a real seqlock over atomics with a retry loop.
- `Vibe/Audio/AudioTrack.m:15` — atomic memoized-cache read.
- `Vibe/Audio/AudioFileMaterializationCoordinator.m:571` /
  `Vibe/Debug/Mac/DebugHealth.m:197` — `handleOpensInFlight` is two atomic
  loads, and the comment's point is precisely that it avoids the state queue.
- `Vibe/Debug/AudioPlayer+Debug.h:20` — `manualRenderingActive` is a plain
  ivar read taken once during async init.

### Implementation direction

Describe the player getters as direct, short locked snapshots. Say precisely
that they perform no player-queue round trip and can briefly contend on
`_stateLock`. Keep the current locking design rather than attempting a riskier
lock-free rewrite for a terminology cleanup.

Note that `AudioPlayer+Devices.m:176` and `AudioPlayer+State.m:105` are making
a *correct* point about node lifetime that happens to be worded with the wrong
term — the hazard is that the queue can detach `_node` between the snapshot
and the off-lock read, and that survives the rewording intact.

### Acceptance criteria

- Public, private, implementation, device, and subsystem documentation use the
  same accurate terminology for these getters.
- "Performs no player-queue round trip" and "can wait for `_stateLock`" are
  clearly distinguished.
- The node-detach hazard notes keep their meaning.
- The getter implementations and their synchronization remain unchanged unless
  a separate measured reason justifies redesign.
- A repository search leaves no false lock-free claim attached to the player
  position or gapless snapshot, and the four genuine uses above are untouched.

### Likely files

- `Vibe/Audio/AudioPlayer.h`
- `Vibe/Audio/AudioPlayer+State.m`
- `Vibe/Audio/AudioPlayer+Gapless.m`
- `Vibe/Audio/AudioPlayerInternal.h`
- `Vibe/Audio/Mac/Devices/AudioPlayer+Devices.m`
- `Vibe/Audio/CLAUDE.md`

## C7 — Playlist fallback extensions duplicate and incompletely mirror playable formats

**Priority:** Low

### Current issue

Playlist entry recovery tries alternate extensions when the named file is not
readable, but its private list contains only `wav`, `aif`, `aiff`, `flac`, and
`mp3`. The folder/open filter separately recognizes eleven spellings:
`mp2`, `mp3`, `aac`, `aif`, `aiff`, `wav`, `wave`, `bwf`, `flac`, `m4a`, and
`mp4`.

The duplication has two costs. A playlist referring to a pre-transcode name
cannot recover to another fully supported extension such as `.m4a`, and future
format changes can update one list without the other. The relationship between
the two lists is not named, so a reader cannot know whether the five-item
subset is deliberate or stale. The surrounding comment even hardcodes the
count ("its five alternate-extension candidates"), which a shared source would
have to reword.

### Evidence

- `Vibe/Playlist/PlaylistFile.m:293-297` — the five alternate extensions;
  `298-321` is the directory-probe optimization and the candidate loop.
- `Vibe/Util/NSURLUtil.m:197-206` — `+ supportedExtensions`, eleven spellings.
- `Vibe/Util/NSURLUtil.m:12` — `NSURLUtil.m` imports `PlaylistFile.h`, which
  is the dependency that must not be inverted.
- `Vibe/Util/CLAUDE.md` identifies the latter as the playable extension set.

### Implementation direction

Create one deterministic ordered playable-extension source in a neutral shared
API that both callers can consume. `PlaylistFile` must not import `NSURLUtil`,
because `NSURLUtil` already imports `PlaylistFile`; that would invert the
dependency into a cycle. The common source should provide ordering for playlist
candidate generation and a set, or set-like membership view, for folder/open
filtering without duplicating the literal values.

Preserve candidate precedence: the explicitly named path first, the basename
beside the playlist second, then alternate spellings. Preserve path-based
deduplication and the one-probe-per-primary-directory optimization, including
its memoization across the pass. OGG remains unsupported.

### Acceptance criteria

- There is one literal source for all playable extension spellings.
- Every supported spelling participates in playlist fallback.
- Candidate order is deterministic and the named path/basename precedence is
  unchanged.
- Case normalization and path deduplication remain correct.
- The per-directory reachability memo still gates the primary-path candidates
  and still leaves the beside-the-playlist candidates unconditional.
- Tests cover a replacement extension absent from the old five-item subset,
  aliases such as `wave`/`bwf`, duplicate suppression, and OGG exclusion.
- The documented extension set and the app's declared document types cannot
  silently drift from the shared source.

### Likely files

- `Vibe/Playlist/PlaylistFile.m`
- `Vibe/Util/NSURLUtil.h`
- `Vibe/Util/NSURLUtil.m`
- A neutral shared file selected during implementation, without introducing a
  `PlaylistFile` -> `NSURLUtil` dependency
- `Vibe/Util/CLAUDE.md`
- Playlist and URL-expansion tests under `Tests/`

## C8 — Codec/FX comments describe an obsolete alpha and color model

**Priority:** Low

### Current issue

The current rendering deliberately gives the inline FX symbols full-strength
`secondaryLabelColor` while the codec text uses `tertiaryLabelColor`; the field
itself stays at alpha 1.0 so it does not dim both runs together. The appearance
documentation, the content view's field setup and the `symbolRun` implementation
all agree on that model.

The comment above `composeFileMetadataLabel`, however, still says that inline
symbols receive the label's color and 50 percent alpha "for free." The spacer
wording claims the whitespace run is "dimmed like the codec text", but the
spacer carries only `NSFontAttributeName` and so draws at the field's own
`secondaryLabelColor` — harmless, since it is whitespace, and the real reason
for the comment is the kerning note that follows it. The content view then
points to a `codecTextAttributes` helper that does not exist; the helper is
`cornerTextAttributes`. These comments direct future appearance work toward
behavior the code intentionally removed.

### Evidence

- Stale description: `Vibe/Mac/MainWindow/TrackDisplayController.m:423-427`;
  the false sentence is line 427.
- Nearby spacer wording: `Vibe/Mac/MainWindow/TrackDisplayController.m:442-445`.
- Stale helper reference: `Vibe/Mac/MainWindow/MainPlayerContentView.m:649-653`.
- Current implementation: `Vibe/Mac/MainWindow/TrackDisplayController.m:497-501`
  (`symbolRun`'s full-strength secondary) and `104-108` (`cornerTextAttributes`,
  tertiary).
- Current design: `Vibe/Mac/MainWindow/APPEARANCE.md:45-51`.

### Implementation direction

Correct or remove the stale sentences. Keep only the non-obvious reason the
symbols are inline — the fixed right-aligned run keeps them attached to the
moving left edge of the codec text — and describe the current per-run colors.
Align the spacer explanation with what the run actually carries, keeping the
kerning rationale, and rename the helper reference.

This item should not alter layout, alpha, color, or attributed-string behavior.

### Acceptance criteria

- All descriptions agree that the field alpha is 1.0, codec text is tertiary,
  and FX symbols are full-strength secondary.
- No comment says the symbols inherit a 50 percent field alpha.
- References name the helper that actually supplies codec text attributes
  (`cornerTextAttributes`).
- The spacer comment keeps the kerning reason and drops the color claim.
- The source diff contains no rendering behavior change.

### Likely files

- `Vibe/Mac/MainWindow/TrackDisplayController.m`
- `Vibe/Mac/MainWindow/MainPlayerContentView.m`
- `Vibe/Mac/MainWindow/APPEARANCE.md`, only if wording needs to stay aligned

## C10 — The About-window mail link is mouse-only

**Priority:** Low

### Current issue

`VibeLinkLabel` manually narrows hit testing to the author's glyphs, supplies a
pointing-hand cursor, and opens the `mailto:` URL from `mouseUp:`. It exposes no
link accessibility role/action, focus behavior, or keyboard activation. The
underlined name therefore looks like a link but is unavailable to VoiceOver
and keyboard-only users.

The full-window `VectorBallsView` is **not** part of the defect. Although it is
layered above the labels, its `hitTest:` deliberately returns `nil`, so pointer
events pass through to the copyright label and window background.

### Evidence

- `Vibe/Mac/About/AboutWindowController.m:25-81` — the custom mouse-only
  label: `linkRect` (38-52), `hitTest:` (54-57), `resetCursorRects` (59-65),
  the claimed-but-empty `mouseDown:` (71-72) and `mouseUp:` (73-78).
- `Vibe/Mac/About/AboutWindowController.m:163-170` — the underline attribute
  and the `mailto:` URL assignment.
- `Vibe/Mac/About/AboutWindowController.m:22-23` — the author name is matched
  as a substring of the Info.plist copyright line, so an unmatched name simply
  renders unlinked; that fallback must survive.
- `Vibe/Mac/About/VectorBallsView.m:408-413` — decorative overlay is
  explicitly hit-test transparent.

### Implementation direction

Prefer a standard attributed AppKit link in a tightly sized field centered on
the copyright line. Tight sizing preserves the current behavior in which only
the text region captures the pointer and the rest of the window remains
available for background dragging. If the standard control cannot satisfy all
of those behaviors, retain a custom subclass only with a complete accessible
link role, press action, focus ring/key-view participation, and Return/Space
activation.

Do not change `VectorBallsView`'s hit testing; its existing pass-through is the
correct behavior.

### Acceptance criteria

- VoiceOver announces one link with a useful label.
- Full Keyboard Access can focus it, and Return/Space opens the mail URL.
- Pointer activation remains confined to the visible link/text region.
- Clicking elsewhere still permits normal About-window background dragging.
- A copyright line that does not contain the author name still renders, with
  no link and no crash.
- The decorative Metal view remains hit-test transparent.
- The mail URL and visible copyright localization behavior remain unchanged.

### Likely files

- `Vibe/Mac/About/AboutWindowController.m`
- `Vibe/Mac/About/VectorBallsView.m` only if a comment reference needs updating;
  its behavior should not change

## C11 — iOS documentation describes a retired shell-side materialization hold

**Priority:** Medium — **new**

### Current issue

The foreground/background rule used to be shell state: the player raised a
pre-submit delegate edge, and each shell set and released a hold on the
metadata cache. That design was replaced — the rule now lives entirely inside
`AudioFileMaterializationCoordinator`, which derives "a foreground transfer is
active" from its own claim table. `Vibe/Audio/Metadata/CLAUDE.md` states the
replacement explicitly: "The foreground/background rule itself carries no shell
or cache state at all."

`Vibe/iOS/CLAUDE.md` still documents the old design, and it names a delegate
selector, `willSubmitPlayForTrack:`, that exists nowhere in the source. Root
`CLAUDE.md` carries a weaker version of the same residue in a parenthetical.

This is the most costly kind of stale doc in this backlog: it is not a wrong
name for a live thing, it is a live-sounding description of a mechanism that
was deliberately removed, sitting in the file a maintainer reads *first* when
working on iOS playback, and it directly contradicts the subsystem doc it
cross-references.

### Evidence

- `Vibe/iOS/CLAUDE.md:30` — "the metadata cache's background-materialization
  hold, set here from the player's pre-submit `willSubmitPlayForTrack:` edge
  and released in `didStartPlaying:`'s prefetch claim acknowledgement or the
  error path".
- No such selector exists: `grep -rn willSubmitPlay Vibe` matches only that
  documentation line. `AudioPlayerDelegate` (`Vibe/Audio/AudioPlayer.h:227-267`)
  has no pre-submit edge at all.
- `Vibe/Audio/Metadata/CLAUDE.md:37` — the contradicting, current statement.
- `Vibe/Audio/AudioFileMaterializationCoordinator.m:577` —
  `isForegroundTransferActive`, derived from the claim table.
- Root `CLAUDE.md:101` — "state the newer play has already set up, the
  background-materialization hold included", which reads as shell state a
  settlement can tear down.
- `docs/future/carplay.md:65` inherits the phrase from the same era.
- `Vibe/Mac/MainWindow/CLAUDE.md` has no equivalent residue — the macOS half
  was cleaned up when the rule moved; only the iOS half was missed.

### Implementation direction

Rewrite `Vibe/iOS/CLAUDE.md:30` to describe what the iOS shell actually still
owns — deferring the sweep's *start* until the picked track's open settles
(`scheduleDeferredMetadataLoad`, the two-second fallback, the
`folderSession:didOpenTracks:` / `didStartPlaying:` / error-path wiring) — and
to point at the coordinator for the rule itself, matching root `CLAUDE.md`'s
"the open the user is waiting on outranks every background read" guarantee.

Reword root `CLAUDE.md:101` so the settlement-identity guarantee stands on its
own without implying a shell-held hold; the point it is making (a stale
settlement tears down state a newer play set up) survives without that example.
Fix `docs/future/carplay.md:65` in the same pass so a future CarPlay
implementer does not go looking for the hold.

No source change is expected. If a hold-shaped mechanism turns out to still
exist under a different name, document that name instead and note the finding.

### Acceptance criteria

- No document names `willSubmitPlayForTrack:` or any other selector absent
  from the source.
- `Vibe/iOS/CLAUDE.md` and `Vibe/Audio/Metadata/CLAUDE.md` agree on where the
  foreground/background rule lives, and both agree with root `CLAUDE.md`.
- The scheduling-nicety half that the shell genuinely still owns is still
  documented, on both platforms, and still distinguished from the rule.
- Root `CLAUDE.md`'s settlement-identity guarantee keeps its meaning.
- No behavior change.

### Likely files

- `Vibe/iOS/CLAUDE.md`
- `CLAUDE.md`
- `docs/future/carplay.md`

## C12 — Subsystem docs name symbols that do not exist

**Priority:** Low — **new**

### Current issue

Two subsystem docs name a symbol that the source does not define. Neither is
load-bearing on its own, but each sends a reader to a `grep` that returns
nothing, in a repository whose documentation is otherwise precise enough that
readers trust the names.

- `Vibe/Audio/CLAUDE.md` names the pending-start-paused state `_pendingStartPaused`.
  The ivar is `_loadingStartPaused` and the internal property is
  `loadingStartPaused`.
- `Vibe/WaveformUI/Mac/CLAUDE.md` says the loading control "is the shared
  `WaveformLoadingIndicator`". There is no such class. The shared control is
  `LoadingIndicator` in `Vibe/Controls/`, drawn in its waveform style, with
  `LoadingIndicatorView` as the row-gutter host — which is exactly what
  `Vibe/Controls/CLAUDE.md` says.

### Evidence

- `Vibe/Audio/CLAUDE.md:88` — `_pendingStartPaused`.
  Actual: `Vibe/Audio/AudioPlayerInternal.h:271` (`loadingStartPaused`),
  `Vibe/Audio/AudioPlayer.m:1392,1468,1473` (`_loadingStartPaused`).
- `Vibe/WaveformUI/Mac/CLAUDE.md:10` — `WaveformLoadingIndicator`.
  Actual: `Vibe/Controls/LoadingIndicator.h:32`,
  `Vibe/Controls/LoadingIndicatorView.h:31`,
  `Vibe/Controls/CLAUDE.md:15-19`.

Deliberately **not** findings, checked and cleared: framework names
(`UnderWindowBackground`, `resignKeyAppearance`, `CFRunLoopObserver`,
`NSFileProviderSearchQuery`, `zoomScale`), documented-as-removed symbols
(`baselineAlphaForPlayed:` in `Vibe/WaveformUI/iOS/CLAUDE.md:41`), ellipsis
shorthand (`…DidEndAdjusting:`), enum-member fragments, and directory names.
Root `CLAUDE.md` is clean.

### Implementation direction

Correct both names. While there, consider whether this class of drift is worth
a mechanical gate: a script that extracts backticked identifiers from every
`CLAUDE.md` / `APPEARANCE.md` and fails on any that appears nowhere in the
non-Markdown sources catches all of the above. It needs an allowlist for
framework symbols and for symbols the docs name precisely because they were
removed, which is the reason to weigh it rather than adopt it reflexively — an
allowlist that grows faster than the findings is worse than the drift. If
adopted it belongs beside `make check-vocabulary`, not inside it.

### Acceptance criteria

- Both names match the source.
- If a checker is added, it runs clean on the current tree, its allowlist is
  short and each entry is justified in a comment, and it is wired into the
  same place as the other `check-*` gates.
- No behavior change.

### Likely files

- `Vibe/Audio/CLAUDE.md`
- `Vibe/WaveformUI/Mac/CLAUDE.md`
- `scripts/` and `Makefile`, only if the optional checker is adopted

## Future integrated verification

When selected items are implemented, run the repository gates appropriate to
the touched shared/macOS code:

- `make test`
- `make build CONFIG=Debug`
- `make build-ios CONFIG=Debug` for shared-source compatibility
- `make analyze CONFIG=Release`
- `make check-layout`
- `make check-vocabulary`
- `make check-strings`, and `make check-translations` if any item ends up
  adding or rewording a user-facing string
- `git diff --check`

C11 and C12 are documentation-only and need no build gate beyond
`git diff --check`, but C11 should be re-read against
`Vibe/Audio/Metadata/CLAUDE.md` and root `CLAUDE.md` after editing, since its
whole purpose is to make three files agree.

The menu and About-link items also require running-app verification. Menu state
must be exercised across transport/playlist states, and the link must be
checked with pointer input, Full Keyboard Access, and VoiceOver rather than
accepted from compilation alone.
