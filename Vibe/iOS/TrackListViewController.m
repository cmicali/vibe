//
//  TrackListViewController.m
//  Vibe (iOS)
//

#import "TrackListViewController.h"
#import "AudioTrack.h"
#import "Playlist.h"
#import "VibeStrings.h"

static NSString *const kTrackCellIdentifier = @"track";
static NSString *const kChooseFolderCellIdentifier = @"choose-folder";
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

// Live: an external open can replace the folder while the sheet is up.
- (void)setFolderName:(NSString *)folderName {
    _folderName = [folderName copy];
    if (self.isViewLoaded) {
        self.title = _folderName;
    }
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
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kChooseFolderCellIdentifier];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                          reuseIdentifier:kChooseFolderCellIdentifier];
        }
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
    content.text = track.displayTitle;
    content.secondaryText = track.displayArtist;
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
    // Dismiss first, then play — the same order the Choose Folder row above
    // and the search sheet both use, so all three selection paths behave
    // alike. The block is captured because self is gone once the sheet is.
    void (^selectTrack)(NSUInteger) = self.onSelectTrack;
    NSUInteger index = (NSUInteger)indexPath.row;
    [self dismissViewControllerAnimated:YES completion:^{
        if (selectTrack) {
            selectTrack(index);
        }
    }];
}

@end
