//
//  ArtworkDisplayRules.h
//  Vibe
//
//  What the header does with the art it has, as a pure function of four facts,
//  testable without a window, a dock tile or a decode.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, VibeArtworkDisplayAction) {
    // The caller still checks identity before paying for the crop.
    VibeArtworkDisplayActionInstall,
    // Nothing to show YET: keeping the previous art stops the backdrop
    // flashing between two tracks that both have art.
    VibeArtworkDisplayActionKeepPrevious,
    VibeArtworkDisplayActionShowDefault,
};

// TRAP: nil art is not proof of artlessness, so artResolved is its own input.
// nil can also mean another worker holds the folder's resolve claim; treated
// as artless, the backdrop flashes over a cover arriving a moment later. Only
// the metadata's `artNeedsLoad` and `artLoadPending` tell the two apart.
//
//  hasTrack    — nothing loaded is definitively artless, or Close would
//                leave its art on screen.
//  artResolved — metadata exists, and no load is worth dispatching or in
//                flight.
//  initialized — the header has rendered once; before that there is no
//                previous art to keep.
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

// The generation orders renders for one target; the identities also matter
// when an unresolved replacement has started no render of its own.
static inline BOOL VibeArtworkRenderResultMayInstall(NSUInteger requestGeneration,
                                                      NSUInteger currentGeneration,
                                                      id _Nullable requestTrack,
                                                      id _Nullable requestMetadata,
                                                      id _Nullable requestArt,
                                                      id _Nullable targetTrack,
                                                      id _Nullable targetMetadata,
                                                      id _Nullable targetArt) {
    return requestGeneration == currentGeneration &&
            requestTrack == targetTrack && requestMetadata == targetMetadata &&
            requestArt == targetArt;
}

NS_ASSUME_NONNULL_END
