//
//  PlaylistEntry.h
//  Vibe
//
//  One entry of a playlist, as the readers return it and the writer takes it:
//  a file whole, or a CUE sheet's window of one. A plain value, made once and
//  never changed, so it crosses threads freely. The app makes its rows from
//  entries.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface PlaylistEntry : NSObject

// A file whole.
+ (instancetype)entryWithURL:(NSURL *)url;

// A window of url in CD frames (1/75 s), start inclusive and end exclusive. An
// end of 0 runs to the file's end. The names and the number are the sheet's.
- (instancetype)initWithURL:(NSURL *)url cueStart:(NSUInteger)start cueEnd:(NSUInteger)end
                      title:(nullable NSString *)title performer:(nullable NSString *)performer
                      sheet:(nullable NSURL *)sheet trackNumber:(NSInteger)trackNumber;

// The same, with what the writer's #EXTINF line names. The readers ignore
// #EXTINF, so they make every entry with the initializer above.
- (instancetype)initWithURL:(NSURL *)url cueStart:(NSUInteger)start cueEnd:(NSUInteger)end
                      title:(nullable NSString *)title performer:(nullable NSString *)performer
                      sheet:(nullable NSURL *)sheet trackNumber:(NSInteger)trackNumber
                   duration:(NSTimeInterval)duration displayTitle:(nullable NSString *)displayTitle
              displayArtist:(nullable NSString *)displayArtist NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@property (nonatomic, copy, readonly) NSURL *url;
@property (nonatomic, readonly) NSUInteger cueStart;
@property (nonatomic, readonly) NSUInteger cueEnd;
@property (nonatomic, copy, readonly, nullable) NSString *cueTitle;
@property (nonatomic, copy, readonly, nullable) NSString *cuePerformer;
@property (nonatomic, copy, readonly, nullable) NSURL *cueSheetURL;
@property (nonatomic, readonly) NSInteger cueTrackNumber;

// The #EXTINF line's length in seconds, 0 or less when unknown, and its
// artist and title. A nil title writes an empty name.
@property (nonatomic, readonly) NSTimeInterval duration;
@property (nonatomic, copy, readonly, nullable) NSString *displayTitle;
@property (nonatomic, copy, readonly, nullable) NSString *displayArtist;

// YES when the entry plays less than its whole file.
- (BOOL)isWindowed;

@end

NS_ASSUME_NONNULL_END
