//
//  AudioFileConverter+Sandbox.h
//  Vibe
//
//  Getting the encoded file from the temp directory to where the user asked
//  for it, which in a sandboxed app is the hard half of converting. Three
//  rungs, cheapest first, and the encode is finished before any of them runs:
//
//  1. **A plain move.** Works when a folder grant already covers the
//     destination — a dropped folder, or one added in Settings > Files.
//  2. **The related-item path.** The sandbox extends the *source* file's grant
//     to a sibling with the same name and a different extension, but only
//     while a presenter claiming that relationship is registered AND only
//     inside a coordinated write. This is the rung that makes "convert the
//     file I opened, in place" work with no folder grant at all.
//  3. **A save panel.** Always works, because the user's pick carries its own
//     grant, and costs one Return keypress since it is pre-filled.
//
//  A successful presenter from rung 2 is deliberately never unregistered: the
//  extension dies with the registration, and the app goes on reading the file
//  it just wrote.
//

#import "AudioFileConverter.h"

NS_ASSUME_NONNULL_BEGIN

@interface AudioFileConverter (Sandbox)

// Rungs 1 and 2, in order. Returns where the file landed, or nil with the
// plain move's error — the one that says why the obvious path was refused.
- (nullable NSURL *)moveTemp:(NSURL *)tempURL
                      source:(NSURL *)sourceURL
                 destination:(NSURL *)destinationURL
                       error:(NSError **)error;

// Rung 3. Sheets on window; the completion runs on the main thread, with
// NSUserCancelledError when the user dismisses the panel.
- (void)runSavePanelForTemp:(NSURL *)tempURL
                destination:(NSURL *)destinationURL
                     window:(NSWindow *)window
                 completion:(void (^)(NSURL *_Nullable, NSError *_Nullable))completion;

@end

NS_ASSUME_NONNULL_END
