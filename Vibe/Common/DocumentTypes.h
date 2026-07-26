//
//  DocumentTypes.h
//  Vibe
//

#import <Foundation/Foundation.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

NS_ASSUME_NONNULL_BEGIN

// The document types Vibe declares in Info.plist (CFBundleDocumentTypes), and
// the Launch Services side of them: asking the system to make Vibe the default
// app for every audio type it plays, so the user doesn't have to walk Finder's
// Get Info > Open With > Change All for each extension.
//
// Stateless — all class methods. Info.plist is the single source of truth: the
// open panel's filter, the types offered to Launch Services, and what the app
// is actually registered for can't drift apart.
@interface DocumentTypes : NSObject

// Every LSItemContentTypes entry across all declarations, folders included.
@property (class, readonly) NSArray<UTType *> *declaredTypes;

// Just the file types — the "Folder" declaration is an Alternate handler (for
// dropping/opening a folder of tracks), never something to become the system
// default for.
@property (class, readonly) NSArray<UTType *> *declaredFileTypes;

// YES when Vibe is already the default app for every declaredFileTypes entry.
@property (class, readonly) BOOL isDefaultAppForAllFileTypes;

// Requests default-app status for every declaredFileTypes entry. Returns
// immediately — the system asks the user to confirm and reports the outcome
// itself; the result shows up in isDefaultAppForAllFileTypes and in the log.
+ (void)makeDefaultApp;

@end

NS_ASSUME_NONNULL_END
