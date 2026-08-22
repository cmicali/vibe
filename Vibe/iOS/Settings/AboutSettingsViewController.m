//
//  AboutSettingsViewController.m
//  Vibe (iOS)
//
//  See AboutSettingsViewController.h.
//

#import "AboutSettingsViewController.h"

#import "AppStats.h"
#import "Formatters.h"
#import "NSBundle+BuildInfo.h"
#import "NSString+FormLabel.h"
#import "VibeProductURLs.h"
#import "VibeStrings.h"

typedef NS_ENUM(NSInteger, VibeAboutSection) {
    VibeAboutSectionLinks = 0,
    VibeAboutSectionStats,
    VibeAboutSectionCount,
};

// Same three, in the mac pane's order.
typedef NS_ENUM(NSInteger, VibeAboutLinkRow) {
    VibeAboutLinkRowWeb = 0,
    VibeAboutLinkRowSupport,
    VibeAboutLinkRowRepo,
    VibeAboutLinkRowCount,
};

typedef NS_ENUM(NSInteger, VibeAboutStatRow) {
    VibeAboutStatRowFilesOpened = 0,
    VibeAboutStatRowFoldersOpened,
    VibeAboutStatRowAudioPlayed,
    VibeAboutStatRowCount,
};

static const CGFloat kIconSide         = 88;
static const CGFloat kIconCornerRadius = 19.6;   // the iOS icon squircle at this size
static const CGFloat kHeaderTopPadding = 24;
static const CGFloat kHeaderBottomPadding = 12;

static NSString *const kValueCellIdentifier = @"value";

// The app icon, for the header. UIKit has no NSApp.applicationIconImage, so
// there are two ways to it and the order matters:
//
//   1. the asset catalog's own "AppIcon", which is only addressable by name
//      because ASSETCATALOG_COMPILER_INCLUDE_ALL_APPICON_ASSETS is on
//      (project.yml). This is the 1024pt rendition, and it carries the light,
//      dark and tintable variants, so it also tracks the appearance.
//   2. the loose PNG actool writes beside the executable, named by the
//      bundle's CFBundleIcons declaration.
//
// The fallback is worth keeping even though (1) works today: it is one build
// setting away from vanishing, and it is 120px against a header drawn at 88pt,
// which is the difference between a crisp icon and a visibly soft one. Nil is a
// real outcome — the header drops the image rather than drawing a placeholder
// that would itself read as the icon failing to load.
static UIImage *AppIconImage(void) {
    UIImage *catalogIcon = [UIImage imageNamed:@"AppIcon"];
    if (catalogIcon) {
        return catalogIcon;
    }
    NSDictionary *icons = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleIcons"];
    NSDictionary *primary = icons[@"CFBundlePrimaryIcon"];
    NSArray<NSString *> *files = primary[@"CFBundleIconFiles"];
    // Last, not first: the array is ordered smallest to largest.
    NSString *name = files.lastObject;
    return name.length ? [UIImage imageNamed:name] : nil;
}

@implementation AboutSettingsViewController

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = STR_SETTINGS_ABOUT;
    self.tableView.tableHeaderView = [self identityHeaderView];
}

// Icon, name and version, centered above the first group — the mac pane's
// identity block. A table header view is laid out by frame, so it is sized once
// here against the table's width and re-sized on rotation in viewDidLayoutSubviews.
- (UIView *)identityHeaderView {
    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 4;

    UIImage *icon = AppIconImage();
    if (icon) {
        UIImageView *iconView = [[UIImageView alloc] initWithImage:icon];
        iconView.contentMode = UIViewContentModeScaleAspectFit;
        iconView.layer.cornerRadius = kIconCornerRadius;
        iconView.layer.cornerCurve = kCACornerCurveContinuous;
        iconView.layer.masksToBounds = YES;
        iconView.accessibilityIgnoresInvertColors = YES;
        [NSLayoutConstraint activateConstraints:@[
            [iconView.widthAnchor constraintEqualToConstant:kIconSide],
            [iconView.heightAnchor constraintEqualToConstant:kIconSide],
        ]];
        [stack addArrangedSubview:iconView];
        [stack setCustomSpacing:10 afterView:iconView];
    }

    UILabel *name = [[UILabel alloc] init];
    name.text = VibeAppName();
    name.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    name.adjustsFontForContentSizeCategory = YES;
    [stack addArrangedSubview:name];

    UILabel *version = [[UILabel alloc] init];
    version.text = [NSString stringWithFormat:STR_LABEL_ABOUT_VERSION,
                    NSBundle.mainBundle.vibeVersionString];
    version.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    version.adjustsFontForContentSizeCategory = YES;
    version.textColor = UIColor.secondaryLabelColor;
    version.textAlignment = NSTextAlignmentCenter;
    version.numberOfLines = 0;
    [stack addArrangedSubview:version];

    UIView *header = [[UIView alloc] init];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [header addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:header.topAnchor constant:kHeaderTopPadding],
        [stack.bottomAnchor constraintEqualToAnchor:header.bottomAnchor
                                           constant:-kHeaderBottomPadding],
        [stack.leadingAnchor constraintEqualToAnchor:header.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:header.trailingAnchor],
    ]];
    return header;
}

// TRAP: a table header view is positioned by AUTORESIZING, not by the table's
// constraints, so it keeps whatever height its frame was given. Sizing it here
// — rather than once at build time — is what makes it survive a rotation, an
// iPad window resize and a Dynamic Type change, each of which changes the
// height the stack needs without the table asking for a new one.
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    UIView *header = self.tableView.tableHeaderView;
    CGFloat width = CGRectGetWidth(self.tableView.bounds);
    if (!header || width <= 0) {
        return;
    }
    CGFloat height = [header systemLayoutSizeFittingSize:CGSizeMake(width, 0)
                          withHorizontalFittingPriority:UILayoutPriorityRequired
                                verticalFittingPriority:UILayoutPriorityFittingSizeLevel].height;
    if (ABS(CGRectGetHeight(header.frame) - height) < 0.5
            && ABS(CGRectGetWidth(header.frame) - width) < 0.5) {
        return;     // assigning tableHeaderView re-enters layout; only do it on a real change
    }
    header.frame = CGRectMake(0, 0, width, height);
    self.tableView.tableHeaderView = header;
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return VibeAboutSectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (VibeAboutSection)section == VibeAboutSectionStats ? (NSInteger)VibeAboutStatRowCount
                                                              : (NSInteger)VibeAboutLinkRowCount;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    // Nothing over the links: three addresses under the app's own name need no
    // heading to say what they are.
    return (VibeAboutSection)section == VibeAboutSectionStats ? STR_SETTINGS_STATS_SECTION : nil;
}

// The link rows' display text is the bare address, deliberately unlocalized and
// deliberately not built from the URL constants: what is SHOWN drops the scheme,
// what is OPENED must not.
static NSString *LinkDisplayTextForRow(NSInteger row) {
    switch ((VibeAboutLinkRow)row) {
        case VibeAboutLinkRowSupport: return VibeNotLocalized(@"vibeplayer.app/support");
        case VibeAboutLinkRowRepo:    return VibeNotLocalized(@"github.com/cmicali/vibe");
        default:                      return VibeNotLocalized(@"vibeplayer.app");
    }
}

static NSString *LinkTitleForRow(NSInteger row) {
    switch ((VibeAboutLinkRow)row) {
        case VibeAboutLinkRowSupport: return STR_SETTINGS_ABOUT_SUPPORT;
        case VibeAboutLinkRowRepo:    return VibeNotLocalized(@"GitHub");
        default:                      return STR_SETTINGS_ABOUT_WEB;
    }
}

static NSString *LinkURLStringForRow(NSInteger row) {
    switch ((VibeAboutLinkRow)row) {
        case VibeAboutLinkRowSupport: return kVibeSupportURL;
        case VibeAboutLinkRowRepo:    return kVibeRepoURL;
        default:                      return kVibeWebURL;
    }
}

// The stat labels are the mac's, colon and all — the catalogs keep the form
// colon the mac's panes draw, and a grouped row drops it (NSString+FormLabel).
static NSString *StatTitleForRow(NSInteger row) {
    switch ((VibeAboutStatRow)row) {
        case VibeAboutStatRowFoldersOpened: return STR_SETTINGS_FOLDERS_OPENED_LABEL.vibeFormLabel;
        case VibeAboutStatRowAudioPlayed:   return STR_SETTINGS_AUDIO_PLAYED_LABEL.vibeFormLabel;
        default:                            return STR_SETTINGS_FILES_OPENED_LABEL.vibeFormLabel;
    }
}

- (NSString *)statValueTextForRow:(NSInteger)row {
    AppStats *stats = AppStats.sharedInstance;
    Formatters *formatters = Formatters.sharedInstance;
    switch ((VibeAboutStatRow)row) {
        case VibeAboutStatRowFoldersOpened:
            return [formatters countString:stats.totalFoldersOpened];
        case VibeAboutStatRowAudioPlayed:
            // Live: totalSecondsPlayed folds in the run still going, so opening
            // this screen mid-track reports the listening time including it.
            return [formatters spelledDurationString:stats.totalSecondsPlayed];
        default:
            return [formatters countString:stats.totalFilesOpened];
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kValueCellIdentifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                      reuseIdentifier:kValueCellIdentifier];
    }
    BOOL isLink = (VibeAboutSection)indexPath.section == VibeAboutSectionLinks;
    UIListContentConfiguration *content = [UIListContentConfiguration valueCellConfiguration];
    content.text = isLink ? LinkTitleForRow(indexPath.row) : StatTitleForRow(indexPath.row);
    content.secondaryText = isLink ? LinkDisplayTextForRow(indexPath.row)
                                   : [self statValueTextForRow:indexPath.row];
    if (isLink) {
        content.secondaryTextProperties.color = self.view.tintColor ?: UIColor.linkColor;
    }
    cell.contentConfiguration = content;
    cell.selectionStyle = isLink ? UITableViewCellSelectionStyleDefault
                                 : UITableViewCellSelectionStyleNone;
    cell.accessoryType = UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if ((VibeAboutSection)indexPath.section != VibeAboutSectionLinks) {
        return;     // a statistic is a readout, not a control
    }
    NSURL *url = [NSURL URLWithString:LinkURLStringForRow(indexPath.row)];
    if (url) {
        [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
    }
}

@end
