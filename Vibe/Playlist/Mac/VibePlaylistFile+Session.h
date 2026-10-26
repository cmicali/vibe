//
//  VibePlaylistFile+Session.h
//  Vibe
//

#import "VibePlaylistFile.h"

@class AudioTrack;

NS_ASSUME_NONNULL_BEGIN

extern NSString *const kVibeLastPlaylistCurrentIndexKey;

@interface VibePlaylistFile (Session)

// The app's private session mirror: explicit URL/defaults keep it independent
// of the shell and let tests use a temporary folder. No grants or Open Recent.
// A failed write removes both stale mirror and cursor; nil write uses atomic M3U.
+ (BOOL)saveSessionTracks:(NSArray<AudioTrack *> *)tracks currentIndex:(NSUInteger)index
                 enabled:(BOOL)enabled toURL:(NSURL *)url defaults:(NSUserDefaults *)defaults
                   write:(BOOL (^_Nullable)(NSError * _Nullable * _Nullable error))write
                   error:(NSError * _Nullable * _Nullable)error;
+ (void)removeSessionAtURL:(NSURL *)url defaults:(NSUserDefaults *)defaults;
+ (BOOL)restoreSessionAtURL:(NSURL *)url enabled:(BOOL)enabled defaults:(NSUserDefaults *)defaults
                     load:(void (^)(NSArray<AudioTrack *> *rows, NSUInteger index, BOOL paused))load;

@end

NS_ASSUME_NONNULL_END
