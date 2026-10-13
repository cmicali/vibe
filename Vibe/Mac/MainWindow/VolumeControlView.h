//
//  VolumeControlView.h
//  Vibe
//

#import <Cocoa/Cocoa.h>

@class VibeSlider;

NS_ASSUME_NONNULL_BEGIN

// "Vol", the slider and the percentage, which fade and hide as one. It sizes
// its columns, renders the percentage and colors the slider.
// MainPlayerContentView places it, shadows its labels and decides its alpha
// and hidden flag (setControlsShown:animated:).
@interface VolumeControlView : NSView

// The slider's action is volumeChanged:, sent to target.
- (instancetype)initWithFrame:(NSRect)frame target:(id)target;

// The slider is on and the theme puts it in the top-right corner. There it
// swaps with the codec and BPM lines.
@property (class, readonly) BOOL atTopRight;

@property (readonly) NSTextField *label;
@property (readonly) VibeSlider *slider;
@property (readonly) NSTextField *percentLabel;

- (void)applyThemedLabelFonts;
- (void)applyThemedLabelColors;

// Sets the view's width and its columns. The origin is the caller's.
- (void)layoutColumns;

- (void)renderPercent;

// The slider's fill and knob from the theme's volumeBar and volumeKnob.
// The caller passes its appearance and the waveform's art color.
- (void)applyColorsDark:(BOOL)dark artworkColor:(nullable NSColor *)artworkColor;

@end

NS_ASSUME_NONNULL_END
