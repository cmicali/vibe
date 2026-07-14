//
//  MainPlayerController+Debug.h
//  Vibe
//
//  Extra surface for the debug command channel (Util/DebugUtil.mm) — internal
//  outlets re-declared so the state dump can read them. The accessors are the
//  ones synthesized by the class extension in MainPlayerController.m; there is
//  deliberately no @implementation for this category. Debug builds only.
//

#if DEBUG

#import "MainPlayerController.h"

@class SYFlatButton;
@class PitchControlPanel;
@class AudioWaveformView;

NS_ASSUME_NONNULL_BEGIN

@interface MainPlayerController (Debug)

@property (weak, readonly) SYFlatButton *nextButton;
@property (weak, readonly) SYFlatButton *playButton;
@property (weak, readonly) NSTextField *artistTextField;
@property (weak, readonly) NSTextField *titleTextField;
@property (weak, readonly) NSTextField *totalTimeTextField;
@property (weak, readonly) NSTextField *currentTimeTextField;
@property (weak, readonly) NSTextField *fileMetadataTextField;
@property (weak, readonly) AudioWaveformView *waveformView;

- (PitchControlPanel *)pitchPanel;
- (void)debugRefreshUI;

@end

NS_ASSUME_NONNULL_END

#endif
