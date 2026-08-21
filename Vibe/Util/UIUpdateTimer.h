//
//  UIUpdateTimer.h
//  Vibe
//
//  An occlusion-gated repeating main-queue timer for the playback-position UI.
//  The handler fires only while the work is wanted, meaning playback wants
//  updates, and the window is visible: the ticks' work is invisible when the
//  window is occluded, and Control Center keeps counting on its own.
//
//  It owns the trap-prone dispatch-source bookkeeping — an unbalanced resume or
//  suspend traps, as does releasing a suspended source — so the owner need only
//  state its intent.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Main thread only: the setters reconcile the dispatch source in place.
@interface UIUpdateTimer : NSObject

// The handler runs on the main queue. Capture weakly, because the timer's
// owner usually owns the objects the handler touches.
- (instancetype)initWithHz:(NSUInteger)hz handler:(dispatch_block_t)handler;

// The two gates. The timer runs only while both are YES, and each set
// reconciles the underlying source immediately.
@property (nonatomic) BOOL wanted;
@property (nonatomic) BOOL windowVisible;

// The tick rate, re-armed in place and taking effect immediately, running or
// not. Setting it re-phases the next tick from now, so it no-ops on the value
// it already holds; 0 is ignored.
@property (nonatomic) NSUInteger hz;

@end

NS_ASSUME_NONNULL_END
