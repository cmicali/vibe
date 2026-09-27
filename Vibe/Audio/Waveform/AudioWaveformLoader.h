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

// Which analyzers the decode pass should run, since both ride it. A provider
// rather than a stored pair because it is asked once per load, so a settings
// change applies to the next decode with nobody republishing it; and this
// layer must not reach into a settings singleton it cannot be tested without.
//
// UNSET MEANS NEITHER RUNS: what iOS, which does not analyze, and the tests
// get.
typedef struct {
    BOOL bpm;
    BOOL key;
} VibeWaveformAnalysis;

typedef VibeWaveformAnalysis (^VibeWaveformAnalysisProvider)(void);

@interface AudioWaveformLoader : NSObject

@property (nullable, weak) id <AudioWaveformLoaderDelegate> delegate;

// Asked once per load:, on whatever queue the decode runs on.
@property (nullable, copy) VibeWaveformAnalysisProvider analysisProvider;

- (instancetype)initWithDelegate:(id <AudioWaveformLoaderDelegate>)delegate;

// The decode finished. Set on the decode thread before the final delivery
// block reaches main (see CLAUDE.md on why detach must still cover it), and
// the loader is not the only writer: the cache sets it on a disk hit, so the
// detached-loader pool treats a hit like a finished decode.
@property (atomic) BOOL isComplete;
@property (atomic) BOOL isCancelled;
// Superseded but still decoding: deliveries stop, the decode runs on and the
// cache persists the result for the next request. Set by detach, cleared by
// reattach when the same file is requested again mid-decode.
@property (atomic) BOOL isDetached;
// The path this loader decodes, stamped by the cache when it starts the
// load; the detached-loader pool is keyed on it for reattachment.
@property (nullable, atomic, copy) NSString *trackPath;

- (void)cancel;
- (void)detach;
- (void)reattach;
- (nullable CodableAudioWaveform *)load:(NSString *)filename;

@end

@protocol AudioWaveformLoaderDelegate <NSObject>

- (void)audioWaveformLoader:(AudioWaveformLoader*)loader waveform:(CodableAudioWaveform *)waveform didLoadData:(float)percentLoaded;

@end

NS_ASSUME_NONNULL_END
