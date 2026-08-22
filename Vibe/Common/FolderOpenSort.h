//
//  FolderOpenSort.h
//  Vibe
//
//  The order a folder's tracks land in the playlist when the user opens it.
//
//  Here rather than in NSURLUtil.h because two directories are written in
//  terms of it: the setting (Common/AppSettings) and the walk that applies it
//  (Util/NSURLUtil), and Util may not import a setting — see Util/CLAUDE.md.
//  Each shell reads the setting and hands the walk an answer.
//

#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, VibeFolderOpenSort) {
    // Filename, Finder's numeric comparator. The default, and what every
    // folder open did before the setting existed.
    VibeFolderOpenSortName = 0,
    // Content modification date, newest first — the same date the Finder and
    // the iOS Files browser sort by under "Date Modified". Files sharing a
    // date fall back to the name comparator, so a batch copy still reads in
    // track order rather than arbitrarily.
    VibeFolderOpenSortNewestFirst,
    // No sort at all: the order the file system or the file provider
    // enumerated. On a file-provider folder that is the provider's own
    // listing order; on a local APFS volume it is hash order, which is
    // effectively random.
    VibeFolderOpenSortAsReceived,
};

// Stable stored identifiers, never display names.
#define SETTINGS_VALUE_FOLDER_OPEN_SORT_NAME            @"name"
#define SETTINGS_VALUE_FOLDER_OPEN_SORT_NEWEST_FIRST    @"newest_first"
#define SETTINGS_VALUE_FOLDER_OPEN_SORT_AS_RECEIVED     @"as_received"
