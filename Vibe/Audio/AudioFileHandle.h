//
//  AudioFileHandle.h
//  Vibe
//
//  One opened audio file. For reading: a descriptor this process owns,
//  CoreAudio's parser over it through AudioFileOpenWithCallbacks, and an
//  ExtAudioFile decoding it to PCM. For writing: an ExtAudioFile encoding PCM
//  into a file it creates. The surface is AVAudioFile's — the file's facts, a
//  cursor in file frames, reads from and writes of a PCM buffer — so the
//  player, the bus, the waveform loader, the converter and the test fixtures
//  share one class and one lifetime rule: the last reference disposes the
//  codec (or closes dr_flac or dr_wav), closes the parser and closes the
//  descriptor, in that order. A FAILED open leaks nothing, which is why no
//  preflight precedes it.
//
//  Reading facts are immutable after init; writing advances length. Cursor,
//  read, write and close operations belong to one consumer at a time (the
//  bus's decoder after a voice starts, AudioVoiceBus.h).
//
//  An MPEG file (MP1, MP2, MP3) is decoded by dr_mp3 instead of ExtAudioFile
//  unless Apple's is chosen, since Apple's MPEG decoder's only output is
//  16-bit integers: clipped at full scale and rounded without dither.
//  CoreAudio's parser still finds its packets, priming and length, so gapless
//  trims and durations are the ones every other reader sees.
//
//  A FLAC file is decoded by dr_flac, bit-identical to Apple's decode, which
//  it replaces for its cost and its seeks: Apple's scans the stream from its
//  start on the first seek into any part not yet read, and never uses the seek
//  table (docs/audio-quality.md). CoreAudio's parser answers the file's format
//  and layout and is then closed; dr_flac reads the stream through the
//  descriptor itself and answers its length, found from the last frames when
//  STREAMINFO leaves it unknown. The vendored copy carries fixes of its own
//  (ThirdParty/AGENTS.md).
//
//  A WAV or AIFF file is decoded by dr_wav the same way, when it holds a
//  coding dr_wav decodes (ThirdParty/AGENTS.md lists them).
//

#import <AVFAudio/AVFAudio.h>
#import <AudioToolbox/AudioToolbox.h>

NS_ASSUME_NONNULL_BEGIN

@interface AudioFileHandle : NSObject

// Opens for reading non-interleaved: AVAudioFile's standard processing format.
- (nullable instancetype)initForReading:(NSURL *)url error:(NSError * _Nullable __autoreleasing * _Nullable)error;

// Opens for reading, decoding to float32 at the file's rate, channels and
// layout, interleaved or not.
- (nullable instancetype)initForReading:(NSURL *)url
                            interleaved:(BOOL)interleaved
                                  error:(NSError * _Nullable __autoreleasing * _Nullable)error NS_DESIGNATED_INITIALIZER;
// Creates `url` (replacing any file there) as a `fileType` container holding
// `fileFormat` — PCM, or a codec with its rate, channels and, for FLAC, the
// source depth in its flags — encoded from buffers in `processingFormat`. The
// file is complete only once closeWithError: has returned YES.
- (nullable instancetype)initForWriting:(NSURL *)url
                               fileType:(AudioFileTypeID)fileType
                             fileFormat:(AVAudioFormat *)fileFormat
                       processingFormat:(AVAudioFormat *)processingFormat
                                  error:(NSError * _Nullable __autoreleasing * _Nullable)error NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

// Which decoder MPEG files opened from now on get: dr_mp3 (NO, the default;
// docs/audio-quality.md) or Apple's (YES). The mac's Settings > Advanced
// chooses; iOS keeps the default. A handle keeps the decoder it opened with.
@property (class, atomic) BOOL appleMPEGDecoder;
// "dr_mp3", "dr_flac", "dr_wav" or "apple", for the audio-path report.
@property (nonatomic, readonly) NSString *decoderName;
// YES for an MPEG file opened under the other appleMPEGDecoder choice than
// the current one: a handle opened before a change and handed on after it.
@property (nonatomic, readonly) BOOL decoderChoiceIsStale;

@property (nonatomic, readonly) NSURL *url;
// The file's own format: codec, native rate, channels, and for PCM the depth.
@property (nonatomic, readonly) AVAudioFormat *fileFormat;
// What reads deliver.
@property (nonatomic, readonly) AVAudioFormat *processingFormat;
// Logical decoded frames, encoder priming and padding excluded.
@property (nonatomic, readonly) AVAudioFramePosition length;
// Logical file frames. A refused seek leaves the cursor at the decoder's
// reported position; callers must stop that operation rather than assume it moved.
@property (nonatomic, readonly) AVAudioFramePosition framePosition;
- (BOOL)seekToFrame:(AVAudioFramePosition)frame error:(NSError * _Nullable * _Nullable)error;

// Reads up to `frameCount` frames (at most the buffer's capacity) at the
// cursor into `buffer`, whose format must be processingFormat, and sets its
// frameLength. Fewer frames than asked means the file ended: the read loops
// until the count is met or the decoder produces nothing. YES with zero frames
// is the end; NO is a decode or I/O failure with `error` set.
- (BOOL)readIntoBuffer:(AVAudioPCMBuffer *)buffer
            frameCount:(AVAudioFrameCount)frameCount
                 error:(NSError * _Nullable __autoreleasing * _Nullable)error;
// readIntoBuffer:frameCount:error: for the buffer's whole capacity.
- (BOOL)readIntoBuffer:(AVAudioPCMBuffer *)buffer error:(NSError * _Nullable __autoreleasing * _Nullable)error;

// Writing only: appends the buffer's frameLength frames, whose format must be
// processingFormat, and advances length by them.
- (BOOL)writeFromBuffer:(AVAudioPCMBuffer *)buffer error:(NSError * _Nullable __autoreleasing * _Nullable)error;
// Writing only: flushes the last packet and finishes the container; the
// status the encoder's end returns. Idempotent; dealloc closes silently.
- (BOOL)closeWithError:(NSError * _Nullable __autoreleasing * _Nullable)error;

@end

NS_ASSUME_NONNULL_END
