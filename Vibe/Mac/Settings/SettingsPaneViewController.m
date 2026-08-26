//
//  SettingsPaneViewController.m
//  Vibe
//

#import "SettingsPaneViewController.h"
#import "WindowAnimation.h"


@implementation SettingsPaneViewController {
    NSStackView *_sectionStack;
    NSLayoutConstraint *_paneWidth;
    NSLayoutConstraint *_paneHeight;
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

- (void)loadPaneWithSections:(NSArray<__kindof NSView *> *)sections {
    NSStackView *stack = [NSStackView stackViewWithViews:sections];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 20;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    // TRAP: implicit layout animation only moves layer-backed views. Back the
    // whole subtree or the cards animate while their section headers jump.
    stack.wantsLayer = YES;
    for (NSView *section in sections) {
        [section.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;
    }
    _sectionStack = stack;
    // This pane's own measurement, which the shared pass below then replaces
    // with the largest pane's. The design size is a minimum: a localization
    // whose labels outgrow it widens the pane instead of clipping at the
    // edges (Greek was the first to overflow the original fixed width).
    NSSize paneSize = [self naturalPaneSize];

    NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, paneSize.width, paneSize.height)];
    // The size constraints define the pane's fitting size, which IS the
    // settings window's settled size: the constraint engine re-sizes a
    // contentViewController window to its content's fitting size after every
    // layout pass (_changeWindowFrameFromConstraintsIfNecessary), so a frame
    // held anywhere else snaps back. At 999, not required: a required size
    // forces the window there in a single layout pass when shared size changes;
    // at 999 the window edge wins while the coordinated frame and pane layout
    // animate to that size.
    //
    // The height rides the safe-area guide, not the view: the titlebar
    // overlays the pane (full-size content view), and anchoring the guide
    // makes the engine add that overlay to the window on its own.
    //
    // TRAP: the height is a CONSTANT, remeasured by paneContentDidChange, and
    // must stay one. Expressing it as an inequality against the stack instead
    // — height >= stack.height + padding — leaves the stack's own height
    // under-determined, and the solver spends the slack by stretching the
    // first section card down the pane.
    _paneWidth = [view.widthAnchor constraintEqualToConstant:paneSize.width];
    _paneHeight = [view.safeAreaLayoutGuide.heightAnchor constraintEqualToConstant:paneSize.height];
    _paneWidth.priority = NSLayoutPriorityRequired - 1;
    _paneHeight.priority = NSLayoutPriorityRequired - 1;
    [NSLayoutConstraint activateConstraints:@[_paneWidth, _paneHeight]];
    self.preferredContentSize = paneSize;

    [view addSubview:stack];
    // The safe-area top, not the view's: the settings window's titlebar
    // overlays the content (full-size content view), and the pane's design
    // height budgets the area below it.
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:view.safeAreaLayoutGuide.topAnchor constant:kPanePadding],
        [stack.leadingAnchor constraintEqualToAnchor:view.leadingAnchor constant:kPanePadding],
        [stack.trailingAnchor constraintEqualToAnchor:view.trailingAnchor constant:-kPanePadding],
    ]];

    self.view = view;
}

// What this pane alone would take: the section stack it is currently showing,
// floored at the design size.
- (NSSize)naturalPaneSize {
    NSSize fitting = _sectionStack.fittingSize;
    return NSMakeSize(MAX(kSettingsPaneWidth, fitting.width + 2 * kPanePadding),
                      MAX(kSettingsPaneMinHeight, fitting.height + 2 * kPanePadding));
}

// YES when the pane's size actually moved, which is what the host needs to
// know: the window follows the panes, not the other way round.
- (BOOL)applyPaneSize:(NSSize)size {
    if (!_paneWidth || !_paneHeight) {
        return NO;
    }
    if (fabs(_paneWidth.constant - size.width) < 0.5 && fabs(_paneHeight.constant - size.height) < 0.5) {
        return NO;
    }
    _paneWidth.constant = size.width;
    _paneHeight.constant = size.height;
    self.preferredContentSize = size;
    return YES;
}

+ (void)settleSharedSizeForPanes:(NSArray<__kindof NSViewController *> *)panes {
    for (NSViewController *pane in panes) {
        // Loads the rows, then settles only the state that affects their
        // measurement. Full refreshes belong to the selected pane.
        (void)pane.view;
        if ([pane isKindOfClass:SettingsPaneViewController.class]) {
            [(SettingsPaneViewController *)pane resolveLayoutStateFromSettings];
        }
    }
    [self applySharedSizeToPanes:panes];
}

// One size for every pane — the largest's — so switching panes resizes
// nothing. Recomputed rather than kept as a high-water mark, so a revealed row
// grows every pane and hiding it again gives the height back.
+ (void)applySharedSizeToPanes:(NSArray<__kindof NSViewController *> *)panes {
    NSSize shared = NSMakeSize(kSettingsPaneWidth, kSettingsPaneMinHeight);
    for (NSViewController *pane in panes) {
        if (![pane isKindOfClass:SettingsPaneViewController.class] || !pane.isViewLoaded) {
            continue;
        }
        NSSize natural = [(SettingsPaneViewController *)pane naturalPaneSize];
        shared.width = MAX(shared.width, natural.width);
        shared.height = MAX(shared.height, natural.height);
    }
    BOOL changed = NO;
    for (NSViewController *pane in panes) {
        if ([pane isKindOfClass:SettingsPaneViewController.class]) {
            changed |= [(SettingsPaneViewController *)pane applyPaneSize:shared];
        }
    }
    // The visible pane's constraints cannot move the window on their own —
    // they sit below required — so the host applies the matching frame.
    id host = panes.firstObject.parentViewController;
    if (changed && [host conformsToProtocol:@protocol(SettingsPaneSizeHost)]) {
        [(id<SettingsPaneSizeHost>)host settingsPaneSizeDidChange];
    }
}

// Siblings, not self alone: the size is shared, so one pane's change re-sizes
// all of them.
- (void)remeasurePanes {
    if (!_sectionStack) {
        return;
    }
    NSArray<__kindof NSViewController *> *panes = self.parentViewController.childViewControllers;
    [SettingsPaneViewController applySharedSizeToPanes:panes.count > 0 ? panes : @[self]];
}

// TRAP: loadView runs before resolveLayoutStateFromSettings, so the size first
// measured there counts every row that later hides itself. The shared-size
// pass resolves that layout state before taking its maximum, and the panes are
// remeasured after each selected-pane refresh or direct row toggle.
- (void)paneContentDidChange {
    [self animatePaneContentChange:^{}];
}

- (void)animatePaneContentChange:(void (^)(void))change {
    if (!_sectionStack) {
        change();
        return;
    }
    // Capture the old arranged-view frames before hidden changes replace the
    // stack's constraints. The layout pass inside the animation then moves the
    // section headers and cards with the frame instead of jumping ahead of it.
    [self.view layoutSubtreeIfNeeded];
    void (^updates)(void) = ^{
        change();
        [self remeasurePanes];
        [self.view layoutSubtreeIfNeeded];
    };
    if (!self.view.window.isVisible) {
        updates();
        return;
    }
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = kWindowResizeAnimationDuration;
        context.allowsImplicitAnimation = YES;
        updates();
    }];
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

- (NSSwitch *)switchWithAction:(SEL)action {
    NSSwitch *toggle = [[NSSwitch alloc] init];
    toggle.target = self;
    toggle.action = action;
    toggle.controlSize = NSControlSizeSmall;
    return toggle;
}

- (void)resolveLayoutStateFromSettings {
}

- (void)refreshFromSettings {
}

- (void)viewWillAppear {
    [super viewWillAppear];
    [self refreshSettingsAndPaneSize];
}

- (void)refreshSettingsAndPaneSize {
    [self resolveLayoutStateFromSettings];
    [self refreshFromSettings];
    [self paneContentDidChange];
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
                        [weakSelf refreshSettingsAndPaneSize];
                    }];
    _menuTrackingObserver = [NSNotificationCenter.defaultCenter
            addObserverForName:NSMenuDidEndTrackingNotification
                        object:NSApp.mainMenu
                         queue:NSOperationQueue.mainQueue
                    usingBlock:^(NSNotification *note) {
                        // After the menu item's action has run, not between
                        // tracking end and dispatch.
                        dispatch_async(dispatch_get_main_queue(), ^{
                            [weakSelf refreshSettingsAndPaneSize];
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
