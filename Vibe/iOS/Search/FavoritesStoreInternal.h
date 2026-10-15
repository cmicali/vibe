//
//  FavoritesStoreInternal.h
//  Vibe (iOS)
//
//  A store of its own over the same defaults, as a relaunch reads them. The
//  macOS suite's round trips use it. The app has one, FavoritesStore.shared.
//

#import "FavoritesStore.h"

NS_ASSUME_NONNULL_BEGIN

@interface FavoritesStore (Internal)

- (instancetype)initPrivate;

@end

NS_ASSUME_NONNULL_END
