// The browser over a host that is not Vibe's. The root lists the host's
// sources and its rows. Art draws through the browser's default cache and
// holder. A folder screen's bar draws the host's
// actions and words, a file's tap goes to the host, and a row's swipe hands
// the row's URL to the host's selection action after lifting the row. The
// host here offers Import in a sheet, as another app's would.

#import "IOSSimTestCase.h"

#import <AVFoundation/AVFoundation.h>

#import "AudioTrackMetadata.h"
#import "VibeFileMetadataHolder.h"

#import "VibeBrowserRootViewController.h"
#import "VibeBrowserFolderViewControllerInternal.h"

// The subfolder walk, which the bar's menu item starts.
@interface VibeBrowserFolderViewController (Walk)
- (void)openDirectoryWithSubfolders;
@end

@interface FakeBrowserHost : NSObject <VibeBrowserHost>
@property (nonatomic, copy, nullable) NSString *prompt;
@property (nonatomic, copy, nullable) NSString *rootPrompt;
// The folder each walk started from, and the folders it handed over.
@property (nonatomic, readonly) NSMutableArray<NSURL *> *walkedFrom;
@property (nonatomic, readonly) NSMutableArray<NSArray<NSURL *> *> *walked;
@property (nonatomic) BOOL showsCloseButton;
@property (nonatomic) BOOL showsSortMenu;
@property (nonatomic) VibeFolderOpenSort folderSort;
@property (nonatomic, copy) NSArray<id<VibeBrowserSource>> *sources;
@property (nonatomic, copy) NSArray<NSArray<VibeBrowserRootRow *> *> *rootSections;
@property (nonatomic, readonly) NSMutableArray<NSURL *> *tapped;
@property (nonatomic, readonly) NSMutableArray<NSArray<NSURL *> *> *imported;
@end

@implementation FakeBrowserHost

@synthesize selectionAction = _selectionAction;
@synthesize folderAction = _folderAction;

- (instancetype)init {
    self = [super init];
    if (self) {
        _sources = @[];
        _rootSections = @[];
        _tapped = [NSMutableArray array];
        _imported = [NSMutableArray array];
        _walkedFrom = [NSMutableArray array];
        _walked = [NSMutableArray array];
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

- (void)screen:(UIViewController *)screen didTapFile:(NSURL *)url {
    [_tapped addObject:url];
}

- (NSString *)subfoldersTitle {
    return @"Import with Subfolders";
}

- (void (^)(NSArray<NSURL *> *))subfoldersHandlerForFolder:(NSURL *)folder fromScreen:(UIViewController *)screen {
    [_walkedFrom addObject:folder];
    __weak FakeBrowserHost *weakSelf = self;
    return ^(NSArray<NSURL *> *folders) {
        [weakSelf.walked addObject:folders];
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
    VibeBrowserFolderViewController *_folder;
    // How many imports the host had seen when the rows were lifted; -1 before.
    NSInteger _importsAtLift;
}

- (void)setUp {
    [super setUp];
    _directory = [NSURL fileURLWithPath:[VibeTestProcessRoot() stringByAppendingPathComponent:
                                                 [NSUUID UUID].UUIDString] isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:_directory withIntermediateDirectories:YES
                                            attributes:nil error:NULL];
    // A listing skips empty files. The default cache parses these and finds
    // nothing.
    NSData *bytes = [@"not audio" dataUsingEncoding:NSUTF8StringEncoding];
    for (NSString *name in @[@"one.mp3", @"two.mp3"]) {
        [bytes writeToURL:[_directory URLByAppendingPathComponent:name] atomically:YES];
    }
    _host = [[FakeBrowserHost alloc] init];
    _host.prompt = @"Import to Library";
    _host.showsCloseButton = YES;
    _importsAtLift = -1;
    _folder = [[VibeBrowserFolderViewController alloc] initWithHost:_host
                                                       directoryURL:_directory
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

- (VibeBrowserFolderViewController *)showFolder:(NSURL *)directory {
    VibeBrowserFolderViewController *folder = [[VibeBrowserFolderViewController alloc] initWithHost:_host
                                                                                       directoryURL:directory
                                                                                       highlighting:nil
                                                                                         holdsScope:NO];
    self.window.rootViewController = [[UINavigationController alloc] initWithRootViewController:folder];
    [self.window layoutIfNeeded];
    return folder;
}

// Vibe's look: the selection's bar button is the action's glyph.
- (void)testTheSelectionsBarButtonIsTheGlyphByDefault {
    [_folder toggleSelecting];
    UIBarButtonItem *add = _folder.navigationItem.rightBarButtonItems.lastObject;
    XCTAssertNotNil(add.image);
    XCTAssertNil(add.title);
    XCTAssertEqualObjects(add.accessibilityLabel, @"Import");
}

- (void)testAnActionCanAskItsBarButtonForItsTitle {
    _host.selectionAction.showsTitle = YES;
    VibeBrowserFolderViewController *folder = [self showFolder:_directory];
    [folder toggleSelecting];
    UIBarButtonItem *add = folder.navigationItem.rightBarButtonItems.lastObject;
    XCTAssertNil(add.image);
    XCTAssertEqualObjects(add.title, @"Import");
}

// The walk starts from a folder with no songs of its own, so only the
// handler's folder can name it.
- (void)testTheSubfolderWalkTellsTheHostWhereItStarted {
    NSURL *outer = [_directory URLByAppendingPathComponent:@"Outer" isDirectory:YES];
    NSURL *inner = [outer URLByAppendingPathComponent:@"Inner" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:inner withIntermediateDirectories:YES
                                            attributes:nil error:NULL];
    [[@"not audio" dataUsingEncoding:NSUTF8StringEncoding]
            writeToURL:[inner URLByAppendingPathComponent:@"song.mp3"] atomically:YES];
    VibeBrowserFolderViewController *folder = [self showFolder:outer];
    [folder openDirectoryWithSubfolders];
    XCTAssertEqualObjects(_host.walkedFrom, @[outer]);
    XCTAssertTrue([self eventually:^BOOL {
        return self->_host.walked.count == 1;
    }]);
    XCTAssertEqualObjects(_host.walked.firstObject.firstObject.lastPathComponent, @"Inner");
}

// Vibe's add sheet: a host with a prompt and no root prompt leaves the root
// bare.
- (void)testTheRootShowsAPromptOnlyWhenTheHostGivesItOne {
    VibeBrowserRootViewController *root = [[VibeBrowserRootViewController alloc] initWithHost:_host];
    self.window.rootViewController = [[UINavigationController alloc] initWithRootViewController:root];
    [self.window layoutIfNeeded];
    XCTAssertNil(root.navigationItem.prompt);

    _host.rootPrompt = @"Import";
    root = [[VibeBrowserRootViewController alloc] initWithHost:_host];
    self.window.rootViewController = [[UINavigationController alloc] initWithRootViewController:root];
    [self.window layoutIfNeeded];
    XCTAssertEqualObjects(root.navigationItem.prompt, @"Import");
}

- (void)testTheRootListsTheHostsSourcesAndOpensThem {
    _host.sources = @[[VibeBrowserFolderSource sourceWithRootURL:_directory
                                                           title:@"Library"
                                                           image:[UIImage systemImageNamed:@"books.vertical"]]];
    VibeBrowserRootViewController *root = [[VibeBrowserRootViewController alloc] initWithHost:_host];
    UINavigationController *stack = [[UINavigationController alloc] initWithRootViewController:root];
    self.window.rootViewController = stack;
    [self.window layoutIfNeeded];
    [root beginAppearanceTransition:YES animated:NO];
    [root endAppearanceTransition];
    NSIndexPath *first = [NSIndexPath indexPathForRow:0 inSection:0];
    UITableViewCell *cell = [root tableView:root.tableView cellForRowAtIndexPath:first];
    XCTAssertEqualObjects(((UIListContentConfiguration *)cell.contentConfiguration).text, @"Library");
    [root tableView:root.tableView didSelectRowAtIndexPath:first];
    XCTAssertTrue([self eventually:^BOOL {
        return [stack.topViewController isKindOfClass:VibeBrowserFolderViewController.class];
    }]);
}

- (void)testTheRootDrawsTheHostsRowsAndHandsTheirTapTheRoot {
    __block UIViewController *tappedOn = nil;
    VibeBrowserRootRow *row = [VibeBrowserRootRow rowWithTitle:@"Import from a Computer"
                                                          image:[UIImage systemImageNamed:@"desktopcomputer"]
                                                        handler:^(UIViewController *screen) {
        tappedOn = screen;
    }];
    row.isAction = YES;
    _host.rootSections = @[@[row]];
    VibeBrowserRootViewController *root = [[VibeBrowserRootViewController alloc] initWithHost:_host];
    self.window.rootViewController = [[UINavigationController alloc] initWithRootViewController:root];
    [self.window layoutIfNeeded];
    XCTAssertEqual([root numberOfSectionsInTableView:root.tableView], 2);
    NSIndexPath *imported = [NSIndexPath indexPathForRow:0 inSection:1];
    UITableViewCell *cell = [root tableView:root.tableView cellForRowAtIndexPath:imported];
    XCTAssertEqualObjects(((UIListContentConfiguration *)cell.contentConfiguration).text, @"Import from a Computer");
    [root tableView:root.tableView didSelectRowAtIndexPath:imported];
    XCTAssertEqual(tappedOn, root);
}

// A short M4A whose tag carries a cover, made with the system's encoder.
- (NSURL *)songWithCoverNamed:(NSString *)name inDirectory:(NSURL *)directory {
    NSURL *scratch = [NSURL fileURLWithPath:[VibeTestProcessRoot() stringByAppendingPathComponent:
                                                     [NSUUID UUID].UUIDString]];
    [NSFileManager.defaultManager createDirectoryAtURL:scratch withIntermediateDirectories:YES
                                            attributes:nil error:NULL];
    NSURL *source = [scratch URLByAppendingPathComponent:@"source.caf"];
    AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:44100 channels:2];
    AVAudioFile *file = [[AVAudioFile alloc] initForWriting:source settings:format.settings error:NULL];
    AVAudioPCMBuffer *silence = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:22050];
    silence.frameLength = 22050;
    [file writeFromBuffer:silence error:NULL];
    file = nil;
    UIImage *cover = [[[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(64, 64)]
            imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [UIColor.systemRedColor setFill];
        [context fillRect:CGRectMake(0, 0, 64, 64)];
    }];
    AVMutableMetadataItem *art = [AVMutableMetadataItem metadataItem];
    art.identifier = AVMetadataIdentifieriTunesMetadataCoverArt;
    art.dataType = (__bridge NSString *)kCMMetadataBaseDataType_PNG;
    art.value = UIImagePNGRepresentation(cover);
    AVAssetExportSession *export = [[AVAssetExportSession alloc]
            initWithAsset:[AVURLAsset URLAssetWithURL:source options:nil] presetName:AVAssetExportPresetAppleM4A];
    NSURL *song = [directory URLByAppendingPathComponent:name];
    export.outputURL = song;
    export.outputFileType = AVFileTypeAppleM4A;
    export.metadata = @[art];
    XCTestExpectation *exported = [self expectationWithDescription:@"export"];
    [export exportAsynchronouslyWithCompletionHandler:^{
        [exported fulfill];
    }];
    [self waitForExpectations:@[exported] timeout:30];
    XCTAssertEqual(export.status, AVAssetExportSessionStatusCompleted, @"%@", export.error);
    [NSFileManager.defaultManager removeItemAtURL:scratch error:NULL];
    return song;
}

// The host gives neither a cache nor a holder: the browser's own draw the
// file's cover in its row.
- (void)testArtIsDrawnThroughTheDefaultCacheAndHolder {
    NSURL *directory = [NSURL fileURLWithPath:[VibeTestProcessRoot() stringByAppendingPathComponent:
                                                       [NSUUID UUID].UUIDString] isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES
                                            attributes:nil error:NULL];
    NSURL *song = [self songWithCoverNamed:@"cover.m4a" inDirectory:directory];
    VibeBrowserFolderViewController *folder = [self showFolder:directory];
    XCTAssertTrue([self eventually:^BOOL {
        // The screen's holders by row, which the screen keeps private.
        NSDictionary *holders = [folder valueForKey:@"_artTracks"];
        id<AudioTrackMetadataHolder> holder = holders[song];
        return [holder isKindOfClass:VibeFileMetadataHolder.class] && [holder.metadata cachedThumbnail] != nil;
    }]);
    [NSFileManager.defaultManager removeItemAtURL:directory error:NULL];
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
