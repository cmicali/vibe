//
//  FolderSessionRules.h
//  Vibe (iOS)
//
//  FolderSession's decisions: which open the next launch restores, and whether
//  an Add may still land. Header-only and Foundation-only so the macOS suite
//  can test it.
//

#ifndef FolderSessionRules_h
#define FolderSessionRules_h

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - The restored playlist

// Whether an open's base becomes the bookmark the next launch restores. An
// open strictly inside a one-off pick's grant keeps the session's. A one-file
// open keeps a folder bookmark, whose grant reaches more than the file. A
// link is the one exception. It needs no grant, a web address is the only
// other way back to it, and the next launch restores it from its
// placeholder. A mirror file opened alone keeps the folder bookmark.
static inline BOOL VibeFolderSessionPersistsBase(BOOL keepsSessionBookmark,
                                                 BOOL openedFolder,
                                                 BOOL persistedBaseIsFolder,
                                                 BOOL baseIsLink) {
    if (keepsSessionBookmark) {
        return NO;
    }
    return openedFolder || baseIsLink || !persistedBaseIsFolder;
}

#pragma mark - The open intent

// A replace bumps openIntentGeneration and an Add captures it as its token.
// The landed generation is the last settled replace's, and zero while nothing
// has landed. FolderSession holds the state.

// Whether an Add may still land, from the token taken when the user asked. A
// token one below the live promoted generation is a promoted sibling's, so it
// is still the user's. A real replace or a clear bumps past it.
static inline BOOL VibeFolderSessionAddTokenIsCurrent(uint64_t token,
                                                      uint64_t openIntentGeneration,
                                                      uint64_t promotedOpenIntentGeneration) {
    if (token == openIntentGeneration) {
        return YES;
    }
    return promotedOpenIntentGeneration != 0
            && token + 1 == promotedOpenIntentGeneration
            && openIntentGeneration == promotedOpenIntentGeneration;
}

// The landed generation after a replace settles empty or is cancelled. The
// playlist left standing answers for it, so a later Add captures a generation
// that landed. Zero stays zero, so the next Add is still promoted.
static inline uint64_t VibeFolderSessionCarriedOpenIntentGeneration(uint64_t landedOpenIntentGeneration,
                                                                    uint64_t openIntentGeneration) {
    return landedOpenIntentGeneration != 0 ? openIntentGeneration : 0;
}

NS_ASSUME_NONNULL_END

#endif /* FolderSessionRules_h */
