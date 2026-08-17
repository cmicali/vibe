//
//  LibraryViewController.m
//  Vibe (iOS)
//
//  See LibraryViewController.h. The row is LibraryTrackCell, at the bottom of
//  this file: it is drawn nowhere else, so it needs no header.
//

#import "LibraryViewController.h"

#import "AudioTrack.h"
#import "EqualizerIndicatorView.h"
#import "PlaybackController.h"
#import "Playlist.h"
#import "SettingsViewController.h"
#import "VibeStrings.h"

static NSString *const kTrackCellIdentifier = @"track";
// Apple Music's proportions: a roomy row, artwork most of its height, and the
// text block two lines deep beside it.
static const CGFloat kEstimatedRowHeight = 64;
// Measured off the Apple Music screenshot this row is modelled on: 44pt
// artwork with a 14pt gap to the text. The row is taller than that shot's 59pt
// because these rows carry two lines of text where those carry one.
static const CGFloat kArtSide = 44;
static const CGFloat kNumberColumnWidth = 26;
static const CGFloat kArtTextGap = 14;

#pragma mark - The row

// The mac playlist table's four columns in one iOS row. The number column
// carries the app's bouncing bars on the playing row instead of its index —
// the very same EqualizerIndicatorView the mac table draws, which is why it
// lives in the shared Vibe/Controls/.
@interface LibraryTrackCell : UITableViewCell
// Answers whether the row's height can have moved — the artist line appearing
// or leaving is the only thing here that changes it. A caller rendering in
// place owes the table a height recompute when it does; see
// refreshVisibleRowAtIndex:.
- (BOOL)renderTrack:(AudioTrack *)track
             number:(NSUInteger)number
            playing:(BOOL)playing
          animating:(BOOL)animating;
@end

#pragma mark - The screen

@interface LibraryViewController () <PlaybackObserver>
@end

@implementation LibraryViewController {
    PlaybackController *_playback;
    Playlist           *_playlist;
    // The last pick found no audio. It changes what the empty state says, and
    // it is cleared by the next open that does find something.
    BOOL               _lastPickWasEmpty;
}

- (instancetype)initWithPlayback:(PlaybackController *)playback {
    self = [super initWithStyle:UITableViewStylePlain];
    if (self) {
        _playback = playback;
        _playlist = playback.playlist;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.rightBarButtonItem =
            [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"gearshape"]
                                             style:UIBarButtonItemStylePlain
                                            target:self
                                            action:@selector(settingsTapped)];
    self.navigationItem.rightBarButtonItem.accessibilityLabel = STR_SETTINGS_TITLE;
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeAlways;
    self.navigationController.navigationBar.prefersLargeTitles = YES;

    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = kEstimatedRowHeight;
    // The rule starts at the title, past the artwork, as Apple Music's does.
    self.tableView.separatorInset =
            UIEdgeInsetsMake(0, 12 + kNumberColumnWidth + 8 + kArtSide + kArtTextGap, 0, 0);
    [self.tableView registerClass:LibraryTrackCell.class forCellReuseIdentifier:kTrackCellIdentifier];

    [_playback addObserver:self];
    [self refreshChrome];
}

- (void)openTapped {
    [_playback presentPickerFromViewController:self];
}

// Pushed rather than presented: the mini strip and the tabs stay up, and the
// settings on it are all things the strip and the card behind it draw.
- (void)settingsTapped {
    [self.navigationController pushViewController:[[SettingsViewController alloc] init]
                                         animated:YES];
}

// Title and empty state both follow "is there anything to play", so they move
// together and from one place.
- (void)refreshChrome {
    // navigationItem, not self.title: the latter is also the tab bar item's
    // title, and the open folder's name is not what the tab is called.
    self.navigationItem.title = _playback.folderDisplayName ?: STR_TAB_PLAYLIST;
    if (_playlist.count > 0) {
        self.contentUnavailableConfiguration = nil;
        return;
    }
    UIContentUnavailableConfiguration *empty =
            [UIContentUnavailableConfiguration emptyConfiguration];
    empty.image = [UIImage systemImageNamed:@"music.note.list"];
    empty.text = STR_LABEL_EMPTY_TITLE;
    empty.secondaryText = _lastPickWasEmpty ? STR_ERROR_FOLDER_EMPTY : STR_LABEL_EMPTY_MESSAGE;
    UIButtonConfiguration *button = [UIButtonConfiguration borderedProminentButtonConfiguration];
    button.title = STR_BUTTON_OPEN;
    button.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    empty.button = button;
    __weak LibraryViewController *weakSelf = self;
    empty.buttonProperties.primaryAction =
            [UIAction actionWithHandler:^(__kindof UIAction *action) {
        [weakSelf openTapped];
    }];
    self.contentUnavailableConfiguration = empty;
}

#pragma mark - Table

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)_playlist.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    LibraryTrackCell *cell = [tableView dequeueReusableCellWithIdentifier:kTrackCellIdentifier
                                                             forIndexPath:indexPath];
    NSUInteger index = (NSUInteger)indexPath.row;
    BOOL playing = index == _playlist.currentIndex && _playlist.count > 0;
    [cell renderTrack:[_playlist trackAtIndex:index]
               number:index + 1
              playing:playing
            animating:(playing && _playback.isPlaying)];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    [_playback selectTrackAtIndex:(NSUInteger)indexPath.row];
}

- (void)refreshVisibleRowAtIndex:(NSUInteger)index {
    if (index >= _playlist.count) {
        return;
    }
    NSIndexPath *path = [NSIndexPath indexPathForRow:(NSInteger)index inSection:0];
    LibraryTrackCell *cell = [self.tableView cellForRowAtIndexPath:path];
    if (!cell) {
        return;
    }
    BOOL playing = index == _playlist.currentIndex;
    BOOL heightMoved = [cell renderTrack:[_playlist trackAtIndex:index]
                                  number:index + 1
                                 playing:playing
                               animating:(playing && _playback.isPlaying)];
    // TRAP: rendering in place does NOT re-run an automatic-dimension row's
    // height. The artist line arriving with metadata grows the text stack, and
    // at accessibility sizes that no longer fits the height the row was given —
    // so an empty update pass is what asks the table to measure it again.
    if (heightMoved) {
        [self.tableView performBatchUpdates:nil completion:nil];
    }
}

#pragma mark - PlaybackObserver

- (void)playbackDidReplacePlaylist:(PlaybackController *)playback {
    _lastPickWasEmpty = NO;
    [self.tableView reloadData];
    [self refreshChrome];
}

- (void)playback:(PlaybackController *)playback didAppendTracksAtIndexes:(NSIndexSet *)indexes {
    [self.tableView reloadData];
    [self refreshChrome];
}

- (void)playback:(PlaybackController *)playback didReplaceTrackAtIndex:(NSUInteger)index {
    [self refreshVisibleRowAtIndex:index];
}

- (void)playback:(PlaybackController *)playback
        didChangeCurrentIndexFromIndex:(NSUInteger)previousIndex {
    [self refreshVisibleRowAtIndex:previousIndex];
    [self refreshVisibleRowAtIndex:playback.currentIndex];
    // The mac scrolls the playing row into view on every track change and
    // nowhere else; the same rule, and the same no-op when it is already up.
    if (playback.currentIndex < _playlist.count) {
        [self.tableView scrollToRowAtIndexPath:
                [NSIndexPath indexPathForRow:(NSInteger)playback.currentIndex inSection:0]
                              atScrollPosition:UITableViewScrollPositionNone
                                      animated:YES];
    }
}

// Only the playing row draws the play state, and only on its bars.
- (void)playbackDidChangePlayState:(PlaybackController *)playback {
    [self refreshVisibleRowAtIndex:playback.currentIndex];
}

- (void)playback:(PlaybackController *)playback didLoadMetadataForTrack:(AudioTrack *)track {
    NSInteger row = [_playlist getIndexForTrack:track];
    if (row >= 0) {
        [self refreshVisibleRowAtIndex:(NSUInteger)row];
    }
}

- (void)playbackDidOpenEmptyFolder:(PlaybackController *)playback {
    _lastPickWasEmpty = YES;
    [self refreshChrome];
}

- (void)playbackHasNothingToRestore:(PlaybackController *)playback {
    [self refreshChrome];
}

@end

#pragma mark - LibraryTrackCell

@implementation LibraryTrackCell {
    UILabel                 *_numberLabel;
    EqualizerIndicatorView  *_indicatorView;
    UIImageView *_artView;
    UILabel     *_titleLabel;
    UILabel     *_artistLabel;
    UILabel     *_durationLabel;
    UIStackView *_textStack;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style
              reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        [self build];
    }
    return self;
}

- (void)build {
    UIView *content = self.contentView;

    // The row number and the duration are the artist line's size, exactly:
    // same text style, so they scale together under Dynamic Type rather than
    // agreeing only at the default size. Monospaced digits so the two columns
    // of numbers stay in line down the list.
    UIFont *numbers = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleFootnote]
            scaledFontForFont:[UIFont monospacedDigitSystemFontOfSize:13
                                                               weight:UIFontWeightRegular]];

    _numberLabel = [[UILabel alloc] init];
    _numberLabel.font = numbers;
    _numberLabel.adjustsFontForContentSizeCategory = YES;
    _numberLabel.textColor = UIColor.secondaryLabelColor;
    _numberLabel.textAlignment = NSTextAlignmentRight;
    _numberLabel.adjustsFontSizeToFitWidth = YES;
    _numberLabel.minimumScaleFactor = 0.6;
    _numberLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:_numberLabel];

    // The mac's five bouncing bars, literally: same layers, same keyframe
    // tables, same mismatched durations.
    _indicatorView = [[EqualizerIndicatorView alloc] initWithFrame:CGRectZero];
    _indicatorView.hidden = YES;
    _indicatorView.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:_indicatorView];

    _artView = [[UIImageView alloc] init];
    _artView.contentMode = UIViewContentModeScaleAspectFill;
    _artView.clipsToBounds = YES;
    _artView.layer.cornerRadius = 4;
    _artView.layer.cornerCurve = kCACornerCurveContinuous;
    _artView.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:_artView];

    _titleLabel = [[UILabel alloc] init];
    _titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    _titleLabel.adjustsFontForContentSizeCategory = YES;
    _titleLabel.textColor = UIColor.labelColor;
    _titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;

    _artistLabel = [[UILabel alloc] init];
    _artistLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    _artistLabel.adjustsFontForContentSizeCategory = YES;
    _artistLabel.textColor = UIColor.secondaryLabelColor;
    _artistLabel.lineBreakMode = NSLineBreakByTruncatingTail;

    // Title over artist, the way Apple Music stacks them. Negative spacing for
    // the same reason as the mini player's: a label's height carries its
    // font's leading, so zero already reads as a gap.
    UIStackView *text = [[UIStackView alloc] initWithArrangedSubviews:@[_titleLabel, _artistLabel]];
    text.axis = UILayoutConstraintAxisVertical;
    text.alignment = UIStackViewAlignmentLeading;
    text.spacing = -2;
    text.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:text];
    _textStack = text;

    _durationLabel = [[UILabel alloc] init];
    _durationLabel.font = numbers;
    _durationLabel.adjustsFontForContentSizeCategory = YES;
    _durationLabel.textColor = UIColor.secondaryLabelColor;
    _durationLabel.textAlignment = NSTextAlignmentRight;
    _durationLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:_durationLabel];
    [_durationLabel setContentCompressionResistancePriority:UILayoutPriorityRequired
                                                    forAxis:UILayoutConstraintAxisHorizontal];

    [NSLayoutConstraint activateConstraints:@[
        [content.heightAnchor constraintGreaterThanOrEqualToConstant:kEstimatedRowHeight],

        [_numberLabel.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:12],
        [_numberLabel.widthAnchor constraintEqualToConstant:kNumberColumnWidth],
        [_numberLabel.centerYAnchor constraintEqualToAnchor:content.centerYAnchor],
        [_numberLabel.topAnchor constraintGreaterThanOrEqualToAnchor:content.topAnchor constant:8],
        [_numberLabel.bottomAnchor constraintLessThanOrEqualToAnchor:content.bottomAnchor constant:-8],

        [_indicatorView.centerXAnchor constraintEqualToAnchor:_numberLabel.centerXAnchor],
        [_indicatorView.centerYAnchor constraintEqualToAnchor:content.centerYAnchor],
        // The mac draws it 16x14 in a 28pt row; the same proportions here.
        [_indicatorView.widthAnchor constraintEqualToConstant:16],
        [_indicatorView.heightAnchor constraintEqualToConstant:14],

        [_artView.leadingAnchor constraintEqualToAnchor:_numberLabel.trailingAnchor constant:8],
        [_artView.centerYAnchor constraintEqualToAnchor:content.centerYAnchor],
        [_artView.widthAnchor constraintEqualToConstant:kArtSide],
        [_artView.heightAnchor constraintEqualToConstant:kArtSide],
        [_artView.topAnchor constraintGreaterThanOrEqualToAnchor:content.topAnchor constant:10],
        [_artView.bottomAnchor constraintLessThanOrEqualToAnchor:content.bottomAnchor constant:-10],

        [_textStack.leadingAnchor constraintEqualToAnchor:_artView.trailingAnchor
                                                 constant:kArtTextGap],
        [_textStack.centerYAnchor constraintEqualToAnchor:content.centerYAnchor],
        [_textStack.topAnchor constraintGreaterThanOrEqualToAnchor:content.topAnchor constant:8],
        [_textStack.bottomAnchor constraintLessThanOrEqualToAnchor:content.bottomAnchor constant:-8],
        [_textStack.trailingAnchor constraintLessThanOrEqualToAnchor:_durationLabel.leadingAnchor
                                                            constant:-8],

        [_durationLabel.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-16],
        [_durationLabel.centerYAnchor constraintEqualToAnchor:content.centerYAnchor],
        [_durationLabel.topAnchor constraintGreaterThanOrEqualToAnchor:content.topAnchor constant:8],
        [_durationLabel.bottomAnchor constraintLessThanOrEqualToAnchor:content.bottomAnchor constant:-8],
    ]];
}

- (BOOL)renderTrack:(AudioTrack *)track
             number:(NSUInteger)number
            playing:(BOOL)playing
          animating:(BOOL)animating {
    _numberLabel.text = [NSString stringWithFormat:@"%lu", (unsigned long)number];
    _numberLabel.hidden = playing;
    _indicatorView.hidden = !playing;
    _indicatorView.animating = animating;
    _artView.image = track.cachedThumbnail ?: [UIImage imageNamed:@"record-bg"];
    _durationLabel.text = track.durationString;
    _titleLabel.text = track.displayTitle ?: @"";
    // A nil displayArtist means there is no second line to draw, not an empty
    // one — the cross-directory rule AudioTrack is the single home of. Hidden
    // rather than blank, so the title centres on its own.
    NSString *artist = track.displayArtist;
    BOOL hidden = artist.length == 0;
    BOOL heightMoved = hidden != _artistLabel.isHidden;
    _artistLabel.text = artist ?: @"";
    _artistLabel.hidden = hidden;
    return heightMoved;
}

@end
