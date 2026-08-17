# Deferred understandability changes

This document is the implementation backlog for the selected Section C audit
findings. These items have been revalidated against the current working copy,
but **none of the changes described below has been implemented yet**. The
original identifiers are retained so each item can be selected independently.

Scope is the macOS app and the shared code it consumes. C6 and C9 are omitted
because they were not selected for this backlog.

## C1 — `playOnQueue:` hides an ordering-sensitive state transition inside one large method

**Priority:** Medium

### Current issue

`AudioPlayer`'s queue-confined play transition is one 171-line method. Its
length is not merely cosmetic: it interleaves several independently meaningful
phases whose order is part of playback correctness:

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

### Evidence

- `Vibe/Audio/AudioPlayer.m:359-529` — `playOnQueue:intent:declick:submittedPlayIdentifier:`.
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

Two comments preserve the history of a fix rather than stating the current
rule a maintainer must keep:

- `isDatalessFile:` includes an abandoned `NSURL` resource-value design, a
  device measurement transcript, benchmark numbers, and the symptoms observed
  while debugging it.
- `playWillStartHandler` explains where the callback used to fire and narrates
  why the old implementation failed.

Both comments contain valuable constraints, but those constraints are buried
inside change history. This conflicts with the repository rule that comments
state non-obvious current behavior, threading/order requirements, or traps;
implementation history belongs in version control.

### Evidence

- `Vibe/Util/NSURLUtil.m:74-102`.
- `Vibe/Playlist/Mac/PlaylistController.h:25-37`.

### Implementation direction

Replace each narrative with a terse, present-tense contract:

- For dataless detection, retain that one `stat` and `SF_DATALESS` are the
  authoritative check. If the per-instance caching behavior of `NSURL`
  resource values is important enough to prevent recurrence, preserve it as a
  short `TRAP:` or in `Vibe/Util/CLAUDE.md`, without the experiment log and
  benchmark transcript.
- For `playWillStartHandler`, state when it fires, that it precedes the
  asynchronous open, and that the common `play` funnel covers every playback
  entry point. Remove the account of what the code used to do.

No runtime behavior should change under this item.

### Acceptance criteria

- The comments answer “what must remain true?” without describing an abandoned
  implementation, a past bug, or how the change was verified.
- The reason not to use cached `NSURL` resource values remains discoverable.
- The handler's timing and all-entry-point coverage remain unambiguous.
- No source behavior, public API, or test expectation changes.

### Likely files

- `Vibe/Util/NSURLUtil.m`
- `Vibe/Util/CLAUDE.md`, only if the durable trap belongs there
- `Vibe/Playlist/Mac/PlaylistController.h`

## C3 — Menu validation is monolithic and silently enables unknown identifiers

**Priority:** Medium

### Current issue

`MainPlayerController` validates most of the app's menu surface through one
125-line `if`/`else if` chain. The chain mixes several different jobs:

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

### Evidence

- `Vibe/Mac/MainWindow/MainPlayerController+Menus.m:19-143`.
- `Vibe/Mac/Menu/MainMenuBuilder.m` is the principal static identifier source;
  waveform style items are populated dynamically by the same category.

### Implementation direction

Split validation into small domain-specific decisions, while retaining one
`validateMenuItem:` entry point. A helper result must distinguish “recognized
and always enabled” from “not recognized”; a plain `BOOL` cannot express that
distinction safely.

Give every builder-owned identifier an explicit disposition. Explicitly cover
the always-enabled preference/FX items and the dynamic
`waveform_style_*` family. Unknown items targeted at this controller should be
disabled in release behavior and made visible during development with a Debug
assertion or log. Identifier ownership should be centralized or otherwise
shared with the builder closely enough that coverage can be audited without
searching a long string chain.

Preserve the deliberate delegation boundaries: playlist row-menu items are
validated by `PlaylistController`, Output has its own menu controller, and the
converter remains the authority for Convert to FLAC enablement and retitling.

### Acceptance criteria

- Every static and dynamic menu identifier targeting `MainPlayerController`
  has one explicit validation policy.
- Unknown targeted identifiers no longer default silently to enabled.
- Existing checkmarks, titles, images, and enablement remain unchanged.
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
- `Tests/`, if a pure identifier-classification seam is introduced

## C4 — Playback-state documentation contradicts the actual writer model

**Priority:** Medium

### Current issue

The state documentation repeatedly calls `publishPlaybackState:` the “single
writer,” then immediately documents exceptions:

- `position` writes `_lastValidPosition` after an epoch check;
- node-retirement paths unpublish `_node` directly under `_stateLock` before
  detaching it; and
- track completion writes `_state` and `_node` together without publishing the
  full position tuple.

Those writes can be correct while the wording is still unsafe. A maintainer
cannot tell whether “single writer” is the actual threading guarantee, an
aspiration with violations, or shorthand for “the only full-tuple writer.”

### Evidence

- `Vibe/Audio/AudioPlayer+State.m:14-18` — claims a single writer and then names
  `_lastValidPosition` as a second writer.
- `Vibe/Audio/AudioPlayer+State.m:123-135` — epoch-guarded cache writeback.
- `Vibe/Audio/AudioPlayer.m:1151-1160` — calls the publisher the single writer,
  then permits direct `_state` and `_node` writes.
- `Vibe/Audio/AudioPlayerInternal.h:157-177` — repeats the mixed ownership
  story on the shared state.
- Representative partial writes currently appear in `AudioPlayer.m`'s play,
  finish, and stop paths and in `AudioPlayer+Devices.m` before node detachment.

### Implementation direction

Document the model that the code actually enforces:

- the player queue owns engine and playback-state transitions;
- `_stateLock` protects the UI-facing snapshot;
- `publishPlaybackState:` is the atomic **full-tuple publisher**, ensuring that
  getters do not observe a new state with old position fields; and
- a short, enumerated set of partial writers may unpublish a node, publish a
  terminal state that intentionally preserves position fields, or refresh the
  last-valid-position cache under the epoch guard.

Where it improves auditability, hide repeated partial mutation behind named
private helpers such as node unpublication or epoch-checked position-cache
refresh. Do not force a full publisher call into a path whose deliberate
purpose is to leave the position tuple untouched.

### Acceptance criteria

- No unqualified “single writer” claim remains where multiple writers exist.
- The distinction between full-tuple publication and permitted partial writes
  is stated once and reflected consistently in the source and subsystem docs.
- Every permitted partial writer is discoverable by name or is documented next
  to the protected state.
- Direct partial writes still hold `_stateLock`; position writeback still
  verifies the snapshotted epoch.
- No behavior change is introduced solely to make an inaccurate comment true.

### Likely files

- `Vibe/Audio/AudioPlayer.m`
- `Vibe/Audio/AudioPlayer+State.m`
- `Vibe/Audio/AudioPlayerInternal.h`
- `Vibe/Audio/Mac/Devices/AudioPlayer+Devices.m`, if a named unpublish helper is
  adopted
- `Vibe/Audio/CLAUDE.md`

## C5 — Player getters are described as lock-free even though they take `_stateLock`

**Priority:** Low

### Current issue

The public header first explains that state getters take a short state-lock
snapshot, then calls `position` and `gaplessArmed` “lock-free.” The
implementation confirms that these accessors do take `os_unfair_lock`:
`position` takes it for the initial snapshot and again for guarded cache
writeback, and `isGaplessArmed` takes it for its mirror read.

The intended property is useful but differently named: these getters are
synchronous and do not marshal work onto the player queue. They can still wait
briefly to acquire `_stateLock`. Calling them lock-free—or saying they never
block—overstates the guarantee and could invite use from a lock-held or
real-time context where even brief contention matters.

### Evidence

- `Vibe/Audio/AudioPlayer.h:124-136`.
- `Vibe/Audio/AudioPlayer+State.m:73-81`, `124-135`, and `143-145`.
- False player-state “lock-free” wording also appears in:
  - `Vibe/Audio/AudioPlayer+State.m:97-101`;
  - `Vibe/Audio/AudioPlayer+Gapless.m:13`;
  - `Vibe/Audio/AudioPlayerInternal.h:116`;
  - `Vibe/Audio/Mac/Devices/AudioPlayer+Devices.m:176-181`; and
  - `Vibe/Audio/CLAUDE.md:70`.

Other uses of “lock-free,” such as `AudioTrack`'s atomic memoized-cache read,
are separate claims and should not be mechanically renamed without checking
their implementations.

### Implementation direction

Describe the player getters as direct, short locked snapshots. Say precisely
that they perform no player-queue round trip and can briefly contend on
`_stateLock`. Keep the current locking design rather than attempting a riskier
lock-free rewrite for a terminology cleanup.

### Acceptance criteria

- Public, private, implementation, device, and subsystem documentation use the
  same accurate terminology for these getters.
- “Performs no player-queue round trip” and “can wait for `_stateLock`” are
  clearly distinguished.
- The getter implementations and their synchronization remain unchanged unless
  a separate measured reason justifies redesign.
- A repository search leaves no false lock-free claim attached to the player
  position or gapless snapshot.

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
subset is deliberate or stale.

### Evidence

- `Vibe/Playlist/PlaylistFile.m:289-317` — five alternate extensions.
- `Vibe/Util/NSURLUtil.m:132-143` — eleven supported extension spellings.
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
deduplication and the one-probe-per-primary-directory optimization. OGG remains
unsupported.

### Acceptance criteria

- There is one literal source for all playable extension spellings.
- Every supported spelling participates in playlist fallback.
- Candidate order is deterministic and the named path/basename precedence is
  unchanged.
- Case normalization and path deduplication remain correct.
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
documentation and `symbolRun` implementation agree on that model.

The comment above `composeFileMetadataLabel`, however, still says that inline
symbols receive the label's color and 50 percent alpha “for free.” Nearby
spacer wording also describes inherited dimming imprecisely, and the content
view points to a stale `codecTextAttributes` helper name. These comments direct
future appearance work toward behavior the code intentionally removed.

### Evidence

- Stale description: `Vibe/Mac/MainWindow/TrackDisplayController.m:420-424`.
- Nearby spacer wording: `Vibe/Mac/MainWindow/TrackDisplayController.m:437-450`.
- Stale helper reference: `Vibe/Mac/MainWindow/MainPlayerContentView.m:649-653`.
- Current implementation: `Vibe/Mac/MainWindow/TrackDisplayController.m:483-499`.
- Current design: `Vibe/Mac/MainWindow/APPEARANCE.md:35-45`.

### Implementation direction

Correct or remove the stale sentences. Keep only the non-obvious reason the
symbols are inline—the fixed right-aligned run keeps them attached to the
moving left edge of the codec text—and describe the current per-run colors.
Align the spacer explanation and helper reference with the actual attributes.

This item should not alter layout, alpha, color, or attributed-string behavior.

### Acceptance criteria

- All descriptions agree that the field alpha is 1.0, codec text is tertiary,
  and FX symbols are full-strength secondary.
- No comment says the symbols inherit a 50 percent field alpha.
- References name the helper that actually supplies codec text attributes.
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

- `Vibe/Mac/About/AboutWindowController.m:25-78` — custom mouse-only label.
- `Vibe/Mac/About/AboutWindowController.m:147-172` — underlined name and URL.
- `Vibe/Mac/About/VectorBallsView.m:434-439` — decorative overlay is explicitly
  hit-test transparent.

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
- The decorative Metal view remains hit-test transparent.
- The mail URL and visible copyright localization behavior remain unchanged.

### Likely files

- `Vibe/Mac/About/AboutWindowController.m`
- `Vibe/Mac/About/VectorBallsView.m` only if a comment reference needs updating;
  its behavior should not change

## Future integrated verification

When selected items are implemented, run the repository gates appropriate to
the touched shared/macOS code:

- `make test`
- `make build CONFIG=Debug`
- `make build-ios CONFIG=Debug` for shared-source compatibility
- `make analyze CONFIG=Release`
- `make check-layout`
- `make check-vocabulary`
- `make check-strings`
- `git diff --check`

The menu and About-link items also require running-app verification. Menu state
must be exercised across transport/playlist states, and the link must be
checked with pointer input, Full Keyboard Access, and VoiceOver rather than
accepted from compilation alone.
