//
//  AudioFileHandleStreamingTestCase.h
//
//  The harness the AudioFileHandle streaming tests share: a per-test temp
//  directory behind CloudFileMaterializer's remote root, the fixtures and
//  their reference decodes, and the read-ahead's scripted network mount.
//  It runs no tests. AudioFileHandleStreamingTests and
//  AudioFileHandleReadAheadTests subclass it.
//

#import <XCTest/XCTest.h>
#import <AVFoundation/AVFoundation.h>
#include <libkern/OSByteOrder.h>
#include <os/lock.h>
#include <stdatomic.h>

#import "AudioFileHandle.h"
#import "AudioFileHandle+Debug.h"
#import "AudioFileMaterializationCoordinatorInternal.h"
#import "TailWindowMath.h"
#import "AudioFixtures.h"
#import "AudioTrack.h"
#import "CloudFileMaterializer.h"
#import "CloudTransferRegistry.h"
#import "NSURL+Hash.h"
#import "VibeReadAheadScript.h"

NS_ASSUME_NONNULL_BEGIN

// Deterministic, nonperiodic and full scale 16-bit samples.
NSData *VibeNoiseSamples(uint32_t frames, uint16_t channels);
AVAudioPCMBuffer *VibeNoiseBuffer(uint32_t frames);
// A codec file through the handle's own writer.
NSURL *_Nullable VibeWriteEncoded(NSURL *url, AudioFileTypeID type, AudioStreamBasicDescription file, NSError **error);
// Interleaved float32 from the cursor; nil when a read answers NO.
NSData *_Nullable VibeDecode(AudioFileHandle *handle, AVAudioFrameCount chunk, AVAudioFramePosition limit,
                             NSError **error);
// An M4A with its moov first rewritten with it last; nil when it was not first.
NSData *_Nullable VibeMoovLast(NSData *m4a);
// The MP3 with its Xing or Info tag blanked; nil when it has neither.
NSData *_Nullable VibeWithoutVBRHeader(NSData *mp3);

@interface AudioFileHandleStreamingTestCase : XCTestCase {
@protected
    NSURL *_directory;
    os_unfair_lock _streamsLock;
    NSMutableDictionary<NSString *, CloudFileAvailability *> *_streams;
    NSMutableArray<NSString *> *_lookups;
    CloudFileAvailability *_Nullable (^_lookupOverride)(NSURL *url);
    // Through the coordinator: the remote fetch. setUp's remote root calls it.
    CloudFileRemoteFetch _fetch;
    // The read-ahead tests' network mount: files under it read ahead, their
    // reads as the script says.
    NSURL *_network;
    VibeReadAheadScript *_script;
}
- (CloudFileAvailability *_Nullable)availabilityForURL:(NSURL *)url;
// The fixtures every test runs over: the decoder each one reaches, by file.
- (NSDictionary<NSURL *, NSString *> *)fixtures;
- (NSURL *)sourceNamed:(NSString *)name;
- (AudioFileHandle *)openWhole:(NSURL *)source;
- (NSData *)referenceOf:(NSURL *)source from:(AVAudioFramePosition)frame frames:(AVAudioFramePosition)frames;
// Exact, but for AAC, which is held to four float epsilons.
- (void)assertPCM:(NSData *)pcm equals:(NSData *)reference context:(NSString *)context;
// The tail-reading opens, by the decoder each reaches, and a WAV and MP3s.
- (NSDictionary<NSURL *, NSString *> *)tailFixtures;
// Files on the test's network mount read ahead.
- (VibeReadAheadScript *)readAhead;
- (NSURL *)networkCopyOf:(NSURL *)source;
- (BOOL)await:(dispatch_semaphore_t)semaphore;
// Spins main, which carries the registry's edges, until the condition holds.
- (BOOL)eventually:(BOOL (^)(void))condition;
@end

NS_ASSUME_NONNULL_END
