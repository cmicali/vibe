//
//  LibraryViewController.m
//  Vibe (iOS)
//
//  LibraryTrackCell, at the bottom, is drawn nowhere else, so it has no header.
//

#import "LibraryViewController.h"

#import "AudioTrack.h"
#import "BrowserViewController.h"
#import "AudioTrackMetadata.h"
#import "CloudTransferRegistry.h"
#import "EqualizerIndicatorView.h"
#import "FavoritesStore.h"
#import "LoadingIndicatorMath.h"
#import "LoadingIndicatorView.h"
#import "PlaybackController.h"
#import "Playlist.h"
#import "SettingsViewController.h"
#import "VibeStrings.h"

static NSString *const kTrackCellIdentifier = @"track";
// Apple Music's proportions.
static const CGFloat kEstimatedRowHeight = 64;
static const CGFloat kArtSide = 44;
static const CGFloat kNumberColumnWidth = 26;
static const CGFloat kArtTextGap = 14;

#pragma mark - The row

// The mac playlist table's four columns in one row.
@interface LibraryTrackCell : UITableViewCell
// Set at dequeue: the table mints the cell and it never sees the model.
@property (nonatomic, weak, nullable) id<EqualizerLevelSource> levelSource;
@property (nonatomic) BOOL equalizerAudioOutputActive;
@property (nonatomic) BOOL equalizerPresentationVisible;
// YES while a provider transfer is running for this row's file. Outranks
// playing: mid-open there is no output audio for the equalizer to show.
@property (nonatomic, getter=isLoading) BOOL loading;
@property (nonatomic) float loadingProgress;
// YES when the row's height can have moved; a caller rendering in place then
// owes the table a height pass (refreshVisibleRowAtIndex:).
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
    // Changes what the empty state says until the next open finds audio.
    BOOL               _lastPickWasEmpty;
    // Appearance covers tabs and pushes; the root's surface fact covers the
    // card, which moves over this view without an appearance transition.
    BOOL               _viewPresentationVisible;
    BOOL               _equalizerSurfaceVisible;
    // The add sheet's browser, which this screen's exposure exposes.
    __weak BrowserViewController *_addSheet;
    // A hidden track change, parked at once on the next reveal.
    NSUInteger         _pendingScrollIndex;
    UIBarButtonItem    *_settingsItem;
    UIBarButtonItem    *_addItem;
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
    // Clear Playlist alone in a destructive inline group, as the Favorites
    // long-press menu builds Remove.
    __weak LibraryViewController *weakSelf = self;
    UIAction *settings = [UIAction actionWithTitle:STR_SETTINGS_TITLE
                                             image:[UIImage systemImageNamed:@"gearshape"]
                                        identifier:nil
                                           handler:^(UIAction *action) {
        [weakSelf settingsTapped];
    }];
    UIAction *clear = [UIAction actionWithTitle:STR_MENU_PLAYLIST_CLEAR
                                          image:[UIImage systemImageNamed:@"trash"]
                                     identifier:nil
                                        handler:^(UIAction *action) {
        [weakSelf clearTapped];
    }];
    clear.attributes = UIMenuElementAttributesDestructive;
    UIMenu *destructive = [UIMenu menuWithTitle:@""
                                          image:nil
                                     identifier:nil
                                        options:UIMenuOptionsDisplayInline
                                       children:@[clear]];
    _settingsItem =
            [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"gearshape"]
                                              menu:[UIMenu menuWithTitle:@""
                                                               children:@[settings, destructive]]];
    _settingsItem.accessibilityLabel = STR_A11Y_PLAYLIST_MENU;
    _addItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"plus"]
                                                style:UIBarButtonItemStylePlain
                                               target:self
                                               action:@selector(addTapped)];
    _addItem.accessibilityLabel = STR_MENU_CONTEXT_ADD_TO_PLAYLIST;
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeAlways;
    self.navigationController.navigationBar.prefersLargeTitles = YES;

    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = kEstimatedRowHeight;
    // The rule starts at the title.
    self.tableView.separatorInset =
            UIEdgeInsetsMake(0, 12 + kNumberColumnWidth + 8 + kArtSide + kArtTextGap, 0, 0);
    [self.tableView registerClass:LibraryTrackCell.class forCellReuseIdentifier:kTrackCellIdentifier];

    [_playback addObserver:self];
    [CloudTransferRegistry.sharedRegistry addObserver:self];
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(thumbnailDidLoad:)
                                               name:AudioTrackMetadataThumbnailDidLoadNotification
                                             object:nil];
    // An unstar elsewhere and the star's own asynchronous add both arrive here.
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(refreshChrome)
                                               name:VibeFavoritesDidChangeNotification
                                             object:nil];
    [self refreshChrome];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)thumbnailDidLoad:(NSNotification *)notification {
    // Visible rows only: willDisplayCell re-renders a prepared cell.
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
    // At the start of a transition; a cancelled one comes back through
    // viewWillAppear:.
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
    _addSheet.equalizerSurfaceVisible = equalizerSurfaceVisible;
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

// The Files tab's browser as a sheet in which every action appends.
- (void)addTapped {
    BrowserViewController *browser = [[BrowserViewController alloc] initWithPlayback:_playback
                                                                        directoryURL:nil
                                                                           appending:YES];
    browser.equalizerSurfaceVisible = _equalizerSurfaceVisible;
    _addSheet = browser;
    [self presentViewController:[[UINavigationController alloc] initWithRootViewController:browser]
                       animated:YES
                     completion:nil];
}

// The Files tab, not the modal picker: it carries our row actions and leaves
// the user somewhere to keep looking.
- (void)openTapped {
    if (_openFilesHandler) {
        _openFilesHandler();
    }
}

// No confirmation: nothing leaves the disk, and reopening rebuilds it.
- (void)clearTapped {
    [_playback clearPlaylist];
}

// Pushed, not presented, so the strip and the card stay up.
- (void)settingsTapped {
    [self.navigationController pushViewController:[[SettingsViewController alloc] initWithPlayback:_playback]
                                         animated:YES];
}

// Title, star and empty state all follow what is open.
- (void)refreshChrome {
    // Not self.title, which is also the tab's title.
    self.navigationItem.title = _playback.folderDisplayName ?: STR_TAB_PLAYLIST;
    [self refreshBarButtons];
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

#pragma mark - The star

// The star and the plus are absent, not disabled, when there is nothing for
// them to act on; the empty state's Open owns the empty playlist. The plus is
// leading: three trailing items crowd the large title.
- (void)refreshBarButtons {
    self.navigationItem.leftBarButtonItem = _playlist.count > 0 ? _addItem : nil;
    NSURL *folderURL = _playback.folderURL;
    if (!folderURL) {
        self.navigationItem.rightBarButtonItems = @[_settingsItem];
        return;
    }
    BOOL favorited = [FavoritesStore.shared containsFolderURL:folderURL];
    UIBarButtonItem *star = [[UIBarButtonItem alloc]
            initWithImage:[UIImage systemImageNamed:favorited ? @"star.fill" : @"star"]
                    style:UIBarButtonItemStylePlain
                   target:self
                   action:@selector(favoriteTapped)];
    star.accessibilityLabel = favorited ? STR_MENU_CONTEXT_REMOVE_FAVORITE : STR_A11Y_ADD_FAVORITE;
    self.navigationItem.rightBarButtonItems = @[_settingsItem, star];
}

// The star fills when the mint lands, never on the tap: a row without a
// bookmark cannot be opened. A second tap needs no guard; addFolderURL: dedupes.
- (void)favoriteTapped {
    NSURL *folderURL = _playback.folderURL;
    if (!folderURL) {
        return;
    }
    if ([FavoritesStore.shared containsFolderURL:folderURL]) {
        [FavoritesStore.shared removeFolderURL:folderURL];
        return;
    }
    [_playback bookmarkOpenFolderWithCompletion:^(NSURL *url, NSData *bookmark) {
        if (url && bookmark) {
            [FavoritesStore.shared addFolderURL:url bookmark:bookmark];
        }
    }];
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
        // TRAP: UIKit displays a prepared cell without re-running
        // cellForRowAtIndexPath:, and the thumbnail and metadata refreshes
        // repaint only visible rows, so a prepared cell can arrive stale.
        // Re-render here; the art read is a non-blocking cache lookup.
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
        trackCell.loading = NO;
    }
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    [self syncCurrentEqualizerActivity];
}

- (BOOL)isCellMateriallyVisible:(LibraryTrackCell *)cell {
    return _equalizerSurfaceVisible && _viewPresentationVisible && VibeRowIsInViewport(cell, self.tableView);
}

- (void)syncEqualizerActivityForCell:(LibraryTrackCell *)cell {
    NSIndexPath *path = [self.tableView indexPathForCell:cell];
    BOOL current = path && _playlist.count > 0
            && (NSUInteger)path.row == _playlist.currentIndex;
    // A hidden equalizer behind the loading bar must not hold a poller.
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

// In place, never a reload, which would rebuild the playing row's indicator
// and disturb its demand balancing.
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
    // TRAP: rendering in place does NOT re-measure an automatic-dimension row.
    // An artist line arriving with metadata outgrows the row at accessibility
    // sizes; the empty update pass re-measures it.
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
    // Under shuffle the list holds still, rather than chase a play order that
    // jumps across it.
    if (_playlist.shuffleEnabled) {
        _pendingScrollIndex = NSNotFound;
        return;
    }
    // Hidden, keep only the newest destination: unseen animated table work
    // competes with the surface in front.
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
    if (playback.playlist.count > 0) {
        return;   // the playlist stands, and says nothing of the pick
    }
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
    // levelSource forwards to the indicator; no second copy.
    UIImageView *_artView;
    UILabel     *_titleLabel;
    UILabel     *_artistLabel;
    UILabel     *_durationLabel;
    UIStackView *_textStack;
    BOOL         _playing;
    // What renderTrack: last drew from, held strongly so an identity cannot
    // be reused by another object.
    AudioTrack         *_renderedTrack;
    AudioTrackMetadata *_renderedMetadata;
    UIImage            *_renderedThumbnail;
    NSString           *_renderedDuration;
    NSUInteger          _renderedNumber;
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

    // The artist line's text style, so the columns scale together.
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

    _indicatorView = [[EqualizerIndicatorView alloc] initWithFrame:CGRectZero];
    _indicatorView.hidden = YES;
    _indicatorView.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:_indicatorView];

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

    // Negative: a label's height carries its font's leading.
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
        // The mac's size.
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

// Precedence: loading bar, equalizer, number.
- (void)resolveGutter {
    _loadingView.active = _loading;
    _numberLabel.hidden = _loading || _playing;
    _indicatorView.hidden = _loading || !_playing;
}

- (BOOL)renderTrack:(AudioTrack *)track
             number:(NSUInteger)number
            playing:(BOOL)playing {
    // Every appearance renders twice, since willDisplayCell: re-renders a
    // prepared cell, and the second usually finds nothing changed. These are
    // all the row draws from.
    AudioTrackMetadata *metadata = track.metadata;
    UIImage *thumbnail = track.cachedThumbnail;
    NSString *duration = track.durationString;
    if (track == _renderedTrack && metadata == _renderedMetadata && thumbnail == _renderedThumbnail
            && [duration isEqualToString:_renderedDuration] && number == _renderedNumber
            && playing == _playing) {
        return NO;
    }
    _renderedTrack = track;
    _renderedMetadata = metadata;
    _renderedThumbnail = thumbnail;
    _renderedDuration = duration;
    _renderedNumber = number;
    _numberLabel.text = [NSString stringWithFormat:@"%lu", (unsigned long)number];
    _playing = playing;
    [self resolveGutter];
    _artView.image = thumbnail ?: VibeFileTileImage(NO);
    _durationLabel.text = duration;
    _titleLabel.text = track.displayTitle ?: @"";
    // Hidden rather than blank, so the title centres on its own.
    NSString *artist = track.displayArtist;
    BOOL hidden = artist.length == 0;
    BOOL heightMoved = hidden != _artistLabel.isHidden;
    _artistLabel.text = artist ?: @"";
    _artistLabel.hidden = hidden;
    return heightMoved;
}

@end
