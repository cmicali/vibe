//
//  PlaylistFileTestCase.m
//  VibeTests
//

#import "PlaylistFileTestCase.h"

@implementation PlaylistFile (CueFileNames)
+ (NSArray<NSString *> *)fileNamesInCueText:(NSString *)text {
    NSMutableArray<NSString *> *names = [NSMutableArray new];
    [self cueRowsInText:text sheetURL:nil resolvingFile:^NSURL *(NSString *name, BOOL sole) {
        if (!name) {
            return nil;
        }
        [names addObject:name];
        return [NSURL fileURLWithPath:[@"/cue" stringByAppendingPathComponent:name] isDirectory:NO];
    }];
    return names;
}

@end

@implementation PlaylistFileTestCase

- (NSURL *)makeTempDirWithFiles:(NSArray<NSString *> *)names
                   playlistName:(NSString *)playlistName
                           text:(NSString *)text {
    NSURL *dir = [[NSURL fileURLWithPath:NSTemporaryDirectory()]
            URLByAppendingPathComponent:[NSString stringWithFormat:@"PlaylistFileTests-%@", NSUUID.UUID.UUIDString]];
    [NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
    for (NSString *name in names) {
        [[NSData data] writeToURL:[dir URLByAppendingPathComponent:name] atomically:YES];
    }
    [[text dataUsingEncoding:NSUTF8StringEncoding]
            writeToURL:[dir URLByAppendingPathComponent:playlistName] atomically:YES];
    [self addTeardownBlock:^{
        [NSFileManager.defaultManager removeItemAtURL:dir error:nil];
    }];
    return dir;
}

@end
