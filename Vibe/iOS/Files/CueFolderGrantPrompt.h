//
//  CueFolderGrantPrompt.h
//  Vibe (iOS)
//
//  A CUE sheet's grant reaches the sheet alone. When its open names the sheet
//  (PlaybackObserver's needsFolderOfSheetAtURL:), this asks for the folder
//  with the mac's grant wording. Granted, it presents a folder picker there,
//  and the picked folder reopens the sheet. The shell holds one, because a
//  picker's delegate is weak.
//

#import <UIKit/UIKit.h>

@class PlaybackController;

NS_ASSUME_NONNULL_BEGIN

@interface CueFolderGrantPrompt : NSObject

- (void)askForFolderOfSheetAtURL:(NSURL *)sheetURL
                       appending:(BOOL)appending
                        playback:(PlaybackController *)playback
                       presenter:(UIViewController *)presenter;

@end

NS_ASSUME_NONNULL_END
