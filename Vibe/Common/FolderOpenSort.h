//
//  FolderOpenSort.h
//  Vibe
//
//  The order a folder's tracks land in the playlist when the user opens it.
//  Its own header because FolderWalk takes it as a walk parameter and may not
//  import a setting. An app keeps its stored identifiers for the orders.
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
