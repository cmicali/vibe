//
//  FolderOpenSort.h
//  Vibe
//
//  The order a folder's tracks land in the playlist when the user opens it.
//  Its own header because Util/NSURLUtil takes it as a walk parameter and may
//  not import a setting.
//

#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, VibeFolderOpenSort) {
    // Filename, Finder's numeric comparator. The default.
    VibeFolderOpenSortName = 0,
    // Content modification date, newest first; equal dates (a batch copy) fall
    // back to the name comparator.
    VibeFolderOpenSortNewestFirst,
    // The enumeration order: a file provider's own listing order, or APFS hash
    // order (effectively random) on a local volume.
    VibeFolderOpenSortAsReceived,
};

// Stable stored identifiers, never display names.
#define SETTINGS_VALUE_FOLDER_OPEN_SORT_NAME            @"name"
#define SETTINGS_VALUE_FOLDER_OPEN_SORT_NEWEST_FIRST    @"newest_first"
#define SETTINGS_VALUE_FOLDER_OPEN_SORT_AS_RECEIVED     @"as_received"
