//
//  PlaylistFile.h
//  Vibe
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class AudioTrack;

// Readers for playlist-like files that expand into an ordered list of audio
// files — CUE sheets and M3U playlists — and the M3U writer. Only the file
// references are read: CUE TRACK/INDEX timing and M3U #EXTINF metadata are
// ignored, and the referenced files are loaded whole.
@interface PlaylistFile : NSObject

// YES for a (lowercased) path extension this class expands: cue, m3u, m3u8.
+ (BOOL)isPlaylistExtension:(NSString *)extension;

// Decodes playlist bytes to text. BOMs decide UTF-16/UTF-8; otherwise UTF-8 is
// tried first and Windows-1252 then Latin-1 catch the legacy writers, so a
// readable file never fails to decode outright. (.m3u8 promises UTF-8, which
// the first rung already covers.)
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
// Relative names resolve against the playlist's folder; when the named path is
// not readable, its basename beside the playlist is tried (rescuing the common
// Windows-absolute-path case), then both spellings again under each alternate
// audio extension — wav, aif, aiff, flac, mp3 — which rescues a rip
// transcoded after the sheet was written. An entry readable nowhere still
// yields its primary candidate — the caller decides whether that means "ask
// for sandbox access" or "skip" — so calling again after a grant resolves
// better.
+ (NSArray<NSURL *> *)resolvedFileURLsForPlaylistAtURL:(NSURL *)url;

#pragma mark - Writing

// The playlist as extended M3U text: "#EXTM3U", then per track an
// "#EXTINF:<seconds>,<Artist - Title>" line and the path. A path is written
// relative to directory when the track sits under it and absolute otherwise;
// nil means absolute throughout. LF line endings; the caller writes UTF-8
// without a BOM, and the result reads back through m3uEntriesInText: and
// resolvedFileURLsForPlaylistAtURL: unchanged.
+ (NSString *)m3uTextForTracks:(NSArray<AudioTrack *> *)tracks
           relativeToDirectory:(nullable NSURL *)directory;

// The deepest folder every track sits under — the directory a saved file
// makes every entry relative to. nil when nothing below the root is shared.
+ (nullable NSURL *)commonDirectoryForTracks:(NSArray<AudioTrack *> *)tracks;

@end

NS_ASSUME_NONNULL_END
