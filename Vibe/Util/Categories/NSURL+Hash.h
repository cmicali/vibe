//
//  NSURL+Hash.h
//  Vibe
//

#import <Foundation/Foundation.h>

@interface NSData (Hash)

// Lowercase hex SHA-1 of the bytes — the one spelling of the content-hash
// naming that cacheKey's path hash and AppTheme's custom-artwork files share.
- (nonnull NSString *)sha1Hex;

@end

@interface NSURL (Hash)

// A cheap identity key for caching: "<size>-<mtime_us>-<sha1(path)>", computed
// from the symlink-resolved path, so that a link keys off its target's
// identity. It reads file attributes only, never the file body, so it takes
// microseconds against the tens of milliseconds a content hash would cost. It
// misses on a rewrite, where the mtime changes, and on a rename or move, where
// the path hash changes. It is nil when the file cannot be statted, since
// there is then no stable identity to cache under, and callers must skip
// caching on nil.
- (nullable NSString *)cacheKey;

// A stat-free identity for naming a file the app itself lists — the widget's
// snapshot and its seek buttons carry it: lowercase hex SHA-1 of the
// standardized path, taken RELATIVE to the app's home for a file inside it.
// Unlike cacheKey it survives a rewrite of the file (no size or mtime), which
// a "which track is this" key must, and it never touches the disk. nil for a
// URL with no path.
//
// TRAP: the data container MOVES — on every simulator install, and iOS may
// move it on an update — so a key over the absolute path disagrees with every
// consumer that captured it before the move. A provider file lives outside
// the container at a path that does not move, and keeps the whole of it.
- (nullable NSString *)pathKey;

@end
