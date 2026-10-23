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
// A click on the title or the readout. The delegate switches the range.
- (void)pitchControlPanelDidClickHeader:(PitchControlPanel *)panel;
@end

// The strip on the window's right edge: a title, a live readout and the fader.
// Setting .pitch updates both without firing the delegate. A click on the
// title or the readout reports didClickHeader:. The app pushes the text, the
// formatter and the corner radius. It reads none of the app's settings.
@interface PitchControlPanel : NSView

@property (nullable, weak) id<PitchControlPanelDelegate> delegate;

@property (nonatomic) float pitch;

// Percent; the fader rescales and re-clamps.
@property (nonatomic) float maxPitch;

// The legend above the readout.
@property (nonatomic, copy) NSString *title;

// The fader's VoiceOver label.
@property (nonatomic, copy, nullable) NSString *faderAccessibilityLabel;

// The readout and the fader's spoken value, from the pitch in percent. With
// none, the readout is empty.
@property (nonatomic, copy, nullable) NSString *(^pitchFormatter)(double pitch);

// The right-edge corners' radius, the window's own.
@property (nonatomic) CGFloat cornerRadius;

@end

NS_ASSUME_NONNULL_END
