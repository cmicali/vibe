//
//  PlaylistFile+Session.m
//  Vibe
//

#import "PlaylistFile+Session.h"

NSString *const kVibeLastPlaylistCurrentIndexKey = @"VibeLastPlaylistCurrentIndex";

@implementation PlaylistFile (Session)

+ (BOOL)saveSessionTracks:(NSArray<AudioTrack *> *)tracks currentIndex:(NSUInteger)index
                 enabled:(BOOL)enabled toURL:(NSURL *)url defaults:(NSUserDefaults *)defaults
                   write:(BOOL (^)(NSError **))write error:(NSError **)error {
    if (!enabled || tracks.count == 0) {
        [self removeSessionAtURL:url defaults:defaults];
        return YES;
    }
    [NSFileManager.defaultManager createDirectoryAtURL:url.URLByDeletingLastPathComponent
            withIntermediateDirectories:YES attributes:nil error:nil];
    BOOL saved = write ? write(error) : [self writeM3UForTracks:tracks relativeToDirectory:nil toURL:url error:error];
    if (!saved) {
        [self removeSessionAtURL:url defaults:defaults];
        return NO;
    }
    [defaults setInteger:(NSInteger)MIN(index, tracks.count - 1) forKey:kVibeLastPlaylistCurrentIndexKey];
    return YES;
}

+ (void)removeSessionAtURL:(NSURL *)url defaults:(NSUserDefaults *)defaults {
    [NSFileManager.defaultManager removeItemAtURL:url error:nil];
    [defaults removeObjectForKey:kVibeLastPlaylistCurrentIndexKey];
}

+ (BOOL)restoreSessionAtURL:(NSURL *)url enabled:(BOOL)enabled defaults:(NSUserDefaults *)defaults
                     load:(void (^)(NSArray<AudioTrack *> *, NSUInteger, BOOL))load {
    if (!enabled) return NO;
    NSArray<AudioTrack *> *rows = [self rowsInM3UData:[NSData dataWithContentsOfURL:url]];
    if (rows.count == 0) return NO;
    NSInteger stored = [defaults integerForKey:kVibeLastPlaylistCurrentIndexKey];
    NSUInteger index = stored < 0 ? 0 : MIN((NSUInteger)stored, rows.count - 1);
    load(rows, index, YES);
    return YES;
}

@end
