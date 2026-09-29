//
//  SettingsPaneViewController.m
//  Vibe
//

#import "SettingsPaneViewController.h"
#import "NSImage+Util.h"
#import "NSView+DarkMode.h"
#import "WindowAnimation.h"


// Borderless, the value beside a chevron badge that grows into a rounded
// bezel on hover. AppKit draws a popup's arrows only with a bezel, so the
// badge, bezel and value placement are all drawn here; switching the cell's
// own bezel on for hover double-draws against the widened bounds.
@interface VibeInlinePopUpButton : NSPopUpButton
@end

@implementation VibeInlinePopUpButton {
    BOOL _hovered;
}

// Measured off the System Settings reference.
static const CGFloat kInlineBadgeDiameter = 19;
static const CGFloat kInlineBadgeGap = 8;
static const CGFloat kInlineEdgeInset = 3.5;
static const CGFloat kInlineBezelHeight = kInlineBadgeDiameter + 2 * kInlineEdgeInset;
static const CGFloat kInlineBezelRadius = 6;
static const CGFloat kInlineTitleInset = 10;

- (instancetype)initWithFrame:(NSRect)frame pullsDown:(BOOL)flag {
    self = [super initWithFrame:frame pullsDown:flag];
    if (self) {
        // ActiveInActiveApp: hover still lands while the font or color panel
        // holds key.
        [self addTrackingArea:[[NSTrackingArea alloc]
                initWithRect:NSZeroRect
                     options:(NSTrackingMouseEnteredAndExited | NSTrackingActiveInActiveApp
                              | NSTrackingInVisibleRect)
                       owner:self
                    userInfo:nil]];
    }
    return self;
}

// The cell's own padding around the value (image, when the item has one, then
// title), measured off its rects so the value lands at an exact inset.
- (NSEdgeInsets)cellValuePadding {
    NSRect probe = NSMakeRect(0, 0, 200, kInlineBezelHeight);
    NSRect title = [self.cell titleRectForBounds:probe];
    CGFloat leading = NSMinX(title);
    if (self.selectedItem.image) {
        leading = NSMinX([self.cell imageRectForBounds:probe]);
    }
    return NSEdgeInsetsMake(0, leading, 0, NSMaxX(probe) - NSMaxX(title));
}

- (CGFloat)cellImageAdvance {
    if (!self.selectedItem.image) {
        return 0;
    }
    NSRect probe = NSMakeRect(0, 0, 200, kInlineBezelHeight);
    return NSMinX([self.cell titleRectForBounds:probe]) - NSMinX([self.cell imageRectForBounds:probe]);
}

// Sized to the DISPLAYED value, not the widest menu item.
- (NSSize)intrinsicContentSize {
    NSString *title = self.selectedItem.title ?: @"";
    CGFloat text = ceil([title sizeWithAttributes:@{NSFontAttributeName: self.font}].width);
    return NSMakeSize(kInlineTitleInset + [self cellImageAdvance] + text + kInlineBadgeGap
                              + kInlineBadgeDiameter + kInlineEdgeInset,
                      MAX([super intrinsicContentSize].height, kInlineBezelHeight));
}

// Both user picks and programmatic selects pass through here.
- (void)synchronizeTitleAndSelectedItem {
    [super synchronizeTitleAndSelectedItem];
    [self invalidateIntrinsicContentSize];
}

- (void)selectItem:(NSMenuItem *)item {
    if (item == self.selectedItem) {
        return; // a refresh re-selecting the shown value moves no width
    }
    [super selectItem:item];
    [self invalidateIntrinsicContentSize];
}

- (void)setHovered:(BOOL)hovered {
    if (_hovered != hovered) {
        _hovered = hovered;
        self.needsDisplay = YES;
    }
}

- (void)mouseEntered:(NSEvent *)event {
    [self setHovered:YES];
}

- (void)mouseExited:(NSEvent *)event {
    [self setHovered:NO];
}

// The menu tracks inside super's mouseDown:, and no exit event is guaranteed
// for a mouse that left meanwhile.
- (void)mouseDown:(NSEvent *)event {
    [super mouseDown:event];
    NSPoint point = [self convertPoint:self.window.mouseLocationOutsideOfEventStream fromView:nil];
    [self setHovered:[self mouse:point inRect:self.bounds]];
}

- (void)drawRect:(NSRect)dirtyRect {
    NSRect bounds = self.bounds;
    NSRect badge = NSMakeRect(NSMaxX(bounds) - kInlineEdgeInset - kInlineBadgeDiameter,
                              NSMidY(bounds) - kInlineBadgeDiameter / 2,
                              kInlineBadgeDiameter, kInlineBadgeDiameter);
    [[NSColor.labelColor colorWithAlphaComponent:0.08] setFill];
    if (_hovered && self.isEnabled) {
        NSRect bezel = NSInsetRect(bounds, 0, (NSHeight(bounds) - kInlineBezelHeight) / 2);
        bezel = [self backingAlignedRect:bezel options:NSAlignAllEdgesNearest];
        [[NSBezierPath bezierPathWithRoundedRect:bezel xRadius:kInlineBezelRadius
                                         yRadius:kInlineBezelRadius] fill];
    }
    else {
        NSRect circle = [self backingAlignedRect:badge options:NSAlignAllEdgesNearest];
        [[NSBezierPath bezierPathWithOvalInRect:circle] fill];
    }
    NSEdgeInsets padding = [self cellValuePadding];
    NSRect title = bounds;
    title.origin.x = kInlineTitleInset - padding.left;
    title.size.width = NSMinX(badge) - kInlineBadgeGap + padding.right - NSMinX(title);
    [self.cell drawWithFrame:title inView:self];
    // Built per draw so the palette resolves against the current appearance;
    // a template drawInRect: renders black.
    NSImage *chevrons = [NSImage symbolNamed:@"chevron.up.chevron.down"
                                   pointSize:9 weight:NSFontWeightBold
                                     palette:@[NSColor.labelColor]
                    accessibilityDescription:nil];
    NSSize size = chevrons.size;
    NSRect target = NSMakeRect(NSMidX(badge) - size.width / 2,
                               NSMidY(badge) - size.height / 2,
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
    NSSize _lastNaturalSize;
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
    NSStackView *stack = [[SettingsStackView alloc] initWithFrame:NSZeroRect];
    for (NSView *section in sections) [stack addArrangedSubview:section];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 20;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    // TRAP: implicit layout animation moves only layer-backed views; without
    // this the cards animate while their section headers jump.
    stack.wantsLayer = YES;
    for (NSView *section in sections) {
        [section.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;
    }
    _sectionStack = stack;
    NSSize paneSize = [self naturalPaneSize];

    // System Settings' light content area is white, the cards a step darker.
    SettingsFillView *view = [[SettingsFillView alloc]
            initWithFrame:NSMakeRect(0, 0, paneSize.width, paneSize.height)];
    view.darkColor = NSColor.clearColor;
    view.lightColor = NSColor.whiteColor;
    // TRAP: no size constraints on the pane; it follows the tab view by
    // autoresizing mask. The tab controller pins only the pane selected before
    // the window existed, so a pane without the mask collapses to zero height
    // when selected second. Any pane-side size constraint, preferredContentSize
    // included, re-enters the window's fitting-size snap and fights the user's
    // resize; the floor is the window's contentMinSize alone.
    view.translatesAutoresizingMaskIntoConstraints = YES;
    view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _sharedPaneSize = paneSize;

    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.hasVerticalScroller = YES;
    // TRAP: AppKit's default NO draws a scroller down a pane with nothing to scroll.
    scroll.autohidesScrollers = YES;
    scroll.drawsBackground = NO;
    scroll.automaticallyAdjustsContentInsets = NO;
    scroll.documentView = stack;
    [view addSubview:scroll];
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:view.safeAreaLayoutGuide.topAnchor constant:kPanePadding],
        [scroll.leadingAnchor constraintEqualToAnchor:view.leadingAnchor constant:kPanePadding],
        [scroll.trailingAnchor constraintEqualToAnchor:view.trailingAnchor constant:-kPanePadding],
        [scroll.bottomAnchor constraintEqualToAnchor:view.bottomAnchor constant:-kPanePadding],
        [stack.topAnchor constraintEqualToAnchor:scroll.contentView.topAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.contentView.leadingAnchor],
        [stack.widthAnchor constraintEqualToAnchor:scroll.contentView.widthAnchor],
    ]];

    self.view = view;
}

// TRAP: the width must be the PANE's, never the stack's. The theme editor,
// swapped in beside the stack, keeps its required width while hidden; a floor
// from the stack alone let the window sit narrower than the pane, clipping
// every trailing control on every pane. The height is the stack's, because
// the swapped-in page scrolls.
// TRAP: each fittingSize is a full Auto Layout solve, and this takes two.
- (NSSize)naturalPaneSize {
    NSSize stack = _sectionStack.fittingSize;
    // Not loaded: the seed inside loadPaneWithSections:.
    CGFloat width = self.isViewLoaded ? self.view.fittingSize.width
                                      : stack.width + 2 * kPanePadding;
    _lastNaturalSize = NSMakeSize(MAX(kSettingsPaneWidth, width),
                      MIN(kSettingsPaneMaxHeight, MAX(kSettingsPaneMinHeight, stack.height + 2 * kPanePadding)));
    return _lastNaturalSize;
}

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
        (void)pane.view;
        if ([pane isKindOfClass:SettingsPaneViewController.class]) {
            [(SettingsPaneViewController *)pane resolveLayoutStateFromSettings];
        }
    }
    [self applySharedSizeToPanes:panes measure:YES];
}

// Recomputed, never a high-water mark, so hiding a row gives the height back.
// measure NO takes each sibling's last measurement: a hidden pane cannot have
// moved, so a visible pane's change costs one solve, not one per pane.
+ (void)applySharedSizeToPanes:(NSArray<__kindof NSViewController *> *)panes measure:(BOOL)measure {
    NSSize shared = NSMakeSize(kSettingsPaneWidth, kSettingsPaneMinHeight);
    for (NSViewController *pane in panes) {
        if (![pane isKindOfClass:SettingsPaneViewController.class] || !pane.isViewLoaded) {
            continue;
        }
        SettingsPaneViewController *settingsPane = (SettingsPaneViewController *)pane;
        NSSize natural = !measure && !NSEqualSizes(settingsPane->_lastNaturalSize, NSZeroSize)
                ? settingsPane->_lastNaturalSize : [settingsPane naturalPaneSize];
        shared.width = MAX(shared.width, natural.width);
        shared.height = MAX(shared.height, natural.height);
    }
    BOOL changed = NO;
    for (NSViewController *pane in panes) {
        if ([pane isKindOfClass:SettingsPaneViewController.class]) {
            changed |= [(SettingsPaneViewController *)pane applyPaneSize:shared];
        }
    }
    id host = panes.firstObject.parentViewController;
    if (changed && [host conformsToProtocol:@protocol(SettingsPaneSizeHost)]) {
        [(id<SettingsPaneSizeHost>)host settingsPaneSizeDidChange];
    }
}

- (void)remeasurePanes {
    if (!_sectionStack) {
        return;
    }
    NSArray<__kindof NSViewController *> *panes = self.parentViewController.childViewControllers;
    [SettingsPaneViewController applySharedSizeToPanes:panes.count > 0 ? panes : @[self] measure:NO];
}

// TRAP: loadView runs before resolveLayoutStateFromSettings, so the first
// measurement counts rows that later hide themselves. The shared-size pass
// resolves layout state first; this remeasures after each refresh or toggle.
- (void)paneContentDidChange {
    if (!_sectionStack) {
        return;
    }
    // TRAP: a hidden window must do no work here. The panes outlive the
    // window, so measuring would put Auto Layout solves on every later content
    // change, audio events included, for nobody; showWindow: settles every pane.
    if (!self.view.window.isVisible) {
        return;
    }
    // Capture the old frames before hidden changes replace the stack's
    // constraints, so the animated pass below moves rows with the window.
    [self.view layoutSubtreeIfNeeded];
    // The shared size is a maximum over panes: if ours did not move, it did not.
    NSSize previous = _lastNaturalSize;
    if (NSEqualSizes([self naturalPaneSize], previous)) {
        return;
    }
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = kWindowResizeAnimationDuration;
        context.allowsImplicitAnimation = YES;
        [self remeasurePanes];
        [self.view layoutSubtreeIfNeeded];
    }];
}

- (NSPopUpButton *)popUpButtonWithWidth:(CGFloat)width action:(SEL)action {
    NSPopUpButton *popUp = [[VibeInlinePopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    if (action) {
        popUp.target = self;
        popUp.action = action;
    }
    popUp.bordered = NO;
    // A borderless popup still draws its own arrows and reserves room for them.
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
    NSInteger index = [popUp indexOfItemWithRepresentedObject:value];
    if (index != popUp.indexOfSelectedItem) {
        [popUp selectItemAtIndex:index];
    }
}

- (VibeSwitch *)switchWithAction:(SEL)action {
    VibeSwitch *toggle = [[VibeSwitch alloc] init];
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

// Settings change under a visible pane through the menu bar, which never moves
// key, and through system panels that take key (default-player confirmation,
// the converter's save panel).
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
                        // Queued past the item's action, which may have
                        // been File > Close.
                        run_on_main_thread({
                            if (weakSelf.view.window.isVisible) {
                                [weakSelf refreshSettingsAndPaneSize];
                            }
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
