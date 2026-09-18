//
//  VibeWidgetStrings.h
//  Vibe (iOS)
//
//  The widget's user-facing strings, resolved from VibeStrings.h.
//
//  It exists because the extension is Swift and the registry is a header of
//  Objective-C macros: a Swift call site cannot say STR_WIDGET_DESCRIPTION, and
//  the alternative — writing the keys again in Swift — is the exact drift the
//  one-registry rule prevents. So the macros stay the only declaration and this
//  is the door onto them, compiled into the extension beside VibeWidgetState.
//
//  TRAP: the lookups resolve against NSBundle.mainBundle, which inside an
//  appex is the APPEX's bundle, not the app's. The widget target therefore
//  carries Resources/Localizable.xcstrings in its own resources (project.yml);
//  without it every language falls back to the macro's English default, and
//  nothing — not the build, not make check-translations — would say so.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface VibeWidgetStrings : NSObject

@property (class, nonatomic, readonly) NSString *widgetDescription;
@property (class, nonatomic, readonly) NSString *playPauseIntentTitle;
@property (class, nonatomic, readonly) NSString *nextIntentTitle;
@property (class, nonatomic, readonly) NSString *seekIntentTitle;

@end

NS_ASSUME_NONNULL_END
