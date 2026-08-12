//
//  TrackListViewController.m
//  Vibe (iOS)
//

#import "TrackListViewController.h"
#import "AudioTrack.h"
#import "Playlist.h"
#import "VibeStrings.h"

static NSString *const kTrackCellIdentifier = @"track";
static const NSInteger kSectionChooseFolder = 0;
static const NSInteger kSectionTracks = 1;

@implementation TrackListViewController {
    __weak Playlist *_playlist;
}

- (instancetype)initWithPlaylist:(Playlist *)playlist {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _playlist = playlist;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.folderName;
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose
                                                      target:self
                                                      action:@selector(closeTapped)];
}

- (void)closeTapped {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)reloadAll {
    if (self.isViewLoaded) {
        [self.tableView reloadData];
    }
}

- (void)reloadTrackAtIndex:(NSUInteger)index {
    if (!self.isViewLoaded || index >= _playlist.count) {
        return;
    }
    NSIndexPath *path = [NSIndexPath indexPathForRow:(NSInteger)index inSection:kSectionTracks];
    [self.tableView reloadRowsAtIndexPaths:@[path] withRowAnimation:UITableViewRowAnimationNone];
}

#pragma mark - Table view

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 2;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == kSectionChooseFolder ? 1 : (NSInteger)_playlist.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == kSectionChooseFolder) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                                       reuseIdentifier:nil];
        UIListContentConfiguration *content = cell.defaultContentConfiguration;
        content.text = STR_LABEL_CHOOSE_FOLDER;
        content.image = [UIImage systemImageNamed:@"folder"];
        cell.contentConfiguration = content;
        return cell;
    }

    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kTrackCellIdentifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:kTrackCellIdentifier];
    }
    AudioTrack *track = [_playlist trackAtIndex:(NSUInteger)indexPath.row];
    UIListContentConfiguration *content = cell.defaultContentConfiguration;
    content.text = track.singleLineTitle;
    content.textProperties.numberOfLines = 1;
    cell.contentConfiguration = content;

    BOOL isCurrent = (NSUInteger)indexPath.row == _playlist.currentIndex;
    if (isCurrent) {
        UIImageView *speaker = [[UIImageView alloc]
                initWithImage:[UIImage systemImageNamed:@"speaker.wave.2.fill"]];
        speaker.tintColor = [UIColor tintColor];
        cell.accessoryView = speaker;
    }
    else {
        cell.accessoryView = nil;
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == kSectionChooseFolder) {
        void (^chooseFolder)(void) = self.onChooseFolder;
        [self dismissViewControllerAnimated:YES completion:^{
            if (chooseFolder) {
                chooseFolder();
            }
        }];
        return;
    }
    if (self.onSelectTrack) {
        self.onSelectTrack((NSUInteger)indexPath.row);
    }
}

@end
