//
//  AudioWaveformLoader.h
//  Vibe
//

#import <Foundation/Foundation.h>
#import "AudioWaveformObserver.h"

NS_ASSUME_NONNULL_BEGIN

// Kept a forward declaration (its header defines C++ classes): importing
// AudioWaveform.h here would force every transitive importer to compile as
// ObjC++ (same pattern as AudioWaveformCache.h).
@class CodableAudioWaveform;
@protocol AudioWaveformLoaderDelegate;

// What the decode pass computes beyond the waveform, since all of it rides
// one pass. Zero is none of it, which is what the tests get.
typedef struct {
    // The three bands' energies, which only 3-Band reads: four filters a
    // sample, so a decode skips them unless asked.
    BOOL bands;
    // What else rides the pass, each matched by its identifier.
    NSArray<AudioWaveformObserver *> *_Nullable observers;
} VibeWaveformAnalysis;

// Whether what a decode runs, or an entry holds, answers everything a request
// asks for: the bands, and a result for every observer it lists.
static inline BOOL VibeWaveformAnalysisCovers(BOOL bands, NSArray<NSString *> *identifiers, VibeWaveformAnalysis want) {
    if (want.bands && !bands) {
        return NO;
    }
    for (AudioWaveformObserver *observer in want.observers) {
        if (![identifiers containsObject:observer.identifier]) {
            return NO;
        }
    }
    return YES;
}

static inline NSArray<NSString *> *VibeWaveformObserverIdentifiers(VibeWaveformAnalysis analysis) {
    return [analysis.observers valueForKey:@"identifier"] ?: @[];
}

@interface AudioWaveformLoader : NSObject

@property (nullable, weak) id <AudioWaveformLoaderDelegate> delegate;

// Set before load:, like the window below.
@property (nonatomic) VibeWaveformAnalysis analysis;

- (instancetype)initWithDelegate:(id <AudioWaveformLoaderDelegate>)delegate;

// The decode finished. Set on the decode thread before the final delivery
// block reaches main (see AGENTS.md on why detach must still cover it), and
// the loader is not the only writer: the cache sets it on a disk hit, so the
// detached-loader pool treats a hit like a finished decode.
@property (atomic) BOOL isComplete;
@property (atomic) BOOL isCancelled;
// Superseded but still decoding: deliveries stop, the decode runs on and the
// cache persists the result for the next request. Set by detach, cleared by
// reattach when the same file is requested again mid-decode.
@property (atomic) BOOL isDetached;
// The claim this loader was started under, stamped by the cache: the file's
// standardized path, plus the window for a cue row, which the detached-loader
// pool is keyed on for reattachment.
@property (nullable, atomic, copy) NSString *claimKey;

// The window decoded, in CD frames as a VibePlayableItem carries it. The
// waveform and the analyzers see only it, at full resolution. 0 and 0, the
// default, is the whole file. Set before load:.
@property (atomic) NSUInteger cueStart;
@property (atomic) NSUInteger cueEnd;

// Reads blocks of the window into the waveform's detail at full resolution,
// as the mix, for deep zoom (WaveformCore's Detail). Skips blocks already
// held. Set the window first. NO when the file cannot be opened or read, or
// the loader was cancelled.
- (BOOL)loadDetailBlocks:(NSIndexSet *)blocks ofFile:(NSString *)filename
            intoWaveform:(CodableAudioWaveform *)waveform;

// Permanent, and it ends a streaming file's waits for bytes at once.
- (void)cancel;
- (void)detach;
- (void)reattach;
- (nullable CodableAudioWaveform *)load:(NSString *)filename;

@end

@protocol AudioWaveformLoaderDelegate <NSObject>

- (void)audioWaveformLoader:(AudioWaveformLoader*)loader waveform:(CodableAudioWaveform *)waveform didLoadData:(float)percentLoaded;

@end

NS_ASSUME_NONNULL_END
