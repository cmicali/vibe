//
//  SettingsRules.h
//  Vibe
//

#import <Foundation/Foundation.h>

static inline NSInteger VibeNormalizedPitchRange(NSInteger range) {
    return range == 16 ? 16 : 8;
}
