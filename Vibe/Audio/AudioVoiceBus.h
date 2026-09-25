//
//  AudioVoiceBus.h
//  Vibe
//
//  Vibe's own playback core: decode, ring, gain and mix, feeding the render
//  pipeline. A VOICE is one file being rendered — a decoder filling a
//  ring buffer, a gain with at most one pending ramp, an optional queued
//  successor file that continues gaplessly at the boundary. The bus mixes
//  every live voice into the buffers the master bus's render hands it
//  (AudioPlayer+Pipeline.h).
//
//  The transport (AudioPlayer) never waits on the bus. It starts a voice,
//  ramps it, retires it, and learns three things back through the drain it
//  runs itself: a voice WENT LIVE (its first frames are buffered), it PASSED
//  ITS BOUNDARY into the queued successor, or it ENDED (its stream ran out, or
//  a retire ramp landed). Every fade exists only to keep the output free of
//  clicks; the bus evaluates the curve per frame on the audio thread and the
//  transport asks for nothing finer than "fade to this gain over this many
//  frames, then pause or die".
//
//  Threading — three parties, one owner per fact:
//
//  - The PLAYER QUEUE calls every method here except snapshotOfVoice:. It
//    allocates slots, submits ramps, queues successors, drains events.
//  - The DECODE QUEUE (a serial queue the bus owns; inline on the player queue
//    under the frame-driven test pump) reads the files and writes the rings.
//    It is the only thing that touches an AudioFileHandle after startVoice.
//  - The AUDIO THREAD runs VibeVoiceBusRender: plain memory and atomics, no
//    lock, allocation, Objective-C or dispatch call — the compiler enforces
//    that (-Wfunction-effects on the CA_REALTIME_API function). It never
//    signals anyone; the queue polls.
//
//  A slot's state moves free → armed → live → dead → free. The queue does
//  free→armed and armed→dead; the decoder does armed→live; ONLY the audio
//  thread does live→dead, when the stream ends or a retire ramp lands (a kill
//  is a retire of zero frames, applied before any mixing). dead→free runs on
//  the decode queue after the audio thread has completed a render past the
//  death, so no reader or writer can be inside the slot when it is recycled.
//  Slot memory is allocated once and owned by the bus for its life; the
//  master bus retires a bus only once no render is inside it.
//
//  Bit-perfect output permits the transport's chosen declick ramps; with
//  declick disabled those edges are cuts.
//

#import <AVFoundation/AVFoundation.h>
#import "FadeMath.h"

@class AudioFileHandle;

NS_ASSUME_NONNULL_BEGIN

// Identifies one voice for its whole life; 0 is no voice. A stale id never
// addresses a reused slot.
typedef uint64_t VibeVoiceID;

typedef NS_ENUM(int32_t, VibeVoiceState) {
    VibeVoiceStateNone = 0,   // no such voice, or already recycled
    VibeVoiceStateArmed,      // allocated, or pending a slot; the decoder is filling it
    VibeVoiceStateLive,       // the audio thread mixes it
    VibeVoiceStateDead,       // ended; awaiting recycle
};

typedef NS_ENUM(int32_t, VibeVoiceAction) {
    VibeVoiceActionNone = 0,
    VibeVoiceActionPause,     // at landing, stop consuming; a newer ramp resumes
    VibeVoiceActionRetire,    // at landing, die
};

typedef NS_ENUM(int32_t, VibeVoiceEnd) {
    VibeVoiceEndNone = 0,
    VibeVoiceEndOfStream,     // every frame of the file (and successor) was rendered
    VibeVoiceEndRetired,      // a retire ramp landed
    VibeVoiceEndFailed,       // seek, read or conversion failed; errorOfVoice:failedFile: before recycling
};

typedef NS_ENUM(NSInteger, VibeVoiceEvent) {
    VibeVoiceEventLive,       // first frames buffered; rendering can begin
    VibeVoiceEventBoundary,   // the successor is now sounding
    VibeVoiceEventEnded,      // see VibeVoiceSnapshot.ended
};

typedef struct {
    float target;             // 0..1
    uint32_t frames;          // 0 = a cut, applied before the next mixed frame
    VibeFadeCurve curve;
    VibeVoiceAction action;
} VibeVoiceRamp;

static inline VibeVoiceRamp VibeVoiceRampMake(float target, uint32_t frames, VibeFadeCurve curve, VibeVoiceAction action) {
    VibeVoiceRamp ramp = { target, frames, curve, action };
    return ramp;
}

// The same channels: the width, and, wider than stereo, the order the
// layout names. A layout on a mono or stereo format says nothing the width
// does not.
static inline BOOL VibeChannelsMatch(AVAudioFormat *a, AVAudioFormat *b) {
    return a.channelCount == b.channelCount
            && (a.channelCount <= 2 || a.channelLayout == b.channelLayout || [a.channelLayout isEqual:b.channelLayout]);
}

// The same delivery: rate, sample format, and channels. What the bus reads a
// file direct by, what the transport splices by, what the graph keeps a bus by.
static inline BOOL VibeFormatsMatch(AVAudioFormat *a, AVAudioFormat *b) {
    return a.sampleRate == b.sampleRate && a.commonFormat == b.commonFormat && a.isInterleaved == b.isInterleaved
            && VibeChannelsMatch(a, b);
}

// A coherent read of one voice. Frame counters are relative to the voice's
// start: `consumed` is what the audio thread has rendered, `boundary` where
// the successor began (UINT64_MAX until it has), `endOfStream` the stream's
// length once known. The stamp is the audio thread's timestamp for the first
// frame consumed after a start or resume; hostTime is valid only on hardware.
typedef struct {
    VibeVoiceState state;
    BOOL paused;
    VibeVoiceEnd ended;
    uint64_t consumed;
    uint64_t written;
    uint64_t boundary;
    uint64_t endOfStream;
    uint64_t underrunFrames;
    float gain;               // the audio thread's current gain, as last written; exact once a ramp has landed
    AudioTimeStamp startOfConsumption;
} VibeVoiceSnapshot;

// The audio thread's view of the bus: the slots and their rings.
typedef struct VibeVoiceMix VibeVoiceMix;

@interface AudioVoiceBus : NSObject

// busFormat is the bus's format for its life: float32, non-interleaved.
// Every file is delivered in it — converted on the decode queue when its own
// format differs, a wider or narrower file mixed by layout as a mixer would.
// inlineDecoding is the frame-driven test pump's mode: no decode queue
// exists, fillInline does every read on the caller's thread, and the ring
// keeps one producer. queue is the player queue, where voiceWentLive and
// every method here run.
- (instancetype)initWithFormat:(AVAudioFormat *)busFormat
                         queue:(dispatch_queue_t)queue
                inlineDecoding:(BOOL)inlineDecoding NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, readonly) AVAudioFormat *format;
@property (nonatomic, readonly) BOOL inlineDecoding;
// What VibeVoiceBusRender reads; valid for the bus's life.
- (VibeVoiceMix *)mix;
// Called on the queue when a voice goes live off the decode queue, so the
// player can drain promptly rather than at its next poll.
@property (nonatomic, copy, nullable) dispatch_block_t voiceWentLive;

// Starts rendering `file` from `frame` (file frames) at `gain`, with `ramp`
// pending — or paused, which carries no ramp: the first ramp set later is the
// resume. quantizeToInt16 asks for one final rounding after conversion to the bus
// format. The file is read in its processing format. A decode failure ends
// the voice through VibeVoiceEndFailed; read errorOfVoice:failedFile: inside
// the ended handler. Allocation always returns an id: a full pool cuts its
// oldest retiring voice, and a start that still finds no slot is pending
// until the drain frees one. Returns the voice's id.
- (VibeVoiceID)startVoiceWithFile:(AudioFileHandle *)file
                          atFrame:(AVAudioFramePosition)frame
                     quantizeToInt16:(BOOL)quantizeToInt16
                             gain:(float)gain
                             ramp:(VibeVoiceRamp)ramp
                           paused:(BOOL)paused;

// Replaces the pending ramp and its action. Adopting a ramp un-pauses.
- (void)setRamp:(VibeVoiceRamp)ramp forVoice:(VibeVoiceID)voice;

// The voice reads no more of its file, so the file may be handed to another
// voice. For a declick-length retire; a crossfade-length retire keeps reading.
- (void)stopReadingForVoice:(VibeVoiceID)voice;

// Ends the bus's reading for good: every voice reads no more, and
// `decoderLeft` runs on the bus's queue once the decoder has left every file
// — the turn inside a read finishes on its own, however long a stalled mount
// makes that, and none after it reads — so the files may then be handed to a
// replacement bus; at once when decoding inline. Nothing is asked of the bus
// after it. TRAP: never a synchronous join: a read on a stalled mount held
// the player queue, and every transport command behind it, for its whole
// stall, and a bounded join would have handed the file's cursor to a second
// decoder while the first was still inside it.
- (void)stopReadingThen:(dispatch_block_t)decoderLeft;

// Every file a decoder of this bus may still be inside: each voice's, each
// queued successor's, a pending start's. Player queue.
- (NSSet<AudioFileHandle *> *)filesInUse;

// A file a retired bus's decoder may still be inside: a voice started on it
// reads nothing until allowReadsOfFile: says that decoder has left it, and a
// successor queued on it is refused until then, so two decoders never move
// one file's cursor. Player queue.
- (void)withholdReadsOfFile:(AudioFileHandle *)file;
- (void)allowReadsOfFile:(AudioFileHandle *)file;

// Queues `file` to continue at the voice's end without a gap. A successor
// read the same way as the file before it continues through the same
// converter, so a resampler carries across the boundary; a converter stays
// open past its file until the render nears the end, so a successor named
// late still continues it. A voice whose stream's end was declared still
// takes one while it is live: the decoder reopens the stream at the old end
// with a converter of its own, unless the audio thread reached the end
// first, in which case the voice ends as it would have and the successor
// never begins. NO for a dead voice, one retired at declick length, or one
// already continuing.
- (BOOL)queueSuccessor:(AudioFileHandle *)file quantizeToInt16:(BOOL)quantizeToInt16 forVoice:(VibeVoiceID)voice;

// Drops the queued successor. NO means the decoder had already claimed it:
// successor frames sit in the ring or are on their way, and the caller must
// re-voice.
- (BOOL)unqueueSuccessorForVoice:(VibeVoiceID)voice;

// A retire of zero frames: silent from the next render, dead right after.
// Every started voice ends exactly once through the drain, a pending one
// killed before it had a slot included.
- (void)killVoice:(VibeVoiceID)voice;

// Any thread. Retries a torn read; a recycled or unknown id answers None. A
// voice is readable until the drain has reported it ended — read what its
// end needs inside that handler, since the same drain recycles the slot.
- (VibeVoiceSnapshot)snapshotOfVoice:(VibeVoiceID)voice;
// Detailed failure and exact handle identity, including for repeated URLs.
// Read before the ended handler returns.
- (nullable NSError *)errorOfVoice:(VibeVoiceID)voice
                       failedFile:(AudioFileHandle * _Nullable * _Nullable)file;

// How the voice's file reaches the bus, for the audio-path report: nil when
// it is read direct, else the rates and widths either side (`fromSampleRate`,
// `toSampleRate`, `fromChannels`, `toChannels`), the sample format it lands
// in (`toSampleFormat`), whether it was mixed by layout (`mixed`) and
// resampled (`resampled`), and for a resample the converter's `algorithm`
// and `quality` as read back. Any thread; a pending or unknown voice is nil.
- (nullable NSDictionary<NSString *, id> *)conversionOfVoice:(VibeVoiceID)voice;

// Slots that are not free, pending voices included. The drain-timer gate.
- (NSUInteger)occupiedSlotCount;
- (NSUInteger)liveVoiceCount;
// Decoder turns run so far, a diagnostic: a voice that can write nothing
// asks for none, which the tests read.
- (uint64_t)decodeTurns;

// The poll. Binds pending voices, emits each voice's events in the order
// live → boundary → ended (one boundary per successor), tops up rings, and
// recycles dead slots once no render can be inside them — which needs
// outputRunning, since a stopped output renders nothing.
- (void)drainWithOutputRunning:(BOOL)outputRunning
                       handler:(void (^)(VibeVoiceID voice, VibeVoiceEvent event))handler;

// inlineDecoding only: decodes on the caller's thread until every armed and
// live voice is full or at end of stream. Armed voices go live here.
- (void)fillInline;

@end

// The most frames one render mixes at once: the largest slice the pipeline
// hands the bus (kVibeMasterBusMaxFrames is this), and the length of the
// gains scratch a fade is mixed through; a larger ask is mixed in pieces.
static const uint32_t kVibeVoiceBusMaxRenderFrames = 4096;

// The audio thread's entry: mixes every live voice into `output` — one
// buffer per channel, the bus's channels or fewer — for `frameCount` frames
// stamped `timestamp`, any count; `isSilence` reports a block no voice mixed.
OSStatus VibeVoiceBusRender(VibeVoiceMix *mix, BOOL *isSilence, const AudioTimeStamp *timestamp,
                            AVAudioFrameCount frameCount, AudioBufferList *output) CA_REALTIME_API;

NS_ASSUME_NONNULL_END
