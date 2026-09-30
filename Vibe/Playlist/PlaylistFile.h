//
//  PlaylistFile.h
//  Vibe
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class AudioTrack;
extern NSString *const kVibeLastPlaylistCurrentIndexKey;

// Readers for playlist-like files — CUE sheets and M3U playlists — and the M3U
// writer. A CUE sheet reads as rows, each a window of its FILE; an M3U reads
// as file references, its #EXTINF metadata ignored.
@interface PlaylistFile : NSObject

// YES for a (lowercased) path extension this class expands: cue, m3u, m3u8.
+ (BOOL)isPlaylistExtension:(NSString *)extension;

// Decodes playlist bytes to text: a UTF-16 BOM, then a BOM-less UTF-16
// signature, then UTF-8, then Windows-1252 and Latin-1 for legacy writers, so
// a non-empty file always decodes.
+ (nullable NSString *)textFromData:(NSData *)data;

// A CUE sheet as rows, one per AUDIO TRACK kept, each a window of the FILE its
// start INDEX sits in (AudioTrack's cue initializer). A track starts at INDEX
// 01, else INDEX 00; one with neither, or starting before the last kept start
// in its file, is dropped. A row ends at the next row of its file — so a
// pregap plays at the end of the row before it — and the last runs to the
// file's end; a file's first row starts at its first frame, so audio before
// track 1 is reachable. The performer falls back to the sheet's; only TITLE
// and PERFORMER are read. A sheet with no usable TRACK gives one whole-file row
// per FILE. FILE names are unquoted or quoted, a trailing type keyword
// stripped from unquoted ones, backslashes normalized to slashes, consecutive
// duplicates collapsed. resolve maps each FILE name to its URL once, nil for a
// track before any FILE line; sole is YES when the sheet names at most one
// file. A nil URL drops that file's rows.
+ (NSArray<AudioTrack *> *)cueRowsInText:(NSString *)text sheetURL:(nullable NSURL *)sheetURL
                           resolvingFile:(NSURL *_Nullable (^)(NSString *_Nullable name, BOOL sole))resolve;

// The sheet at url as rows, each FILE resolved through the entry rungs below.
// A sheet naming one image — or none — that no rung finds takes the audio named
// like the sheet beside it (Mix.cue's Mix.flac). An entry readable nowhere
// still yields its primary candidate, as for M3U.
+ (NSArray<AudioTrack *> *)cueRowsForSheetAtURL:(NSURL *)url;

// The same, a FILE first looked up in knownFiles — the files a folder walk
// just listed, keyed by knownFileKeyForPath: — so a sheet whose files were
// listed costs no probe and its rows carry the listing's spelling; a miss
// takes the rungs.
+ (NSArray<AudioTrack *> *)cueRowsForSheetAtURL:(NSURL *)url
                                     knownFiles:(nullable NSDictionary<NSString *, NSURL *> *)knownFiles;

// A path folded as the default volume compares names — case and Unicode
// normalization — so a sheet's spelling finds the listed file it means.
+ (NSString *)knownFileKeyForPath:(NSString *)path;

// The entries of an M3U playlist in list order: comment and directive lines
// (#…) skipped, file:// URLs reduced to their paths, other URL schemes
// (streams) dropped, backslash paths normalized to slashes. Duplicates are
// kept — repeating a track is a playlist's prerogative.
+ (NSArray<NSString *> *)m3uEntriesInText:(NSString *)text;

// The entries of the playlist file at url resolved to file URLs, in order; a
// CUE sheet's are its rows' files. Relative names resolve against the
// playlist's folder; an unreadable path falls back to its basename beside the
// playlist, then both spellings under each playable extension. An entry
// readable nowhere still yields its primary candidate, so the caller can ask
// for sandbox access and call again.
+ (NSArray<NSURL *> *)resolvedFileURLsForPlaylistAtURL:(NSURL *)url;

// The entries of M3U data this app wrote itself — m3uTextForTracks: with a
// nil directory, so every entry is absolute — as file URLs in order, with no
// resolution rungs and no probes: nothing is stat'd, a relative entry is
// skipped. The reader for the container mirror; a user's playlist file goes
// through resolvedFileURLsForPlaylistAtURL:.
+ (NSArray<NSURL *> *)fileURLsInM3UData:(nullable NSData *)data;

#pragma mark - Writing

// The playlist as extended M3U text: "#EXTM3U", then per track an
// "#EXTINF:<seconds>,<Artist - Title>" line and the path. A path is written
// relative to directory when the track sits under it and absolute otherwise;
// nil means absolute throughout. LF line endings, and the result reads back
// through m3uEntriesInText: and resolvedFileURLsForPlaylistAtURL: unchanged.
+ (NSString *)m3uTextForTracks:(NSArray<AudioTrack *> *)tracks
           relativeToDirectory:(nullable NSURL *)directory;

// That text written atomically as UTF-8 without a BOM: the one spelling of
// the file's encoding, for every playlist this app writes.
+ (BOOL)writeM3UForTracks:(NSArray<AudioTrack *> *)tracks
      relativeToDirectory:(nullable NSURL *)directory
                    toURL:(NSURL *)url
                    error:(NSError **)error;

// The deepest folder every track sits under — the directory a saved file
// makes every entry relative to. nil when nothing below the root is shared.
+ (nullable NSURL *)commonDirectoryForTracks:(NSArray<AudioTrack *> *)tracks;

// The app's private session mirror: explicit URL/defaults keep it independent
// of the shell and let tests use a temporary folder. No grants or Open Recent.
// A failed write removes both stale mirror and cursor; nil write uses atomic M3U.
+ (BOOL)saveSessionTracks:(NSArray<AudioTrack *> *)tracks currentIndex:(NSUInteger)index
                 enabled:(BOOL)enabled toURL:(NSURL *)url defaults:(NSUserDefaults *)defaults
                   write:(BOOL (^_Nullable)(NSError * _Nullable * _Nullable error))write
                   error:(NSError * _Nullable * _Nullable)error;
+ (void)removeSessionAtURL:(NSURL *)url defaults:(NSUserDefaults *)defaults;
+ (BOOL)restoreSessionAtURL:(NSURL *)url enabled:(BOOL)enabled defaults:(NSUserDefaults *)defaults
                     load:(void (^)(NSArray<NSURL *> *urls, NSUInteger index, BOOL paused))load;

@end

NS_ASSUME_NONNULL_END
