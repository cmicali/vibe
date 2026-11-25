// The rows and strips that draw one track: VibeTrackCell and the Playlist
// tab's wiring of it, FileRow's shared pieces, TrackPageViews and
// VibeMiniPlayerView. Labels are found by what they show.

#import "IOSSimTestCase.h"

#import "FilePaths.h"
#import "AudioTrack+TrackRow.h"
#import "CloudTransferRegistryInternal.h"
#import "EqualizerIndicatorView.h"
#import "FileRow.h"
#import "LoadingIndicatorView.h"
#import "VibeMiniPlayerView.h"
#import "VibePlaylist.h"
#import "VibeTrackCell.h"
#import "PlaylistViewController.h"
#import "TrackPageViews.h"
#import "VibeTrackRow.h"
#import "VibeStrings.h"

@interface MiniPlayerEvents : NSObject <VibeMiniPlayerViewDelegate>
@property (nonatomic) NSMutableArray<NSString *> *events;
@end

@implementation MiniPlayerEvents
- (instancetype)init {
    if ((self = [super init])) {
        _events = [NSMutableArray array];
    }
    return self;
}
- (void)miniPlayerViewDidRequestExpand:(VibeMiniPlayerView *)view { [_events addObject:@"expand"]; }
- (void)miniPlayerViewDidTapPlayPause:(VibeMiniPlayerView *)view { [_events addObject:@"playPause"]; }
- (void)miniPlayerViewDidTapNext:(VibeMiniPlayerView *)view { [_events addObject:@"next"]; }
@end

@interface RowViewsTests : IOSSimTestCase
@end

@implementation RowViewsTests

static id FirstSubviewOfClass(UIView *view, Class cls) {
    if ([view isKindOfClass:cls]) {
        return view;
    }
    for (UIView *subview in view.subviews) {
        id found = FirstSubviewOfClass(subview, cls);
        if (found) {
            return found;
        }
    }
    return nil;
}

static NSArray<UIButton *> *Buttons(UIView *view) {
    NSMutableArray<UIButton *> *buttons = [NSMutableArray array];
    for (UIView *subview in view.subviews) {
        if ([subview isKindOfClass:UIButton.class]) {
            [buttons addObject:(UIButton *)subview];
        }
    }
    return buttons;
}

#pragma mark - VibeTrackCell

- (VibeTrackCell *)cell {
    VibeTrackCell *cell = [[VibeTrackCell alloc] initWithStyle:UITableViewCellStyleDefault
                                               reuseIdentifier:@"t"];
    cell.frame = CGRectMake(0, 0, 390, 64);
    [self.window addSubview:cell];
    return cell;
}

static VibeTrackRow *Row(AudioTrack *track, NSUInteger number, BOOL playing) {
    VibeTrackRow *row = track.trackRow;
    row.numberText = [NSString stringWithFormat:@"%lu", (unsigned long)number];
    row.playing = playing;
    return row;
}

- (void)testATaggedRowShowsTitleArtistNumberAndDuration {
    VibeTrackCell *cell = [self cell];
    AudioTrack *track = [self trackNamed:@"a.mp3" title:@"Song" artist:@"Band" duration:125];
    [cell renderRow:Row(track, 7, NO)];
    XCTAssertNotNil(VibeLabelWithText(cell, @"Song"));
    XCTAssertNotNil(VibeLabelWithText(cell, @"Band"));
    XCTAssertNotNil(VibeLabelWithText(cell, @"7"));
    XCTAssertNotNil(VibeLabelWithText(cell, track.durationString));
    XCTAssertFalse([cell renderRow:Row(track, 7, NO)], @"an unchanged render moves nothing");
    [cell removeFromSuperview];
}

// The cell keeps a copy of what it drew, so an edit to the caller's row is a
// change, and a new thumbnail is a change even when it looks the same.
- (void)testARowRendersAgainOnlyWhenWhatItDrawsChanged {
    VibeTrackCell *cell = [self cell];
    VibeTrackRow *row = [[VibeTrackRow alloc] init];
    row.title = @"Song";
    row.numberText = @"1";
    [cell renderRow:row];
    XCTAssertFalse([cell renderRow:[row copy]]);
    row.title = @"Other";
    [cell renderRow:row];
    XCTAssertNotNil(VibeLabelWithText(cell, @"Other"), @"an edited row is drawn again");
    row.thumbnail = VibeFileTileImage(YES);
    [cell renderRow:row];
    BOOL drawn = NO;
    for (UIView *view in cell.contentView.subviews) {
        drawn = drawn || ([view isKindOfClass:UIImageView.class]
                          && ((UIImageView *)view).image == VibeFileTileImage(YES));
    }
    XCTAssertTrue(drawn, @"a new thumbnail is drawn");
    [cell removeFromSuperview];
}

// The root guarantee: the single line is the title, in the title's color,
// and no second line is drawn.
- (void)testAFilenameRowIsOneLineInTheTitlesColor {
    VibeTrackCell *cell = [self cell];
    AudioTrack *tagged = [self trackNamed:@"a.mp3" title:@"Song" artist:@"Band" duration:60];
    [cell renderRow:Row(tagged, 1, NO)];
    UIColor *titleColor = VibeLabelWithText(cell, @"Song").textColor;
    AudioTrack *bare = [self trackNamed:@"My_Demo.mp3" title:nil artist:nil duration:60];
    XCTAssertNil(bare.displayArtist);
    XCTAssertTrue([cell renderRow:Row(bare, 1, NO)], @"losing a line moves the height");
    UILabel *line = VibeLabelWithText(cell, bare.displayTitle);
    XCTAssertNotNil(line);
    XCTAssertEqualObjects(line.textColor, titleColor);
    XCTAssertEqualObjects(line.textColor, UIColor.labelColor);
    XCTAssertNil(VibeLabelWithText(cell, @"Band"), @"no second line");
    [cell removeFromSuperview];
}

// At an accessibility size, a row that wraps shows its whole title, and
// grows to hold it. A row that doesn't, as in a table of one row height,
// keeps one line at every size.
- (void)testATitleWrapsAtAnAccessibilitySizeOnlyWhenAsked {
    VibeTrackCell *cell = [self cell];
    cell.traitOverrides.preferredContentSizeCategory = UIContentSizeCategoryAccessibilityExtraLarge;
    [cell updateTraitsIfNeeded];
    VibeTrackRow *row = [[VibeTrackRow alloc] init];
    row.title = @"A Song Whose Title Is Far Too Long For One Line At This Size";
    row.subtitle = @"An Artist";
    [cell renderRow:row];
    UILabel *title = VibeLabelWithText(cell, row.title);
    XCTAssertEqual(title.numberOfLines, 1, @"off by default");
    CGSize fits = CGSizeMake(390, UILayoutFittingCompressedSize.height);
    CGFloat oneLine = [cell systemLayoutSizeFittingSize:fits withHorizontalFittingPriority:UILayoutPriorityRequired
                           verticalFittingPriority:UILayoutPriorityFittingSizeLevel].height;

    cell.wrapsTextAtAccessibilitySizes = YES;
    XCTAssertEqual(title.numberOfLines, 0);
    XCTAssertEqual(VibeLabelWithText(cell, @"An Artist").numberOfLines, 2);
    CGFloat wrapped = [cell systemLayoutSizeFittingSize:fits withHorizontalFittingPriority:UILayoutPriorityRequired
                           verticalFittingPriority:UILayoutPriorityFittingSizeLevel].height;
    XCTAssertGreaterThan(wrapped, oneLine, @"the row grows to hold the wrapped title");

    cell.traitOverrides.preferredContentSizeCategory = UIContentSizeCategoryLarge;
    [cell updateTraitsIfNeeded];
    XCTAssertEqual(title.numberOfLines, 1, @"below the accessibility sizes, one line");
    [cell removeFromSuperview];
}

// The gutter's precedence: loading bar, playing marker, number.
- (void)testTheGutterPrefersLoadingThenPlayingThenTheNumber {
    VibeTrackCell *cell = [self cell];
    AudioTrack *track = [self trackNamed:@"a.mp3" title:@"Song" artist:@"Band" duration:60];
    EqualizerIndicatorView *marker = FirstSubviewOfClass(cell.contentView, EqualizerIndicatorView.class);
    LoadingIndicatorView *bar = FirstSubviewOfClass(cell.contentView, LoadingIndicatorView.class);
    [cell renderRow:Row(track, 3, NO)];
    UILabel *number = VibeLabelWithText(cell, @"3");
    XCTAssertNotNil(number);
    XCTAssertTrue(marker.hidden);
    XCTAssertFalse(bar.isActive);

    [cell renderRow:Row(track, 3, YES)];
    XCTAssertTrue(number.hidden);
    XCTAssertFalse(marker.hidden);

    cell.loading = YES;
    XCTAssertTrue(bar.isActive);
    XCTAssertTrue(marker.hidden, @"loading outranks the playing marker");
    XCTAssertTrue(number.hidden);

    cell.loading = NO;
    XCTAssertFalse(bar.isActive);
    XCTAssertFalse(marker.hidden);

    cell.loading = YES;
    [cell prepareForReuse];
    XCTAssertFalse(bar.isActive, @"reuse drops the bar");
    XCTAssertFalse(cell.equalizerPresentationVisible);
    [cell removeFromSuperview];
}

#pragma mark - The Playlist tab's wiring

- (FakePlayback *)playbackWithTracks:(NSUInteger)count current:(NSUInteger)current {
    FakePlayback *playback = [[FakePlayback alloc] init];
    NSMutableArray<AudioTrack *> *tracks = [NSMutableArray array];
    for (NSUInteger i = 0; i < count; i++) {
        [tracks addObject:[self trackNamed:[NSString stringWithFormat:@"row-%lu.mp3", (unsigned long)i]
                                     title:[NSString stringWithFormat:@"Title %lu", (unsigned long)i]
                                    artist:@"Band" duration:60]];
    }
    [playback.playlist replaceAllWithTracks:tracks startingAtIndex:current];
    playback.screenState = VibePlayerScreenStateTrack;
    playback.displayedTrack = playback.playlist.currentTrack;
    return playback;
}

- (PlaylistViewController *)showPlaylistFor:(FakePlayback *)playback {
    PlaylistViewController *screen = [[PlaylistViewController alloc] initWithPlayback:playback.asPlayback];
    self.window.rootViewController = [[UINavigationController alloc] initWithRootViewController:screen];
    [self.window layoutIfNeeded];
    XCTAssertTrue([self eventually:^BOOL { return screen.tableView.visibleCells.count > 0; }]);
    return screen;
}

- (VibeTrackCell *)cellAtRow:(NSInteger)row of:(PlaylistViewController *)screen {
    return (VibeTrackCell *)[screen.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:row inSection:0]];
}

// CloudTransferRegistry is the one home of "this file is loading": a row
// shows the bar while its transfer runs, and in place.
- (void)testARowsLoadingBarFollowsTheTransferRegistry {
    FakePlayback *playback = [self playbackWithTracks:3 current:0];
    PlaylistViewController *screen = [self showPlaylistFor:playback];
    VibeTrackCell *row = [self cellAtRow:1 of:screen];
    XCTAssertFalse(row.isLoading);

    NSURL *url = [playback.playlist trackAtIndex:1].url;
    CloudTransferRegistry *registry = CloudTransferRegistry.sharedRegistry;
    [registry beganTransferForPath:VibeStandardizedAudioOpenPath(url) url:url];
    XCTAssertTrue([self eventually:^BOOL { return row.isLoading; }]);
    XCTAssertFalse([self cellAtRow:0 of:screen].isLoading, @"only the row whose file is on the wire");
    XCTAssertEqual([self cellAtRow:1 of:screen], row, @"in place, never a reload");

    [registry endedTransferForPath:VibeStandardizedAudioOpenPath(url)];
    XCTAssertTrue([self eventually:^BOOL { return !row.isLoading; }]);
}

// The playing row's marker asks for levels only while its surface is
// materially visible, the output runs, and no transfer covers it.
- (void)testThePlayingRowsMarkerDemandsLevelsOnlyWhenSeenAndSounding {
    FakePlayback *playback = [self playbackWithTracks:3 current:0];
    playback.audioOutputActive = YES;
    PlaylistViewController *screen = [self showPlaylistFor:playback];
    VibeSpinFor(kVibeTestNegativeWindow);
    XCTAssertEqual(playback.levelConsumers, 0, @"the root has not exposed the surface");

    screen.equalizerSurfaceVisible = YES;
    XCTAssertTrue([self eventually:^BOOL { return playback.levelConsumers == 1; }]);

    NSURL *url = playback.playlist.currentTrack.url;
    CloudTransferRegistry *registry = CloudTransferRegistry.sharedRegistry;
    [registry beganTransferForPath:VibeStandardizedAudioOpenPath(url) url:url];
    XCTAssertTrue([self eventually:^BOOL { return playback.levelConsumers == 0; }],
                  @"a hidden marker behind the bar must not poll");
    [registry endedTransferForPath:VibeStandardizedAudioOpenPath(url)];
    XCTAssertTrue([self eventually:^BOOL { return playback.levelConsumers == 1; }]);

    screen.equalizerSurfaceVisible = NO;
    XCTAssertEqual(playback.levelConsumers, 0);
}

- (void)testSelectingARowAsksTheModelToPlayIt {
    FakePlayback *playback = [self playbackWithTracks:3 current:0];
    PlaylistViewController *screen = [self showPlaylistFor:playback];
    [playback clearCalls];
    [screen tableView:screen.tableView didSelectRowAtIndexPath:[NSIndexPath indexPathForRow:2 inSection:0]];
    XCTAssertEqualObjects(playback.calls, @[@"selectTrackAtIndex:"]);
}

#pragma mark - FileRow

- (void)testTheTileFollowsTheAppearanceAndTheKind {
    UIImage *tile = VibeFileTileImage(NO);
    XCTAssertEqual(tile, VibeFileTileImage(NO), @"drawn once");
    XCTAssertNotEqual(tile, VibeFileTileImage(YES));
    XCTAssertEqual(tile.size.width, kVibeFileTileSide);
    UIImage *dark = [tile.imageAsset imageWithTraitCollection:
            [UITraitCollection traitCollectionWithUserInterfaceStyle:UIUserInterfaceStyleDark]];
    XCTAssertNotNil(dark);
    XCTAssertNotEqual(dark, tile, @"one image would not follow the appearance");
}

- (void)testAnIconSlotReservesTheTileForEveryKind {
    UIListContentConfiguration *folder = [UIListContentConfiguration cellConfiguration];
    [folder vibeApplyFileIconForFolder:YES playlist:NO art:nil];
    XCTAssertTrue(CGSizeEqualToSize(folder.imageProperties.reservedLayoutSize,
                                    CGSizeMake(kVibeFileTileSide, kVibeFileTileSide)));
    UIListContentConfiguration *cue = [UIListContentConfiguration cellConfiguration];
    [cue vibeApplyFileIconForFolder:NO playlist:YES art:nil];
    XCTAssertEqual(cue.image, VibeFileTileImage(YES));
    UIListContentConfiguration *song = [UIListContentConfiguration cellConfiguration];
    [song vibeApplyFileIconForFolder:NO playlist:NO art:nil];
    XCTAssertEqual(song.image, VibeFileTileImage(NO));
    UIImage *art = VibeFileTileImage(YES);
    [song vibeApplyFileIconForFolder:NO playlist:NO art:art];
    XCTAssertEqual(song.image, art, @"art beats the tile");
}

// Every configuration goes through one funnel, so a reused cell loses the
// spinner.
- (void)testTheOpeningSpinnerComesAndGoesWithTheRowContent {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    UIListContentConfiguration *content = [UIListContentConfiguration cellConfiguration];
    content.text = @"Song.flac";
    [content vibeApplyFileIconForFolder:NO playlist:NO art:nil];
    [cell vibeApplyRowContent:content opening:YES];
    UIActivityIndicatorView *spinner = FirstSubviewOfClass(cell.contentView, UIActivityIndicatorView.class);
    XCTAssertNotNil(spinner);
    XCTAssertTrue(spinner.isAnimating);
    [cell vibeApplyRowContent:content opening:NO];
    XCTAssertNil(FirstSubviewOfClass(cell.contentView, UIActivityIndicatorView.class));
}

- (void)testTheViewportTestNeedsAWindowAndAnOverlap {
    UITableView *table = [[UITableView alloc] initWithFrame:CGRectMake(0, 0, 300, 200)];
    UITableViewCell *cell = [[UITableViewCell alloc] initWithFrame:CGRectMake(0, 0, 300, 44)];
    [table addSubview:cell];
    XCTAssertFalse([cell vibeIsInViewportOfTableView:table], @"no window");
    [self.window addSubview:table];
    XCTAssertTrue([cell vibeIsInViewportOfTableView:table]);
    cell.frame = CGRectMake(0, 400, 300, 44);
    XCTAssertFalse([cell vibeIsInViewportOfTableView:table], @"prepared beyond the screen");
    [table removeFromSuperview];
}

#pragma mark - TrackPageViews

- (void)testTheTimeControlKeepsItsTargetAndSkipsUnchangedText {
    TrackPageTimeControl *control = [[TrackPageTimeControl alloc] initWithFrame:CGRectZero];
    XCTAssertEqualObjects(control.text, STR_LABEL_TIME_UNKNOWN);
    XCTAssertGreaterThanOrEqual(control.intrinsicContentSize.width, 44);
    XCTAssertGreaterThanOrEqual(control.intrinsicContentSize.height, 44);
    control.text = @"-3:05";
    XCTAssertEqualObjects(control.accessibilityValue, @"-3:05");
    XCTAssertNotNil(VibeLabelWithText(control, @"-3:05"));
    control.highlighted = YES;
    XCTAssertEqualWithAccuracy(VibeLabelWithText(control, @"-3:05").alpha, 0.55, 1e-6);
}

- (void)testTheCapsuleAndTheArtCardRestateTheirShapesOnLayout {
    TrackPageActionBarView *bar = [[TrackPageActionBarView alloc] initWithFrame:CGRectMake(0, 0, 200, 40)];
    [bar layoutIfNeeded];
    XCTAssertEqual(bar.layer.cornerRadius, 20);
    TrackPageArtCardView *card = [[TrackPageArtCardView alloc] initWithFrame:CGRectMake(0, 0, 100, 100)];
    [card layoutIfNeeded];
    XCTAssertTrue(CGRectEqualToRect(CGPathGetBoundingBox(card.layer.shadowPath), card.bounds));
    card.frame = CGRectMake(0, 0, 150, 120);
    [card layoutIfNeeded];
    XCTAssertTrue(CGRectEqualToRect(CGPathGetBoundingBox(card.layer.shadowPath), card.bounds),
                  @"a stale halo after a resize");
}

#pragma mark - VibeMiniPlayerView

- (VibeMiniPlayerView *)strip {
    VibeMiniPlayerView *strip = [[VibeMiniPlayerView alloc] initWithFrame:CGRectMake(0, 600, 390, 48)];
    [strip setAccessibilityLabelsForExpand:STR_SETTINGS_NOW_PLAYING_SECTION
                                      play:STR_TRANSPORT_PLAY
                                     pause:STR_TRANSPORT_PAUSE
                                      next:STR_TRANSPORT_NEXT];
    [self.window addSubview:strip];
    [strip layoutIfNeeded];
    return strip;
}

- (void)testTheStripDrawsTheTrackItIsGiven {
    VibeMiniPlayerView *strip = [self strip];
    [strip renderRow:[self trackNamed:@"a.mp3" title:@"Song" artist:@"Band" duration:60].trackRow];
    UILabel *title = VibeLabelWithText(strip, @"Song");
    XCTAssertNotNil(title);
    XCTAssertEqualObjects(title.textColor, UIColor.labelColor);
    XCTAssertNotNil(VibeLabelWithText(strip, @"Band"));

    AudioTrack *bare = [self trackNamed:@"My_Demo.mp3" title:nil artist:nil duration:60];
    [strip renderRow:bare.trackRow];
    UILabel *line = VibeLabelWithText(strip, bare.displayTitle);
    XCTAssertEqual(line, title, @"the single line is the title");
    XCTAssertEqualObjects(line.textColor, UIColor.labelColor);
    XCTAssertNil(VibeLabelWithText(strip, @"Band"), @"no second line");
    [strip removeFromSuperview];
}

- (void)testThePlayButtonNamesWhatItWillDo {
    VibeMiniPlayerView *strip = [self strip];
    NSArray<NSString *> *(^labels)(void) = ^NSArray<NSString *> * {
        NSMutableArray<NSString *> *names = [NSMutableArray array];
        for (UIButton *button in Buttons(strip)) {
            if (button.accessibilityLabel) [names addObject:button.accessibilityLabel];
        }
        return names;
    };
    XCTAssertTrue([labels() containsObject:STR_TRANSPORT_PLAY]);
    [strip setPlaying:YES];
    XCTAssertTrue([labels() containsObject:STR_TRANSPORT_PAUSE]);
    XCTAssertFalse([labels() containsObject:STR_TRANSPORT_PLAY]);
    [strip setPlaying:NO];
    XCTAssertTrue([labels() containsObject:STR_TRANSPORT_PLAY]);
    [strip removeFromSuperview];
}

- (void)testTheStripsControlsReachItsDelegate {
    VibeMiniPlayerView *strip = [self strip];
    MiniPlayerEvents *events = [[MiniPlayerEvents alloc] init];
    strip.delegate = events;
    for (UIButton *button in Buttons(strip)) {
        [button sendActionsForControlEvents:UIControlEventTouchUpInside];
    }
    XCTAssertEqualObjects([NSSet setWithArray:events.events],
                          ([NSSet setWithArray:@[@"expand", @"playPause", @"next"]]));
    [strip removeFromSuperview];
}

// The accessory fits its width to the strip once, not per song, so in a
// regular width the strip asks for the same room whatever it shows.
- (void)testTheStripAsksForRoomOutsideACompactWidth {
    VibeMiniPlayerView *strip = [self strip];
    [strip renderRow:[self trackNamed:@"a.mp3" title:@"Song" artist:@"Band" duration:60].trackRow];
    CGFloat (^fittedWidth)(UIUserInterfaceSizeClass) = ^CGFloat(UIUserInterfaceSizeClass sizeClass) {
        strip.traitOverrides.horizontalSizeClass = sizeClass;
        [strip updateTraitsIfNeeded];
        return [strip systemLayoutSizeFittingSize:UILayoutFittingCompressedSize].width;
    };
    XCTAssertGreaterThanOrEqual(fittedWidth(UIUserInterfaceSizeClassRegular), 360);
    XCTAssertLessThan(fittedWidth(UIUserInterfaceSizeClassCompact), 360, @"the system frames a compact strip");
    [strip removeFromSuperview];
}

@end
