// A folder screen over a host that is not Vibe's: its bar draws the host's
// actions and words, a file's tap goes to the host, and a row's swipe hands
// the row's URL to the host's selection action after lifting the row. The
// host here offers Import in a sheet, as another app's would.

#import "IOSSimTestCase.h"

#import "AudioTrack.h"
#import "FolderViewControllerInternal.h"

@interface FakeBrowserHost : NSObject <VibeBrowserHost>
@property (nonatomic, copy, nullable) NSString *playingPath;
@property (nonatomic, copy, nullable) NSString *openingPath;
@property (nonatomic) BOOL audioOutputActive;
@property (nonatomic, copy, nullable) NSString *prompt;
@property (nonatomic) BOOL showsCloseButton;
@property (nonatomic) BOOL showsSortMenu;
@property (nonatomic) VibeFolderOpenSort folderSort;
@property (nonatomic, readonly) NSMutableArray<NSURL *> *tapped;
@property (nonatomic, readonly) NSMutableArray<NSArray<NSURL *> *> *imported;
@end

@implementation FakeBrowserHost

@synthesize selectionAction = _selectionAction;
@synthesize folderAction = _folderAction;

- (instancetype)init {
    self = [super init];
    if (self) {
        _tapped = [NSMutableArray array];
        _imported = [NSMutableArray array];
        __weak FakeBrowserHost *weakSelf = self;
        _selectionAction = [VibeBrowserAction actionWithTitle:@"Import"
                                                       symbol:@"square.and.arrow.down"
                                                      handler:^(NSArray<NSURL *> *urls, UIViewController *screen) {
            [weakSelf.imported addObject:urls];
        }];
        _selectionAction.liftsRows = YES;
        _folderAction = [VibeBrowserAction actionWithTitle:@"Import Folder"
                                                    symbol:@"folder.badge.plus"
                                                   handler:^(NSArray<NSURL *> *urls, UIViewController *screen) {
            [weakSelf.imported addObject:urls];
        }];
    }
    return self;
}

- (NSString *)label:(VibeBrowserLabel)label {
    return [NSString stringWithFormat:@"label %ld", (long)label];
}

- (NSString *)selectionTitleForCount:(NSUInteger)count {
    return [NSString stringWithFormat:@"%lu to import", (unsigned long)count];
}

- (NSString *)subfoldersCappedMessageForLimit:(NSUInteger)limit {
    return @"capped";
}

- (NSString *)titleForSort:(VibeFolderOpenSort)sort {
    return @"sort";
}

- (id<AudioTrackMetadataHolder>)artHolderForFileURL:(NSURL *)url {
    return [AudioTrack withURL:url];
}

- (id<EqualizerLevelSource>)levelSource {
    return nil;
}

- (void)addObserver:(id<VibeBrowserHostObserver>)observer {
}

- (void)screen:(UIViewController *)screen didTapFile:(NSURL *)url {
    [_tapped addObject:url];
}

- (NSString *)subfoldersTitle {
    return @"Import with Subfolders";
}

- (void (^)(NSArray<NSURL *> *))subfoldersHandlerFromScreen:(UIViewController *)screen {
    return ^(NSArray<NSURL *> *folders) {
    };
}

- (NSArray<VibeBrowserAction *> *)menuActionsForURL:(NSURL *)url isFolder:(BOOL)isFolder {
    return @[_selectionAction];
}

@end

@interface FolderScreenHostTests : IOSSimTestCase
@end

@implementation FolderScreenHostTests {
    NSURL *_directory;
    FakeBrowserHost *_host;
    FolderViewController *_folder;
    // How many imports the host had seen when the rows were lifted; -1 before.
    NSInteger _importsAtLift;
}

- (void)setUp {
    [super setUp];
    _directory = [NSURL fileURLWithPath:[VibeTestProcessRoot() stringByAppendingPathComponent:
                                                 [NSUUID UUID].UUIDString] isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:_directory withIntermediateDirectories:YES
                                            attributes:nil error:NULL];
    // A listing skips empty files. These are never parsed: the stack has no
    // art cache.
    NSData *bytes = [@"not audio" dataUsingEncoding:NSUTF8StringEncoding];
    for (NSString *name in @[@"one.mp3", @"two.mp3"]) {
        [bytes writeToURL:[_directory URLByAppendingPathComponent:name] atomically:YES];
    }
    _host = [[FakeBrowserHost alloc] init];
    _host.prompt = @"Import to Library";
    _host.showsCloseButton = YES;
    _importsAtLift = -1;
    _folder = [[FolderViewController alloc] initWithHost:_host
                                            directoryURL:_directory
                                           stackArtCache:^AudioTrackMetadataCache *{
        return nil;
    }
                                            highlighting:nil
                                              holdsScope:NO];
    __weak FolderScreenHostTests *weakSelf = self;
    _folder.addedRowsHandler = ^(NSArray<UIView *> *rows) {
        FolderScreenHostTests *strongSelf = weakSelf;
        if (strongSelf) {
            strongSelf->_importsAtLift = (NSInteger)strongSelf->_host.imported.count;
        }
    };
    self.window.rootViewController = [[UINavigationController alloc] initWithRootViewController:_folder];
    [self.window layoutIfNeeded];
    XCTAssertTrue([self eventually:^BOOL {
        return [self->_folder itemAtIndexPath:[NSIndexPath indexPathForRow:1 inSection:VibeBrowserSectionFiles]] != nil;
    }]);
}

- (void)tearDown {
    self.window.rootViewController = nil;
    _folder = nil;
    [NSFileManager.defaultManager removeItemAtURL:_directory error:NULL];
    [super tearDown];
}

- (NSURL *)fileAtRow:(NSInteger)row {
    return [_folder itemAtIndexPath:[NSIndexPath indexPathForRow:row inSection:VibeBrowserSectionFiles]];
}

- (void)testTheBarDrawsTheHostsActions {
    NSArray<NSString *> *labels = [_folder.navigationItem.rightBarButtonItems valueForKey:@"accessibilityLabel"];
    XCTAssertTrue([labels containsObject:@"Import Folder"], @"%@", labels);
}

- (void)testTheScreenTakesTheHostsWordsAndLook {
    XCTAssertEqualObjects(_folder.navigationItem.prompt, @"Import to Library");
    NSArray<UIBarButtonItem *> *items = _folder.navigationItem.rightBarButtonItems;
    NSArray<NSString *> *labels = [items valueForKey:@"accessibilityLabel"];
    XCTAssertTrue([labels containsObject:[_host label:VibeBrowserLabelSelect]], @"%@", labels);
    XCTAssertFalse([labels containsObject:[_host label:VibeBrowserLabelSort]], @"%@", labels);
    [_folder toggleSelecting];
    XCTAssertEqualObjects(_folder.navigationItem.title, @"0 to import");
}

- (void)testAFileTapGoesToTheHost {
    NSIndexPath *row = [NSIndexPath indexPathForRow:0 inSection:VibeBrowserSectionFiles];
    [_folder tableView:_folder.tableView didSelectRowAtIndexPath:row];
    XCTAssertEqualObjects(_host.tapped, @[[self fileAtRow:0]]);
}

- (void)testASwipeLiftsTheRowThenHandsItToTheSelectionAction {
    NSIndexPath *row = [NSIndexPath indexPathForRow:1 inSection:VibeBrowserSectionFiles];
    UISwipeActionsConfiguration *swipe = [_folder tableView:_folder.tableView
                        leadingSwipeActionsConfigurationForRowAtIndexPath:row];
    UIContextualAction *action = swipe.actions.firstObject;
    XCTAssertEqualObjects(action.title, @"Import");
    action.handler(action, _folder.tableView, ^(BOOL done) {
    });
    XCTAssertEqual(_importsAtLift, 0);
    XCTAssertEqualObjects(_host.imported, @[@[[self fileAtRow:1]]]);
}

@end
