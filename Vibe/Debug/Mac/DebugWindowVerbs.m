//
//  DebugWindowVerbs.m
//  Vibe
//
//  The main window's ordering and size, and the resize measurement.
//

#import "DebugInternal.h"

#if DEBUG

#import "VibeWorkTally.h"
#import <sys/resource.h>

static NSRect VibeWindowFrameForBodyWidth(MainWindow *window, CGFloat bodyPoints) {
    CGFloat panel = window.isPitchPanelShown ? kPitchPanelWidth : 0;
    NSRect frame = window.frame;
    frame.size.width = MAX(window.minSize.width, bodyPoints + panel);
    return [window frameKeptOnScreen:frame];
}

static double VibeProcessCPUSeconds(void) {
    struct rusage usage = {0};
    getrusage(RUSAGE_SELF, &usage);
    return usage.ru_utime.tv_sec + usage.ru_stime.tv_sec
            + (usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6;
}

NSArray<NSDictionary *> *VibeDebugWindowVerbs(void) {
    static NSArray<NSDictionary *> *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        table = @[
            // TRAP: a shell-driven launch lands behind the frontmost app (the
            // launch's cooperative activate is declined), and once the window
            // is occluded and playback paused the OS defers the whole app: its
            // timers and the channel's wake-up stall for up to ~20s. Ordered
            // front without activating, so the frontmost app keeps the
            // keyboard. No ordering helps a sleeping display or a locked
            // screen, where every window reads occluded. Occlusion settles
            // asynchronously, hence the spin.
            VibeDebugCmd(@"raise_window", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                NSWindow *window = controller.window;
                [window orderFrontRegardless];
                NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:1.0];
                while (!(window.occlusionState & NSWindowOcclusionStateVisible) && deadline.timeIntervalSinceNow > 0) {
                    [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode
                                           beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
                }
                return VibeJSONString(@{@"ok": @YES,
                        @"visible": @((BOOL)((window.occlusionState & NSWindowOcclusionStateVisible) != 0)),
                        @"displayAsleep": @((BOOL)(CGDisplayIsAsleep(CGMainDisplayID()) != 0))});
            }),
            VibeDebugCmd(@"set_window_width <body-points> [height-points] [seconds]", 15, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                double bodyPoints = 0, height = controller.window.frame.size.height, seconds = 0;
                if (tokens.count < 2 || tokens.count > 4 || !VibeParseDouble(tokens[1], &bodyPoints)
                        || (tokens.count > 2 && !VibeParseDouble(tokens[2], &height))
                        || (tokens.count > 3 && !VibeParseDouble(tokens[3], &seconds))
                        || !isfinite(bodyPoints) || bodyPoints <= 0 || bodyPoints > 10000
                        || !isfinite(height) || height <= 0 || height > 10000
                        || !isfinite(seconds) || seconds < 0 || seconds > 10) {
                    return VibeErrorJSON(@"usage: set_window_width <body-points> [height-points] [seconds 0..10]");
                }
                MainWindow *window = (MainWindow *)controller.window;
                CGFloat panel = window.isPitchPanelShown ? kPitchPanelWidth : 0;
                NSRect initial = window.frame;
                NSRect frame = VibeWindowFrameForBodyWidth(window, bodyPoints);
                frame.size.height = MAX(window.minSize.height, height);
                frame.origin.y = NSMaxY(initial) - frame.size.height;
                NSString *(^reply)(void) = ^{
                    return VibeJSONString(@{
                        @"ok": @YES, @"frame": NSStringFromRect(window.frame),
                        @"bodyWidth": @(window.frame.size.width - panel),
                    });
                };
                if (seconds == 0) {
                    [window setFrame:frame display:YES];
                    return reply();
                }
                // Frame changes at 60 Hz: layout and rendering, not an NSEvent
                // tracking loop.
                NSUInteger steps = (NSUInteger)ceil(seconds * 60);
                __block NSUInteger step = 0;
                NSTimer *timer = [NSTimer timerWithTimeInterval:seconds / steps repeats:YES block:^(NSTimer *timer) {
                    CGFloat t = (CGFloat)++step / steps;
                    NSRect next = NSMakeRect(initial.origin.x + (frame.origin.x - initial.origin.x) * t,
                                             initial.origin.y + (frame.origin.y - initial.origin.y) * t,
                                             initial.size.width + (frame.size.width - initial.size.width) * t,
                                             initial.size.height + (frame.size.height - initial.size.height) * t);
                    VibeSignpostBegin(window_resize);
                    [window setFrame:next display:YES];
                    VibeSignpostEnd(window_resize);
                    if (step == steps) {
                        [timer invalidate];
                        VibeWriteDebugResponse(commandId, reply());
                    }
                }];
                [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
                return nil;
            }),
            VibeDebugCmd(@"measure_resize <min-width> <max-width> <frames>", 60, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, MainPlayerController *controller) {
                static BOOL measuring = NO;
                double minWidth = 0, maxWidth = 0;
                NSUInteger frames = 0;
                if (tokens.count != 4 || !VibeParseDouble(tokens[1], &minWidth)
                        || !VibeParseDouble(tokens[2], &maxWidth)
                        || !VibeParseNonnegativeInteger(tokens[3], &frames)
                        || minWidth <= 0 || maxWidth <= minWidth || frames < 30 || frames > 600) {
                    return VibeErrorJSON(@"usage: measure_resize <min-width> <max-width> <frames 30-600>");
                }
                if (measuring) return VibeErrorJSON(@"a resize measurement is already running");
                measuring = YES;
                MainWindow *window = (MainWindow *)controller.window;
                NSRect originalFrame = window.frame;
                [window setFrame:VibeWindowFrameForBodyWidth(window, minWidth) display:YES];
                // Warm the first layout, then measure at display cadence with
                // no channel round trip per frame.
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    NSMutableArray<NSNumber *> *durations = [NSMutableArray arrayWithCapacity:frames];
                    double cpuStart = VibeProcessCPUSeconds();
                    CFTimeInterval start = CACurrentMediaTime();
                    __block NSUInteger index = 0;
                    VibeWorkTallyBegin("resize");
                    NSTimer *timer = [NSTimer timerWithTimeInterval:1.0 / 60 repeats:YES block:^(NSTimer *timer) {
                        double phase = (double)index / (frames - 1);
                        double width = minWidth + (maxWidth - minWidth) * (1 - fabs(2 * phase - 1));
                        CFTimeInterval frameStart = CACurrentMediaTime();
                        [window setFrame:VibeWindowFrameForBodyWidth(window, width) display:YES];
                        [durations addObject:@((CACurrentMediaTime() - frameStart) * 1000)];
                        if (++index < frames) return;
                        [timer invalidate];
                        // Include the final compositor commit and morph tail.
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                            double cpu = VibeProcessCPUSeconds() - cpuStart;
                            double elapsed = CACurrentMediaTime() - start;
                            NSDictionary *work = VibeWorkTallyTakeWindow();
                            NSArray<NSNumber *> *sorted = [durations sortedArrayUsingSelector:@selector(compare:)];
                            double total = 0;
                            for (NSNumber *duration in durations) total += duration.doubleValue;
                            [window setFrame:originalFrame display:YES];
                            measuring = NO;
                            VibeWriteDebugResponse(commandId, VibeJSONString(@{
                                @"ok": @YES, @"frames": @(frames), @"elapsedSeconds": @(elapsed),
                                @"cpuSeconds": @(cpu), @"frameMeanMS": @(total / frames),
                                @"frameP95MS": sorted[(frames - 1) * 95 / 100], @"frameMaxMS": sorted.lastObject,
                                @"work": work,
                            }));
                        });
                    }];
                    [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
                });
                return nil;
            }),
        ];
    });
    return table;
}

#endif
