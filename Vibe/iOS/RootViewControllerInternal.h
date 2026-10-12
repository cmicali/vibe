//
//  RootViewControllerInternal.h
//  Vibe (iOS)
//
//  What RootViewController.m and its +AddedRows category share.
//

#import "RootViewController.h"

NS_ASSUME_NONNULL_BEGIN

@interface RootViewController () {
    // Rows of Adds asked for and not yet settled, oldest first, and when
    // each was lifted.
    NSMutableArray<NSArray<UIView *> *> *_liftedRowBatches;
    NSMutableArray<NSNumber *> *_liftedRowBatchTimes;
}

// The Playlist tab's item, in this view; NO when the bar does not show it.
- (BOOL)getPlaylistTabCenter:(CGPoint *)center;

@end

// The flight of an Add's rows into the Playlist tab.
@interface RootViewController (AddedRows)

- (void)liftAddedRows:(NSArray<UIView *> *)rows;
- (NSArray<NSNumber *> *)liftedRowTimes;
- (void)settleEveryLiftedRowUnlanded;
- (void)settleLiftedRows:(NSArray<UIView *> *)rows landed:(BOOL)landed;

@end

NS_ASSUME_NONNULL_END
