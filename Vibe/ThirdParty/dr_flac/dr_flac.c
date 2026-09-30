// dr_flac's one implementation unit. AudioFileHandle reads through its own
// callbacks and Vibe plays no Ogg FLAC, so neither stdio nor Ogg is compiled.
// Neither switch changes the decoder's struct or a function AudioFileHandle.m
// calls.
#define DR_FLAC_IMPLEMENTATION
#define DR_FLAC_NO_STDIO
#define DR_FLAC_NO_OGG
#include "dr_flac.h"
