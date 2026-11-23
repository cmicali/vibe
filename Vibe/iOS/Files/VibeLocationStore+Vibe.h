//
//  VibeLocationStore+Vibe.h
//  Vibe (iOS)
//
//  What only Vibe knows about its Locations: the defaults keys its grants
//  are stored under, and the names of the two roots that have none of their
//  own on disk, On My iPhone and Dropbox.
//

#import "VibeLocationStore.h"

NS_ASSUME_NONNULL_BEGIN

@interface VibeLocationStore (Vibe)

// Once at launch, before any scene names a folder. modelName is the
// device's, as UIDevice gives it (iPhone, iPad).
+ (void)installVibeWithDeviceModelName:(NSString *)modelName;

@end

NS_ASSUME_NONNULL_END
