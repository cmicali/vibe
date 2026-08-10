//
//  AboutWindowController.m
//  Vibe
//

#import "AboutWindowController.h"
#import "VectorBallsView.h"
#import "Fonts.h"
#import "NSBundle+BuildInfo.h"
#import "VibeStrings.h"

static const CGFloat kAboutWindowWidth = 460;
static const CGFloat kAboutWindowHeight = 340;

// Both lines are set at the main window's drop-hint size, so the About text
// reads at the same weight as the player's own small print.
static const CGFloat kAboutTextFontSize = 13;

// The author's name inside NSHumanReadableCopyright becomes a mailto link.
// Matched as a substring rather than composed here, so the copyright line
// stays Info.plist's to word; an unmatched name simply renders unlinked.
static NSString *const kAboutAuthorName = @"Christopher Micali";
static NSString *const kAboutAuthorMailto = @"mailto:chrismicali@gmail.com";

// A label with one clickable range. A selectable NSTextField would give links
// for free, but these labels span the window's full width while their text is
// centered and short, so selectability would turn a full-width strip into an
// I-beam that also swallows the window's background drag. This hit-tests the
// link's own glyphs instead: only those characters take the click and the
// pointing-hand cursor, and the rest of the label stays transparent.
@interface VibeLinkLabel : NSTextField
@property (nonatomic, copy) NSURL *linkURL;
@property (nonatomic) NSRange linkRange;
@end

@implementation VibeLinkLabel

// The link's glyph rect. The text is a single centered line, so measuring the
// whole string and the part before the link places it without a layout manager.
- (NSRect)linkRect {
    NSAttributedString *text = self.attributedStringValue;
    if (!self.linkURL || self.linkRange.length == 0
            || NSMaxRange(self.linkRange) > text.length) {
        return NSZeroRect;
    }
    CGFloat total = ceil(text.size.width);
    CGFloat before = ceil([text attributedSubstringFromRange:
            NSMakeRange(0, self.linkRange.location)].size.width);
    CGFloat width = ceil([text attributedSubstringFromRange:self.linkRange].size.width);
    CGFloat x = round((NSWidth(self.bounds) - total) / 2.0) + before;
    return NSMakeRect(x, 0, width, NSHeight(self.bounds));
}

- (NSView *)hitTest:(NSPoint)point {
    NSPoint local = [self convertPoint:point fromView:self.superview];
    return NSMouseInRect(local, [self linkRect], self.isFlipped) ? self : nil;
}

- (void)resetCursorRects {
    [super resetCursorRects];
    NSRect rect = [self linkRect];
    if (!NSIsEmptyRect(rect)) {
        [self addCursorRect:rect cursor:NSCursor.pointingHandCursor];
    }
}

- (void)mouseDown:(NSEvent *)event {
    NSPoint local = [self convertPoint:event.locationInWindow fromView:nil];
    if (self.linkURL && NSMouseInRect(local, [self linkRect], self.isFlipped)) {
        [NSWorkspace.sharedWorkspace openURL:self.linkURL];
    }
}

@end

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
    // Same key as the App menu item that opens this window.
    window.title = [NSString stringWithFormat:STR_MENU_APP_ABOUT, VibeAppName()];
    window.titleVisibility = NSWindowTitleHidden;
    window.titlebarAppearsTransparent = YES;
    window.movableByWindowBackground = YES;
    window.releasedWhenClosed = NO;
    window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    // Matches the Metal view's clear color, so the text strip below it blends
    // in.
    window.backgroundColor = [NSColor colorWithSRGBRed:0.02 green:0.02 blue:0.035 alpha:1.0];

    self = [super initWithWindow:window];
    if (self) {
        window.delegate = self;

        // A grooved record texture filling the window behind the vectorballs.
        // A backing layer with resizeAspectFill covers the landscape window
        // from the square source, with no letterbox bars and no distortion.
        NSView *recordView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, kAboutWindowWidth, kAboutWindowHeight)];
        recordView.wantsLayer = YES;
        recordView.layer.contents = [NSImage imageNamed:@"record-bg"];
        recordView.layer.contentsGravity = kCAGravityResizeAspectFill;
        recordView.layer.masksToBounds = YES;
        recordView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [window.contentView addSubview:recordView];

        NSString *version = [NSString stringWithFormat:STR_LABEL_ABOUT_VERSION,
                             NSBundle.mainBundle.vibeVersionString];
        [window.contentView addSubview:[self labelWithString:version
                                                    fontSize:kAboutTextFontSize
                                                       alpha:0.55
                                                           y:36]];
        // objectForInfoDictionaryKey:, NOT infoDictionary[…] — only the former applies InfoPlist.xcstrings.
        NSString *copyright = [NSBundle.mainBundle objectForInfoDictionaryKey:@"NSHumanReadableCopyright"] ?: @"";
        [window.contentView addSubview:[self copyrightLabelWithString:copyright
                                                            fontSize:kAboutTextFontSize
                                                               alpha:0.35
                                                                   y:14]];
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

// The copyright line, with the author's name underlined and wired to a mailto.
// The attributes carry the centering, because setting attributedStringValue
// overrides the field's own alignment.
- (NSTextField *)copyrightLabelWithString:(NSString *)string fontSize:(CGFloat)fontSize alpha:(CGFloat)alpha y:(CGFloat)y {
    VibeLinkLabel *label = [VibeLinkLabel labelWithString:string];
    label.frame = NSMakeRect(0, y, kAboutWindowWidth, fontSize + 6);

    NSMutableParagraphStyle *centered = [[NSParagraphStyle new] mutableCopy];
    centered.alignment = NSTextAlignmentCenter;
    NSMutableAttributedString *text = [[NSMutableAttributedString alloc] initWithString:string
            attributes:@{
                NSFontAttributeName: [Fonts font:fontSize],
                NSForegroundColorAttributeName: [NSColor colorWithWhite:1.0 alpha:alpha],
                NSParagraphStyleAttributeName: centered,
            }];

    NSRange name = [string rangeOfString:kAboutAuthorName];
    if (name.location != NSNotFound) {
        [text addAttribute:NSUnderlineStyleAttributeName
                     value:@(NSUnderlineStyleSingle)
                     range:name];
        label.linkRange = name;
        label.linkURL = [NSURL URLWithString:kAboutAuthorMailto];
    }
    label.attributedStringValue = text;
    return label;
}

- (void)showWindow:(id)sender {
    if (!self.window.isVisible) {
        [self.window center];
        // Build the Metal view fresh each time the window opens. MTKView's
        // render loop, and the CVDisplayLink-based alternatives, do not
        // reliably resume after the window is closed and reopened: the balls
        // freeze on the second open, whereas a new view always starts
        // animating.
        [self rebuildBallsView];
    }
    [super showWindow:sender];
}

- (void)rebuildBallsView {
    [_ballsView removeFromSuperview];
    // A full-window frame, added above every other subview, so the balls are
    // drawn over the version and copyright text wherever they overlap it. The
    // view's transparent clear lets the text and the record show through
    // elsewhere.
    _ballsView = [[VectorBallsView alloc] initWithFrame:NSMakeRect(0, 0, kAboutWindowWidth, kAboutWindowHeight)];
    [self.window.contentView addSubview:_ballsView positioned:NSWindowAbove relativeTo:nil];
}

- (void)windowWillClose:(NSNotification *)notification {
    // Drop the Metal view and its resources. showWindow rebuilds it next time.
    [_ballsView removeFromSuperview];
    _ballsView = nil;
}

// Pauses the 60fps Metal render loop while the window cannot be seen — fully
// covered, the app hidden, or minimized — rather than burning GPU
// indefinitely. The animation is wall-clock based, so it resumes seamlessly.
- (void)windowDidChangeOcclusionState:(NSNotification *)notification {
    BOOL visible = (self.window.occlusionState & NSWindowOcclusionStateVisible) != 0;
    _ballsView.paused = !visible;
}

@end
