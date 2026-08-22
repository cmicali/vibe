//
//  VibeProductURLs.h
//  Vibe
//

#import <Foundation/Foundation.h>

// The project's own web addresses, spelled once. Both platforms' About screens
// list all three, and the mac's Help menu opens the support page, so a copy per
// call site is a copy to forget when one of them moves.
//
// Not localized and never displayed through the string catalog: an address is
// an identifier. What the row is CALLED is a STR_SETTINGS_ABOUT_* string; the
// address itself is drawn verbatim, which is why the display text is a
// VibeNotLocalized literal at each call site rather than derived from these.
extern NSString *const kVibeWebURL;
extern NSString *const kVibeSupportURL;
extern NSString *const kVibeRepoURL;
