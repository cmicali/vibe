//
//  PlayableExtensions.h
//  Vibe
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Every audio extension Vibe plays, spelled once. Two consumers with two
// different needs read it: the open funnel's filter tests membership, and a
// playlist entry that named an unreadable file walks the spellings in order
// looking for a replacement.
//
// It is stateless, with all class methods, and Foundation-only, so it can sit
// below both of them. That position is the point: NSURLUtil imports
// PlaylistFile, so PlaylistFile cannot import NSURLUtil back, and a set either
// of them owned would have to be copied into the other.
//
// Must cover every spelling the CFBundleDocumentTypes claim admits:
// com.microsoft.waveform-audio declares wav, wave AND bwf, so dropping one
// would let Finder offer Vibe a file the filter then silently discards. OGG is
// not supported.
@interface PlayableExtensions : NSObject

// Lowercase, lossless before lossy. A playlist entry naming a pre-transcode
// file tries them in this order and takes the first that exists, so the order
// is what decides which replacement a folder holding several of them yields.
@property (class, readonly) NSArray<NSString *> *ordered;

// The same spellings, for membership tests.
@property (class, readonly) NSSet<NSString *> *lookup;

@end

NS_ASSUME_NONNULL_END
