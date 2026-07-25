//
//  UIUpdateTimer.h
//  Vibe
//
//  Occlusion-gated repeating main-queue timer for playback-position UI: the
//  handler fires only while the work is wanted (playback wants updates) AND
//  the window is visible — the ticks' work is invisible when occluded
//  (Control Center keeps counting on its own). Owns the trap-prone dispatch
//  source bookkeeping (unbalanced resume/suspend traps, as does releasing a
//  suspended source) so the owner only states intent.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Main thread only (the setters reconcile the dispatch source in place).
@interface UIUpdateTimer : NSObject

// The handler runs on the main queue; capture weakly — the timer's owner
// usually owns the objects the handler touches.
- (instancetype)initWithHz:(NSUInteger)hz handler:(dispatch_block_t)handler;

// The two gates: the timer runs only while both are YES. Each set reconciles
// the underlying source immediately.
@property (nonatomic) BOOL wanted;
@property (nonatomic) BOOL windowVisible;

@end

NS_ASSUME_NONNULL_END
