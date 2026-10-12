//
//  PlaylistFileInternal.h
//  Vibe
//
//  The helpers PlaylistFile.m and PlaylistFile+CUE.m share. Import it nowhere else.
//

#import <Foundation/Foundation.h>

NSString *VibeTextOfFile(NSURL *url);

NSString *VibeNormalizePathSeparators(NSString *name);
NSString *VibeStrippedOfUnpathableCharacters(NSString *name);

NSURL *VibeKnownFileAtPath(NSString *path, NSDictionary<NSString *, NSArray<NSURL *> *> *knownFiles);
NSURL *VibeResolveEntry(NSString *entry, NSURL *dir, NSFileManager *fileManager,
                        NSMutableDictionary<NSString *, NSNumber *> *dirReachable,
                        NSDictionary<NSString *, NSArray<NSURL *> *> *knownFiles,
                        NSURL **primaryOut);
