//
// Created by Christopher Micali on 12/18/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Asks the user to grant access to the folder a playlist file's entries live
// in, and answers whether they did. Runs on an expansion worker, never the
// main thread, and must block until it is answered.
//
// This layer knows *when* a grant is needed — it is the one holding the
// unreadable entries — but not what asking looks like: the panel and the
// bookmark are the app's sandbox-grant funnel, which is macOS-only and sits
// well above a path utility. The app installs the handler at launch. Unset,
// as in the tests, means no grant can be obtained and unreadable entries are
// simply skipped.
typedef BOOL (^VibePlaylistFolderGrantHandler)(NSURL *playlistURL);

// What an expansion saw of the folders it touched. This layer *finds* these
// facts — it walks the disk — but must not act on them: the consumer is the
// folder-art resolver, an app singleton behind a user setting and a sandbox
// grant, and a path utility that reached up to it could not be exercised
// without one. Same shape as the playlist grant above, and for the same
// reason — the tests install neither and get a pure walk. The app installs
// these at launch; unset, an expansion throws the harvest away.
//
// Both are called on an expansion worker, never the main thread.

// A walk listed these directories and found these covers in them, keyed by
// directory and spelled as on disk. Every directory named was seen *in full*,
// so "no cover" is an answer rather than a gap. Called once per top-level
// folder expanded.
typedef void (^VibeWalkedDirectoriesHandler)(NSSet<NSString *> *directories,
                                             NSDictionary<NSString *, NSString *> *artFilenameByDirectory);

// The folders of the *loose files* in an open of more than one thing. Nothing
// was listed, so nothing is known about their contents — only that the open was
// bulk enough for a listing each to be a fair price, should anything ask.
// Called once per expansion, and not at all for a single file.
typedef void (^VibeBulkOpenDirectoriesHandler)(NSSet<NSString *> *directories);


@interface NSURLUtil : NSObject

+ (void)setPlaylistFolderGrantHandler:(nullable VibePlaylistFolderGrantHandler)handler;
+ (void)setWalkedDirectoriesHandler:(nullable VibeWalkedDirectoriesHandler)handler;
+ (void)setBulkOpenDirectoriesHandler:(nullable VibeBulkOpenDirectoriesHandler)handler;

// YES for a cloud placeholder whose data is not local — iCloud, Dropbox, any
// File Provider. APFS marks these SF_DATALESS, and reading one blocks until
// the provider materializes it. stat() itself never triggers the download, so
// this check is always fast. It returns NO when the stat fails, since unknown
// is not the same as dataless.
+ (BOOL)isDatalessFile:(NSURL *)url;

// Expands folders and top-level playlist files (the files a .cue/.m3u/.m3u8
// lists, in list order, raising a folder-access grant when the sandbox
// requires one), and filters to playable extensions. Expansions run on a
// four-wide queue, so one dead folder cannot block an unrelated later open and
// a burst of them cannot spawn a thread each; callers coordinate overlapping
// result order (OpenRequestCoordinator). folderCount is how many of the
// top-level URLs resolved as directories, counted here because the check stats
// the file system and so belongs on the expansion queue, not the main-thread
// caller. Completion runs on main.
+ (void)expandAndFilterList:(NSArray<NSURL *> *)list
                 completion:(void (^)(NSArray<NSURL *> *files, NSUInteger folderCount))completion;
@end

NS_ASSUME_NONNULL_END
