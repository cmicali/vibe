//
//  LibraryViewController.m
//  Vibe (iOS)
//
//  See LibraryViewController.h. The row is LibraryTrackCell, at the bottom of
//  this file: it is drawn nowhere else, so it needs no header.
//

#import "LibraryViewController.h"

#import "AudioTrack.h"
#import "AudioTrackMetadata.h"
#import "CloudTransferRegistry.h"
#import "EqualizerIndicatorView.h"
#import "LoadingIndicatorMath.h"
#import "LoadingIndicatorView.h"
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
// carries the app's live equalizer bars on the playing row instead of its index —
// the very same EqualizerIndicatorView the mac table draws, which is why it
// lives in the shared Vibe/Controls/.
@interface LibraryTrackCell : UITableViewCell
// Where the indicator's bars get their audio. Set at dequeue rather than in
// build, because the cell is minted by the table and never sees the model;
// a reused cell already carries it.
@property (nonatomic, weak, nullable) id<EqualizerLevelSource> levelSource;
@property (nonatomic) BOOL equalizerAudioOutputActive;
@property (nonatomic) BOOL equalizerPresentationVisible;
// The number gutter's loading bar: YES while a provider transfer is really
// running for this row's file. Loading outranks playing in the gutter —
// while the open is in flight there is no output audio, so the equalizer
// would be a row of collapsed dots; the loading bar says more.
@property (nonatomic, getter=isLoading) BOOL loading;
@property (nonatomic) float loadingProgress;
// Answers whether the row's height can have moved — the artist line appearing
// or leaving is the only thing here that changes it. A caller rendering in
// place owes the table a height recompute when it does; see
// refreshVisibleRowAtIndex:.
- (BOOL)renderTrack:(AudioTrack *)track
             number:(NSUInteger)number
            playing:(BOOL)playing;
@end

#pragma mark - The screen

@interface LibraryViewController () <PlaybackObserver, CloudTransferRegistryObserver>
@end

@implementation LibraryViewController {
    PlaybackController *_playback;
    Playlist           *_playlist;
    // The last pick found no audio. It changes what the empty state says, and
    // it is cleared by the next open that does find something.
    BOOL               _lastPickWasEmpty;
    // UIKit appearance handles tab switches and navigation pushes. The root's
    // separate surface fact handles the card, which moves over this view
    // without causing an appearance transition.
    BOOL               _viewPresentationVisible;
    BOOL               _equalizerSurfaceVisible;
    // A track change while another tab, Settings, or the full-screen card owns
    // the pixels. Hidden tables do not animate toward it; the next reveal parks
    // once at the newest index.
    NSUInteger         _pendingScrollIndex;
}

- (instancetype)initWithPlayback:(PlaybackController *)playback {
    self = [super initWithStyle:UITableViewStylePlain];
    if (self) {
        _playback = playback;
        _playlist = playback.playlist;
        _pendingScrollIndex = NSNotFound;
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
    CloudTransferRegistry.sharedRegistry.observer = self;
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(thumbnailDidLoad:)
                                               name:AudioTrackMetadataThumbnailDidLoadNotification
                                             object:nil];
    [self refreshChrome];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)thumbnailDidLoad:(NSNotification *)notification {
    // Visible rows only. A prepared (not-yet-visible) cell whose decode lands
    // now is deliberately left stale: willDisplayCell re-renders it at the
    // moment it scrolls in, which is the one edge covering every way a
    // prepared cell can go stale.
    for (NSIndexPath *path in self.tableView.indexPathsForVisibleRows) {
        NSUInteger index = (NSUInteger)path.row;
        if (index < _playlist.count &&
            [_playlist trackAtIndex:index].metadata == notification.object) {
            [self refreshVisibleRowAtIndex:index];
        }
    }
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    _viewPresentationVisible = YES;
    [self syncCurrentEqualizerActivity];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self syncCurrentEqualizerActivity];
    [self applyPendingTrackScrollIfVisible];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    // Stop hidden table work at the start of a tab/navigation transition. An
    // interactive cancellation comes back through viewWillAppear: and applies
    // the newest pending destination once the surface settles.
    _viewPresentationVisible = NO;
    [self syncCurrentEqualizerActivity];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    _viewPresentationVisible = NO;
    [self syncCurrentEqualizerActivity];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self syncCurrentEqualizerActivity];
}

- (void)setEqualizerSurfaceVisible:(BOOL)equalizerSurfaceVisible {
    if (_equalizerSurfaceVisible == equalizerSurfaceVisible) {
        return;
    }
    _equalizerSurfaceVisible = equalizerSurfaceVisible;
    [self syncCurrentEqualizerActivity];
    [self applyPendingTrackScrollIfVisible];
}

- (BOOL)equalizerSurfaceVisible {
    return _equalizerSurfaceVisible;
}

- (BOOL)isSurfaceMateriallyVisible {
    return _viewPresentationVisible && _equalizerSurfaceVisible;
}

- (void)applyPendingTrackScrollIfVisible {
    if (![self isSurfaceMateriallyVisible] || _pendingScrollIndex == NSNotFound) {
        return;
    }
    NSUInteger index = _pendingScrollIndex;
    _pendingScrollIndex = NSNotFound;
    if (index < _playlist.count) {
        [self.tableView scrollToRowAtIndexPath:
                [NSIndexPath indexPathForRow:(NSInteger)index inSection:0]
                              atScrollPosition:UITableViewScrollPositionNone
                                      animated:NO];
    }
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
    cell.levelSource = _playback;
    [cell renderTrack:[_playlist trackAtIndex:index]
               number:index + 1
              playing:playing];
    [self syncLoadingForCell:cell trackIndex:index];
    [self syncEqualizerActivityForCell:cell];
    return cell;
}

- (void)tableView:(UITableView *)tableView
  willDisplayCell:(UITableViewCell *)cell
forRowAtIndexPath:(NSIndexPath *)indexPath {
    if ([cell isKindOfClass:LibraryTrackCell.class]) {
        // TRAP: a prepared cell rendered while still outside the viewport can
        // be stale by the time it scrolls in — the thumbnail notification and
        // the metadata refresh both repaint indexPathsForVisibleRows, which a
        // prepared cell is not in, and UIKit displays it without re-running
        // cellForRowAtIndexPath:. This edge is the one moment "about to be
        // seen" is knowable, so re-render here; the art read is a non-blocking
        // cache lookup.
        NSUInteger index = (NSUInteger)indexPath.row;
        if (index < _playlist.count) {
            [(LibraryTrackCell *)cell renderTrack:[_playlist trackAtIndex:index]
                                           number:index + 1
                                          playing:index == _playlist.currentIndex];
            [self syncLoadingForCell:(LibraryTrackCell *)cell trackIndex:index];
        }
        [self syncEqualizerActivityForCell:(LibraryTrackCell *)cell];
    }
}

- (void)tableView:(UITableView *)tableView
didEndDisplayingCell:(UITableViewCell *)cell
 forRowAtIndexPath:(NSIndexPath *)indexPath {
    if ([cell isKindOfClass:LibraryTrackCell.class]) {
        LibraryTrackCell *trackCell = (LibraryTrackCell *)cell;
        trackCell.equalizerPresentationVisible = NO;
        trackCell.equalizerAudioOutputActive = NO;
        // An off-screen row must not hold a live sweep animation.
        trackCell.loading = NO;
    }
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    [self syncCurrentEqualizerActivity];
}

// Window attachment alone includes UITableView's prepared-cell buffer. This
// intersection is the narrower fact the control needs: some part of the
// current row is actually inside both the table viewport and the window.
- (BOOL)isCellMateriallyVisible:(LibraryTrackCell *)cell {
    UIWindow *window = cell.window;
    if (!window || !_equalizerSurfaceVisible || !_viewPresentationVisible) {
        return NO;
    }
    CGRect rowInTable = [cell convertRect:cell.bounds toView:self.tableView];
    CGRect visibleInTable = CGRectIntersection(rowInTable, self.tableView.bounds);
    if (CGRectIsNull(visibleInTable) || CGRectIsEmpty(visibleInTable)) {
        return NO;
    }
    CGRect visibleInWindow = [self.tableView convertRect:visibleInTable toView:window];
    return !CGRectIsEmpty(CGRectIntersection(visibleInWindow, window.bounds));
}

- (void)syncEqualizerActivityForCell:(LibraryTrackCell *)cell {
    NSIndexPath *path = [self.tableView indexPathForCell:cell];
    BOOL current = path && _playlist.count > 0
            && (NSUInteger)path.row == _playlist.currentIndex;
    // A loading row's gutter belongs to the loading bar; the hidden equalizer
    // must not keep a demand-declaring poller behind it.
    BOOL eligible = current && !cell.isLoading;
    cell.equalizerAudioOutputActive = eligible && _playback.audioOutputActive;
    cell.equalizerPresentationVisible = eligible && [self isCellMateriallyVisible:cell];
}

- (void)syncLoadingForCell:(LibraryTrackCell *)cell trackIndex:(NSUInteger)index {
    AudioTrack *track = index < _playlist.count ? [_playlist trackAtIndex:index] : nil;
    CloudTransferRegistry *registry = CloudTransferRegistry.sharedRegistry;
    BOOL loading = track.url != nil && [registry isTransferringURL:track.url];
    cell.loading = loading;
    cell.loadingProgress = loading ? [registry progressForURL:track.url] : -1;
}

// Reconfigure the visible rows in place — never reload, which would rebuild
// the playing row's EqualizerIndicatorView and disturb its demand balancing.
- (void)cloudTransferRegistryDidChange:(CloudTransferRegistry *)registry {
    for (UITableViewCell *cell in self.tableView.visibleCells) {
        if (![cell isKindOfClass:LibraryTrackCell.class]) {
            continue;
        }
        NSIndexPath *path = [self.tableView indexPathForCell:cell];
        if (!path) {
            continue;
        }
        [self syncLoadingForCell:(LibraryTrackCell *)cell
                      trackIndex:(NSUInteger)path.row];
        [self syncEqualizerActivityForCell:(LibraryTrackCell *)cell];
    }
}

- (void)syncCurrentEqualizerActivity {
    if (_playlist.currentIndex >= _playlist.count) {
        return;
    }
    NSIndexPath *path = [NSIndexPath indexPathForRow:(NSInteger)_playlist.currentIndex
                                           inSection:0];
    UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:path];
    if ([cell isKindOfClass:LibraryTrackCell.class]) {
        [self syncEqualizerActivityForCell:(LibraryTrackCell *)cell];
    }
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
                                 playing:playing];
    [self syncEqualizerActivityForCell:cell];
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
    _pendingScrollIndex = NSNotFound;
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
    // The mac scrolls the playing row into view on every visible track change.
    // Offscreen, retain only the newest destination: animated table work behind
    // the player or another tab cannot be seen and competes with that surface.
    if (playback.currentIndex < _playlist.count) {
        if ([self isSurfaceMateriallyVisible]) {
            _pendingScrollIndex = NSNotFound;
            [self.tableView scrollToRowAtIndexPath:
                    [NSIndexPath indexPathForRow:(NSInteger)playback.currentIndex inSection:0]
                                  atScrollPosition:UITableViewScrollPositionNone
                                          animated:YES];
        }
        else {
            _pendingScrollIndex = playback.currentIndex;
        }
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
    LoadingIndicatorView    *_loadingView;
    // No ivar for levelSource: it forwards straight to the indicator, so the
    // cell keeps no second copy to fall out of step with it.
    UIImageView *_artView;
    UILabel     *_titleLabel;
    UILabel     *_artistLabel;
    UILabel     *_durationLabel;
    UIStackView *_textStack;
    BOOL         _playing;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style
              reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        [self build];
    }
    return self;
}

- (void)prepareForReuse {
    [super prepareForReuse];
    _indicatorView.presentationVisible = NO;
    _indicatorView.audioOutputActive = NO;
    self.loading = NO;
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

    // The mac's five live bars, literally: the same retained pill layers and
    // compositor-driven response to the latest level targets.
    _indicatorView = [[EqualizerIndicatorView alloc] initWithFrame:CGRectZero];
    _indicatorView.hidden = YES;
    _indicatorView.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:_indicatorView];

    // The loading bar shares the gutter: one EQ-bar's weight, appearance-
    // derived colour (iOS keeps the shared control's default, unlike the mac's
    // forced white).
    _loadingView = [[LoadingIndicatorView alloc] initWithFrame:CGRectZero];
    _loadingView.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:_loadingView];

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

        [_loadingView.centerXAnchor constraintEqualToAnchor:_numberLabel.centerXAnchor],
        [_loadingView.centerYAnchor constraintEqualToAnchor:content.centerYAnchor],
        [_loadingView.widthAnchor constraintEqualToConstant:16],
        [_loadingView.heightAnchor constraintEqualToConstant:
                VibeLoadingIndicatorMetricsForStyle(VibeLoadingIndicatorStyleRow, 16).height],

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

- (void)setLevelSource:(id<EqualizerLevelSource>)levelSource {
    _indicatorView.levelSource = levelSource;
}

- (id<EqualizerLevelSource>)levelSource {
    return _indicatorView.levelSource;
}

- (void)setEqualizerAudioOutputActive:(BOOL)equalizerAudioOutputActive {
    _indicatorView.audioOutputActive = equalizerAudioOutputActive;
}

- (BOOL)equalizerAudioOutputActive {
    return _indicatorView.audioOutputActive;
}

- (void)setEqualizerPresentationVisible:(BOOL)equalizerPresentationVisible {
    _indicatorView.presentationVisible = equalizerPresentationVisible;
}

- (BOOL)equalizerPresentationVisible {
    return _indicatorView.presentationVisible;
}

- (void)setLoading:(BOOL)loading {
    if (_loading == loading && _loadingView.isActive == loading) {
        return;
    }
    _loading = loading;
    [self resolveGutter];
}

- (void)setLoadingProgress:(float)loadingProgress {
    _loadingProgress = loadingProgress;
    _loadingView.progress = loadingProgress;
}

// The gutter's three states in precedence: loading bar, equalizer, number.
- (void)resolveGutter {
    _loadingView.active = _loading;
    _numberLabel.hidden = _loading || _playing;
    _indicatorView.hidden = _loading || !_playing;
}

- (BOOL)renderTrack:(AudioTrack *)track
             number:(NSUInteger)number
            playing:(BOOL)playing {
    _numberLabel.text = [NSString stringWithFormat:@"%lu", (unsigned long)number];
    _playing = playing;
    [self resolveGutter];
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
