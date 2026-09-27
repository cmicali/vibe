//
//  VibeFakeCloud.h
//  Vibe
//
//  A stand-in file provider for stress runs: chosen files answer as
//  placeholders, each takes a fixed time to "download", and a cancelled
//  download leaves the file a placeholder. A real provider is slow,
//  nondeterministic and needs an account, and placeholders cannot be staged by
//  hand, so the three chokepoints are injected instead (NSURLUtil's dataless
//  probe, CloudFileMaterializer's transfer, DownloadProgressMonitor's
//  reporting) and everything above them runs unchanged. It tests the app's
//  download ordering, not NSFileCoordinator's cancellation.
//

#if DEBUG

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Hashed is the stress default: chunked steps, a third of files stalling
// partway. The rest are deterministic scripts for ordering and timeout tests.
typedef NS_ENUM(NSInteger, VibeFakeCloudProgressMode) {
    VibeFakeCloudProgressHashed = 0,
    VibeFakeCloudProgressNone,     // no fraction ever: the no-progress provider
    VibeFakeCloudProgressLinear,   // exact elapsed/total, continuous
    VibeFakeCloudProgressSparse,   // linear, but the answer only moves every 10s
    VibeFakeCloudProgressStall,    // linear to 40%, then motionless for good
};

@interface VibeFakeCloud : NSObject

// percent of the corpus reads as placeholders, chosen by a stable path hash.
// transferSeconds is the base: each file's time is spread 0.5x to 2x around it
// by the same hash, with one file in ten ~18x and one in fifty stuck past the
// player's open timeout. Installing again resets the scenario and forgets what
// had materialized, but keeps the completed/cancelled tally.
+ (void)installWithTransferSeconds:(NSTimeInterval)transferSeconds
                   datalessPercent:(NSUInteger)percent;

// Fault injection: files stay placeholders however often they download, so
// every current-track retry skips the parse and the playing track's tags wait
// for the sweep. The probe replaces isDatalessFile:, so this cannot exercise
// the real stat path; it proves the oracle fires on the condition. Install
// resets to NO.
+ (void)setStickyDataless:(BOOL)sticky;

// At most capacity transfers run at once and the rest queue, so a background
// download genuinely delays a foreground one. 0 is unlimited. Install resets
// to 1.
+ (void)setTransferCapacity:(NSUInteger)capacity;

// Every file takes exactly the base transferSeconds, for ordering assertions
// that must not fight the hash. Install resets to NO.
+ (void)setUniformDurations:(BOOL)uniform;

// Install resets to Hashed.
+ (void)setProgressMode:(VibeFakeCloudProgressMode)mode;

// Placeholders carrying no SF_DATALESS, the provider shape isDatalessFile:'s
// comment predicts: the probe answers NO while transfers still block, so lane
// routing sees "local" files that still cost a download. Install resets to NO.
+ (void)setUnflaggedPlaceholders:(BOOL)unflagged;

// Transfers of this basename run to term, then fail: the provider-error
// shape, which spends the metadata retry budget. nil clears.
+ (void)setFailingBasename:(NSString * _Nullable)basename;

// Restores the real dataless test and the real coordinated read.
+ (void)uninstall;

+ (BOOL)isInstalled;

// The run's tally, for the health oracle. metadataOverlapTransfers, the name
// cloud-scenarios.py reads, counts any transfer of a file another transfer
// already was downloading, whatever the roles; path-wide single-flight
// ownership keeps it at zero. foregroundContentionStarts counts
// metadata downloads that began while a playback or prefetch download ran:
// the foreground hold's job as a number.
+ (NSDictionary *)statistics;

// One entry per transfer event (requested, started, completed, cancelled,
// overlap, contention) with its sequence, time since install, role and file,
// so ordering tests need not infer order from elapsed time. Bounded; oldest
// dropped.
+ (NSArray<NSDictionary *> *)traceEvents;
+ (void)clearTrace;

@end

NS_ASSUME_NONNULL_END

#endif
