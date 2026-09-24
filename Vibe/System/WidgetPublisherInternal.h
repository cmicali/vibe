//
//  WidgetPublisherInternal.h
//  Vibe
//
//  WidgetPublisher's private surface, shared with the unit tests and the debug
//  command channel so a rename breaks their build rather than their run.
//

#import "WidgetPublisher.h"

NS_ASSUME_NONNULL_BEGIN

@interface WidgetPublisher ()

// The gate, as WidgetKit's answer (off) or the extension's demand signal (on)
// moves it. Opening it runs activationHandler; closing it commits the empty
// snapshot and releases everything publishing held.
- (void)setWidgetPlaced:(BOOL)placed;

// The one writer of the shared container, serial: tests hold it to stage a
// write still queued when the app quits.
@property (nonatomic, readonly) dispatch_queue_t queue;

@end

NS_ASSUME_NONNULL_END
