// dr_wav's one implementation unit. AudioFileHandle reads through its own
// callbacks, so stdio is not compiled. The switch changes neither the
// decoder's struct nor a function AudioFileHandle.m calls.
#define DR_WAV_IMPLEMENTATION
#define DR_WAV_NO_STDIO
#include "dr_wav.h"
