//
// AudioCachePolicy.h
// Vibe
//
// The disk-cache policy shared by the two PINDiskCache-backed stores,
// AudioTrackMetadataCache and AudioWaveformCache. Keeping it in one home stops
// the policies drifting: both caches key off the same file identity, through
// NSURL+Hash, and their entries should live and die on the same terms.
//

#import <Foundation/Foundation.h>

// The per-cache disk budget. Entries are small — roughly 5-20KB for a metadata
// archive and 64KB for a waveform — so this holds thousands of tracks before
// LRU eviction starts.
static const NSUInteger kAudioCacheByteLimit = 64 * 1024 * 1024;

// Entries untouched for this long are evicted. A rewritten or moved file
// leaves an orphaned entry whose size-and-mtime key never matches again, and
// that must not sit in the byte budget forever.
static const NSTimeInterval kAudioCacheAgeLimit = 6 * (30 * (24 * 60 * 60)); // 6 months
