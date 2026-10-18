//
//  AudioFileHandle.h
//  Vibe
//
//  One opened audio file. For reading: a descriptor this process owns and a
//  decoder over it. dr_flac, dr_wav and libvorbis parse their own containers,
//  and Vibe's MPEG open frames an MPEG file for dr_mp3. Any other file opens
//  CoreAudio's parser over the descriptor through AudioFileOpenWithCallbacks,
//  and an ExtAudioFile decodes it. For
//  writing: an ExtAudioFile encoding PCM into a file it creates. The surface
//  is AVAudioFile's — the file's facts, a cursor in file frames, reads from
//  and writes of a PCM buffer — so the player, the bus, the waveform loader,
//  the converter and the test fixtures share one class and one lifetime rule.
//  The last reference closes the decoder, then the parser, then the
//  descriptor. A FAILED open leaks nothing, which is why no preflight
//  precedes it. For an open with an `interrupted` block, the last
//  step runs later, on a serial queue of the handle's own. That step closes
//  the descriptor, or the parser opened by URL that holds one. A close can
//  wait on a network share's server. The owners of such handles let them go
//  on threads main waits on.
//
//  Reading facts are immutable after init, but for the length of a streaming
//  MP3 with no VBR header: estimated from its head's frames
//  (lengthIsEstimated), and settled by its decode (AudioFileHandle+MPEG.m).
//  Writing advances length. Cursor, read, write and close operations belong
//  to one consumer at a time (the bus's decoder after a voice starts,
//  AudioVoiceBus.h).
//
//  An MPEG file (MP1, MP2, MP3) is decoded by dr_mp3 instead of ExtAudioFile
//  unless Apple's is chosen. Apple's arm64 MPEG decoder outputs 16-bit
//  integers, clipped at full scale and rounded without dither. Its x86_64
//  decoder outputs float32 but still clips overs.
//  Under dr_mp3 the handle frames the stream itself. It states CoreAudio's
//  facts and length, except where CoreAudio is wrong (AudioFileHandle+MPEG.m).
//
//  A FLAC file is decoded by dr_flac, bit-identical to Apple's decode, which
//  it replaces for its cost and its seeks: Apple's scans the stream from its
//  start on the first seek into any part not yet read, and never uses the seek
//  table (docs/audio-quality.md). CoreAudio's parser opens it only when dr_flac
//  refuses it. dr_flac reads the stream through the handle's reads itself.
//  It states the file's format and layout as the parser would. It answers
//  the length, found from the last frames when STREAMINFO leaves it unknown. The vendored copy
//  carries fixes of its own (ThirdParty/AGENTS.md).
//
//  A WAV, W64, RF64 or AIFF file is decoded by dr_wav the same way, when it
//  holds a coding dr_wav decodes (ThirdParty/AGENTS.md lists them). The open
//  tells these containers and FLAC by the file's first bytes. A file dr_wav
//  refuses goes to CoreAudio's parser.
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
//  A file on a network mount reads ahead, when its opener can be
//  interrupted: a thread of the handle's own reads it into an availability
//  with no part file, and every read waits for its bytes there, as a
//  stream's does. The handle then holds no descriptor. A read the server
//  fails is retried until the handle goes. A dead server is then a wait,
//  never a failure. Its dealloc ends the thread once the thread's read
//  returns.
//

#import <AVFAudio/AVFAudio.h>
#import <AudioToolbox/AudioToolbox.h>

NS_ASSUME_NONNULL_BEGIN

// An `interrupted` that answers YES: an open that must never wait for a
// file's bytes. It fails at once where it would wait, and never reads ahead.
// Compared by identity.
FOUNDATION_EXPORT BOOL (^const VibeNeverWaitsForAStream)(void);

@interface AudioFileHandle : NSObject

// Opens CoreAudio's parser alone, with no decoder: the one open every reader
// of CoreAudio's verdict on a file shares. The reading inits open it for
// every file Vibe's decoders do not take, so it refuses what playback
// refuses (FLAC in Ogg). The files they take never open it.
// Only `url` and `parser` answer.
// `interrupted`, held only while the open runs, is asked whenever one of its
// waits for a streaming file's bytes would block, and YES fails the open with
// an interruption. A caller ends a blocked open from another thread by making
// it answer YES, then waking the file's waiters
// ([[CloudFileMaterializer availabilityForURL:url] wakeWaiters]).
// Only an open with an `interrupted` block reads ahead. A nil block, or
// VibeNeverWaitsForAStream, reads a network file directly.
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

// "dr_mp3", "dr_flac", "dr_wav", "libvorbis" or "apple", for the audio-path report.
@property (nonatomic, readonly) NSString *decoderName;

@property (nonatomic, readonly) NSURL *url;
// For property reads while the handle lives. NULL once one of Vibe's decoders
// has taken the file over, and for a writing handle.
@property (nonatomic, readonly, nullable) AudioFileID parser;
// On the opening thread: NO when the parser's kAudioFilePropertyInfoDictionary
// must not be read, for a CAF whose info chunk is absent, runs past the file
// or declares more entries than it can hold. YES for every other container.
// It reads as the parser does, so it may wait for a streaming file's bytes.
@property (nonatomic, readonly) BOOL infoDictionaryReadable;
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
// Any thread: length and lengthIsEstimated as one consistent pair, for a
// reader that needs both. The flag is read first, so NO pairs with the settled
// length; read the other way, a settle between the two showed a short
// estimate as exact.
- (AVAudioFramePosition)lengthEstimated:(BOOL *)estimated;
// On the reading thread: an estimated length made exact, waiting for the
// download to complete, interruptibly as any read does, then counting from
// disk. YES once exact, at once for a length that is; NO for an interruption
// or a transfer or packet-count failure. What a decode sized by a guess (the waveform
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

// A handle's waits, from any thread: interruptReads ends every wait for bytes
// in flight and to come, though not a read the bytes already here serve. The
// read or seek it ends answers NO with an interruption, the cursor is
// undefined, and reads answer the same until a seek after allowReads, which
// is called once that operation has returned. A read-ahead fetches only what
// a wait asks for in between. A whole file never waits.
- (void)interruptReads;
- (void)allowReads;
// YES for the error an interrupted read, seek or open answers.
+ (BOOL)isInterruption:(nullable NSError *)error;
// YES while the handle's reads wait for bytes a writer fetches: a stream's
// transfer or its own read-ahead. Fixed once open.
@property (nonatomic, readonly) BOOL waitsForBytes;
// Any thread, lock-free: YES while a read is blocked waiting for bytes, never
// for bytes already here.
@property (atomic, readonly) BOOL waitingForBytes;
// What the handle's writer has fetched so far. It only grows. It is the
// transfer's progress or the read-ahead's, and the size of a whole file. Any
// thread.
@property (nonatomic, readonly) uint64_t bytesWritten;
// Once, on the opening thread before the handle is shared: makes it one of
// its transfer's readers until dealloc, which keeps the transfer from being
// abandoned. The coordinator sends it to every handle it serves; the waveform
// loader's never is, so a waveform rides the play's stream and never holds it.
// A read-ahead fetches about 30 s of the file ahead instead
// (VibeReadAheadSpanBytes). It fetches ahead only while the plays' read-aheads
// sized before it are idle (VibeNetworkReadAheadSizePlay). A whole file
// ignores it.
- (void)holdStream;

// Writing only: appends the buffer's frameLength frames, whose format must be
// processingFormat, and advances length by them.
- (BOOL)writeFromBuffer:(AVAudioPCMBuffer *)buffer error:(NSError * _Nullable __autoreleasing * _Nullable)error;
// Writing only: flushes the last packet and finishes the container; the
// status the encoder's end returns. Idempotent; dealloc closes silently.
- (BOOL)closeWithError:(NSError * _Nullable __autoreleasing * _Nullable)error;

@end

NS_ASSUME_NONNULL_END
