//
//  UIUpdateTimer.h
//  Vibe
//
//  A main-queue timer for the playback-position UI that fires only while
//  wanted AND the window is visible. It owns the dispatch-source bookkeeping —
//  an unbalanced resume or suspend traps, as does releasing a suspended source.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Main thread only.
@interface UIUpdateTimer : NSObject

// The handler runs on main. Capture weakly: the owner usually owns what the
// handler touches.
- (instancetype)initWithHz:(NSUInteger)hz handler:(dispatch_block_t)handler;

@property (nonatomic) BOOL wanted;
@property (nonatomic) BOOL windowVisible;

// Takes effect at once, re-phasing the next tick a full interval out, so an
// unchanged value no-ops; 0 is ignored.
@property (nonatomic) NSUInteger hz;

@end

NS_ASSUME_NONNULL_END
