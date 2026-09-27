//
//  AboutWindowController.m
//  Vibe
//

#import "AboutWindowController.h"
#import "MenuValidationRules.h"
#import "VectorBallsView.h"
#import "VibeLinkLabel.h"
#import "Fonts.h"
#import "NSBundle+BuildInfo.h"
#import "VibeStrings.h"

static const CGFloat kAboutWindowWidth = 460;
static const CGFloat kAboutWindowHeight = 340;

// The main window's drop-hint size.
static const CGFloat kAboutTextFontSize = 13;

// Matched as a substring of NSHumanReadableCopyright, so Info.plist keeps the
// wording; an unmatched name renders unlinked.
static NSString *const kAboutAuthorName = @"Christopher Micali";
static NSString *const kAboutAuthorMailto = @"mailto:chrismicali@gmail.com";

@interface AboutWindowController () <NSWindowDelegate, NSMenuItemValidation>
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
    window.title = [NSString stringWithFormat:STR_MENU_APP_ABOUT, VibeAppName()];
    window.titleVisibility = NSWindowTitleHidden;
    window.titlebarAppearsTransparent = YES;
    window.movableByWindowBackground = YES;
    window.releasedWhenClosed = NO;
    window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    // The Metal view's clear color, so the text strip blends in.
    window.backgroundColor = [NSColor colorWithSRGBRed:0.02 green:0.02 blue:0.035 alpha:1.0];

    self = [super initWithWindow:window];
    if (self) {
        window.delegate = self;
        // The link is the only focusable view. The content view declines first
        // responder; without it AppKit focuses the link on open and draws its
        // ring unasked.
        window.autorecalculatesKeyViewLoop = YES;
        window.initialFirstResponder = window.contentView;

        // Aspect-fill covers the landscape window from the square source.
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
        // NOT infoDictionary[…]: only this applies InfoPlist.xcstrings.
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

// The attributes carry the centering: attributedStringValue overrides the
// field's alignment.
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
        // Fresh each open: MTKView's render loop does not reliably resume
        // after a close, and the balls freeze on the second open.
        [self rebuildBallsView];
    }
    [super showWindow:sender];
}

- (void)rebuildBallsView {
    [_ballsView removeFromSuperview];
    // Above everything; its transparent clear shows the text and the record
    // through.
    _ballsView = [[VectorBallsView alloc] initWithFrame:NSMakeRect(0, 0, kAboutWindowWidth, kAboutWindowHeight)];
    [self.window.contentView addSubview:_ballsView positioned:NSWindowAbove relativeTo:nil];
}

// ⌘W is nil-targeted: caught here, it closes this window rather than reaching
// the player's, which clears the playlist.
- (IBAction)closeFile:(nullable id)sender {
    [self.window performClose:sender];
}

// The player may have retitled the shared item "Close All Files".
- (BOOL)validateMenuItem:(NSMenuItem *)menuItem {
    if ([menuItem.identifier isEqualToString:kVibeMenuClose]) {
        menuItem.title = STR_MENU_FILE_CLOSE;
    }
    return YES;
}

- (void)windowWillClose:(NSNotification *)notification {
    [_ballsView removeFromSuperview]; // with its Metal resources
    _ballsView = nil;
    // TRAP: this window is reused (releasedWhenClosed = NO), so first responder
    // survives a close, and a focused link would reopen with its ring drawn.
    [self.window makeFirstResponder:nil];
}

// Paused while unseen. The animation is wall-clock based, so it resumes
// seamlessly.
- (void)windowDidChangeOcclusionState:(NSNotification *)notification {
    BOOL visible = (self.window.occlusionState & NSWindowOcclusionStateVisible) != 0;
    _ballsView.paused = !visible;
}

@end
