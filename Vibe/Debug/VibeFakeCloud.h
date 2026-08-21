//
//  VibeFakeCloud.h
//  Vibe
//
//  A stand-in file provider for stress runs: chosen files answer as
//  placeholders, each takes a fixed time to "download", and a cancelled
//  download leaves the file a placeholder exactly as a real one does.
//
//  It exists because the cloud path is otherwise untestable at any useful
//  rate. A real provider is seconds per file, non-deterministic, and needs a
//  network and an account; and the placeholders themselves cannot be staged by
//  hand, since SF_DATALESS belongs to the dataless-file machinery and a file
//  merely carrying the flag would not block on read. So the three chokepoints
//  are injected instead — NSURLUtil's dataless probe, CloudFileMaterializer's
//  transfer, and DownloadProgressMonitor's reporting of it — and everything
//  above them runs unchanged: the same cloud lane, the same hold, the same
//  ranking, the same abandoned opens, the same loading indicator.
//
//  The progress side is not decoration. Under the fake the file on disk is
//  genuinely local, so the monitor's real allocated-size poll reports a final
//  100% on its first tick and cancels itself — a full fill before the transfer
//  has moved. Standing in for it is what makes the determinate half of the
//  indicator observable at all; see DownloadProgressMonitor+Debug.h.
//
//  What it does NOT test is NSFileCoordinator's own cancellation semantics,
//  which are Apple's and are exercised on a device instead. What it does test
//  is this app's ordering: which download runs next, which is abandoned, what
//  is re-queued, and whether anything is left stranded.
//
//  Debug builds only, like everything in this directory.
//

#if DEBUG

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// What the fake progress source reports while a transfer runs. Hashed is the
// stress default: per-path speeds, chunked steps, a third of files stalling
// partway. The rest are deterministic scripts for ordering and timeout tests.
typedef NS_ENUM(NSInteger, VibeFakeCloudProgressMode) {
    VibeFakeCloudProgressHashed = 0,
    VibeFakeCloudProgressNone,     // no fraction ever: the no-progress provider
    VibeFakeCloudProgressLinear,   // exact elapsed/total, continuous
    VibeFakeCloudProgressSparse,   // linear, but the answer only moves every 10s
    VibeFakeCloudProgressStall,    // linear to 40%, then motionless for good
};

@interface VibeFakeCloud : NSObject

// Installs the probe and the transfer. percent is how much of the corpus reads
// as a placeholder, decided per path by a stable hash so a seeded run picks the
// same files every time; 100 makes the whole corpus cloud. transferSeconds is
// what one download costs. Installing again re-arms from scratch, forgetting
// what had materialized.
// transferSeconds is the BASE, not the answer: each file gets its own time
// from a stable hash of its path, spread 0.5x to 2x around it, with a tail
// that is the point of the whole thing — one file in ten is ~18x (slow enough
// that a listener gives up mid-transfer, which is what puts a cancel inside a
// download rather than between two) and one in fifty is effectively stuck,
// long enough to outlast the player's own open timeout. Nothing else in the
// app reaches that timeout.
+ (void)installWithTransferSeconds:(NSTimeInterval)transferSeconds
                   datalessPercent:(NSUInteger)percent;

// Fault injection: a file that stays a placeholder however often it is
// downloaded. It reproduces the SHAPE of the worst bug this machinery has had
// — a dataless test that keeps answering YES after the file has arrived, so
// every retry in the current-track lane skips the parse and the playing
// track's tags and art wait for the background sweep instead.
//
// It exists because the seam cannot reproduce that bug honestly: the probe
// REPLACES isDatalessFile:, so the real stat-and-resource-value path, where
// the fault actually lived, is not even reached under the fake. What this can
// still do is prove the oracle fires on the condition, which is the half that
// matters for keeping it from silently rotting.
+ (void)setStickyDataless:(BOOL)sticky;

// The provider's scarce resource, made explicit: at most capacity transfers
// run at once and the rest queue, so a background download genuinely delays a
// foreground one. Install resets to one; 0 explicitly selects unlimited
// capacity.
+ (void)setTransferCapacity:(NSUInteger)capacity;

// Every file takes exactly the base transferSeconds: no spread, no slow or
// stuck tail. For ordering assertions that must not fight the hash. Install
// resets it to NO.
+ (void)setUniformDurations:(BOOL)uniform;

// See VibeFakeCloudProgressMode. Install resets to Hashed.
+ (void)setProgressMode:(VibeFakeCloudProgressMode)mode;

// The provider shape NSURLUtil.m:98-102 predicts and nothing else can stage:
// placeholders carrying no SF_DATALESS. The dataless probe answers NO for
// every file while their transfers still block, so lane routing sees "local"
// against files that still cost a download. Install resets to NO.
+ (void)setUnflaggedPlaceholders:(BOOL)unflagged;

// Transfers of this exact basename run to term and then report failure — the
// provider-error shape, which spends the metadata retry budget. nil clears.
+ (void)setFailingBasename:(NSString * _Nullable)basename;

// Restores the real dataless test and the real coordinated read.
+ (void)uninstall;

+ (BOOL)isInstalled;

// The run's tally, for the health oracle: completed are the downloads that ran
// to term, cancelled those a hold or a newer play cut short. Both are counted
// at the transfer rather than at the probe, which is asked at sites that never
// download. Also carries the live queued/executing counts, the maximum
// concurrency the run has observed, and metadataOverlapTransfers — how many
// times metadata downloaded a file another role was already downloading.
// Path-wide single-flight ownership keeps that at zero; it shows up in no
// other counter, since both transfers can otherwise complete.
// foregroundContentionStarts is the foreground hold's job stated as a number —
// metadata downloads that BEGAN while a playback download was still running.
+ (NSDictionary *)statistics;

// The bounded admission trace: one entry per transfer event — requested,
// started (with its queued milliseconds), completed, cancelled — each carrying
// a sequence number, milliseconds since install, the caller's role (playback,
// prefetch, metadata), and the file. Ordering tests assert on this rather than
// inferring order from elapsed time. Capped; oldest entries fall off.
+ (NSArray<NSDictionary *> *)traceEvents;
+ (void)clearTrace;

@end

NS_ASSUME_NONNULL_END

#endif
