//
//  FolderViewController+Actions.m
//  Vibe (iOS)
//

#import "FolderViewControllerInternal.h"
#import "AppSettings.h"
#import "FileRow.h"
#import "SettingsRules.h"
#import "VibeStrings.h"

@implementation FolderViewController (Actions)

#pragma mark - The bar

// Multi-select, as opposed to the editing state a row swipe also sets.
- (BOOL)isSelecting {
    return self.tableView.isEditing && !_swipingRow;
}

- (void)refreshBarItems {
    if ([self isSelecting]) {
        NSUInteger count = self.tableView.indexPathsForSelectedRows.count;
        _addSelectedItem.enabled = count > 0;
        self.navigationItem.title = [NSString stringWithFormat:STR_BROWSER_SELECTED_COUNT, (unsigned long)count];
        self.navigationItem.rightBarButtonItems = @[_doneItem, _addSelectedItem];
        self.navigationItem.leftBarButtonItem = _selectAllItem;
        self.navigationItem.hidesBackButton = YES;
        return;
    }
    self.navigationItem.title = _title;
    self.navigationItem.leftBarButtonItem = nil;
    self.navigationItem.hidesBackButton = NO;
    // Absent, not disabled, with nothing to act on: the Playlist tab's rule.
    NSMutableArray<UIBarButtonItem *> *items = [NSMutableArray array];
    // The add sheet is modal and needs its way out at every level.
    if (_closeItem) {
        [items addObject:_closeItem];
    }
    if (!self.isEmpty) {
        [items addObject:_selectItem];
        // With no song directly inside, the tap has nothing to play and the
        // button is its menu alone.
        _playItem.target = _hasSongs ? self : nil;
        _playItem.action = _hasSongs ? @selector(openDirectory) : NULL;
        [items addObject:_playItem];
        // Not in the add sheet: with Close the bar has no room, and the
        // order is a setting the Files tab changes.
        if (!_appending) {
            [items addObject:_sortItem];
        }
    }
    self.navigationItem.rightBarButtonItems = items;
}

// Built when opened, so its check follows a change made on another screen.
// The title says what the choice reaches: it is the one folder-open setting,
// not this folder's view.
- (UIMenu *)sortMenu {
    __weak FolderViewController *weakSelf = self;
    UIDeferredMenuElement *choices = [UIDeferredMenuElement elementWithUncachedProvider:
            ^(void (^completion)(NSArray<UIMenuElement *> *)) {
        VibeFolderOpenSort current = AppSettings.sharedInstance.folderOpenSort;
        NSMutableArray<UIAction *> *actions = [NSMutableArray array];
        for (VibeFolderOpenSort sort = VibeFolderOpenSortName; sort <= VibeFolderOpenSortAsReceived; sort++) {
            UIAction *action = [UIAction actionWithTitle:VibeFolderOpenSortDisplayName(sort)
                                                   image:nil
                                              identifier:nil
                                                 handler:^(UIAction *a) {
                AppSettings.sharedInstance.folderOpenSort = sort;
                [weakSelf reloadFromDisk];
            }];
            action.state = sort == current ? UIMenuElementStateOn : UIMenuElementStateOff;
            [actions addObject:action];
        }
        completion(actions);
    }];
    return [UIMenu menuWithTitle:STR_SETTINGS_FOLDER_SORT_LABEL children:@[choices]];
}

- (void)toggleSelecting {
    [self setEditing:!self.tableView.isEditing animated:YES];
}

- (void)selectAllRows {
    for (NSInteger section = 0; section < VibeBrowserSectionCount; section++) {
        NSInteger rows = [self.tableView numberOfRowsInSection:section];
        for (NSInteger row = 0; row < rows; row++) {
            [self.tableView selectRowAtIndexPath:[NSIndexPath indexPathForRow:row inSection:section]
                                        animated:NO
                                  scrollPosition:UITableViewScrollPositionNone];
        }
    }
    [self refreshBarItems];
}

- (void)setEditing:(BOOL)editing animated:(BOOL)animated {
    [super setEditing:editing animated:animated];
    [self refreshBarItems];
}

- (void)tableView:(UITableView *)tableView willBeginEditingRowAtIndexPath:(NSIndexPath *)indexPath {
    _swipingRow = YES;
}

- (void)tableView:(UITableView *)tableView didEndEditingRowAtIndexPath:(NSIndexPath *)indexPath {
    _swipingRow = NO;
    [self refreshBarItems];
}

#pragma mark - Selection

// A folder opens. A file is the host's.
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (tableView.isEditing) {
        [self refreshBarItems];
        return;
    }
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSURL *url = [self itemAtIndexPath:indexPath];
    if (!url) {
        return;
    }
    if (indexPath.section == VibeBrowserSectionFolders) {
        [self pushDirectory:url];
    }
    else {
        [_host screen:self didTapFile:url];
    }
}

- (void)tableView:(UITableView *)tableView didDeselectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (tableView.isEditing) {
        [self refreshBarItems];
    }
}

#pragma mark - Row actions

// For Select and the swipe's action. Nothing here is deleted.
- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return YES;
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView
           editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath {
    return UITableViewCellEditingStyleNone;
}

// A context menu is never the only road to the selection's action.
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
        leadingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSURL *url = [self itemAtIndexPath:indexPath];
    if (!url) {
        return nil;
    }
    __weak FolderViewController *weakSelf = self;
    VibeBrowserAction *selection = _host.selectionAction;
    UIContextualAction *add = [UIContextualAction
            contextualActionWithStyle:UIContextualActionStyleNormal
                                title:selection.title
                              handler:^(UIContextualAction *action, UIView *source, void (^completion)(BOOL)) {
        [weakSelf performAction:selection onRowAtIndexPath:indexPath url:url];
        completion(YES);
    }];
    add.image = [UIImage systemImageNamed:selection.symbol];
    add.backgroundColor = UIColor.tintColor;
    UISwipeActionsConfiguration *config = [UISwipeActionsConfiguration configurationWithActions:@[add]];
    config.performsFirstActionWithFullSwipe = YES;
    return config;
}

- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView
        contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath
                                            point:(CGPoint)point {
    if (tableView.isEditing) {
        return nil;
    }
    __weak FolderViewController *weakSelf = self;
    NSURL *url = [self itemAtIndexPath:indexPath];
    if (!url) {
        return nil;
    }
    BOOL folder = indexPath.section == VibeBrowserSectionFolders;
    id<VibeBrowserHost> host = _host;
    return [UIContextMenuConfiguration configurationWithIdentifier:nil
                                                   previewProvider:nil
                                                    actionProvider:^UIMenu *(NSArray<UIMenuElement *> *suggested) {
        NSMutableArray<UIMenuElement *> *items = [NSMutableArray array];
        for (VibeBrowserAction *action in [host menuActionsForURL:url isFolder:folder]) {
            [items addObject:VibeMenuAction(action.title, action.symbol, ^{
                [weakSelf performAction:action onRowAtIndexPath:indexPath url:url];
            })];
        }
        return [UIMenu menuWithTitle:@"" children:items];
    }];
}

@end
