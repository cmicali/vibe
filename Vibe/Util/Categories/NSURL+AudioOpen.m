//
//  NSURL+AudioOpen.m
//  Vibe
//

#import "NSURL+AudioOpen.h"

#import <AudioToolbox/AudioToolbox.h>

#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

@implementation NSURL (AudioOpen)

// TRAP: AVAudioFile — and ExtAudioFileOpenURL and AudioFileOpenURL under it —
// leaks a file descriptor on every FAILED open. All three URL-based open APIs
// leak identically (measured: 20 failed opens each cost exactly 20
// descriptors), so no URL-based preflight can help; the only fd-safe probe is
// AudioFileOpenWithCallbacks over a descriptor this process owns and closes,
// which is what failsAudioOpenPreflight does. The leak triggers on any file
// the kernel opens but the parser then refuses — a zero-length file, a
// directory, a truncated download, a tag table promising more bytes than the
// file holds — so emptiness is NOT the whole test: a partial download is the
// common case in a real library, and each background decode retry against one
// costs another descriptor forever.
//
// validateAudioFileIsReadableAndHasContent is separate and deliberately
// stricter for FLAC conversion's destructive handoff. Regular audio-open paths
// must retain failsAudioOpenPreflight's behavior and cost.
//
// TRAP: st_size, never st_blocks or NSURLFileAllocatedSizeKey. An evicted
// iCloud or Dropbox file is dataless — true logical size, zero allocated
// blocks — so an allocation-based test would reject every cloud-hosted track.
// stat() reads that metadata locally and never materializes the file.
- (BOOL)isEmptyOrDirectory {
    if (!self.isFileURL) {
        return NO;
    }
    struct stat info;
    if (stat(self.fileSystemRepresentation, &info) != 0) {
        return NO; // unstattable: let the real open report why
    }
    return S_ISDIR(info.st_mode) || info.st_size == 0;
}

// The read side of the preflight parse. Short reads are answered as such and
// a read at or past EOF is the end-of-file status, which is the shape the
// header parsers expect from AudioFile's own file reader; verdict parity with
// AudioFileOpenURL was verified per format (MP3, FLAC, WAV, M4A, AIFF) on
// both accepting and refusing files.
typedef struct {
    int descriptor;
    SInt64 size;
} VibePreflightContext;

static OSStatus VibePreflightRead(void *clientData, SInt64 position,
                                  UInt32 requestCount, void *buffer,
                                  UInt32 *actualCount) {
    VibePreflightContext *context = clientData;
    ssize_t got = pread(context->descriptor, buffer, requestCount, position);
    if (got < 0) {
        *actualCount = 0;
        return kAudioFilePositionError;
    }
    *actualCount = (UInt32)got;
    return (got == 0 && requestCount > 0) ? kAudioFileEndOfFileError : noErr;
}

static SInt64 VibePreflightGetSize(void *clientData) {
    return ((VibePreflightContext *)clientData)->size;
}

// The type CoreAudio registers for an extension: the hint AudioFileOpenURL
// takes from a path. 0 when none is registered.
static AudioFileTypeID VibeFileTypeForExtension(NSString *extension) {
    // A strong local, not a bridged temporary: ARC frees an unretained
    // expression result at the end of its statement, and the registry lookup
    // below then compared against freed memory.
    NSString *lowered = extension.lowercaseString;
    CFStringRef key = (__bridge CFStringRef)lowered;
    UInt32 size = 0;
    if (!key || AudioFileGetGlobalInfoSize(kAudioFileGlobalInfo_TypesForExtension, sizeof(key), &key, &size) != noErr
            || size < sizeof(AudioFileTypeID)) {
        return 0;
    }
    AudioFileTypeID types[8] = {0};
    size = MIN(size, (UInt32)sizeof(types));
    if (AudioFileGetGlobalInfo(kAudioFileGlobalInfo_TypesForExtension, sizeof(key), &key, &size, types) != noErr) {
        return 0;
    }
    return types[0];
}

static OSStatus VibePreflightOpen(VibePreflightContext *context, AudioFileTypeID hint) {
    AudioFileID file = NULL;
    OSStatus status = AudioFileOpenWithCallbacks(context, VibePreflightRead, NULL,
                                                 VibePreflightGetSize, NULL, hint, &file);
    if (file) {
        AudioFileClose(file);
    }
    return status;
}

#if VIBE_VERBOSE_LOGGING
// Beta instrumentation (#47): a refusal names both statuses and how the file
// starts, so a report says why without the file itself.
static void VibeLogPreflightRefusal(NSURL *url, VibePreflightContext *context, AudioFileTypeID hint,
                                    OSStatus hinted, OSStatus sniffed) {
    unsigned char head[16] = {0};
    ssize_t got = pread(context->descriptor, head, sizeof(head), 0);
    NSString *start;
    if (got >= 10 && head[0] == 'I' && head[1] == 'D' && head[2] == '3') {
        // ID3v2: a syncsafe size in bytes 6-9, excluding the 10-byte header.
        uint32_t tag = ((head[6] & 0x7f) << 21) | ((head[7] & 0x7f) << 14) | ((head[8] & 0x7f) << 7) | (head[9] & 0x7f);
        start = [NSString stringWithFormat:@"an ID3v2.%u tag of %u bytes", head[3], tag + 10];
    } else {
        NSMutableString *hex = [NSMutableString string];
        for (ssize_t i = 0; i < got; i++) {
            [hex appendFormat:@"%02x", head[i]];
        }
        start = [NSString stringWithFormat:@"the bytes %@", hex];
    }
    LogWarn(@"Preflight: CoreAudio refused %@ as its extension's type (%@) and by content (%d); %lld bytes, "
            @"starting with %@", url.lastPathComponent, hint ? [NSString stringWithFormat:@"%d", (int)hinted] : @"none registered",
            (int)sniffed, context->size, start);
}
#endif

- (BOOL)failsAudioOpenPreflight {
    if (self.isEmptyOrDirectory) {
        return YES;
    }
    if (!self.isFileURL) {
        return NO;
    }
    VibePreflightContext context;
    context.descriptor = open(self.fileSystemRepresentation, O_RDONLY);
    if (context.descriptor < 0) {
        return NO; // unopenable here may still be openable with the app's grants
    }
    struct stat info;
    if (fstat(context.descriptor, &info) != 0) {
        close(context.descriptor);
        return NO;
    }
    context.size = info.st_size;
    // TRAP: probe as the type the extension claims first, as AudioFileOpenURL
    // does — the real open the caller makes next. Sniffing the content alone
    // refuses an MP3 with ANY undeclared bytes between its ID3 tag and the first
    // frame, a defect taggers leave behind, while the real open plays it: #47's
    // Darkside.mp3 was refused before AVAudioFile ever saw it. A refusal under
    // the hint falls back to sniffing, so a file named for the wrong type is
    // still judged by what it holds.
    AudioFileTypeID hint = VibeFileTypeForExtension(self.pathExtension);
    OSStatus hinted = hint ? VibePreflightOpen(&context, hint) : kAudioFileUnsupportedFileTypeError;
    OSStatus status = hinted == noErr ? noErr : VibePreflightOpen(&context, 0);
#if VIBE_VERBOSE_LOGGING
    if (status != noErr && status != kAudio_UnimplementedError) {
        VibeLogPreflightRefusal(self, &context, hint, hinted, status);
    }
#endif
    close(context.descriptor);
    // TRAP: CoreAudio's QuickTime reader (file type MooV, the container Voice
    // Memos exports as .qta) implements no callback open at all: it answers
    // kAudio_UnimplementedError for any hint whatever the header holds, so that
    // status says nothing about the file. Let the real open decide; the leak
    // above is then bounded to a corrupt QuickTime file, the one case this
    // probe cannot see.
    return status != noErr && status != kAudio_UnimplementedError;
}

- (BOOL)validateAudioFileIsReadableAndHasContent {
    if (!self.isFileURL) {
        return NO;
    }
    VibePreflightContext context;
    context.descriptor = open(self.fileSystemRepresentation, O_RDONLY);
    if (context.descriptor < 0) {
        return NO;
    }
    struct stat info;
    if (fstat(context.descriptor, &info) != 0) {
        close(context.descriptor);
        return NO;
    }
    if (!S_ISREG(info.st_mode) || info.st_size <= 0) {
        close(context.descriptor);
        return NO;
    }
    context.size = info.st_size;
    AudioFileID file = NULL;
    OSStatus status = AudioFileOpenWithCallbacks(&context, VibePreflightRead, NULL,
                                                 VibePreflightGetSize, NULL, 0, &file);
    UInt64 packetCount = 0;
    UInt32 packetCountSize = sizeof(packetCount);
    OSStatus packetStatus = status == noErr && file
            ? AudioFileGetProperty(file, kAudioFilePropertyAudioDataPacketCount,
                                   &packetCountSize, &packetCount)
            : kAudioFileUnspecifiedError;
    if (file) {
        AudioFileClose(file);
    }
    close(context.descriptor);
    return status == noErr && packetStatus == noErr && packetCount > 0;
}

@end
