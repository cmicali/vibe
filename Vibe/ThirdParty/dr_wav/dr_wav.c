// AudioFileHandle supplies callbacks instead of stdio.
#define DR_WAV_IMPLEMENTATION
#define DR_WAV_NO_STDIO
// Upstream's 384 kHz refuses a 705.6 kHz file. 768 kHz is the fastest rate an
// output device runs.
#define DRWAV_MAX_SAMPLE_RATE 768000
#include "dr_wav.h"
