//
//  FLACDisposalRules.h
//  Vibe
//
//  The filesystem-result and replacement-safety decisions for conversion
//  disposal. Pure inputs only; file I/O stays with AudioFileConverter.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger, VibeTrashOutcome) {
    VibeTrashOutcomeSkipped = 0,
    VibeTrashOutcomeFailed,
    VibeTrashOutcomeMovedKnownURL,
    VibeTrashOutcomeMovedUnknownURL,
};

// NSFileManager's BOOL is authoritative: a successful trash may still return
// no resulting URL, which means moved but not programmatically restorable.
static inline VibeTrashOutcome VibeTrashOutcomeForResult(
        BOOL moved, BOOL hasResultURL) {
    if (!moved) {
        return VibeTrashOutcomeFailed;
    }
    return hasResultURL ? VibeTrashOutcomeMovedKnownURL
                        : VibeTrashOutcomeMovedUnknownURL;
}

static inline BOOL VibeTrashOutcomeDidMove(VibeTrashOutcome outcome) {
    return outcome == VibeTrashOutcomeMovedKnownURL ||
            outcome == VibeTrashOutcomeMovedUnknownURL;
}

typedef NS_ENUM(NSUInteger, VibeFLACFileLocation) {
    VibeFLACFileLocationExpectedPath = 0,
    VibeFLACFileLocationKnownTrashURL,
    VibeFLACFileLocationUnknownTrashURL,
};

// A failed or skipped trash leaves the item where it was. Successful movement
// without a returned URL stays distinct: nil may never become proof that the
// item is back at its expected path.
static inline VibeFLACFileLocation VibeFLACFileLocationAfterTrash(
        VibeTrashOutcome outcome) {
    if (outcome == VibeTrashOutcomeMovedKnownURL) {
        return VibeFLACFileLocationKnownTrashURL;
    }
    if (outcome == VibeTrashOutcomeMovedUnknownURL) {
        return VibeFLACFileLocationUnknownTrashURL;
    }
    return VibeFLACFileLocationExpectedPath;
}

// A failed inverse still leaves its opposite on NSUndoManager's stack. If the
// counterpart is already in a known or unknown Trash location, the expected
// path may now belong to an unrelated file and must not be disposed.
static inline BOOL VibeFLACMayDisposeExpectedPath(
        VibeFLACFileLocation location) {
    return location == VibeFLACFileLocationExpectedPath;
}

NS_ASSUME_NONNULL_END
