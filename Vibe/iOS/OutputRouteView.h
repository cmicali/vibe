//
//  OutputRouteView.h
//  Vibe (iOS)
//
//  The card's output-route indicator: a glyph for where the audio is going,
//  the system's name for that device beside it when the audio is off-device,
//  and a tap that raises the system route picker.
//
//  It draws only what it is told. The route pair comes from PlaybackController
//  through PlayerViewController, which owns the one instance — this is card
//  chrome, not a page's control.
//

#import <UIKit/UIKit.h>

#import "OutputRouteRules.h"

@class OutputRouteView;

NS_ASSUME_NONNULL_BEGIN

@protocol OutputRouteViewDelegate <NSObject>
// The system route picker is up over the card, which holds its playhead
// display link for the duration exactly as it does for a sheet. The NO edge is
// also the only signal that the user may have just changed the route, since a
// destination picked against an inactive session posts no route notification.
- (void)outputRouteView:(OutputRouteView *)view isPresentingRoutes:(BOOL)presenting;
@end

@interface OutputRouteView : UIView

@property (nonatomic, weak) id<OutputRouteViewDelegate> delegate;

// The one entry point: the pair read from PlaybackController.
- (void)setRouteKind:(VibeOutputRouteKind)kind deviceName:(nullable NSString *)name;

// What it actually drew. Ordinary readonly state that the debug channel's
// state dump reports — a shipping header carries no #if DEBUG.
@property (nonatomic, readonly, copy) NSString *symbolName;
@property (nonatomic, readonly) BOOL showsDeviceName;

@end

NS_ASSUME_NONNULL_END
