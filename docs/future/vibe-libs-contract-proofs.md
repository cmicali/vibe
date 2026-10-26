# vibe-libs: the seam contracts under Vibe's tests

**Status: Done.** Phase 3 is complete, and the tests below were its precondition. The lines marked **No test** are still open.

vibe-libs' plan asks, before Phase 3 starts, that the contracts of seams 13, 15, 17, and 22, and rule 4's version check, are each proven in Vibe under its existing tests. This page lists, for each line of each contract, the tests that pin it. They were found by reading the tests. A line with no test says so. That is a finding, not a failure.

The contracts are quoted in short from the plan in `vibe-libs/docs/plan.md`.

A test named as vibe-libs' moved there with its piece, and runs in vibe-libs' CI.

## Seam 13: the playable-item protocol

| Contract | Tests that pin it |
| --- | --- |
| An item gives its file, its window, its source key, and its disk key. | `AudioTrackTests` `testTheSourceKeyIdentifiesTheWindow`. vibe-libs' `NSURLHashTests` `testKeyIsSizeMtimeAndPathHash`, `testTrackMemoizesItsKey`, `testTrackDoesNotMemoizeAFailedStat`. |
| The pieces that read a file take the protocol and hand back the same object. | Waveform: vibe-libs' `AudioWaveformObserverTests` `testADecodeFeedsItsSinkEveryFrameAndDeliversTheResult`, `testACacheHitDecodesNothingAndHandsBackTheResult`. Player: vibe-libs' `AudioPlayerRenderEdgesTests` `testATrackSplicesIntoItselfGaplessly`, vibe-libs' `AudioPlayerRenderOutputTests` `testOutputRateChangeKeepsThePlayingAndPausedTrack`, vibe-libs' `PlaybackRequestCoordinatorTests` `testRebindBeforeSlowDeliveryUsesTheLatestTrackAndIntent`. Metadata: vibe-libs' `AudioTrackMetadataLoaderSharedFileTests` `testPriorityTakesItsFilesRecordAndItsRowTakesAFailureFirst`. |
| Two entries for one file stay two entries. | vibe-libs' `AudioWaveformObserverTests` `testARequestJoinsADecodeThatCarriesItsObservers`. vibe-libs' `AudioPlayerRenderEdgesTests` `testAPickOfAnotherRowOfTheFileBeingOpenedRebindsTheOpen`. vibe-libs' `AudioTrackMetadataLoaderSharedFileTests` `testSuccessfulParseJoinsDuplicateRowsAndPublishesIndependentCopies`. vibe-libs' `MetadataParseCoordinatorTests` `testEqualButDistinctRowsWaitIndependently`. vibe-libs' `VibePlaylistTests` `testStampingReachesEveryRowSoundingTheWindowAndNoOtherRowOfTheFile`. |
| The CUE window math is one header that the readers share. | vibe-libs' `CueWindowMathTests`, all six tests. |
| Only the player, Metadata, and the waveform loader take the protocol, and any object may adopt it. | vibe-libs' `VibePlayableItemTests` adopt the protocol in a plain object, and its two helpers read it. The player's tests, vibe-libs' render suite included, hand it `VibeTestTrack`, a plain object of their own. vibe-libs' metadata and waveform tests hand those pieces objects of their own, `VibeLoaderTestTrack` and `VibeTestTrack`. vibe-libs' `PlaybackRequestCoordinatorTests` passes a bare object, but never reads it. Which pieces take the protocol is compile-time only, by Phase 2's `grep` for `AudioTrack.h`. |

## Seam 15: the loader's handle

| Contract | Tests that pin it |
| --- | --- |
| The opener is a block that the caller passes. | vibe-libs' `AudioFileMaterializationCoordinatorHandleOpenTests` `testAWedgedPrefetchOpenDoesNotStarveBackgroundTransfers`, `testARebindWhileAnAbandonedHandleOpenReturnsGetsAFreshRun`. Both pass openers of their own. |
| A served handle holds its stream, and the transfer ends when the play lets go. | vibe-libs' `AudioPlayerRenderStreamTests` `testAStopOrASkipWhileParkedAtTheEdgeLetsTheStreamGo`. vibe-libs' `AudioWaveformLoaderTests` `testAStreamingLoadFillsInAsTheDownloadArrivesAndCompletesWithIt`, which shows a waveform's handle holds nothing. vibe-libs' `CloudFileMaterializerTests` `testAvailabilityCallsBackWhenItsLastReaderGoes`. |
| Interrupting stays the opener's `interrupted` block. | vibe-libs' `CloudFileMaterializerTests` `testAvailabilityInterruptEndsOnlyAWaitThatBlocks`, `testAWakeMakesABlockedWaitSeeAnInterrupt`. vibe-libs' `AudioPlayerRenderStreamTests` `testTheOpenDeadlineStopsAStreamingOpenParkedAtTheEdge`. vibe-libs' `AudioWaveformLoaderTests` `testCancellingAStreamingLoadParkedAtTheEdgeEndsItPromptly`. |
| A download that installs another version bumps the generation on `NSURL (Hash)`. | vibe-libs' `AudioFileHandleStreamingTests` `testATransferInstallingAnotherVersionRetiresTheMemoizedKeys`, which reads the generation itself. **No test** plays the bump through a row's memo. |
| A download that installs its placeholder's version leaves the memos alone. | **No test.** Nothing checks that the generation stays put. A spurious bump costs one stat per memo. |
| The read-ahead's test hooks are FileLoading's own, and `AudioFileHandle (Debug)` forwards to them. | vibe-libs' `AudioFileHandleReadAheadTests`, through `VibeReadAheadScript`, which installs the hooks through the forwarding category. |
| FileLoading builds and tests alone in Debug. | vibe-libs' `FileLoadingTests`, which build with the headermap off and no Decode header path. It was Phase 3 step 4's done-when. |
| The served handle is any object that adopts `ServedFileHandle`. | vibe-libs' `AudioFileMaterializationCoordinatorHandleOpenTests`, whose openers return `VibeTestServedFile`, a handle with no decoder. vibe-libs' minimal consumer serves one of its own. |

## Seam 17: the decode's observers

| Contract | Tests that pin it |
| --- | --- |
| An observer has a stable identifier, which names its result in the archive. | vibe-libs' `CodableAudioWaveformTests` `testEncodeThenDecodePreservesTheSummaryBandsAndResults`, `testResultsThatWillNotReadRejectTheEntry`. |
| The loader asks each listed observer for a sink, given the rate and the window, and feeds it every mono block in order. | vibe-libs' `AudioWaveformObserverTests` `testADecodeFeedsItsSinkEveryFrameAndDeliversTheResult`. |
| Each sink returns one result, any property-list object, filed beside the summary. | vibe-libs' `CodableAudioWaveformTests` `testEveryPropertyListClassRoundTrips`. A sink that returns something else asserts in Debug and is dropped in Release. **No test** covers that drop. |
| A cache hit decodes nothing and hands back the filed results. | vibe-libs' `AudioWaveformObserverTests` `testACacheHitDecodesNothingAndHandsBackTheResult`. |
| An entry covers a request only if it holds a result for every observer listed. | vibe-libs' `AudioWaveformObserverTests` `testAnEntryWithoutAResultMissesForARequestThatListsIt`. vibe-libs' `AudioWaveformLoaderTests` `testCacheOnlyLookupMissesWithoutDecodingAndChecksAnalysisRequirements`, for the bands. |
| A request joins a running decode only if that decode carries every observer it wants. | vibe-libs' `AudioWaveformObserverTests` `testARequestJoinsADecodeThatCarriesItsObservers`, `testARequestThatWantsMoreDoesNotJoin`. |
| A cancelled request detaches its decode, and its sinks still finish. | vibe-libs' `AudioWaveformObserverTests` `testACancelledRequestsDecodeStillFinishesItsSinks`. vibe-libs' `AudioWaveformLoaderTests` `testDetachedLoadFinishesWithoutProgressDeliveries`. |
| A late completion reaches only a request that is still current, by source key and version. | By source key: vibe-libs' `AudioWaveformObserverTests` `testALateCompletionReachesOnlyItsOwnTrack`, `PageWaveformCoordinatorTests` `testDeliveryForAnotherRowOfTheSameFileIsDropped`, vibe-libs' `VibePlaylistTests` `testStampingReachesEveryRowSoundingTheWindowAndNoOtherRowOfTheFile`. By version: rule 4's rows below. |
| A CUE window decodes only its frames, so its observers see only those. | vibe-libs' `AudioWaveformObserverTests` `testACueWindowsSinkSeesOnlyItsFrames`. vibe-libs' `AudioWaveformLoaderTests` `testFullLoadOfAWindowCoversOnlyTheWindow`. |
| `VibeBenchComponents --analyze` proves tempo and key identical. | A measurement, not a test. It is the `vibe-perf` skill's. It ran again for Analysis' move (#374): every answer over 655 GiantSteps tempo files and 602 key files was identical. |

## Seam 22: Metadata's holder protocol

| Contract | Tests that pin it |
| --- | --- |
| The loader installs a result only while the holder has none from the same version. | `AudioTrackTests` `testConcurrentMetadataInstallationPublishesOnlyTheWinner`. vibe-libs' `AudioTrackMetadataLoaderTests` `testStageOneCacheHitInstallsAndPublishesWithoutMaterialization`. Another version's answer: vibe-libs' `AudioTrackMetadataLoaderRetryTests` `testARowHoldingAnOldVersionsTagsParsesAgainInTheNextSweep`. |
| It delivers only while that result is still installed. | `AudioTrackTests` `testQueuedDeliveryDropsAfterMetadataReplacementBeforeMainRuns`, `testDeliveryKeepsReplacementOutUntilObserverReturns`. |
| The check and the install stay atomic in the holder, so a replaced item never shows a stale result. | The same three `AudioTrackTests`. vibe-libs' `AudioTrackMetadataLoaderSharedFileTests` `testFailedParsePublishesIndependentFallbacksToOwnerAndWaiter`. |
| The holder is Metadata's own protocol, and the playable item stays free of metadata. | vibe-libs' loader tests hold `VibeLoaderTestTrack`, a plain object that adopts the holder, so any object may. That the playable item stays free of metadata is compile-time only. |

## Rule 4: the version check

| Contract | Tests that pin it |
| --- | --- |
| Source identity does not change with the file's contents. Version identity does. | `AudioTrackTests` `testTheSourceKeyIdentifiesTheWindow`. vibe-libs' `NSURLHashTests` `testRewritingTheFileMovesTheKey`, `testSameSizeRewriteStillMovesTheKeyViaMtime`. |
| An item may memoize the disk key. A memo below the generation computes the key again. | vibe-libs' `NSURLHashTests` `testAReplacedFileAnswersItsNewKeyOnceTheMemosAreRetired`. vibe-libs' `AudioWaveformLoaderTests` `testAReKeyedTrackMissesTheOldVersionsEntry`. |
| A waveform job compares the key it was submitted under with the item's current one, and drops a mismatch. | vibe-libs' `AudioWaveformObserverTests` `testALateCompletionOfAReplacedVersionIsNotDelivered`, `testALateCompletionOfAnUnchangedFileIsDelivered`, `testACueWindowsLateCompletionIsCheckedUnderItsWindowedKey`. |
| A metadata job compares the same way before it installs. | vibe-libs' `AudioTrackMetadataLoaderRetryTests` `testAParseOfAReplacedVersionInstallsNothingAndTheRowParsesAgain`, `testAParseOfAnUnchangedFileInstallsOnceTheMemosAreRetired`. A cache hit is not checked. It carries the key it was read under, so a hit that lands after a re-key is parsed again in the next sweep. |
| A new version clears what Metadata's holder installed, so the next parse can install. | vibe-libs' `AudioTrackMetadataLoaderRetryTests` `testARowHoldingAnOldVersionsTagsParsesAgainInTheNextSweep`. The holder takes another version's answer over its own. Nothing starts that sweep at the re-key. A priority edge does not check the version, because it runs on main. |
| The source already sounding keeps the version it opened, and its transport settles by submission identity. | Submission identity: vibe-libs' `PlaybackRequestCoordinatorTests` `testStaleWorkersCannotMutateOrConsumeANewerRequest`, `testSlowSameRowReplayRequestsACurrentLoadingDelivery`. The open version: **no test** plays a file through a re-key. |
