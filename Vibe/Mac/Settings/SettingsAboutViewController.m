//
//  SettingsAboutViewController.m
//  Vibe
//

#import "SettingsAboutViewController.h"
#import "AppDelegate.h"
#import "AppStats.h"
#import "Formatters.h"
#import "NSBundle+BuildInfo.h"
#import "VibeStrings.h"

static const CGFloat kAboutIconSize = 96;

static NSString *const kAboutWebURL = @"https://vibeplayer.app";
static NSString *const kAboutRepoURL = @"https://github.com/cmicali/vibe";

// A borderless button styled as a hyperlink; a plain NSButton so the debug
// walker addresses it by title.
@interface VibeSettingsLinkButton : NSButton
@end

@implementation VibeSettingsLinkButton

- (void)resetCursorRects {
    [super resetCursorRects];
    [self addCursorRect:self.bounds cursor:NSCursor.pointingHandCursor];
}

@end

@implementation SettingsAboutViewController {
    NSTextField *_filesOpenedValue;
    NSTextField *_foldersOpenedValue;
    NSTextField *_audioPlayedValue;
}

- (void)loadView {
    NSButton *webLink = [self linkButtonWithTitle:VibeNotLocalized(@"vibeplayer.app")
                                           action:@selector(openWeb:)];
    NSButton *supportLink = [self linkButtonWithTitle:VibeNotLocalized(@"vibeplayer.app/support")
                                               action:@selector(openSupport:)];
    NSButton *repoLink = [self linkButtonWithTitle:VibeNotLocalized(@"github.com/cmicali/vibe")
                                            action:@selector(openRepo:)];

    _filesOpenedValue = [self valueLabel];
    _foldersOpenedValue = [self valueLabel];
    _audioPlayedValue = [self valueLabel];

    [self loadPaneWithSections:@[
        [self identityBlock],
        [SettingsSectionView sectionWithRows:@[
            [SettingsRowView rowWithTitle:STR_SETTINGS_ABOUT_WEB control:webLink],
            [SettingsRowView rowWithTitle:STR_SETTINGS_ABOUT_SUPPORT control:supportLink],
            [SettingsRowView rowWithTitle:VibeNotLocalized(@"GitHub") control:repoLink],
        ]],
        [SettingsSectionView sectionWithHeader:STR_SETTINGS_STATS_SECTION rows:@[
            [SettingsRowView rowWithTitle:STR_SETTINGS_FILES_OPENED_LABEL control:_filesOpenedValue],
            [SettingsRowView rowWithTitle:STR_SETTINGS_FOLDERS_OPENED_LABEL control:_foldersOpenedValue],
            [SettingsRowView rowWithTitle:STR_SETTINGS_AUDIO_PLAYED_LABEL control:_audioPlayedValue],
        ]],
    ]];
}

// Icon, name and version, centered on the pane background rather than inside
// a card.
- (NSView *)identityBlock {
    // The icon doubles as the About window's opener, with the hand cursor as
    // the affordance. Nil-targeted: the settings window is key when clicked,
    // so the action resolves to AppDelegate.showAboutWindow: exactly as the
    // app menu's item does.
    VibeSettingsLinkButton *icon = [VibeSettingsLinkButton buttonWithImage:NSApp.applicationIconImage
                                                                    target:nil
                                                                    action:@selector(showAboutWindow:)];
    icon.bordered = NO;
    icon.imageScaling = NSImageScaleProportionallyUpOrDown;
    icon.accessibilityLabel = [NSString stringWithFormat:STR_MENU_APP_ABOUT, VibeAppName()];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [icon.widthAnchor constraintEqualToConstant:kAboutIconSize],
        [icon.heightAnchor constraintEqualToConstant:kAboutIconSize],
    ]];

    NSTextField *name = [NSTextField labelWithString:VibeAppName()];
    name.font = [NSFont systemFontOfSize:15 weight:NSFontWeightSemibold];

    NSString *versionText = [NSString stringWithFormat:STR_LABEL_ABOUT_VERSION,
                             NSBundle.mainBundle.vibeVersionString];
    NSTextField *version = [NSTextField labelWithString:versionText];
    version.font = [NSFont systemFontOfSize:12];
    version.textColor = NSColor.secondaryLabelColor;

    NSStackView *stack = [NSStackView stackViewWithViews:@[icon, name, version]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeCenterX;
    stack.spacing = 4;
    stack.edgeInsets = NSEdgeInsetsMake(12, 0, 0, 0);
    [stack setCustomSpacing:10 afterView:icon];
    return stack;
}

- (NSTextField *)valueLabel {
    NSTextField *label = [NSTextField labelWithString:@""];
    label.textColor = NSColor.secondaryLabelColor;
    return label;
}

- (NSButton *)linkButtonWithTitle:(NSString *)title action:(SEL)action {
    VibeSettingsLinkButton *button = [VibeSettingsLinkButton buttonWithTitle:title
                                                                      target:self
                                                                      action:action];
    button.bordered = NO;
    button.attributedTitle = [[NSAttributedString alloc] initWithString:title
            attributes:@{
                NSFontAttributeName: [NSFont systemFontOfSize:13],
                NSForegroundColorAttributeName: NSColor.linkColor,
            }];
    return button;
}

- (void)refreshFromSettings {
    AppStats *stats = AppStats.sharedInstance;
    Formatters *formatters = Formatters.sharedInstance;
    _filesOpenedValue.stringValue = [formatters countString:stats.totalFilesOpened];
    _foldersOpenedValue.stringValue = [formatters countString:stats.totalFoldersOpened];
    _audioPlayedValue.stringValue = [formatters spelledDurationString:stats.totalSecondsPlayed];
}

- (void)openWeb:(id)sender {
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:kAboutWebURL]];
}

- (void)openSupport:(id)sender {
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:kVibeSupportURL]];
}

- (void)openRepo:(id)sender {
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:kAboutRepoURL]];
}

@end
