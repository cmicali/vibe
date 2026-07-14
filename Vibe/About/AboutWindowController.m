//
//  AboutWindowController.m
//  Vibe
//

#import "AboutWindowController.h"
#import "VectorBallsView.h"
#import "Fonts.h"

static const CGFloat kAboutWindowWidth = 460;
static const CGFloat kAboutWindowHeight = 340;

@interface AboutWindowController () <NSWindowDelegate>
@end

@implementation AboutWindowController {
    VectorBallsView *_ballsView;
}

- (instancetype)init {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, kAboutWindowWidth, kAboutWindowHeight)
                                                   styleMask:NSWindowStyleMaskTitled |
                                                             NSWindowStyleMaskClosable |
                                                             NSWindowStyleMaskFullSizeContentView
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    window.title = @"About Vibe";
    window.titleVisibility = NSWindowTitleHidden;
    window.titlebarAppearsTransparent = YES;
    window.movableByWindowBackground = YES;
    window.releasedWhenClosed = NO;
    window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    // Matches the Metal view's clear color so the text strip below it blends in.
    window.backgroundColor = [NSColor colorWithSRGBRed:0.02 green:0.02 blue:0.035 alpha:1.0];

    self = [super initWithWindow:window];
    if (self) {
        window.delegate = self;

        // Grooved record texture filling the window behind the vectorballs.
        // A backing layer with resizeAspectFill covers the landscape window
        // from the square source without letterbox bars or distortion.
        NSView *recordView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, kAboutWindowWidth, kAboutWindowHeight)];
        recordView.wantsLayer = YES;
        recordView.layer.contents = [NSImage imageNamed:@"record-bg"];
        recordView.layer.contentsGravity = kCAGravityResizeAspectFill;
        recordView.layer.masksToBounds = YES;
        recordView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [window.contentView addSubview:recordView];

        NSDictionary *info = NSBundle.mainBundle.infoDictionary;
#if DEBUG
        NSString *configuration = @"Debug";
#else
        NSString *configuration = @"Release";
#endif
        NSString *version = [NSString stringWithFormat:@"Version %@ (%@) · %@",
                                                       info[@"CFBundleShortVersionString"] ?: @"?",
                                                       info[@"CFBundleVersion"] ?: @"?",
                                                       configuration];
        [window.contentView addSubview:[self labelWithString:version
                                                    fontSize:11
                                                       alpha:0.55
                                                           y:30]];
        NSString *copyright = info[@"NSHumanReadableCopyright"] ?: @"";
        [window.contentView addSubview:[self labelWithString:copyright
                                                    fontSize:10
                                                       alpha:0.35
                                                           y:13]];
    }
    return self;
}

- (NSTextField *)labelWithString:(NSString *)string fontSize:(CGFloat)fontSize alpha:(CGFloat)alpha y:(CGFloat)y {
    NSTextField *label = [NSTextField labelWithString:string];
    label.font = [Fonts font:fontSize];
    label.textColor = [NSColor colorWithWhite:1.0 alpha:alpha];
    label.alignment = NSTextAlignmentCenter;
    label.frame = NSMakeRect(0, y, kAboutWindowWidth, fontSize + 6);
    return label;
}

- (void)showWindow:(id)sender {
    if (!self.window.isVisible) {
        [self.window center];
        // Build the Metal view fresh each time the window opens. MTKView's
        // render loop (and CVDisplayLink-based alternatives) does not reliably
        // resume after the window is closed and reopened, which left the balls
        // frozen on the second open; a new view always starts animating.
        [self rebuildBallsView];
    }
    [super showWindow:sender];
}

- (void)rebuildBallsView {
    [_ballsView removeFromSuperview];
    // Full-window frame, added above every other subview: the balls are drawn
    // over the version/copyright text where they happen to overlap it. The
    // view's transparent clear lets the text and record show through elsewhere.
    _ballsView = [[VectorBallsView alloc] initWithFrame:NSMakeRect(0, 0, kAboutWindowWidth, kAboutWindowHeight)];
    [self.window.contentView addSubview:_ballsView positioned:NSWindowAbove relativeTo:nil];
}

- (void)windowWillClose:(NSNotification *)notification {
    // Drop the Metal view and its resources; showWindow rebuilds it next time.
    [_ballsView removeFromSuperview];
    _ballsView = nil;
}

// Pause the 60fps Metal render loop while the window can't be seen (fully
// covered, app hidden, minimized) instead of burning GPU indefinitely. The
// animation is wall-clock based, so it resumes seamlessly.
- (void)windowDidChangeOcclusionState:(NSNotification *)notification {
    BOOL visible = (self.window.occlusionState & NSWindowOcclusionStateVisible) != 0;
    _ballsView.paused = !visible;
}

@end
