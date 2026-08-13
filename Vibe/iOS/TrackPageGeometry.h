//
//  TrackPageGeometry.h
//  Vibe (iOS)
//
//  The waveform-band geometry shared between TrackPageCell, which lays the
//  boxes out, and PlayerViewController, which mirrors the NOMINAL numbers to
//  place overlay chrome (the empty-state line) without constraining across
//  the cell boundary. One home, so the mirror cannot drift.
//

#import <CoreGraphics/CoreGraphics.h>

// The waveform strip, per orientation.
static const CGFloat kTrackPageWaveformHeight = 180;
static const CGFloat kTrackPageWaveformHeightLandscape = 120;

// The glass bar's slice of the safe area, which both layouts clear.
static const CGFloat kTrackPageBottomBarClearance = 56;

// Nominal distance from the safe bottom to the waveform strip's bottom: bar
// clearance + time row, plus centering slack in portrait, where the two-box
// stack floats and the waveform centers between the label block and the
// paused glyph. Landscape is bottom-anchored, so its inset is exact at
// standard text size; portrait's holds only where the centering puts it.
static const CGFloat kTrackPageWaveformBottomInset = 137;
static const CGFloat kTrackPageWaveformBottomInsetLandscape = 91;
