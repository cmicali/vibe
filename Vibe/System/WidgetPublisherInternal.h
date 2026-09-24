//
//  WidgetPublisherInternal.h
//  Vibe
//
//  WidgetPublisher's private surface, shared with the unit tests and the debug
//  command channel so a rename breaks their build rather than their run.
//

#import "WidgetPublisher.h"

NS_ASSUME_NONNULL_BEGIN

// VibeWidgetReloader's two class methods, for a class the mac only has as a
// runtime lookup. `completion` may run on any queue.
@protocol VibeWidgetReloading <NSObject>
+ (void)reload;
+ (void)queryPlaced:(void (^)(BOOL placed, NSError *_Nullable error))completion;
@end

@interface WidgetPublisher ()

// Stands in for VibeWidgetReloader in every publisher created after it, nil
// restoring it: the unit tests' WidgetKit, answering queries when and how
// they choose.
+ (void)setReloaderClass:(nullable Class<VibeWidgetReloading>)reloaderClass;

// The gate, as a current WidgetKit answer or the extension's demand signal
// (on) moves it. Opening it, or confirming it while a write awaits the answer,
// admits the current state (activationHandler included); closing it commits
// the empty snapshot and releases everything publishing held.
- (void)setWidgetPlaced:(BOOL)placed;

// The one writer of the shared container, serial: tests hold it to stage a
// write still queued when the app quits.
@property (nonatomic, readonly) dispatch_queue_t queue;

@end

NS_ASSUME_NONNULL_END
