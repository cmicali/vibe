//
//  ArtworkDisplayRules.h
//  Vibe
//
//  What the header should do with the art it has — a pure function of four
//  facts, so the policy can be tested without a window, a dock tile or a decode.
//  ArtworkDisplayController is then only the plumbing that carries it out.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, VibeArtworkDisplayAction) {
    // There is art to show. The caller still checks identity before paying for
    // the crop and the dominant-color pass.
    VibeArtworkDisplayActionInstall,
    // Nothing to show YET. The previous track's art stays up, which is what
    // keeps the record backdrop from flashing between two tracks that both
    // have artwork.
    VibeArtworkDisplayActionKeepPrevious,
    // Known to have no art at all: the backdrop replaces whatever is up.
    VibeArtworkDisplayActionShowDefault,
};

// TRAP, and why artResolved is an input of its own rather than derived from
// hasArt: **nil art is not proof of artlessness.** With the folder fallback, nil
// can also mean "another worker holds this folder's resolve claim", and treating
// that as artless flashes the backdrop over a cover that appears a moment later.
// Only the metadata's own account of what is pending (`artNeedsLoad`,
// `artLoadDispatched`) tells the two apart.
//
//  hasTrack    — a file is loaded at all. Nothing loaded is definitively
//                artless, or closing a file would leave its art on screen.
//  hasArt      — art is in hand right now.
//  artResolved — nothing is pending: no load worth dispatching and none in
//                flight, and the metadata exists to answer the question.
//  initialized — the header has rendered at least once. Before that there is
//                no "previous art" to keep, so an unresolved track must show
//                the backdrop rather than an empty frame.
static inline VibeArtworkDisplayAction VibeArtworkDisplayActionFor(BOOL hasTrack,
                                                                   BOOL hasArt,
                                                                   BOOL artResolved,
                                                                   BOOL initialized) {
    if (!hasTrack) {
        return VibeArtworkDisplayActionShowDefault;
    }
    if (hasArt) {
        return VibeArtworkDisplayActionInstall;
    }
    if (!artResolved) {
        return initialized ? VibeArtworkDisplayActionKeepPrevious
                           : VibeArtworkDisplayActionShowDefault;
    }
    return VibeArtworkDisplayActionShowDefault;
}

NS_ASSUME_NONNULL_END
