//
//  FileSearchIndex.h
//  Vibe (iOS)
//
//  The search screen's second section: the audio files reachable anywhere under
//  the locations this app holds access to, walked once into memory and then
//  filtered away from the main thread per keystroke.
//
//  There is no public API that searches the Files app. An app can only search
//  file trees it actually holds. PlaybackController composes the transient
//  FolderSession root with SearchFolderStore's persistent roots (the folders
//  added in Settings plus the app's own Documents directory).
//
//  The walk STREAMS: batches land as they are found rather than at the end, so
//  a query answers off a partial index and grows. It reads directory listings
//  and nothing else — never a file's bytes, never its tags — so a provider tree
//  costs IPC per directory and no downloads.
//
//  Main thread only, except where noted. The walk and localized filtering own
//  separate private queues; their deliveries return here.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class FileSearchIndex;

// One found file. Named entirely from its path — nothing here was stat'd, read
// or parsed.
@interface FileSearchHit : NSObject

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@property (nonatomic, readonly) NSURL *url;
// The file as it is spelled on disk, extension included.
@property (nonatomic, readonly) NSString *fileName;
// Its directory's name, drawn as the row's second line and matched alongside
// the filename.
@property (nonatomic, readonly) NSString *folderName;
@end

@protocol FileSearchIndexDelegate <NSObject>
// A batch landed, or the walk ended. Both only ever arrive between
// beginBuildIfNeeded and the walk finishing, and both on main.
- (void)fileSearchIndexDidGrow:(FileSearchIndex *)index;
- (void)fileSearchIndexDidFinishBuilding:(FileSearchIndex *)index;
@end

@interface FileSearchIndex : NSObject

@property (nonatomic, weak) id<FileSearchIndexDelegate> delegate;

// YES between beginBuildIfNeeded and fileSearchIndexDidFinishBuilding:, so the
// screen can say it is still looking rather than that there is nothing.
@property (nonatomic, readonly) BOOL isBuilding;

// Roots the same as the ones in hand are a no-op — the index survives, and a
// return to the search screen costs nothing. Any change discards it and
// abandons a walk in flight.
- (void)setRoots:(NSArray<NSURL *> *)roots;

// Starts the walk unless one already ran or is running for these roots. Cheap
// to call on every appearance of the search screen, which is where it belongs:
// a tap on the search circle is the signal that this work is wanted, and
// nothing walks a provider tree before then.
- (void)beginBuildIfNeeded;

// Finds indexed files without doing localized matching on main. The walk
// prepares each row's folded search text once; while the index grows, an
// unchanged query examines only the appended suffix. Results keep discovery
// order and are capped at limit; excludedPaths drops what the playlist already
// shows, keyed by NSURL.path. An empty query matches nothing. Each request
// supersedes the previous one. Only the latest request delivers on main.
- (void)requestHitsMatchingQuery:(NSString *)query
                       excluding:(nullable NSSet<NSString *> *)excludedPaths
                           limit:(NSUInteger)limit
                      completion:(void (^)(NSArray<FileSearchHit *> *hits))completion;

// Supersedes pending localized filtering without discarding the index.
- (void)cancelPendingHitRequests;

@end

NS_ASSUME_NONNULL_END
