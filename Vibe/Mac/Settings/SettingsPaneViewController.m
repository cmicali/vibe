//
//  SettingsPaneViewController.m
//  Vibe
//

#import "SettingsPaneViewController.h"
#import "NSImage+Util.h"
#import "NSView+DarkMode.h"
#import "WindowAnimation.h"


// The System Settings inline dropdown: borderless, the value beside an
// always-visible chevron badge, no hover treatment — the reference has none;
// the menu just pops on click. AppKit draws a popup's arrows only with a
// bezel, so the badge is drawn here, in width the intrinsic size reserves
// for it. (A bezel-on-hover variant fought the widened bounds and double
// drew; owning the whole rendering is the stable form.)
@interface VibeInlinePopUpButton : NSPopUpButton
@end

@implementation VibeInlinePopUpButton

// The badge is the System Settings treatment, measured off its pixels: the
// chevrons sit in a filled circle one lift-step above the card, label-colored
// so both halves adapt to the appearance.
static const CGFloat kInlineBadgeDiameter = 19;
static const CGFloat kInlineBadgeGap = 8;

// Sized to the DISPLAYED value, not the widest menu item — the badge stays
// pinned at the row's trailing edge and the text hugs it, like the
// reference. The height is the cell's own answer.
- (NSSize)intrinsicContentSize {
    NSSize size = [super intrinsicContentSize];
    NSString *title = self.selectedItem.title ?: @"";
    CGFloat text = ceil([title sizeWithAttributes:@{NSFontAttributeName: self.font}].width);
    size.width = text + 8 + kInlineBadgeGap + kInlineBadgeDiameter + 2;
    return size;
}

// Selection reaches the displayed title through here, for a user pick and
// the programmatic selects alike — the moment the width's input changes.
- (void)synchronizeTitleAndSelectedItem {
    [super synchronizeTitleAndSelectedItem];
    [self invalidateIntrinsicContentSize];
}

- (void)selectItem:(NSMenuItem *)item {
    [super selectItem:item];
    [self invalidateIntrinsicContentSize];
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    NSRect bounds = self.bounds;
    NSRect circle = NSMakeRect(NSMaxX(bounds) - kInlineBadgeDiameter - 2,
                               NSMidY(bounds) - kInlineBadgeDiameter / 2,
                               kInlineBadgeDiameter, kInlineBadgeDiameter);
    circle = [self backingAlignedRect:circle options:NSAlignAllEdgesNearest];
    [[NSColor.labelColor colorWithAlphaComponent:0.08] setFill];
    [[NSBezierPath bezierPathWithOvalInRect:circle] fill];
    // Built per draw so the palette color resolves against the appearance the
    // draw runs under — a template drawInRect: renders black, not tinted.
    NSImage *chevrons = [NSImage symbolNamed:@"chevron.up.chevron.down"
                                   pointSize:9 weight:NSFontWeightBold
                                     palette:@[NSColor.labelColor]
                    accessibilityDescription:nil];
    NSSize size = chevrons.size;
    NSRect target = NSMakeRect(NSMidX(circle) - size.width / 2,
                               NSMidY(circle) - size.height / 2,
                               size.width, size.height);
    [chevrons drawInRect:[self backingAlignedRect:target options:NSAlignAllEdgesNearest]
                fromRect:NSZeroRect
               operation:NSCompositingOperationSourceOver
                fraction:1.0
          respectFlipped:YES
                   hints:nil];
}

@end

@implementation SettingsPaneViewController {
    NSStackView *_sectionStack;
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

    // The pane's own backdrop: white in light mode — System Settings' light
    // content area is white, not the window gray, with the cards a step
    // DARKER — and nothing in dark, where the window background already
    // matches.
    SettingsFillView *view = [[SettingsFillView alloc]
            initWithFrame:NSMakeRect(0, 0, paneSize.width, paneSize.height)];
    view.darkColor = NSColor.clearColor;
    view.lightColor = NSColor.whiteColor;
    // TRAP: the pane carries NO size constraints of its own — the view
    // follows the tab view by autoresizing mask, the frame NSTabView hands
    // every selected item view. It cannot lean on the host's constraints:
    // the tab controller pins only the item selected before the window
    // existed, and every later selection runs its transition path, which
    // sets a frame and adds nothing — so a pane that opted out of the mask
    // collapsed to its fitting size the moment it was selected second (zero
    // height, the rows drawn hanging below it): no click landed inside it,
    // and the theme editor, pinned to the pane's bottom, had no height. Any
    // pane-side size constraint, equality or minimum, re-enters the
    // fitting-size snap: the constraint engine re-sizes a
    // contentViewController window to its content's fitting size after
    // every layout pass, so a user's drag snapped straight back to the
    // constrained answer (observed with both forms). That includes
    // preferredContentSize itself: macOS 26.5 turns a nonzero one into
    // equality constraints on this view at priority 501, which pinned the
    // window (sharedPaneSize in the header). The shared size lives in that
    // plain property alone; the tab controller turns it into the window's
    // contentMinSize and grows an undersized window, and AppKit's own resize
    // clamp holds the floor under a user drag.
    view.translatesAutoresizingMaskIntoConstraints = YES;
    view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _sharedPaneSize = paneSize;

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
    if (!self.isViewLoaded) {
        return NO;
    }
    if (fabs(_sharedPaneSize.width - size.width) < 0.5
            && fabs(_sharedPaneSize.height - size.height) < 0.5) {
        return NO;
    }
    _sharedPaneSize = size;
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
    // A pane carries no size constraints, so the new shared size cannot reach
    // the window by itself — the host applies the matching frame.
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
    if (!_sectionStack) {
        return;
    }
    // Capture the old arranged-view frames before hidden changes replace the
    // stack's constraints. The layout pass inside the animation then moves the
    // section headers and cards with the frame instead of jumping ahead of it.
    [self.view layoutSubtreeIfNeeded];
    void (^updates)(void) = ^{
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

// The width is a CAP for a runaway localized or device-named title, not a
// fixed size — the value hugs the row's trailing edge.
- (NSPopUpButton *)popUpButtonWithWidth:(CGFloat)width action:(SEL)action {
    NSPopUpButton *popUp = [[VibeInlinePopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    if (action) {
        popUp.target = self;
        popUp.action = action;
    }
    popUp.bordered = NO;
    // A borderless popup still draws its own small arrows where the badge
    // sits; the badge is the only chevron treatment.
    ((NSPopUpButtonCell *)popUp.cell).arrowPosition = NSPopUpNoArrow;
    [popUp setContentHuggingPriority:NSLayoutPriorityDefaultHigh
                      forOrientation:NSLayoutConstraintOrientationHorizontal];
    [popUp.widthAnchor constraintLessThanOrEqualToConstant:width].active = YES;
    return popUp;
}

- (void)addItem:(NSString *)title value:(id)value to:(NSPopUpButton *)popUp {
    [popUp addItemWithTitle:title];
    popUp.lastItem.representedObject = value;
}

- (void)selectValue:(id)value in:(NSPopUpButton *)popUp {
    [popUp selectItemAtIndex:[popUp indexOfItemWithRepresentedObject:value]];
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
// registration's confirmation, the converter's save panel).
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
                        run_on_main_thread({
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
