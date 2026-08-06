//
//  DocumentTypes.h
//  Vibe
//

#import <Foundation/Foundation.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

NS_ASSUME_NONNULL_BEGIN

// The document types Vibe declares in Info.plist, under
// CFBundleDocumentTypes, and the Launch Services side of them: asking the
// system to make Vibe the default app for every audio type it plays, so that
// the user need not walk Finder's Get Info > Open With > Change All once per
// extension.
//
// It is stateless, with all class methods. Info.plist is the single source of
// truth, so the open panel's filter, the types offered to Launch Services and
// what the app is actually registered for cannot drift apart.
@interface DocumentTypes : NSObject

// Every LSItemContentTypes entry across all declarations, folders included.
@property (class, readonly) NSArray<UTType *> *declaredTypes;

// The file types alone. The "Folder" declaration is an Alternate handler, for
// dropping or opening a folder of tracks, and never something to become the
// system default for.
@property (class, readonly) NSArray<UTType *> *declaredFileTypes;

// YES when Vibe is already the default app for every declaredFileTypes entry.
@property (class, readonly) BOOL isDefaultAppForAllFileTypes;

// Requests default-app status for every declaredFileTypes entry. It returns
// immediately: the system asks the user to confirm and reports the outcome
// itself, and the result shows up in isDefaultAppForAllFileTypes and in the
// log.
+ (void)makeDefaultApp;

@end

NS_ASSUME_NONNULL_END
