//
//  WaveformMidline.h
//  Vibe
//
//  The metrics of every non-waveform midline: the loading indicator's track,
//  filled head and shimmer band, the empty state's static line, and the iOS
//  scrubber's off-track baselines.
//
//  THEY ARE ONE ELEMENT IN DIFFERENT STATES, so they share a height and a
//  palette and cannot drift apart. That claim used to be made by a Mac-only
//  private header, which is exactly how the iOS scrubber came to draw its
//  placeholder at 2pt while drawing its own baselines at 1pt, and its shimmer
//  half again as bright as the mac's. Both views read these now.
//

#import <CoreGraphics/CoreGraphics.h>

// A whole point keeps the line on device pixels at any backing scale: a
// half-point height would centre at a half pixel and render soft, which on a
// hairline reads as a dimmer line rather than a thinner one.
static const CGFloat kVibeMidlineHeight = 1;

// What an unplayed waveform bar is actually worth on screen: the renderer
// family's 0.5 gradient top under its 0.75 layer opacity. The loading shimmer
// peaks here so the waveform arriving over it is the same brightness rather
// than a step down from a brighter placeholder.
static const CGFloat kVibeUnplayedWaveformAlpha = 0.375;

// The inert midline, shared by the loading indicator's unfilled track and the
// empty state's static line. It lands on the unplayed waveform's own baseline,
// the midline the short bars sit on, so the two read as one surface when the
// waveform replaces it.
static const CGFloat kVibeInertMidlineAlpha = 0.275;

// The loading indicator's filled head, which fades to zero over its last few
// points so it meets the shimmer as a soft front rather than a hard cut.
static const CGFloat kVibeLoadingFillAlpha = 0.85;
