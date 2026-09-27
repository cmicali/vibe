//
//  PitchControlPanel.h
//  Vibe
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

// Width the main window grows by when the pitch panel is revealed.
extern const CGFloat kPitchPanelWidth;

@class PitchControlPanel;

// The fader inside is an implementation detail, so the panel is the sender.
@protocol PitchControlPanelDelegate <NSObject>
- (void)pitchControlPanel:(PitchControlPanel *)panel didChangePitch:(float)pitch;
// Once per gesture (mouse-up, double-click reset or an accessibility step),
// for work too heavy for every drag tick.
- (void)pitchControlPanelDidEndAdjusting:(PitchControlPanel *)panel;
@end

// The strip on the window's right edge: a title, a live readout and the fader.
// Setting .pitch updates both without firing the delegate.
@interface PitchControlPanel : NSView

@property (nullable, weak) id<PitchControlPanelDelegate> delegate;

@property (nonatomic) float pitch;

// Percent; the fader rescales and re-clamps. Keep in sync with
// AudioPlayer.maxPitch.
@property (nonatomic) float maxPitch;

@end

NS_ASSUME_NONNULL_END
