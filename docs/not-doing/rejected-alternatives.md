# Rejected alternatives from landed work

Designs weighed and turned down while a feature or fix was landing, kept so they are not proposed again. Each entry says what shipped and why the alternative lost. The full plans were deleted with `docs/done/`; the commit each entry names still holds its plan, at `git show <sha>:docs/done/<file>`.

## Same-path duplicate downloads: the narrow compare-and-set, and doing nothing

Record: `git show c4751ce4:docs/done/cloud-materialization-claim-plan.md`.

The metadata lane once asked an advisory is-materializing query, then dispatched, then asked again, then materialized; a claim registered in any gap was invisible, and both paths downloaded the same bytes (reproduced once in a long cloud soak against an unbounded fake provider). What shipped is the two-layer design: `AudioFileMaterializationCoordinator` is a path-keyed claim that owns only making bytes local, and the deliberate playback/prefetch `AVAudioFile` open race lives untouched above it.

- **A begin/end compare-and-set pair on the coordinator's state queue**, consulted by playback and prefetch when they register. Small and local, but it covers only the metadata-second direction: prefetch registers with no hold to cancel anything, so a prefetch starting on top of a lane transfer is untouched. It also kept the one-second blocked-recheck poll that the `waiter` vocabulary rules out.
- **Doing nothing.** Defensible on cost — one duplicate whole-file download, bounded, with the `cloud.metadata_lane_stands_aside` detector permanent — but the protection was emergent from hold ordering, with nothing in the code stating the dependency, so a later change to that ordering would have removed it silently.
- **The objection that a path-keyed claim would have to rebuild the prefetch/open race as a special case** was wrong, and is why the full design was first passed over. The race is over which open consumes the play request; a claim that owns only bytes does not touch it.

## A wedged background handle open: widening the background lane

Record: `git show fabbc5da:docs/done/background-lane-wedged-open-starvation.md`; the decision is file-loading spec J8.

A never-returning prefetch or gapless `AVAudioFile` call carried the sole background transfer slot forever. What shipped ends every transfer slot at stage-1 settlement and bounds live handle runs separately (six per coordinator, `Audio/Loading/CLAUDE.md`).

- **Raising `maximumBackgroundMaterializations` to 2.** One line, and validation already allows up to 4. It doubles concurrent background provider transfers against the foreground-priority rule the whole file-loading spec is built on, tolerates exactly one wedge, and leaves the category error — a transfer slot carried into a handle open — in place. A stopgap at most.
- **A watchdog that reclaims a wedged run on a deadline.** Reclaiming lets stranded workers grow without bound. A never-returning call stays one of the six until process restart and holds no transfer slot, which is the bounded failure.

## The metadata-loader test hold race: three fixes not taken

Record: `git show 557c191f:docs/done/fix-metadata-loader-test-hold-race.md`.

The fake provider operation in `Tests/AudioTrackMetadataLoaderTests.m` could escape its `blocksUntilCancelled` hold and complete as a success, because it read the flag one step after the point the test synchronized on. What shipped hoists that read; a gate at the bad interleaving is the regression.

- **Lengthening the test's settle delay.** The settle exists to let an erroneous fourth start appear; the bug is a first start taking the wrong branch, which has already happened by then. Slower, no more correct.
- **Making every hold/clear pair observable** with a second expectation each test waits on. Defensible, but it edits all ten pairs for the same guarantee; the hook that shipped pins one interleaving.
- **Serializing the fake behind one lock** across the vulnerable steps. Works only if the lock is released before the completion step, and pulls the controller's flag, failure and start access into one critical section for no stronger guarantee than the hoisted read.
