//
//  OutputRouteView.h
//  Vibe (iOS)
//
//  A page's output-route indicator: a glyph, the device name when the audio is
//  off-device, and a tap that raises the system route picker. It draws only
//  what PlayerViewController pushes to every visible page.
//

#import <UIKit/UIKit.h>

#import "OutputRouteRules.h"

@class OutputRouteView;

NS_ASSUME_NONNULL_BEGIN

@protocol OutputRouteViewDelegate <NSObject>
// The NO edge is not guaranteed (PlayerViewControllerInternal.h). It is
// also the only signal of a destination picked against an inactive session,
// which posts no route notification.
- (void)outputRouteView:(OutputRouteView *)view isPresentingRoutes:(BOOL)presenting;
@end

@interface OutputRouteView : UIView

@property (nonatomic, weak) id<OutputRouteViewDelegate> delegate;

- (void)setRouteKind:(VibeOutputRouteKind)kind deviceName:(nullable NSString *)name;

// The two page layouts differ; a change redraws the current route.
@property (nonatomic) CGFloat glyphPointSize;

// What it drew, for the debug state dump.
@property (nonatomic, readonly, copy) NSString *symbolName;
@property (nonatomic, readonly) BOOL showsDeviceName;

@end

NS_ASSUME_NONNULL_END
