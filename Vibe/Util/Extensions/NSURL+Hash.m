//
// Created by Christopher Micali on 12/30/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import "NSURL+Hash.h"
#include <CommonCrypto/CommonDigest.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdint.h>
#include <stdio.h>

@implementation NSURL (Hash)

- (NSString *)md5HashOfFile {
    TIME_START(@"md5")
    NSString *result = [NSURL md5HashOfFileAtPath:self.path];
    TIME_END
    return result;
}

- (NSString *)sha1HashOfFile {
    TIME_START(@"sha1")
    NSString *result =  [NSURL sha1HashOfFileAtPath:self.path];
    TIME_END
    return result;
}

- (NSString *)sha512HashOfFile {
    TIME_START(@"sha512")
    NSString *result = [NSURL sha512HashOfFileAtPath:self.path];
    TIME_END
    return result;
}

// Constants
static const size_t FileHashDefaultChunkSizeForReadingData = 64 * 1024;

// Function pointer types for functions used in the computation
// of a cryptographic hash.
typedef int (*FileHashInitFunction)   (uint8_t *hashObjectPointer[]);
typedef int (*FileHashUpdateFunction) (uint8_t *hashObjectPointer[], const void *data, CC_LONG len);
typedef int (*FileHashFinalFunction)  (unsigned char *md, uint8_t *hashObjectPointer[]);

// Structure used to describe a hash computation context.
typedef struct _FileHashComputationContext {
    FileHashInitFunction initFunction;
    FileHashUpdateFunction updateFunction;
    FileHashFinalFunction finalFunction;
    size_t digestLength;
    uint8_t **hashObjectPointer;
} FileHashComputationContext;

#define FileHashComputationContextInitialize(context, hashAlgorithmName)                    \
    CC_##hashAlgorithmName##_CTX hashObjectFor##hashAlgorithmName;                          \
    context.initFunction      = (FileHashInitFunction)&CC_##hashAlgorithmName##_Init;       \
    context.updateFunction    = (FileHashUpdateFunction)&CC_##hashAlgorithmName##_Update;   \
    context.finalFunction     = (FileHashFinalFunction)&CC_##hashAlgorithmName##_Final;     \
    context.digestLength      = CC_##hashAlgorithmName##_DIGEST_LENGTH;                     \
    context.hashObjectPointer = (uint8_t **)&hashObjectFor##hashAlgorithmName

+ (NSString *)hashOfFileAtPath:(NSString *)filePath withComputationContext:(FileHashComputationContext *)context {
    NSString *result = nil;
    CFURLRef fileURL = CFURLCreateWithFileSystemPath(kCFAllocatorDefault, (__bridge CFStringRef)filePath, kCFURLPOSIXPathStyle, (Boolean)false);
    CFReadStreamRef readStream = fileURL ? CFReadStreamCreateWithFile(kCFAllocatorDefault, fileURL) : NULL;
    BOOL didSucceed = readStream ? (BOOL)CFReadStreamOpen(readStream) : NO;
    if (didSucceed) {

        // Use default value for the chunk size for reading data.
        const size_t chunkSizeForReadingData = FileHashDefaultChunkSizeForReadingData;

        // Initialize the hash object
        (*context->initFunction)(context->hashObjectPointer);

        // Feed the data to the hash object.
        BOOL hasMoreData = YES;
        while (hasMoreData) {
            uint8_t buffer[chunkSizeForReadingData];
            CFIndex readBytesCount = CFReadStreamRead(readStream, (UInt8 *)buffer, (CFIndex)sizeof(buffer));
            if (readBytesCount == -1) {
                break;
            } else if (readBytesCount == 0) {
                hasMoreData = NO;
            } else {
                (*context->updateFunction)(context->hashObjectPointer, (const void *)buffer, (CC_LONG)readBytesCount);
            }
        }

        // Compute the hash digest
        unsigned char digest[context->digestLength];
        (*context->finalFunction)(digest, context->hashObjectPointer);

        // Close the read stream.
        CFReadStreamClose(readStream);

        // Proceed if the read operation succeeded.
        didSucceed = !hasMoreData;
        if (didSucceed) {
            char hash[2 * sizeof(digest) + 1];
            for (size_t i = 0; i < sizeof(digest); ++i) {
                snprintf(hash + (2 * i), 3, "%02x", (int)(digest[i]));
            }
            result = [NSString stringWithUTF8String:hash];
        }

    }
    if (readStream) CFRelease(readStream);
    if (fileURL)    CFRelease(fileURL);
    return result;
}

+ (NSString *)md5HashOfFileAtPath:(NSString *)filePath {
    FileHashComputationContext context;
    FileHashComputationContextInitialize(context, MD5);
    return [self hashOfFileAtPath:filePath withComputationContext:&context];
}

+ (NSString *)sha1HashOfFileAtPath:(NSString *)filePath {
    FileHashComputationContext context;
    FileHashComputationContextInitialize(context, SHA1);
    return [self hashOfFileAtPath:filePath withComputationContext:&context];
}

+ (NSString *)sha512HashOfFileAtPath:(NSString *)filePath {
    FileHashComputationContext context;
    FileHashComputationContextInitialize(context, SHA512);
    return [self hashOfFileAtPath:filePath withComputationContext:&context];
}

@end
