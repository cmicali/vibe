//
//  BrowserRootViewController.m
//  Vibe (iOS)
//

#import "BrowserRootViewController.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#import "BrowserRules.h"
#import "FileRow.h"
#import "FileSearchRules.h"
#import "FilePaths.h"
#import "FolderViewController.h"
#import "LocationStore.h"
#import "VibeBrowserHost.h"

static NSString *const kSourceCellIdentifier = @"source";
static NSString *const kActionCellIdentifier = @"action";

@implementation VibeBrowserRootRow

+ (instancetype)rowWithTitle:(NSString *)title image:(UIImage *)image handler:(dispatch_block_t)handler {
    VibeBrowserRootRow *row = [[self alloc] initPrivate];
    row->_title = [title copy];
    row->_image = image;
    row->_handler = [handler copy];
    return row;
}

- (instancetype)initPrivate {
    return [super init];
}

@end

@interface BrowserRootViewController () <VibeBrowserHostObserver>
@end

@implementation BrowserRootViewController {
    // What every folder screen of the stack reads and acts through.
    id<VibeBrowserHost> _host;
    // The picker that grants a location, while it is up.
    __weak UIDocumentPickerViewController *_locationPicker;
    // The sources that had a root when the root last reloaded. The rows read
    // this, never the live sources. An account flips off main before its
    // change is posted. A live read in that gap maps a folder's row to the
    // folder beside it.
    NSArray<id<VibeBrowserSource>> *_shownSources;
}

- (instancetype)initWithHost:(id<VibeBrowserHost>)host {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _host = host;
        _shownSources = @[];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeAlways;
    self.navigationController.navigationBar.prefersLargeTitles = YES;
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(locationsDidChange:)
                                               name:VibeSearchFoldersDidChangeNotification
                                             object:LocationStore.shared];
    if (_host.showsCloseButton && self.navigationController.viewControllers.firstObject == self) {
        self.navigationItem.leftBarButtonItem =
                [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose
                                                              target:self
                                                              action:@selector(dismissSheet)];
    }
    UIBarButtonItem *addLocation = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"plus"]
                                                                     menu:[self addLocationMenu]];
    addLocation.accessibilityLabel = [_host label:VibeBrowserLabelAddLocation];
    self.navigationItem.rightBarButtonItem = addLocation;
    if ([_host respondsToSelector:@selector(addBrowserObserver:)]) {
        [_host addBrowserObserver:self];
    }
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadSources];
}

- (void)reloadSources {
    NSMutableArray<id<VibeBrowserSource>> *shown = [NSMutableArray array];
    for (id<VibeBrowserSource> source in _host.sources) {
        if (source.rootURL) {
            [shown addObject:source];
        }
    }
    _shownSources = shown;
    [self.tableView reloadData];
}

#pragma mark - What the stack shares

// Every folder of the stack follows. A folder pushed later is handed it.
- (void)setEqualizerSurfaceVisible:(BOOL)equalizerSurfaceVisible {
    if (_equalizerSurfaceVisible == equalizerSurfaceVisible) {
        return;
    }
    _equalizerSurfaceVisible = equalizerSurfaceVisible;
    for (UIViewController *controller in self.navigationController.viewControllers) {
        if ([controller isKindOfClass:FolderViewController.class]) {
            ((FolderViewController *)controller).equalizerSurfaceVisible = equalizerSurfaceVisible;
        }
    }
}

- (void)locationsDidChange:(NSNotification *)notification {
    [self reloadSources];
}

- (void)browserHostSourcesDidChange {
    [self reloadSources];
}

// The root's plus. It is built each time it opens, so a source's connect
// item follows its account.
- (UIMenu *)addLocationMenu {
    __weak BrowserRootViewController *weakSelf = self;
    id<VibeBrowserHost> host = _host;
    UIDeferredMenuElement *items = [UIDeferredMenuElement elementWithUncachedProvider:
            ^(void (^completion)(NSArray<UIMenuElement *> *)) {
        UIAction *addFolder = VibeMenuAction([host label:VibeBrowserLabelAddFolder], @"folder.badge.plus", ^{
            [weakSelf presentLocationPicker];
        });
        addFolder.subtitle = [host label:VibeBrowserLabelAddFolderCaption];
        NSMutableArray<UIMenuElement *> *elements = [NSMutableArray arrayWithObject:addFolder];
        for (id<VibeBrowserSource> source in host.sources) {
            if (source.rootURL || ![source respondsToSelector:@selector(connectFromScreen:connected:)]) {
                continue;
            }
            [elements addObject:[UIAction actionWithTitle:source.connectTitle
                                                    image:source.image
                                               identifier:nil
                                                  handler:^(UIAction *action) {
                [weakSelf connectSource:source];
            }]];
        }
        completion(elements);
    }];
    return [UIMenu menuWithChildren:@[items]];
}

// A connection that lands goes straight into the source: the plus was tapped
// to get there.
- (void)connectSource:(id<VibeBrowserSource>)source {
    __weak BrowserRootViewController *weakSelf = self;
    [source connectFromScreen:self connected:^{
        BrowserRootViewController *strongSelf = weakSelf;
        NSURL *root = source.rootURL;
        if (root && strongSelf.navigationController.topViewController == strongSelf) {
            [strongSelf pushDirectory:root];
        }
    }];
}

#pragma mark - The stack

- (void)dismissSheet {
    [self.navigationController.presentingViewController dismissViewControllerAnimated:YES completion:nil];
}

// A screen of this stack. Open Folder hands its last one the file to
// highlight, and a scope to hold.
- (FolderViewController *)folderForDirectory:(NSURL *)url highlighting:(NSURL *)file holdsScope:(BOOL)holdsScope {
    FolderViewController *folder = [[FolderViewController alloc] initWithHost:_host
                                                                 directoryURL:url
                                                                 highlighting:file
                                                                   holdsScope:holdsScope];
    folder.addedRowsHandler = _addedRowsHandler;
    folder.equalizerSurfaceVisible = _equalizerSurfaceVisible;
    return folder;
}

- (void)pushDirectory:(NSURL *)url {
    [self.navigationController pushViewController:[self folderForDirectory:url highlighting:nil holdsScope:NO]
                                         animated:YES];
}

// The sources' roots that are not locations come first: the granted folders
// and Documents are LocationStore's searchRoots.
- (void)showDirectory:(NSURL *)directory highlighting:(NSURL *)file {
    NSArray<NSURL *> *searchRoots = LocationStore.shared.searchRoots;
    NSMutableArray<NSURL *> *sources = [NSMutableArray array];
    for (id<VibeBrowserSource> source in _host.sources) {
        NSURL *root = source.rootURL;
        if (root && ![searchRoots containsObject:root]) {
            [sources addObject:root];
        }
    }
    [sources addObjectsFromArray:searchRoots];
    NSMutableArray<NSString *> *sourcePaths = [NSMutableArray arrayWithCapacity:sources.count];
    for (NSURL *source in sources) {
        [sourcePaths addObject:VibeComparablePath(source.path) ?: @""];
    }
    NSString *standardized = VibeComparablePath(directory.path);
    NSUInteger index = VibeSearchFolderCoveringRootIndex(sourcePaths, standardized);
    NSMutableArray<UIViewController *> *stack = [NSMutableArray arrayWithObject:self];
    if (index == NSNotFound) {
        // A bookmark's URL carries the grant; a path-derived one answers NO.
        BOOL holdsScope = [directory startAccessingSecurityScopedResource];
        [stack addObject:[self folderForDirectory:directory highlighting:file holdsScope:holdsScope]];
    }
    else {
        NSMutableArray<NSURL *> *steps = [NSMutableArray arrayWithObject:sources[index]];
        NSArray<NSString *> *components = standardized.pathComponents;
        NSUInteger depth = sourcePaths[index].pathComponents.count;
        for (NSUInteger i = depth; i < components.count; i++) {
            [steps addObject:[steps.lastObject URLByAppendingPathComponent:components[i] isDirectory:YES]];
        }
        for (NSURL *step in steps) {
            [stack addObject:[self folderForDirectory:step
                                         highlighting:step == steps.lastObject ? file : nil
                                           holdsScope:NO]];
        }
    }
    [self.navigationController setViewControllers:stack animated:NO];
}

#pragma mark - Table

- (NSArray<NSArray<VibeBrowserRootRow *> *> *)appSections {
    return @[];
}

- (void)reloadAppSection:(NSUInteger)index animated:(BOOL)animated {
    if (self.viewIfLoaded.window) {
        [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:index + 1]
                      withRowAnimation:animated ? UITableViewRowAnimationFade : UITableViewRowAnimationNone];
    }
}

// The app's row at a table index path below Locations; nil in Locations.
- (VibeBrowserRootRow *)appRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) {
        return nil;
    }
    NSArray<NSArray<VibeBrowserRootRow *> *> *sections = [self appSections];
    NSUInteger section = (NSUInteger)indexPath.section - 1;
    if (section >= sections.count || (NSUInteger)indexPath.row >= sections[section].count) {
        return nil;
    }
    return sections[section][(NSUInteger)indexPath.row];
}

- (NSUInteger)locationIndexAtIndexPath:(NSIndexPath *)indexPath {
    return indexPath.section == 0
            ? VibeBrowserLocationIndex((NSUInteger)indexPath.row, _shownSources.count,
                                       LocationStore.shared.folderURLs.count)
            : NSNotFound;
}

// The granted folder a Locations row shows. Nil for any other row.
- (NSURL *)locationAtIndexPath:(NSIndexPath *)indexPath {
    NSUInteger index = [self locationIndexAtIndexPath:indexPath];
    return index == NSNotFound ? nil : LocationStore.shared.folderURLs[index];
}

// The source a Locations row shows. Nil for any other row.
- (id<VibeBrowserSource>)sourceAtIndexPath:(NSIndexPath *)indexPath {
    return indexPath.section == 0 && (NSUInteger)indexPath.row < _shownSources.count
            ? _shownSources[(NSUInteger)indexPath.row] : nil;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return (NSInteger)[self appSections].count + 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) {
        return (NSInteger)(_shownSources.count + LocationStore.shared.folderURLs.count);
    }
    NSArray<NSArray<VibeBrowserRootRow *> *> *sections = [self appSections];
    return (NSUInteger)section - 1 < sections.count ? (NSInteger)sections[(NSUInteger)section - 1].count : 0;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == 0 ? [_host label:VibeBrowserLabelLocations] : nil;
}

- (UITableViewCell *)cellWithIdentifier:(NSString *)identifier {
    UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:identifier];
    }
    cell.accessoryType = UITableViewCellAccessoryNone;
    return cell;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UIListContentConfiguration *content = [UIListContentConfiguration subtitleCellConfiguration];
    content.imageProperties.tintColor = UIColor.secondaryLabelColor;
    // A source's glyph can be a 28pt asset, wider than a symbol's
    // reservation, so every row reserves its width and the labels line up.
    content.imageProperties.reservedLayoutSize = CGSizeMake(28, 28);
    BOOL action = NO;
    BOOL opening = NO;
    id<VibeBrowserSource> source = [self sourceAtIndexPath:indexPath];
    VibeBrowserRootRow *row = [self appRowAtIndexPath:indexPath];
    if (source) {
        content.text = source.title;
        content.secondaryText = source.subtitle;
        content.image = source.image;
    }
    else if (row) {
        content.text = row.title;
        content.image = row.image;
        action = row.isAction;
        opening = row.spinning;
    }
    else {
        content.text = [LocationStore displayNameForFolderURL:[self locationAtIndexPath:indexPath]];
        content.image = [UIImage systemImageNamed:@"folder"];
    }
    UITableViewCell *cell = [self cellWithIdentifier:action ? kActionCellIdentifier : kSourceCellIdentifier];
    if (action) {
        // TRAP: the dynamic tint, never self.view.tintColor's value. That
        // value is gray while a sheet or alert dims the tint, and a row made
        // then kept it after the dimming ended.
        content.textProperties.color = UIColor.tintColor;
        content.imageProperties.tintColor = UIColor.tintColor;
    }
    else {
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    [cell vibeApplyRowContent:content opening:opening];
    return cell;
}

#pragma mark - Selection

// A swipe's Delete sets isEditing.
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (tableView.isEditing) {
        return;
    }
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    id<VibeBrowserSource> source = [self sourceAtIndexPath:indexPath];
    NSURL *location = [self locationAtIndexPath:indexPath];
    if (source) {
        NSURL *root = source.rootURL;
        if (root) {
            [self pushDirectory:root];
        }
    }
    else if (location) {
        [self pushDirectory:location];
    }
    else {
        dispatch_block_t handler = [self appRowAtIndexPath:indexPath].handler;
        if (handler) {
            handler();
        }
    }
}

#pragma mark - Row actions

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return [self locationIndexAtIndexPath:indexPath] != NSNotFound;
}

// The system draws and localizes Delete, which forgets a location.
- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView
           editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath {
    return UITableViewCellEditingStyleDelete;
}

- (void)tableView:(UITableView *)tableView
        commitEditingStyle:(UITableViewCellEditingStyle)style
         forRowAtIndexPath:(NSIndexPath *)indexPath {
    NSUInteger index = [self locationIndexAtIndexPath:indexPath];
    if (style == UITableViewCellEditingStyleDelete && index != NSNotFound) {
        [LocationStore.shared removeFolderAtIndex:index];
    }
}

- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView
        contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath
                                            point:(CGPoint)point {
    if (tableView.isEditing) {
        return nil;
    }
    // The swipe's Delete, where a long press finds it too.
    NSURL *location = [self locationAtIndexPath:indexPath];
    if (!location) {
        return nil;
    }
    NSString *title = [_host label:VibeBrowserLabelRemoveLocation];
    return [UIContextMenuConfiguration configurationWithIdentifier:nil
                                                   previewProvider:nil
                                                    actionProvider:^UIMenu *(NSArray<UIMenuElement *> *suggested) {
        UIAction *remove = VibeMenuAction(title, @"minus.circle", ^{
            // By URL: the list can move while the menu is up.
            NSUInteger index = [LocationStore.shared.folderURLs indexOfObject:location];
            if (index != NSNotFound) {
                [LocationStore.shared removeFolderAtIndex:index];
            }
        });
        remove.attributes = UIMenuElementAttributesDestructive;
        return [UIMenu menuWithChildren:@[remove]];
    }];
}

#pragma mark - The location picker

// One folder, granted for good (LocationStore). asCopy:NO: the grant must be
// to the real folder.
- (void)presentLocationPicker {
    UIDocumentPickerViewController *picker =
            [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeFolder] asCopy:NO];
    picker.allowsMultipleSelection = NO;
    picker.delegate = self;
    _locationPicker = picker;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
        didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if (controller != _locationPicker) {
        return;
    }
    NSURL *url = urls.firstObject;
    if (!url) {
        return;
    }
    if ([LocationStore.shared addFolderURL:url]) {
        // Opened, not played: adding a folder leaves playback alone.
        [self pushDirectory:url];
    }
    else {
        // Silence would read as a failed pick.
        VibeBrowserPresentAlert(self, _host, [_host label:VibeBrowserLabelLocations],
                                [_host label:VibeBrowserLabelLocationCovered], nil);
    }
}

@end
