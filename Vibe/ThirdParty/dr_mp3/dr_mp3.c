// dr_mp3's one implementation unit. The float output is set here, beside the
// implementation it changes, rather than in project.yml: drmp3dec_decode_frame
// takes a void * either way, so a caller could not tell it wrote int16.
#define DR_MP3_IMPLEMENTATION
#define DR_MP3_FLOAT_OUTPUT
#define DR_MP3_NO_STDIO
#include "dr_mp3.h"
