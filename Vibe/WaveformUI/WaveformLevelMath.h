//
//  WaveformLevelMath.h
//  Vibe
//
//  The chunk-to-level mapping every bar style draws from, and the one gain
//  setting that bends it. Header-only and Foundation-free so the mapping is
//  testable without the renderer headers' C++ and Core Animation imports.
//

#import <math.h>

// The drawn level for a bar, from its chunk's energy rather than its peaks.
// Peak min/max pegs on limited dance masters — at Basic's pitch every bar
// covers seconds of audio, so each one contains a full-scale transient and
// the whole strip reads as a solid block — while RMS still varies through
// drops and breakdowns. Full height is kVibeWaveformFullScaleRMS (-9 dBFS
// RMS — a loud club master's sustained level fills the band); anything
// hotter clamps.
static const float kVibeWaveformFullScaleRMS = 0.35f;

// Settings > Appearance > Waveform > Gain, in dB, is two things at once. It
// is a display gain ahead of the full-scale clamp: up, and the waveform
// grows into the ceiling as a louder master would; down, and it shrinks,
// which is what lets a pegged master show its few dB of variation. And it
// bends the curve in the same direction, by an exponent that doubles per
// this many dB down and halves per as many up: down expands, spreading a
// loud track's variation over more of the band than the gain alone would;
// up compresses, lifting the quiet passages toward the ceiling with the
// rest, the way a limiter reads. 0 dB is the plain mapping.
static const float kVibeWaveformGainDBPerExponentDoubling = 24.0f;

// fullScaleRMS is the RMS that draws full height at 0 dB:
// kVibeWaveformFullScaleRMS, or under Settings > Appearance > Waveform >
// Normalize the track's own loudest energy column, so every track fills the
// band whatever its master's level and only the gain decides what pegs. The
// reference scales the level; the gain alone bends the curve.
static inline float VibeWaveformBarLevel(float meanSquare, float fullScaleRMS, float gainDB) {
    float gain = powf(10.0f, gainDB / 20.0f);
    float exponent = exp2f(-gainDB / kVibeWaveformGainDBPerExponentDoubling);
    float level = sqrtf(fmaxf(meanSquare, 0.0f)) / fullScaleRMS * gain;
    return fminf(powf(level, exponent), 1.0f);
}
