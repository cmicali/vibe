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
//  Reading facts are immutable after init, but for the length of a streaming
//  MP3 with no VBR header: estimated from its head's frames
//  (lengthIsEstimated), and settled by its decode (AudioFileHandle.m).
//  Writing advances length. Cursor, read, write and close operations belong
//  to one consumer at a time (the bus's decoder after a voice starts,
//  AudioVoiceBus.h).
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
//  A WAV, W64, RF64 or AIFF file is decoded by dr_wav the same way, when it
//  holds a coding dr_wav decodes (ThirdParty/AGENTS.md lists them); no file
//  of another container is offered it: WAVE (BWF among them), W64, RF64,
//  AIFF and AIFF-C, as the parser names them.
//
//  A file a remote transfer is still writing from byte 0
//  (CloudFileMaterializer's availabilityForURL:) is read from its part file
//  at its final size, and a read past the bytes written waits for them. A
//  wait ends in one of three ways: the bytes arrived; the transfer failed, a
//  read failure with its error; or it was interrupted, which is neither the
//  end nor a failure. Waits happen only on the reading thread, never the
//  render's. A handle that holdStream was sent is one of the transfer's
//  readers until its dealloc (CloudFileAvailability's addReader); one that
//  was not reads what the transfer writes and fails with it.
//

#import <AVFAudio/AVFAudio.h>
#import <AudioToolbox/AudioToolbox.h>

NS_ASSUME_NONNULL_BEGIN

@interface AudioFileHandle : NSObject

// Opens CoreAudio's parser alone, with no decoder: the one open every reader
// of CoreAudio's verdict on a file shares, the reading inits included, so it
// refuses what playback refuses (FLAC in Ogg). Only `url` and `parser` answer.
// `interrupted`, held only while the open runs, is asked whenever one of its
// waits for a streaming file's bytes would block, and YES fails the open with
// an interruption. A caller ends a blocked open from another thread by making
// it answer YES, then waking the file's waiters
// ([[CloudFileMaterializer availabilityForURL:url] wakeWaiters]).
- (nullable instancetype)initParserForReading:(NSURL *)url
                                  interrupted:(nullable BOOL (^)(void))interrupted
                                        error:(NSError * _Nullable __autoreleasing * _Nullable)error NS_DESIGNATED_INITIALIZER;
- (nullable instancetype)initParserForReading:(NSURL *)url error:(NSError * _Nullable __autoreleasing * _Nullable)error;

// Opens for reading, decoding to float32 non-interleaved at the file's rate,
// channels and layout — AVAudioFile's standard processing format.
- (nullable instancetype)initForReading:(NSURL *)url error:(NSError * _Nullable __autoreleasing * _Nullable)error;

// Opens for reading, decoding to float32 at the file's rate, channels and
// layout, interleaved or not.
- (nullable instancetype)initForReading:(NSURL *)url
                            interleaved:(BOOL)interleaved
                                  error:(NSError * _Nullable __autoreleasing * _Nullable)error;
// The same, interruptible as initParserForReading:interrupted:error: is.
- (nullable instancetype)initForReading:(NSURL *)url
                            interleaved:(BOOL)interleaved
                            interrupted:(nullable BOOL (^)(void))interrupted
                                  error:(NSError * _Nullable __autoreleasing * _Nullable)error;
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
// For property reads while the handle lives. NULL once dr_flac or dr_wav has
// taken the file over, and for a writing handle.
@property (nonatomic, readonly, nullable) AudioFileID parser;
// The file's own format: codec, native rate, channels, and for PCM the depth.
@property (nonatomic, readonly) AVAudioFormat *fileFormat;
// What reads deliver.
@property (nonatomic, readonly) AVAudioFormat *processingFormat;
// Logical decoded frames, encoder priming and padding excluded.
@property (nonatomic, readonly) AVAudioFramePosition length;
// Any thread: YES while length is a guess, a streaming MP3's with no VBR
// header, constant rate or not, until the decode settles it: at the first
// read once the download is complete, or where the reads reach the stream's
// end, whichever is first; or awaitExactLength: does. A guessed length is
// kept ahead of the cursor, a seek's included, so the reads run to the
// stream's true end, short or long of it, and grows as they pass it.
@property (nonatomic, readonly) BOOL lengthIsEstimated;
// On the reading thread: an estimated length made exact, waiting for the
// download to complete, interruptibly as any read does, then counting from
// disk. YES once exact, at once for a length that is; NO for an interruption
// or the transfer's failure. What a decode sized by a guess (the waveform
// loader's) checks before calling itself complete.
- (BOOL)awaitExactLength:(NSError * _Nullable __autoreleasing * _Nullable)error;
// Logical file frames. A refused seek leaves the cursor at the decoder's
// reported position; callers must stop that operation rather than assume it moved.
@property (nonatomic, readonly) AVAudioFramePosition framePosition;
- (BOOL)seekToFrame:(AVAudioFramePosition)frame error:(NSError * _Nullable * _Nullable)error;

// Reads up to `frameCount` frames (at most the buffer's capacity) at the
// cursor into `buffer`, whose format must be processingFormat, and sets its
// frameLength. Fewer frames than asked means the file ended: the read loops
// until the count is met or the decoder produces nothing. YES with zero frames
// is the end; NO is a decode or I/O failure with `error` set, or an
// interruption (+isInterruption:).
- (BOOL)readIntoBuffer:(AVAudioPCMBuffer *)buffer
            frameCount:(AVAudioFrameCount)frameCount
                 error:(NSError * _Nullable __autoreleasing * _Nullable)error;
// readIntoBuffer:frameCount:error: for the buffer's whole capacity.
- (BOOL)readIntoBuffer:(AVAudioPCMBuffer *)buffer error:(NSError * _Nullable __autoreleasing * _Nullable)error;

// A streaming handle's waits, from any thread: interruptReads ends every wait
// for bytes in flight and to come, though not a read the bytes on disk serve.
// The read or seek it ends answers NO with an interruption, the cursor is
// undefined, and reads answer the same until a seek after allowReads, which
// is called once that operation has returned. A whole file never waits.
- (void)interruptReads;
- (void)allowReads;
// YES for the error an interrupted read, seek or open answers.
+ (BOOL)isInterruption:(nullable NSError *)error;
// Any thread, lock-free: YES while a read is blocked waiting for a streaming
// file's bytes, never for bytes on disk.
@property (atomic, readonly) BOOL waitingForBytes;
// How much of a streaming file its transfer has written so far; the size of
// a whole file. Any thread.
@property (nonatomic, readonly) uint64_t bytesWritten;
// Once, on the opening thread before the handle is shared: makes it one of
// its transfer's readers until dealloc, which keeps the transfer from being
// abandoned. The coordinator sends it to every handle it serves; the waveform
// loader's never is, so a waveform rides the play's stream and never holds it.
// A whole file ignores it.
- (void)holdStream;

// Writing only: appends the buffer's frameLength frames, whose format must be
// processingFormat, and advances length by them.
- (BOOL)writeFromBuffer:(AVAudioPCMBuffer *)buffer error:(NSError * _Nullable __autoreleasing * _Nullable)error;
// Writing only: flushes the last packet and finishes the container; the
// status the encoder's end returns. Idempotent; dealloc closes silently.
- (BOOL)closeWithError:(NSError * _Nullable __autoreleasing * _Nullable)error;

@end

NS_ASSUME_NONNULL_END
