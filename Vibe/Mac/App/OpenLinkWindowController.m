//
//  OpenLinkWindowController.m
//  Vibe
//

#import "OpenLinkWindowController.h"
#import "AppDelegate.h"
#import "LinkRules.h"
#import "MainPlayerController.h"
#import "MenuValidationRules.h"
#import "VibeStrings.h"

#if DEBUG
#import "OpenLinkWindowController+Debug.h"
#endif

@implementation OpenLinkWindowController {
    __weak AppDelegate *_appDelegate;
    // The window and its controls while it is up. A second ⌘U re-fronts it.
    NSPanel *_openLinkWindow;
    NSTextField *_openLinkField;
    NSButton *_openLinkButton;
    NSProgressIndicator *_openLinkSpinner;
    // Cancels the window's link while it resolves.
    dispatch_block_t _cancelOpenLink;
}

- (instancetype)initWithAppDelegate:(AppDelegate *)appDelegate {
    self = [super init];
    if (self) {
        _appDelegate = appDelegate;
    }
    return self;
}

- (NSPanel *)window {
    return _openLinkWindow;
}

// Its own window, not a sheet, so the player keeps working while it is up.
// It stays up when Vibe is not active, since the link is often copied from a
// browser.
- (void)showWindow:(id)sender {
    NSWindow *player = _appDelegate.mainPlayerController.window;
    [player makeKeyAndOrderFront:sender];
    if (_openLinkWindow) {
        [_openLinkWindow makeKeyAndOrderFront:sender];
        [_openLinkWindow makeFirstResponder:_openLinkField];
        return;
    }
    const CGFloat width = 480;
    const CGFloat margin = 20;
    NSTextField *label = [NSTextField labelWithString:STR_LINK_PROMPT_LABEL];
    NSTextField *field = [NSTextField textFieldWithString:@""];
    field.placeholderString = VibeNotLocalized(@"https://");
    field.usesSingleLineMode = NO;
    field.cell.wraps = YES;
    field.cell.scrollable = NO;
    field.lineBreakMode = NSLineBreakByCharWrapping;
    field.delegate = self;
    NSButton *open = [NSButton buttonWithTitle:STR_BUTTON_OPEN target:self action:@selector(confirmOpenLink:)];
    open.keyEquivalent = @"\r";
    open.enabled = NO;
    NSButton *cancel = [NSButton buttonWithTitle:STR_BUTTON_CANCEL target:self action:@selector(cancelOpenLink:)];
    cancel.keyEquivalent = @"\e";
    NSProgressIndicator *spinner = [[NSProgressIndicator alloc] init];
    spinner.style = NSProgressIndicatorStyleSpinning;
    spinner.controlSize = NSControlSizeSmall;
    spinner.displayedWhenStopped = NO;
    [spinner sizeToFit];
    [open sizeToFit];
    [cancel sizeToFit];

    // Bottom up: the buttons at the right, the spinner beside them, a field
    // three lines tall, and its label.
    CGFloat buttonWidth = MAX(MAX(NSWidth(open.frame), NSWidth(cancel.frame)), 80);
    CGFloat buttonHeight = NSHeight(open.frame);
    open.frame = NSMakeRect(width - margin - buttonWidth, margin, buttonWidth, buttonHeight);
    cancel.frame = NSOffsetRect(open.frame, -(buttonWidth + 12), 0);
    NSSize spin = spinner.frame.size;
    spinner.frame = NSMakeRect(NSMinX(cancel.frame) - 10 - spin.width,
                               margin + (buttonHeight - spin.height) / 2, spin.width, spin.height);
    CGFloat lineHeight = [[[NSLayoutManager alloc] init] defaultLineHeightForFont:field.font];
    field.frame = NSMakeRect(margin, NSMaxY(open.frame) + margin, width - 2 * margin, ceil(3 * lineHeight) + 6);
    [label sizeToFit];
    label.frame = NSMakeRect(margin, NSMaxY(field.frame) + 6, NSWidth(label.frame), NSHeight(label.frame));

    NSPanel *panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, width, NSMaxY(label.frame) + margin)
                                                styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                                  backing:NSBackingStoreBuffered
                                                    defer:YES];
    panel.title = STR_LINK_PROMPT_TITLE;
    panel.hidesOnDeactivate = NO;
    panel.releasedWhenClosed = NO;
    panel.delegate = self;
    panel.initialFirstResponder = field;
    for (NSView *view in @[label, field, spinner, cancel, open]) {
        [panel.contentView addSubview:view];
    }
    NSRect frame = panel.frame;
    frame.origin = NSMakePoint(round(NSMidX(player.frame) - NSWidth(frame) / 2),
                               round(NSMidY(player.frame) - NSHeight(frame) / 2));
    [panel setFrame:[panel constrainFrameRect:frame toScreen:player.screen] display:NO];
    _openLinkWindow = panel;
    _openLinkField = field;
    _openLinkButton = open;
    _openLinkSpinner = spinner;
    [_appDelegate applyAuxiliaryWindowLevels];
    [panel makeKeyAndOrderFront:sender];
}

// Open is enabled only with a link in the field. The window stays up until
// the link settles. Its field and Open are disabled, and its spinner turns.
- (void)confirmOpenLink:(id)sender {
    _openLinkField.enabled = NO;
    _openLinkButton.enabled = NO;
    [_openLinkSpinner startAnimation:nil];
    __weak OpenLinkWindowController *weakSelf = self;
    NSPanel *window = _openLinkWindow;
    _cancelOpenLink = [_appDelegate openLinkString:_openLinkField.stringValue completion:^(NSURL *file, NSError *error) {
        // However it settled, a newer open's cancel included. The user's own
        // cancel already closed it, and a later window is not this one.
        OpenLinkWindowController *strongSelf = weakSelf;
        if (strongSelf && strongSelf->_openLinkWindow == window) {
            strongSelf->_cancelOpenLink = nil;
            [window close];
        }
    }];
}

// Cancel, Escape, and ⌘.: the window closes, which cancels the resolve.
- (void)cancelOpenLink:(id)sender {
    [_openLinkWindow close];
}

// ⌘W while the window is key. As its delegate, this catches the nil-targeted
// closeFile: ahead of the player's, which clears the playlist.
- (IBAction)closeFile:(id)sender {
    [_openLinkWindow performClose:sender];
}

// The player may have retitled the shared item "Close All Files".
- (BOOL)validateMenuItem:(NSMenuItem *)menuItem {
    if ([menuItem.identifier isEqualToString:kVibeMenuClose]) {
        menuItem.title = STR_MENU_FILE_CLOSE;
        return _openLinkWindow.isKeyWindow;
    }
    return YES;
}

// Every way the window goes ends here. A link still resolving stops, and
// nothing opens.
- (void)windowWillClose:(NSNotification *)notification {
    if (notification.object != _openLinkWindow) {
        return;
    }
    dispatch_block_t cancel = _cancelOpenLink;
    _cancelOpenLink = nil;
    _openLinkWindow = nil;
    _openLinkField = nil;
    _openLinkButton = nil;
    _openLinkSpinner = nil;
    if (cancel) {
        cancel();
    }
}

// A link has no line breaks, so a paste's are dropped.
- (void)controlTextDidChange:(NSNotification *)notification {
    NSText *editor = _openLinkField.currentEditor;
    NSString *text = editor.string;
    NSString *joined = [[text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]
            componentsJoinedByString:@""];
    if (joined.length != text.length) {
        editor.string = joined;
    }
    _openLinkButton.enabled = !VibeLinkTextIsBlank(joined);
}

// Return presses Open, with or without a modifier, and never breaks the line.
// Escape and ⌘. arrive as cancelOperation:, which would otherwise complete.
- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView doCommandBySelector:(SEL)selector {
    if (selector == @selector(insertNewline:) || selector == @selector(insertNewlineIgnoringFieldEditor:)
            || selector == @selector(insertLineBreak:)) {
        [_openLinkButton performClick:nil];
        return YES;
    }
    if (selector == @selector(cancelOperation:)) {
        [self cancelOpenLink:control];
        return YES;
    }
    return NO;
}

#if DEBUG
- (BOOL)debugResolving {
    return _cancelOpenLink != nil;
}
#endif

@end
