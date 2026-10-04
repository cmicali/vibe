//
//  AudioWaveformLoader.h
//  Vibe
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Kept a forward declaration (its header defines C++ classes): importing
// AudioWaveform.h here would force every transitive importer to compile as
// ObjC++ (same pattern as AudioWaveformCache.h).
@class CodableAudioWaveform;
@protocol AudioWaveformLoaderDelegate;

// What the decode pass computes beyond the waveform, since all of it rides
// one pass. Zero is none of it, which is what the tests get.
typedef struct {
    BOOL bpm;
    BOOL key;
    // The three bands' energies, which only 3-Band reads: four filters a
    // sample, so a decode skips them unless asked.
    BOOL bands;
} VibeWaveformAnalysis;

// Whether what a decode has (or ran) answers everything a request asks for.
static inline BOOL VibeWaveformAnalysisCovers(VibeWaveformAnalysis have, VibeWaveformAnalysis want) {
    return (!want.bpm || have.bpm) && (!want.key || have.key) && (!want.bands || have.bands);
}

@interface AudioWaveformLoader : NSObject

@property (nullable, weak) id <AudioWaveformLoaderDelegate> delegate;

// Set before load:, like the window below.
@property (atomic) VibeWaveformAnalysis analysis;

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

// The window decoded, in CD frames as AudioTrack carries it: the waveform and
// the analyzers see only it, at full resolution. 0 and 0, the default, is
// the whole file. Set before load:.
@property (atomic) NSUInteger cueStart;
@property (atomic) NSUInteger cueEnd;

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
