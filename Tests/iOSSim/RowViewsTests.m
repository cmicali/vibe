// The rows and strips that draw one track: PlaylistTrackCell and the Playlist
// tab's wiring of it, FileRow's shared pieces, TrackPageViews and
// MiniPlayerView. Labels are found by what they show.

#import "IOSSimTestCase.h"

#import "AudioFileOpenRules.h"
#import "AudioTrack.h"
#import "CloudTransferRegistryInternal.h"
#import "EqualizerIndicatorView.h"
#import "FileRow.h"
#import "LoadingIndicatorView.h"
#import "MiniPlayerView.h"
#import "Playlist.h"
#import "PlaylistTrackCell.h"
#import "PlaylistViewController.h"
#import "TrackPageViews.h"
#import "VibeStrings.h"

@interface MiniPlayerEvents : NSObject <MiniPlayerViewDelegate>
@property (nonatomic) NSMutableArray<NSString *> *events;
@end

@implementation MiniPlayerEvents
- (instancetype)init {
    if ((self = [super init])) {
        _events = [NSMutableArray array];
    }
    return self;
}
- (void)miniPlayerViewDidRequestExpand:(MiniPlayerView *)view { [_events addObject:@"expand"]; }
- (void)miniPlayerViewDidTapPlayPause:(MiniPlayerView *)view { [_events addObject:@"playPause"]; }
- (void)miniPlayerViewDidTapNext:(MiniPlayerView *)view { [_events addObject:@"next"]; }
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

#pragma mark - PlaylistTrackCell

- (PlaylistTrackCell *)cell {
    PlaylistTrackCell *cell = [[PlaylistTrackCell alloc] initWithStyle:UITableViewCellStyleDefault
                                                       reuseIdentifier:@"t"];
    cell.frame = CGRectMake(0, 0, 390, 64);
    [self.window addSubview:cell];
    return cell;
}

- (void)testATaggedRowShowsTitleArtistNumberAndDuration {
    PlaylistTrackCell *cell = [self cell];
    AudioTrack *track = [self trackNamed:@"a.mp3" title:@"Song" artist:@"Band" duration:125];
    [cell renderTrack:track number:7 playing:NO];
    XCTAssertNotNil(VibeLabelWithText(cell, @"Song"));
    XCTAssertNotNil(VibeLabelWithText(cell, @"Band"));
    XCTAssertNotNil(VibeLabelWithText(cell, @"7"));
    XCTAssertNotNil(VibeLabelWithText(cell, track.durationString));
    XCTAssertFalse([cell renderTrack:track number:7 playing:NO], @"an unchanged render moves nothing");
    [cell removeFromSuperview];
}

// The root guarantee: the single line is the title, in the title's color,
// and no second line is drawn.
- (void)testAFilenameRowIsOneLineInTheTitlesColor {
    PlaylistTrackCell *cell = [self cell];
    AudioTrack *tagged = [self trackNamed:@"a.mp3" title:@"Song" artist:@"Band" duration:60];
    [cell renderTrack:tagged number:1 playing:NO];
    UIColor *titleColor = VibeLabelWithText(cell, @"Song").textColor;
    AudioTrack *bare = [self trackNamed:@"My_Demo.mp3" title:nil artist:nil duration:60];
    XCTAssertNil(bare.displayArtist);
    XCTAssertTrue([cell renderTrack:bare number:1 playing:NO], @"losing a line moves the height");
    UILabel *line = VibeLabelWithText(cell, bare.displayTitle);
    XCTAssertNotNil(line);
    XCTAssertEqualObjects(line.textColor, titleColor);
    XCTAssertEqualObjects(line.textColor, UIColor.labelColor);
    XCTAssertNil(VibeLabelWithText(cell, @"Band"), @"no second line");
    [cell removeFromSuperview];
}

// The gutter's precedence: loading bar, playing marker, number.
- (void)testTheGutterPrefersLoadingThenPlayingThenTheNumber {
    PlaylistTrackCell *cell = [self cell];
    AudioTrack *track = [self trackNamed:@"a.mp3" title:@"Song" artist:@"Band" duration:60];
    EqualizerIndicatorView *marker = FirstSubviewOfClass(cell.contentView, EqualizerIndicatorView.class);
    LoadingIndicatorView *bar = FirstSubviewOfClass(cell.contentView, LoadingIndicatorView.class);
    [cell renderTrack:track number:3 playing:NO];
    UILabel *number = VibeLabelWithText(cell, @"3");
    XCTAssertNotNil(number);
    XCTAssertTrue(marker.hidden);
    XCTAssertFalse(bar.isActive);

    [cell renderTrack:track number:3 playing:YES];
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
    XCTAssertTrue([self waitUntil:^BOOL { return screen.tableView.visibleCells.count > 0; }]);
    return screen;
}

- (PlaylistTrackCell *)cellAtRow:(NSInteger)row of:(PlaylistViewController *)screen {
    return (PlaylistTrackCell *)[screen.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:row inSection:0]];
}

// CloudTransferRegistry is the one home of "this file is loading": a row
// shows the bar while its transfer runs, and in place.
- (void)testARowsLoadingBarFollowsTheTransferRegistry {
    FakePlayback *playback = [self playbackWithTracks:3 current:0];
    PlaylistViewController *screen = [self showPlaylistFor:playback];
    PlaylistTrackCell *row = [self cellAtRow:1 of:screen];
    XCTAssertFalse(row.isLoading);

    NSURL *url = [playback.playlist trackAtIndex:1].url;
    CloudTransferRegistry *registry = CloudTransferRegistry.sharedRegistry;
    [registry beganTransferForPath:VibeStandardizedAudioOpenPath(url) url:url];
    XCTAssertTrue([self waitUntil:^BOOL { return row.isLoading; }]);
    XCTAssertFalse([self cellAtRow:0 of:screen].isLoading, @"only the row whose file is on the wire");
    XCTAssertEqual([self cellAtRow:1 of:screen], row, @"in place, never a reload");

    [registry endedTransferForPath:VibeStandardizedAudioOpenPath(url)];
    XCTAssertTrue([self waitUntil:^BOOL { return !row.isLoading; }]);
}

// The playing row's marker asks for levels only while its surface is
// materially visible, the output runs, and no transfer covers it.
- (void)testThePlayingRowsMarkerDemandsLevelsOnlyWhenSeenAndSounding {
    FakePlayback *playback = [self playbackWithTracks:3 current:0];
    playback.audioOutputActive = YES;
    PlaylistViewController *screen = [self showPlaylistFor:playback];
    [self spin];
    XCTAssertEqual(playback.levelConsumers, 0, @"the root has not exposed the surface");

    screen.equalizerSurfaceVisible = YES;
    [self spin];
    XCTAssertEqual(playback.levelConsumers, 1);

    NSURL *url = playback.playlist.currentTrack.url;
    CloudTransferRegistry *registry = CloudTransferRegistry.sharedRegistry;
    [registry beganTransferForPath:VibeStandardizedAudioOpenPath(url) url:url];
    XCTAssertTrue([self waitUntil:^BOOL { return playback.levelConsumers == 0; }],
                  @"a hidden marker behind the bar must not poll");
    [registry endedTransferForPath:VibeStandardizedAudioOpenPath(url)];
    XCTAssertTrue([self waitUntil:^BOOL { return playback.levelConsumers == 1; }]);

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
    XCTAssertEqual(tile.size.width, kFileTileSide);
    UIImage *dark = [tile.imageAsset imageWithTraitCollection:
            [UITraitCollection traitCollectionWithUserInterfaceStyle:UIUserInterfaceStyleDark]];
    XCTAssertNotNil(dark);
    XCTAssertNotEqual(dark, tile, @"one image would not follow the appearance");
}

- (void)testAnIconSlotReservesTheTileForEveryKind {
    UIListContentConfiguration *folder = [UIListContentConfiguration cellConfiguration];
    [folder vibeApplyFileIconForName:@"Albums" folder:YES art:nil];
    XCTAssertTrue(CGSizeEqualToSize(folder.imageProperties.reservedLayoutSize,
                                    CGSizeMake(kFileTileSide, kFileTileSide)));
    UIListContentConfiguration *cue = [UIListContentConfiguration cellConfiguration];
    [cue vibeApplyFileIconForName:@"Live.cue" folder:NO art:nil];
    XCTAssertEqual(cue.image, VibeFileTileImage(YES));
    UIListContentConfiguration *song = [UIListContentConfiguration cellConfiguration];
    [song vibeApplyFileIconForName:@"Song.flac" folder:NO art:nil];
    XCTAssertEqual(song.image, VibeFileTileImage(NO));
    UIImage *art = VibeFileTileImage(YES);
    [song vibeApplyFileIconForName:@"Song.flac" folder:NO art:art];
    XCTAssertEqual(song.image, art, @"art beats the tile");
}

// Every configuration goes through one funnel, so a reused cell loses the
// spinner.
- (void)testTheOpeningSpinnerComesAndGoesWithTheRowContent {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    UIListContentConfiguration *content = [UIListContentConfiguration cellConfiguration];
    content.text = @"Song.flac";
    [content vibeApplyFileIconForName:@"Song.flac" folder:NO art:nil];
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

#pragma mark - MiniPlayerView

- (MiniPlayerView *)strip {
    MiniPlayerView *strip = [[MiniPlayerView alloc] initWithFrame:CGRectMake(0, 600, 390, 48)];
    [self.window addSubview:strip];
    [strip layoutIfNeeded];
    return strip;
}

- (void)testTheStripDrawsTheTrackItIsGiven {
    MiniPlayerView *strip = [self strip];
    [strip renderTrack:[self trackNamed:@"a.mp3" title:@"Song" artist:@"Band" duration:60]];
    UILabel *title = VibeLabelWithText(strip, @"Song");
    XCTAssertNotNil(title);
    XCTAssertEqualObjects(title.textColor, UIColor.labelColor);
    XCTAssertNotNil(VibeLabelWithText(strip, @"Band"));

    AudioTrack *bare = [self trackNamed:@"My_Demo.mp3" title:nil artist:nil duration:60];
    [strip renderTrack:bare];
    UILabel *line = VibeLabelWithText(strip, bare.displayTitle);
    XCTAssertEqual(line, title, @"the single line is the title");
    XCTAssertEqualObjects(line.textColor, UIColor.labelColor);
    XCTAssertNil(VibeLabelWithText(strip, @"Band"), @"no second line");
    [strip removeFromSuperview];
}

- (void)testThePlayButtonNamesWhatItWillDo {
    MiniPlayerView *strip = [self strip];
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
    MiniPlayerView *strip = [self strip];
    MiniPlayerEvents *events = [[MiniPlayerEvents alloc] init];
    strip.delegate = events;
    for (UIButton *button in Buttons(strip)) {
        [button sendActionsForControlEvents:UIControlEventTouchUpInside];
    }
    XCTAssertEqualObjects([NSSet setWithArray:events.events],
                          ([NSSet setWithArray:@[@"expand", @"playPause", @"next"]]));
    [strip removeFromSuperview];
}

@end
