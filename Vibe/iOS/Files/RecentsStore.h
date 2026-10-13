//
//  RecentsStore.h
//  Vibe (iOS)
//
//  Every file and folder opened or added, newest first, at most 50, each
//  {path, bookmark (absent when the mint failed), folder, location}. Persisted
//  in NSUserDefaults. FolderSession records them where an open lands. A
//  restore records nothing, and clearing the session keeps them.
//
//  The list is read from defaults on every call, so recentItems is safe on any
//  thread. Recording and clearing are main thread only.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface RecentsStore : NSObject

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@property (class, nonatomic, readonly) RecentsStore *shared;

@property (nonatomic, readonly) NSArray<NSDictionary *> *recentItems;

// A path already listed moves to the top. Picked together, the first picked
// lands on top. The open brings each bookmark, since minting needs the scope
// open.
- (void)recordRecentItems:(NSArray<NSDictionary *> *)items;

// The recent's URL from its bookmark, else its path while something is there.
// Off main; completion on main, nil when neither reaches it.
- (void)resolveRecentItem:(NSDictionary *)item completion:(void (^)(NSURL *_Nullable url))completion;

- (void)clearRecentItems;

@end

NS_ASSUME_NONNULL_END
