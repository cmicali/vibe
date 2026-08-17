//
//  FileSearchIndex.h
//  Vibe (iOS)
//
//  The search screen's second section: the audio files reachable anywhere under
//  the locations this app holds access to, walked once into memory and then
//  filtered per keystroke.
//
//  There is no public API that searches the Files app. An app can only search
//  file trees it actually holds — so the roots are the open folder (a folder
//  grant covers its WHOLE subtree, which the flat directory-as-playlist listing
//  never reaches) and the app's own Documents directory, which is what Files
//  shows as "On My iPhone -> Vibe". FolderSession.searchRoots is where they are
//  named.
//
//  The walk STREAMS: batches land as they are found rather than at the end, so
//  a query answers off a partial index and grows. It reads directory listings
//  and nothing else — never a file's bytes, never its tags — so a provider tree
//  costs IPC per directory and no downloads.
//
//  Main thread only, except where noted. The walk owns a private queue and hops
//  its batches back here, so a query never takes a lock.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class FileSearchIndex;

// One found file. Named entirely from its path — nothing here was stat'd, read
// or parsed.
@interface FileSearchHit : NSObject
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

// Every indexed file matching query, in discovery order — depth-first, so a
// folder's tracks arrive together — capped at limit. excludedPaths drops what
// the playlist section is already showing, keyed by NSURL.path. An empty query
// matches nothing (see FileSearchRules.h).
- (NSArray<FileSearchHit *> *)hitsMatchingQuery:(NSString *)query
                                      excluding:(nullable NSSet<NSString *> *)excludedPaths
                                          limit:(NSUInteger)limit;

@end

NS_ASSUME_NONNULL_END
