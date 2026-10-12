//
//  AudioTrackMetadataLoader+Materialization.m
//  Vibe
//
//  The materialization lane: priority marks, the two slots' picks, the
//  foreground gate, and each completion's settlement and retry.
//

#import "AudioTrackMetadataLoader.h"
#import "AudioFileMaterializationCoordinator.h"
#import "AudioTrack.h"
#import "AudioTrackMetadata.h"
#import "AudioFileOpenRules.h"
#import "MetadataScanEntry.h"
#import "MetadataScanOrderRules.h"
#import "MetadataRetryRules.h"
#import "PlaceholderFiles.h"

#import "AudioTrackMetadataLoader+Debug.h"

@implementation AudioTrackMetadataLoader (Materialization)

#pragma mark - The materialization lane

- (void)enqueueScanMaterialization:(MetadataScanEntry *)entry {
    entry.local = ![PlaceholderFiles isDatalessFile:entry.url];
    BOOL kick = NO;
    BOOL dropped = NO;
    os_unfair_lock_lock(&_materializationLock);
    if (!self.isCancelled) {
        NSString *path = entry.standardizedPath;
        if (_materializationAttemptsByPath[path].unsignedIntegerValue
                >= _materializationMaximumAttempts) {
            [self dropRecordsForExhaustedPathOfEntryLocked:entry];
            dropped = YES;
        }
        else {
            [_pendingMaterializations addObject:entry];
            _scanOrderGeneration++;
            // A priority record does not wait for the stage-1 barrier.
            kick = [self priorityMarkForEntryLocked:entry] != nil;
        }
    }
    os_unfair_lock_unlock(&_materializationLock);
    if (kick || dropped) {
        [self dispatchNextScanMaterialization];
    }
}

// A pending or delayed record holding the track is reactivated for one
// submission; an in-flight or mid-stage-1 one adopts the mark at completion or
// enqueue; any other track gets its own high-priority cache check, then joins
// its file's pending record or mints one.
- (void)prioritizeTrack:(AudioTrack *)track {
    if (track.metadata.parsedOK) {
        [self retirePriorityMarksSatisfiedByTracks:@[track]];
        return;
    }
    NSURL *url = track.url;
    if (!url) {
        return;
    }
    BOOL alreadyQueued;
    BOOL needsScan;
    NSOperation *parseOperation;
    os_unfair_lock_lock(&_materializationLock);
    MetadataPriorityMark *mark = [[MetadataPriorityMark alloc] init];
    mark.markGeneration = ++_nextPriorityMarkGeneration;
    mark.track = track;
    _priorityMarks[url] = mark;
    MetadataScanEntry *held = [self unpickedRecordHoldingTrackLocked:track];
    if (held) {
        held.priorityMarkGeneration = mark.markGeneration;
        held.yieldedUnderHold = NO;
        if ([_delayedScanRetryEntries containsObject:held]) {
            [_delayedScanRetryEntries removeObject:held];
            [_pendingMaterializations addObject:held];
        }
    }
    _scanOrderGeneration++;
    alreadyQueued = [_queuedTracks containsObject:track];
    if (!alreadyQueued) {
        [_queuedTracks addObject:track];
    }
    needsScan = ![_tracksWithScanInFlight containsObject:track];
    if (needsScan) {
        [_tracksWithScanInFlight addObject:track];
    }
    parseOperation = [_parseOperationsByTrack objectForKey:track];
    if (parseOperation) {
        parseOperation.qualityOfService = NSQualityOfServiceUserInitiated;
        parseOperation.queuePriority = NSOperationQueuePriorityHigh;
#if DEBUG
        [self debugNoteScheduledParseQualityOfService:NSQualityOfServiceUserInitiated];
#endif
    }
    os_unfair_lock_unlock(&_materializationLock);
    // A winner that installed before the mark existed retired nothing.
    if (track.metadata.parsedOK) {
        [self finishTracks:@[track]];
        return;
    }
    LogDebug(@"Priority load %@%@", url.lastPathComponent,
             alreadyQueued ? @": already queued" : @"");
    if (!needsScan) {
        [self dispatchNextScanMaterialization];
        return;
    }
    __weak __typeof(self) weakSelf = self;
    NSOperation *op = [NSBlockOperation blockOperationWithBlock:^{
        __typeof(self) strongSelf = weakSelf;
        if (!strongSelf || strongSelf.isCancelled) {
            return;
        }
        if (track.metadata.parsedOK || [strongSelf loadTrackFromDiskCache:track]) {
            [strongSelf finishTracks:@[track]];
            return;
        }
        // The file's pending record takes the row, so the file still reads
        // once and its answer settles the rows beside it.
        NSString *path = VibeStandardizedAudioOpenPath(track.url);
        BOOL joined = NO;
        os_unfair_lock_lock(&strongSelf->_materializationLock);
        for (MetadataScanEntry *record in strongSelf->_pendingMaterializations) {
            if ([record.standardizedPath isEqualToString:path]) {
                record.tracks = [record.tracks arrayByAddingObject:track];
                record.yieldedUnderHold = NO;
                strongSelf->_scanOrderGeneration++;
                joined = YES;
                break;
            }
        }
        os_unfair_lock_unlock(&strongSelf->_materializationLock);
        if (!joined) {
            [strongSelf enqueueScanMaterialization:[[MetadataScanEntry alloc]
                    initWithTracks:@[track] standardizedPath:path playlistIndex:NSNotFound]];
        }
        [strongSelf dispatchNextScanMaterialization];
    }];
    op.queuePriority = NSOperationQueuePriorityHigh;
    op.qualityOfService = NSQualityOfServiceUserInitiated;
    [_queue addOperation:op];
}

- (void)dispatchNextScanMaterialization {
    BOOL shouldSchedule = NO;
    os_unfair_lock_lock(&_materializationLock);
    if (!_scanDispatchKickPending && !self.isCancelled) {
        _scanDispatchKickPending = YES;
        shouldSchedule = YES;
    }
    os_unfair_lock_unlock(&_materializationLock);
    if (!shouldSchedule) {
        return;
    }
    __weak __typeof(self) weakSelf = self;
    dispatch_async(_materializationCallbackQueue, ^{
        __typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        os_unfair_lock_lock(&strongSelf->_materializationLock);
        strongSelf->_scanDispatchKickPending = NO;
        os_unfair_lock_unlock(&strongSelf->_materializationLock);
        [strongSelf dispatchNextScanMaterializationOnCallbackQueue];
    });
}

- (void)dispatchNextScanMaterializationOnCallbackQueue {
    // A snapshot: a submission racing a rising edge is yielded unspent.
    BOOL suspended = [_materializationCoordinator isForegroundTransferActive];
    // Before any idle pick, or a kick in the release gap could resubmit a
    // still-dataless yielded record instead of demoting it.
    if (!suspended) {
        [self judgeWaitingPriorityRecordsWhileHeld:NO];
    }
    // The priority slot runs beside the scan's, so the current track never
    // waits for the sweep's transfer (D3).
    MetadataScanEntry *priorityPick = nil;
    os_unfair_lock_lock(&_materializationLock);
    if (!_priorityMaterializationInFlight && !self.isCancelled
            && _priorityMarks.count > 0) {
        NSMutableArray<MetadataScanEntry *> *targeted = [NSMutableArray array];
        for (MetadataScanEntry *entry in _pendingMaterializations) {
            if ([self priorityMarkForEntryLocked:entry]
                    && ![entry.standardizedPath
                            isEqualToString:_scanMaterializationPath]) {
                [targeted addObject:entry];
            }
        }
        priorityPick = (MetadataScanEntry *)VibeBestPriorityScanCandidate(
                (NSArray<id<MetadataScanOrderCandidate>> *)targeted, suspended);
        if (priorityPick) {
            [_pendingMaterializations removeObjectIdenticalTo:priorityPick];
            _scanOrderGeneration++;
            _priorityMaterializationInFlight = YES;
            _priorityMaterializationPath = priorityPick.standardizedPath;
            priorityPick.priorityMarkGeneration =
                    [self priorityMarkForEntryLocked:priorityPick].markGeneration;
        }
    }
    os_unfair_lock_unlock(&_materializationLock);
    if (priorityPick) {
        [self submitMaterializationForEntry:priorityPick priority:YES];
    }

    // One pass in place under the lock, no copy: a real playlist holds over
    // 100,000 misses, and the sweep picks once per file.
    MetadataScanEntry *chosen = nil;
    NSUInteger chosenIndex = NSNotFound;
    NSUInteger orderGeneration = 0;
    os_unfair_lock_lock(&_materializationLock);
    if (!_scanMaterializationInFlight && !self.isCancelled
            && _stageOneFinished && _pendingMaterializations.count > 0) {
        NSDictionary<NSURL *, MetadataPriorityMark *> *marks =
                _priorityMarks.count > 0 ? _priorityMarks : nil;
        NSString *priorityMaterializationPath = _priorityMaterializationPath;
        NSArray<NSURL *> *neighborhood = _neighborhood;
        NSUInteger neighborhoodGeneration = _neighborhoodGeneration;
        chosenIndex = VibeBestMetadataScanCandidateIndex(
                (NSArray<id<MetadataScanOrderCandidate>> *)_pendingMaterializations,
                ^NSUInteger(id<MetadataScanOrderCandidate> candidate) {
            MetadataScanEntry *entry = (MetadataScanEntry *)candidate;
            if (entry.neighborhoodRankGeneration != neighborhoodGeneration) {
                entry.neighborhoodRank = VibeMetadataScanNeighborhoodRank(entry.url, neighborhood);
                entry.neighborhoodRankGeneration = neighborhoodGeneration;
            }
            return entry.neighborhoodRank;
        }, ^BOOL(id<MetadataScanOrderCandidate> candidate) {
            MetadataScanEntry *entry = (MetadataScanEntry *)candidate;
            // Priority records belong to the priority slot alone, and a marked
            // URL holds its other records back until the mark settles. Local
            // entries start no transfer, so they keep parsing; no dataless
            // record is submitted while suspended, even one C3 would join (J4).
            return (marks && marks[entry.url] != nil)
                    || (priorityMaterializationPath
                            && [entry.standardizedPath isEqualToString:priorityMaterializationPath])
                    || (suspended && !entry.local);
        });
        if (chosenIndex != NSNotFound) {
            chosen = _pendingMaterializations[chosenIndex];
        }
        orderGeneration = _scanOrderGeneration;
    }
    os_unfair_lock_unlock(&_materializationLock);
    if (!chosen) {
        [self scheduleGatedRepickIfNeededWhileSuspended:suspended];
        return;
    }

#if DEBUG
    dispatch_block_t beforeValidation = [self debugBeforeScanPickValidation];
    if (beforeValidation) {
        beforeValidation();
    }
#endif
    BOOL retryPick = NO;
    os_unfair_lock_lock(&_materializationLock);
    if (_scanMaterializationInFlight || self.isCancelled
            || (suspended && !chosen.local)) {
        chosen = nil;
    }
    // Every pending-list, priority-mark and priority-path change moves the
    // generation, so an unchanged one still has the pick, at its index.
    else if (orderGeneration != _scanOrderGeneration) {
        chosen = nil;
        retryPick = YES;
    }
    else {
        [_pendingMaterializations removeObjectAtIndex:chosenIndex];
        _scanOrderGeneration++;
        _scanMaterializationInFlight = YES;
        _scanMaterializationPath = chosen.standardizedPath;
    }
    os_unfair_lock_unlock(&_materializationLock);
    if (retryPick) {
        [self dispatchNextScanMaterialization];
        return;
    }
    if (!chosen) {
        [self scheduleGatedRepickIfNeededWhileSuspended:suspended];
        return;
    }
    [self submitMaterializationForEntry:chosen priority:NO];
}

// Stands in for the hold's release edge: one coalesced re-pick per second
// while the rule gates work. A gap between rapid nexts cannot flap the sweep;
// the tick just finds the foreground active again.
- (void)scheduleGatedRepickIfNeededWhileSuspended:(BOOL)suspended {
    if (!suspended) {
        return;
    }
    BOOL shouldSchedule = NO;
    os_unfair_lock_lock(&_materializationLock);
    if (!_gatedRepickPending && !self.isCancelled
            && (_pendingMaterializations.count > 0
                    || _delayedScanRetryEntries.count > 0)) {
        _gatedRepickPending = YES;
        shouldSchedule = YES;
    }
    os_unfair_lock_unlock(&_materializationLock);
    if (!shouldSchedule) {
        return;
    }
    __weak __typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)),
                   _materializationCallbackQueue, ^{
        __typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        os_unfair_lock_lock(&strongSelf->_materializationLock);
        strongSelf->_gatedRepickPending = NO;
        os_unfair_lock_unlock(&strongSelf->_materializationLock);
        if (strongSelf.isCancelled) {
            return;
        }
        [strongSelf recheckForegroundGate];
    });
}

- (void)recheckForegroundGate {
    if (self.isCancelled) {
        return;
    }
    [self judgeWaitingPriorityRecordsWhileHeld:
            [_materializationCoordinator isForegroundTransferActive]];
    [self dispatchNextScanMaterialization];
}

// Every gated tick (MetadataRetryRules.h). The probe is I/O, so it runs off
// the lock, and the mark generation is revalidated after it so an old mark's
// judgement cannot remove a new prioritizeTrack: edge.
- (void)judgeWaitingPriorityRecordsWhileHeld:(BOOL)held {
    NSMutableArray<MetadataScanEntry *> *waiting = [NSMutableArray array];
    NSMutableArray<NSNumber *> *markGenerations = [NSMutableArray array];
    os_unfair_lock_lock(&_materializationLock);
    // A waiting record is a marked one: with no mark, no pass over the misses.
    if (_priorityMarks.count > 0) {
        for (MetadataScanEntry *entry in _pendingMaterializations) {
            if (entry.yieldedUnderHold && [self priorityMarkForEntryLocked:entry]) {
                [waiting addObject:entry];
                [markGenerations addObject:@(entry.priorityMarkGeneration)];
            }
        }
    }
    os_unfair_lock_unlock(&_materializationLock);
    for (NSUInteger index = 0; index < waiting.count; index++) {
        MetadataScanEntry *entry = waiting[index];
        NSUInteger markGeneration = markGenerations[index].unsignedIntegerValue;
        BOOL local = ![PlaceholderFiles isDatalessFile:entry.url];
        BOOL demoted = NO;
        os_unfair_lock_lock(&_materializationLock);
        BOOL stillPending = [_pendingMaterializations containsObject:entry];
        BOOL sameEntryMark = entry.priorityMarkGeneration == markGeneration;
        MetadataPriorityMark *currentMark = [self priorityMarkForEntryLocked:entry];
        BOOL sameCurrentMark = currentMark != nil
                && currentMark.markGeneration == markGeneration;
        if (!stillPending || !entry.yieldedUnderHold || !sameEntryMark) {
            os_unfair_lock_unlock(&_materializationLock);
            continue;
        }
        entry.local = local;
        VibeMetadataPriorityYieldOutcome outcome =
                VibeMetadataPriorityAfterYield(held, local);
        if (!sameCurrentMark) {
            // A newer mark, already reactivated; this probe cannot touch it.
            os_unfair_lock_unlock(&_materializationLock);
            continue;
        }
        switch (outcome) {
            case VibeMetadataPriorityYieldWait:
                break;
            case VibeMetadataPriorityYieldRetry:
                entry.yieldedUnderHold = NO;
                break;
            case VibeMetadataPriorityYieldDemote:
                entry.yieldedUnderHold = NO;
                [_priorityMarks removeObjectForKey:currentMark.track.url];
                _scanOrderGeneration++;
                demoted = YES;
                break;
        }
        os_unfair_lock_unlock(&_materializationLock);
        if (demoted) {
            LogInfo(@"Priority record %@ still dataless once the foreground settled — left to the sweep",
                    entry.url.lastPathComponent);
        }
    }
}

- (void)submitMaterializationForEntry:(MetadataScanEntry *)entry
                             priority:(BOOL)priority {
    __weak __typeof(self) weakSelf = self;
    dispatch_async(_materializationCallbackQueue, ^{
        __typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;

        // Re-probed: a rule that rose since the pick must not requeue a file
        // the playback open has since downloaded.
        entry.local = ![PlaceholderFiles isDatalessFile:entry.url];
        BOOL suspended = !priority && !entry.local
                && [strongSelf->_materializationCoordinator isForegroundTransferActive];
        BOOL requeueBehindRule = NO;
        os_unfair_lock_lock(&strongSelf->_materializationLock);
        if (strongSelf.isCancelled) {
            if (priority) {
                strongSelf->_priorityMaterializationInFlight = NO;
                strongSelf->_priorityMaterializationPath = nil;
            }
            else {
                strongSelf->_scanMaterializationInFlight = NO;
                strongSelf->_scanMaterializationPath = nil;
            }
        }
        else if (suspended) {
            // Scan picks only: a priority submission goes through, served by
            // a same-path foreground claim or yielded by the coordinator (J4).
            [strongSelf->_pendingMaterializations addObject:entry];
            strongSelf->_scanOrderGeneration++;
            strongSelf->_scanMaterializationInFlight = NO;
            strongSelf->_scanMaterializationPath = nil;
            requeueBehindRule = YES;
        }
        BOOL shouldSubmit = !strongSelf.isCancelled && !requeueBehindRule;
        NSUInteger stillPending = strongSelf->_pendingMaterializations.count;
        os_unfair_lock_unlock(&strongSelf->_materializationLock);
        if (requeueBehindRule) {
            [strongSelf scheduleGatedRepickIfNeededWhileSuspended:YES];
        }
        if (!shouldSubmit) {
            return;
        }
        // A remote placeholder's tags are read by range (AudioTrackMetadata's
        // VibeRangedStream), so it takes no claim: one would download the
        // whole file for a few hundred KB of tags. Ready at once, with no
        // token — the slot holds none yet, so the completion's match passes.
        // The foreground hold above covers the scan's picks only: a priority
        // read — the tags of the track being downloaded and its neighbors' —
        // goes out beside the foreground download, a few hundred KB each, so
        // the header is not blank until the whole file lands. A format TagLib
        // cannot parse is materialized as any cloud file is: CoreAudio's
        // facts need the whole file.
        if ([PlaceholderFiles readsRemotePlaceholderByRange:entry.url]) {
            [strongSelf completeMaterializationForEntry:entry
                                               priority:priority
                                                  token:nil
                                                 result:VibeAudioFileMaterializationResultReady
                                                  error:nil
                                                elapsed:0];
            return;
        }
        LogInfo(@"Metadata %@ materializing %@ (%lu pending behind it)",
                priority ? @"priority" : @"scan",
                entry.url.lastPathComponent, (unsigned long)stillPending);

        __block __weak AudioFileMaterializationRequestToken *weakToken = nil;
        AudioFileMaterializationRequestToken *token =
                [strongSelf->_materializationCoordinator
                        materializeURL:entry.url
                                  role:priority
                                          ? VibeAudioFileMaterializationRoleMetadataPriority
                                          : VibeAudioFileMaterializationRoleMetadataScan
                       completionQueue:strongSelf->_materializationCallbackQueue
                            completion:^(VibeAudioFileMaterializationResult result,
                                         NSError *error,
                                         NSTimeInterval elapsed) {
            [weakSelf completeMaterializationForEntry:entry
                                             priority:priority
                                                token:weakToken
                                               result:result
                                                error:error
                                              elapsed:elapsed];
        }];
        weakToken = token;

        BOOL cancelToken = NO;
        os_unfair_lock_lock(&strongSelf->_materializationLock);
        BOOL slotStillOurs = priority ? strongSelf->_priorityMaterializationInFlight
                                      : strongSelf->_scanMaterializationInFlight;
        if (strongSelf.isCancelled || !slotStillOurs) {
            cancelToken = YES;
        }
        else {
            if (priority) {
                strongSelf->_priorityMaterializationToken = token;
            }
            else {
                strongSelf->_scanMaterializationToken = token;
            }
            [strongSelf->_liveMaterializationTokens addObject:token];
        }
        os_unfair_lock_unlock(&strongSelf->_materializationLock);
        if (cancelToken) {
            [token cancel];
        }
    });
}

- (void)completeMaterializationForEntry:(MetadataScanEntry *)entry
                               priority:(BOOL)priority
                                  token:(AudioFileMaterializationRequestToken *)token
                                 result:(VibeAudioFileMaterializationResult)result
                                  error:(NSError *)error
                                elapsed:(NSTimeInterval)elapsed {
    BOOL shouldParse = NO;
    BOOL didRequeue = NO;
    BOOL didScheduleDelayedRetry = NO;
    BOOL demoted = NO;
    BOOL satisfiesCurrentPriority = NO;
    NSTimeInterval retryDelay = 0;
    NSUInteger attempt = 0;
    NSString *attemptKey = entry.standardizedPath;

    // Off the lock (I/O): a requeued entry re-ranks on fresh locality, and the
    // yield triage below judges against this rule sample.
    entry.local = ![PlaceholderFiles isDatalessFile:entry.url];
    BOOL suspended = priority && result == VibeAudioFileMaterializationResultYielded
            && [_materializationCoordinator isForegroundTransferActive];
    os_unfair_lock_lock(&_materializationLock);
    if (![self settleMaterializationSlotForPriorityLocked:priority token:token]) {
        os_unfair_lock_unlock(&_materializationLock);
        return;
    }
    if (!self.isCancelled) {
        if (result == VibeAudioFileMaterializationResultReady) {
            shouldParse = YES;
            entry.yieldedUnderHold = NO;
            MetadataPriorityMark *mark = [self leadEntryWithItsMarkedRowLocked:entry];
            if (mark) {
                satisfiesCurrentPriority = YES;
                [_priorityMarks removeObjectForKey:mark.track.url];
                _scanOrderGeneration++;
            }
            if (attemptKey) {
                [_materializationAttemptsByPath removeObjectForKey:attemptKey];
            }
        }
        else if (priority && result == VibeAudioFileMaterializationResultYielded) {
            demoted = [self triageYieldedPriorityEntryLocked:entry suspended:suspended];
            didRequeue = YES;
        }
        else {
            NSUInteger priorAttempts = attemptKey
                    ? _materializationAttemptsByPath[attemptKey].unsignedIntegerValue : 0;
            VibeMetadataMaterializationRetry retry =
                    VibeMetadataMaterializationRetryForResult(
                            result, priorAttempts,
                            _materializationMaximumAttempts);
            if (retry != VibeMetadataMaterializationRetryNone) {
                if (retry == VibeMetadataMaterializationRetryDeferred
                        || retry == VibeMetadataMaterializationRetryDeferredAfterDelay) {
                    attempt = priorAttempts + 1;
                    entry.deferred = YES;
                    if (attemptKey) {
                        _materializationAttemptsByPath[attemptKey] = @(attempt);
                    }
                }
                if (retry == VibeMetadataMaterializationRetryDeferredAfterDelay) {
                    retryDelay = VibeMetadataAdmissionRetryDelay(priorAttempts);
                    [_delayedScanRetryEntries addObject:entry];
                    didScheduleDelayedRetry = YES;
                }
                else {
                    [_pendingMaterializations addObject:entry];
                    _scanOrderGeneration++;
                }
                didRequeue = YES;
            }
            else if (result == VibeAudioFileMaterializationResultFailed
                    || result == VibeAudioFileMaterializationResultAdmissionExhausted) {
                attempt = priorAttempts + 1;
                if (attemptKey) {
                    _materializationAttemptsByPath[attemptKey] = @(attempt);
                }
                // Exhausted (D7): the path and its priority mark are dropped
                // until a fresh loader.
                [self dropRecordsForExhaustedPathOfEntryLocked:entry];
            }
        }
    }
    os_unfair_lock_unlock(&_materializationLock);

    if (shouldParse) {
        BOOL userInitiatedParse = [self scheduleParseForEntry:entry
                                                 userInitiated:priority || satisfiesCurrentPriority];
        LogInfo(@"Metadata %@ materialized %@ in %.1fs",
                userInitiatedParse ? @"priority" : @"scan",
                entry.url.lastPathComponent, elapsed);
    }
    else if (result == VibeAudioFileMaterializationResultYielded) {
        LogInfo(@"Metadata %@ yielded %@ after %.1fs%@",
                priority ? @"priority" : @"scan",
                entry.url.lastPathComponent, elapsed,
                demoted ? @" — still dataless, left to the sweep" : @"");
    }
    else if (result == VibeAudioFileMaterializationResultFailed
            || result == VibeAudioFileMaterializationResultAdmissionExhausted) {
        if (didRequeue) {
            LogWarn(@"Metadata materialization failed for %@ "
                    @"(attempt %lu of %lu); re-queued last (%@)",
                    entry.url.lastPathComponent, (unsigned long)attempt,
                    (unsigned long)_materializationMaximumAttempts,
                    error.localizedDescription);
        }
        else {
            LogWarn(@"Metadata materialization failed for %@ and is out of attempts (%@)",
                    entry.url.lastPathComponent, error.localizedDescription);
        }
    }
    if (didScheduleDelayedRetry) {
        [self scheduleDelayedScanRetryForEntry:entry delay:retryDelay];
    }
    [self dispatchNextScanMaterialization];
}

// _materializationLock held. Frees the slot the completion's token held.
// Answers NO for a token the slot no longer holds, which settles nothing.
- (BOOL)settleMaterializationSlotForPriorityLocked:(BOOL)priority
                                             token:(AudioFileMaterializationRequestToken *)token {
    AudioFileMaterializationRequestToken *slotToken =
            priority ? _priorityMaterializationToken : _scanMaterializationToken;
    if (slotToken != token) {
        if (token) {
            [_liveMaterializationTokens removeObject:token];
        }
        return NO;
    }
    if (token) {
        [_liveMaterializationTokens removeObject:token];
    }
    if (priority) {
        _priorityMaterializationToken = nil;
        _priorityMaterializationInFlight = NO;
        _priorityMaterializationPath = nil;
    }
    else {
        _scanMaterializationToken = nil;
        _scanMaterializationInFlight = NO;
        _scanMaterializationPath = nil;
    }
    return YES;
}

// _materializationLock held. A priority record that yielded requeues at its
// rank. Answers whether its mark was demoted.
- (BOOL)triageYieldedPriorityEntryLocked:(MetadataScanEntry *)entry
                               suspended:(BOOL)suspended {
    BOOL demoted = NO;
    // Yield triage (MetadataRetryRules.h); spends no budget.
    VibeMetadataPriorityYieldOutcome outcome =
            VibeMetadataPriorityAfterYield(suspended, entry.local);
    MetadataPriorityMark *currentMark = [self priorityMarkForEntryLocked:entry];
    BOOL sameCurrentMark = currentMark != nil
            && currentMark.markGeneration == entry.priorityMarkGeneration;
    if (!sameCurrentMark) {
        // Carried an older mark: reactivate the newer edge once.
        entry.yieldedUnderHold = NO;
    }
    else {
        switch (outcome) {
            case VibeMetadataPriorityYieldWait:
                entry.yieldedUnderHold = YES;
                break;
            case VibeMetadataPriorityYieldRetry:
                entry.yieldedUnderHold = NO;
                break;
            case VibeMetadataPriorityYieldDemote:
                entry.yieldedUnderHold = NO;
                [_priorityMarks removeObjectForKey:currentMark.track.url];
                _scanOrderGeneration++;
                demoted = YES;
                break;
        }
    }
    [_pendingMaterializations addObject:entry];
    _scanOrderGeneration++;
    return demoted;
}

- (void)scheduleDelayedScanRetryForEntry:(MetadataScanEntry *)entry
                                   delay:(NSTimeInterval)delay {
    __weak __typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   _materializationCallbackQueue, ^{
        __typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        BOOL shouldDispatch = NO;
        os_unfair_lock_lock(&strongSelf->_materializationLock);
        if ([strongSelf->_delayedScanRetryEntries containsObject:entry]) {
            [strongSelf->_delayedScanRetryEntries removeObject:entry];
            if (!strongSelf.isCancelled) {
                [strongSelf->_pendingMaterializations addObject:entry];
                strongSelf->_scanOrderGeneration++;
                shouldDispatch = YES;
            }
        }
        os_unfair_lock_unlock(&strongSelf->_materializationLock);
        if (shouldDispatch) {
            [strongSelf dispatchNextScanMaterialization];
        }
    });
}

- (void)setNeighborhoodURLs:(NSArray<NSURL *> *)urls {
    os_unfair_lock_lock(&_materializationLock);
    _neighborhood = [urls copy] ?: @[];
    _neighborhoodGeneration++;
    _scanOrderGeneration++;
    os_unfair_lock_unlock(&_materializationLock);
    [self dispatchNextScanMaterialization];
}

#pragma mark - Priority marks

// _materializationLock held. The record not yet picked, pending or delayed,
// that holds the row; a row is in at most one.
- (MetadataScanEntry *)unpickedRecordHoldingTrackLocked:(AudioTrack *)track {
    for (MetadataScanEntry *record in _pendingMaterializations) {
        if ([record holdsTrack:track]) {
            return record;
        }
    }
    for (MetadataScanEntry *record in _delayedScanRetryEntries) {
        if ([record holdsTrack:track]) {
            return record;
        }
    }
    return nil;
}

// _materializationLock held. A record is priority while one of its rows is a
// mark's exact target. The marks are few, the rows can be many.
- (MetadataPriorityMark *)priorityMarkForEntryLocked:(MetadataScanEntry *)entry {
    for (MetadataPriorityMark *mark in _priorityMarks.objectEnumerator) {
        if ([entry holdsTrack:mark.track]) {
            return mark;
        }
    }
    return nil;
}

// _materializationLock held, on a picked record. The parse reads for the first
// row, so a failure hands its fallback to the row the user waits on rather
// than requeue it behind the file's other rows.
- (MetadataPriorityMark *)leadEntryWithItsMarkedRowLocked:(MetadataScanEntry *)entry {
    MetadataPriorityMark *mark = [self priorityMarkForEntryLocked:entry];
    if (mark && entry.tracks.firstObject != mark.track) {
        NSMutableArray<AudioTrack *> *tracks = [entry.tracks mutableCopy];
        [tracks removeObjectIdenticalTo:mark.track];
        [tracks insertObject:mark.track atIndex:0];
        entry.tracks = tracks;
    }
    return mark;
}

// _materializationLock held. Answers whether any mark was retired.
- (BOOL)retirePriorityMarksTargetingTracksLocked:(NSArray<AudioTrack *> *)tracks {
    if (_priorityMarks.count == 0) {
        return NO;
    }
    NSSet<NSURL *> *retired = [_priorityMarks keysOfEntriesPassingTest:
            ^BOOL(NSURL *url, MetadataPriorityMark *mark, BOOL *stop) {
        return [tracks indexOfObjectIdenticalTo:mark.track] != NSNotFound;
    }];
    if (retired.count == 0) {
        return NO;
    }
    [_priorityMarks removeObjectsForKeys:retired.allObjects];
    _scanOrderGeneration++;
    return YES;
}

- (void)retirePriorityMarksSatisfiedByTracks:(NSArray<AudioTrack *> *)tracks {
    os_unfair_lock_lock(&_materializationLock);
    BOOL retired = [self retirePriorityMarksTargetingTracksLocked:tracks];
    os_unfair_lock_unlock(&_materializationLock);
    if (retired) {
        [self dispatchNextScanMaterialization];
    }
}

// _materializationLock held. D7 is per path: a record minted beside the file's
// own must not buy another run from an exhausted ledger. A picked record
// settles on its own.
- (void)dropRecordsForExhaustedPathOfEntryLocked:(MetadataScanEntry * _Nonnull)entry {
    NSString *path = entry.standardizedPath;
    NSPredicate *samePath = [NSPredicate predicateWithBlock:
            ^BOOL(MetadataScanEntry *record, NSDictionary *bindings) {
        return [record.standardizedPath isEqualToString:path];
    }];
    NSArray<MetadataScanEntry *> *removed = [[_pendingMaterializations filteredArrayUsingPredicate:samePath]
            arrayByAddingObjectsFromArray:[_delayedScanRetryEntries filteredSetUsingPredicate:samePath].allObjects];
    NSMutableArray<AudioTrack *> *dropped = [entry.tracks mutableCopy];
    for (MetadataScanEntry *record in removed) {
        [dropped addObjectsFromArray:record.tracks];
        [_pendingMaterializations removeObjectIdenticalTo:record];
        [_delayedScanRetryEntries removeObject:record];
    }
    [_tracksWithScanInFlight minusSet:[NSSet setWithArray:dropped]];
    [self retirePriorityMarksTargetingTracksLocked:dropped];
    _scanOrderGeneration++;
}

- (void)abandonQueuedTrack:(AudioTrack *)track {
    if (!track) {
        return;
    }
    os_unfair_lock_lock(&_materializationLock);
    // Only a record not yet picked gives the row up; picked work settles it
    // normally. A record still in stage 1 is missed and costs at most one
    // transfer; its delivery no-ops.
    MetadataScanEntry *record = [self unpickedRecordHoldingTrackLocked:track];
    if (record) {
        NSMutableArray<AudioTrack *> *remaining = [record.tracks mutableCopy];
        [remaining removeObjectIdenticalTo:track];
        if (remaining.count > 0) {
            record.tracks = remaining;
        }
        else {
            [_pendingMaterializations removeObjectIdenticalTo:record];
            [_delayedScanRetryEntries removeObject:record];
        }
        _scanOrderGeneration++;
        // So an undo's prioritizeTrack: builds a fresh record.
        [_queuedTracks removeObject:track];
        [_tracksWithScanInFlight removeObject:track];
    }
    // A mark left on a removed row would hold its file's other records out of
    // the scan for good, since no record holds the row for the priority slot.
    BOOL retired = [self retirePriorityMarksTargetingTracksLocked:@[track]];
    os_unfair_lock_unlock(&_materializationLock);
    if (retired) {
        [self dispatchNextScanMaterialization];
    }
}

@end
