//
//  VibeWidget-Bridging-Header.h
//  VibeWidget
//
//  The extension's whole view of the app: the published snapshot and nothing
//  else. Widening this is the wrong move — the extension is a second process
//  with no engine, no playlist and no audio session, and anything it needs to
//  draw belongs in VibeWidgetState where the app can publish it. The one other
//  header is a Foundation-only seam of numbers, not app state: the empty
//  strip's midline is the mac player's, drawn by the same metrics.
//

#import "LoadingIndicatorMath.h"
#import "VibeWidgetState.h"
