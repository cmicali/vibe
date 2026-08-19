//
//  WaveformMidline.h
//  Vibe
//
//  The metrics of every non-waveform midline: the loading indicator's track,
//  filled head and shimmer band, and macOS's empty-state line.
//
//  The loading control and macOS empty line share a height and palette so they
//  cannot drift apart. The iOS empty state deliberately draws no line.
//
//  Nothing here draws beside a loaded waveform any more: the scrubber's
//  off-track baselines are gone, so a track showing its waveform shows no
//  midline at all.
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
// macOS empty-state line. It lands on the unplayed waveform's own baseline, so
// the loading track and arriving waveform read as one surface.
static const CGFloat kVibeInertMidlineAlpha = 0.275;

// The loading indicator's filled head, which fades to zero over its last few
// points so it meets the shimmer as a soft front rather than a hard cut.
static const CGFloat kVibeLoadingFillAlpha = 0.85;
