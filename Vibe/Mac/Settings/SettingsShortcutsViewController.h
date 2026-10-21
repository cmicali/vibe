//
//  SettingsShortcutsViewController.h
//  Vibe
//

#import "SettingsPaneViewController.h"
#import "ShortcutRules.h"

NS_ASSUME_NONNULL_BEGIN

// The app's remappable commands, listed in groups under their titles.
// Recording is a state of the pane, not a control. The pane reads nothing of
// the app's. Its rows, its strings, and every read and write of the shortcuts
// are handed in.
@interface SettingsShortcutsViewController : SettingsPaneViewController

// commandRows answers the groups, @[title, @[@[identifier, label], …]]
// each. It is asked again on every refresh, since a label can follow a
// setting. shortcutForCommand answers the shortcut a command's menu item
// carries, None for none. The pane draws it (ShortcutLayout.h). overrides
// reads the store, sparse over the defaults (ShortcutRules.h).
// setOverrides replaces it whole. Reset All passes none, and undo passes the
// set from before a write. assign records or clears (None) one command's
// shortcut. It refuses or stores, and names in *loser the command that lost
// the shortcut. Each write requests its own effects.
- (instancetype)initWithEffectsSink:(void (^)(NSUInteger effects))sink
                        commandRows:(NSArray<NSArray *> *(^)(void))commandRows
                 shortcutForCommand:(VibeShortcut (^)(NSString *identifier))shortcutForCommand
                          overrides:(NSDictionary<NSString *, NSNumber *> *(^)(void))overrides
                       setOverrides:(void (^)(NSDictionary<NSString *, NSNumber *> *overrides))setOverrides
                             assign:(VibeShortcutAssignment (^)(VibeShortcut shortcut, NSString *identifier,
                                                                NSString *_Nullable *_Nullable loser))assign;

// The pane's strings. Every one is set before the view loads.
@property (copy, nonatomic) NSString *commandColumnTitle;
@property (copy, nonatomic) NSString *shortcutColumnTitle;
@property (copy, nonatomic) NSString *recordTitle;
@property (copy, nonatomic) NSString *clearTitle;
@property (copy, nonatomic) NSString *resetAllTitle;
// The caption below the list when there is nothing to report, and its tooltip.
@property (copy, nonatomic) NSString *explainer;
@property (copy, nonatomic) NSString *layoutNote;
// Tooltips of a disabled button: no command is selected, the command has no
// shortcut, and every shortcut is its default.
@property (copy, nonatomic) NSString *selectTip;
@property (copy, nonatomic) NSString *noneTip;
@property (copy, nonatomic) NSString *defaultsTip;
@property (copy, nonatomic) NSString *undoActionName;
// The captions. recordingFormat takes the command's label. reservedFormat
// takes the shortcut. reassignedFormat takes the shortcut, the command that
// took it, and the command that lost it.
@property (copy, nonatomic) NSString *recordingFormat;
@property (copy, nonatomic) NSString *reservedFormat;
@property (copy, nonatomic) NSString *unusableCaption;
@property (copy, nonatomic) NSString *reassignedFormat;

@end

NS_ASSUME_NONNULL_END
