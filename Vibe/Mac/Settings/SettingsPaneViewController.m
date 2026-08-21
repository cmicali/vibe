//
//  SettingsPaneViewController.m
//  Vibe
//

#import "SettingsPaneViewController.h"

static const CGFloat kPanePadding = 20;

@implementation SettingsPaneViewController {
    id _windowKeyObserver;
    id _menuTrackingObserver;
}

- (instancetype)initWithPlayerController:(MainPlayerController *)playerController {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _playerController = playerController;
    }
    return self;
}

- (void)loadPaneWithSize:(NSSize)size grid:(NSGridView *)grid {
    grid.translatesAutoresizingMaskIntoConstraints = NO;
    // The design size is a minimum: a localization whose labels outgrow it
    // widens the pane instead of clipping at the edges (Greek was the first
    // to overflow the original fixed width).
    NSSize fitting = grid.fittingSize;
    NSSize paneSize = NSMakeSize(MAX(size.width, fitting.width + 2 * kPanePadding),
                                 MAX(MAX(size.height, fitting.height + 2 * kPanePadding),
                                     kSettingsPaneMinHeight));

    NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, paneSize.width, paneSize.height)];
    // The size constraints define the pane's fitting size, which IS the
    // settings window's settled size: the constraint engine re-sizes a
    // contentViewController window to its content's fitting size after every
    // layout pass (_changeWindowFrameFromConstraintsIfNecessary), so a frame
    // held anywhere else snaps back. At 999, not required: a required size
    // forces the window there in a single layout pass on pane switch, which
    // is exactly the snap the animated resize in SettingsWindowController
    // exists to replace — at 999 the window edge wins while the frame is
    // animating and the pane stretches with it.
    //
    // The height rides the safe-area guide, not the view: the titlebar
    // overlays the pane (full-size content view), and anchoring the guide
    // makes the engine add that overlay to the window on its own.
    NSLayoutConstraint *width = [view.widthAnchor constraintEqualToConstant:paneSize.width];
    NSLayoutConstraint *height = [view.safeAreaLayoutGuide.heightAnchor constraintEqualToConstant:paneSize.height];
    width.priority = NSLayoutPriorityRequired - 1;
    height.priority = NSLayoutPriorityRequired - 1;
    [NSLayoutConstraint activateConstraints:@[width, height]];
    self.preferredContentSize = paneSize;

    [view addSubview:grid];
    // The safe-area top, not the view's: the settings window's titlebar
    // overlays the content (full-size content view), and the pane's design
    // height budgets the area below it.
    [NSLayoutConstraint activateConstraints:@[
        [grid.topAnchor constraintEqualToAnchor:view.safeAreaLayoutGuide.topAnchor constant:kPanePadding],
        [grid.centerXAnchor constraintEqualToAnchor:view.centerXAnchor],
        [grid.leadingAnchor constraintGreaterThanOrEqualToAnchor:view.leadingAnchor constant:kPanePadding],
    ]];

    self.view = view;
}

+ (NSGridView *)formGridWithRows:(NSArray<NSArray<NSView *> *> *)rows {
    NSGridView *grid = [NSGridView gridViewWithViews:rows];
    grid.rowSpacing = 14;
    grid.columnSpacing = 8;
    grid.rowAlignment = NSGridRowAlignmentFirstBaseline;
    [grid columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;
    return grid;
}

- (NSPopUpButton *)popUpButtonWithWidth:(CGFloat)width action:(SEL)action {
    NSPopUpButton *popUp = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    if (action) {
        popUp.target = self;
        popUp.action = action;
    }
    [popUp.widthAnchor constraintEqualToConstant:width].active = YES;
    return popUp;
}

- (void)refreshFromSettings {
}

- (void)viewWillAppear {
    [super viewWillAppear];
    [self refreshFromSettings];
}

// Settings can change while the pane stays visible: through the menu bar —
// which never moves key focus, hence the menu-tracking observer — or through
// a system panel that took key, hence the key observer (the default-player
// claim's confirmation, the converter's save panel).
- (void)viewDidAppear {
    [super viewDidAppear];
    __weak __typeof(self) weakSelf = self;
    _windowKeyObserver = [NSNotificationCenter.defaultCenter
            addObserverForName:NSWindowDidBecomeKeyNotification
                        object:self.view.window
                         queue:NSOperationQueue.mainQueue
                    usingBlock:^(NSNotification *note) {
                        [weakSelf refreshFromSettings];
                    }];
    _menuTrackingObserver = [NSNotificationCenter.defaultCenter
            addObserverForName:NSMenuDidEndTrackingNotification
                        object:NSApp.mainMenu
                         queue:NSOperationQueue.mainQueue
                    usingBlock:^(NSNotification *note) {
                        // After the menu item's action has run, not between
                        // tracking end and dispatch.
                        dispatch_async(dispatch_get_main_queue(), ^{
                            [weakSelf refreshFromSettings];
                        });
                    }];
}

- (void)viewWillDisappear {
    [super viewWillDisappear];
    if (_windowKeyObserver) {
        [NSNotificationCenter.defaultCenter removeObserver:_windowKeyObserver];
        _windowKeyObserver = nil;
    }
    if (_menuTrackingObserver) {
        [NSNotificationCenter.defaultCenter removeObserver:_menuTrackingObserver];
        _menuTrackingObserver = nil;
    }
}

@end
