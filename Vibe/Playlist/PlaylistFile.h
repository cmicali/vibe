//
//  PlaylistFile.h
//  Vibe
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class AudioTrack;
extern NSString *const kVibeLastPlaylistCurrentIndexKey;

// Readers for playlist-like files that expand into an ordered list of audio
// files — CUE sheets and M3U playlists — and the M3U writer. Only the file
// references are read: CUE TRACK/INDEX timing and M3U #EXTINF metadata are
// ignored, and the referenced files are loaded whole.
@interface PlaylistFile : NSObject

// YES for a (lowercased) path extension this class expands: cue, m3u, m3u8.
+ (BOOL)isPlaylistExtension:(NSString *)extension;

// Decodes playlist bytes to text: a UTF-16 BOM, then a BOM-less UTF-16
// signature, then UTF-8, then Windows-1252 and Latin-1 for legacy writers, so
// a non-empty file always decodes.
+ (nullable NSString *)textFromData:(NSData *)data;

// The FILE entries of a CUE sheet in sheet order: quoted or unquoted names, a
// trailing type keyword (WAVE, MP3, …) stripped from unquoted ones, backslash
// paths normalized to slashes. Consecutive duplicates collapse to one, because
// some writers repeat the single image FILE before every TRACK.
+ (NSArray<NSString *> *)cueFileEntriesInText:(NSString *)text;

// The entries of an M3U playlist in list order: comment and directive lines
// (#…) skipped, file:// URLs reduced to their paths, other URL schemes
// (streams) dropped, backslash paths normalized to slashes. Duplicates are
// kept — repeating a track is a playlist's prerogative.
+ (NSArray<NSString *> *)m3uEntriesInText:(NSString *)text;

// The entries of the playlist file at url resolved to file URLs, in order.
// Relative names resolve against the playlist's folder; an unreadable path
// falls back to its basename beside the playlist, then both spellings under
// each playable extension. An entry readable nowhere still yields its primary
// candidate, so the caller can ask for sandbox access and call again.
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
