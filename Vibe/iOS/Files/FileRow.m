//
//  FileRow.m
//  Vibe (iOS)
//

#import "FileRow.h"

#import "PlaylistFile.h"

UIAction *VibeMenuAction(NSString *title, NSString *symbol, void (^handler)(void)) {
    return [UIAction actionWithTitle:title
                               image:[UIImage systemImageNamed:symbol]
                          identifier:nil
                             handler:^(UIAction *action) {
        handler();
    }];
}

// The mark on a row whose file is not downloaded: a tap waits on the network.
UIView *VibeNotDownloadedMark(void) {
    UIImageView *mark = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"arrow.down.circle"]];
    mark.tintColor = UIColor.secondaryLabelColor;
    return mark;
}

// Drawn once, in both appearances: an image asset holding the light and the
// dark tile follows the trait collection by itself, which a single rendered
// image would not.
UIImage *VibeFileTileImage(BOOL playlist) {
    static UIImage *tiles[2];
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        CGRect bounds = CGRectMake(0, 0, kFileTileSide, kFileTileSide);
        UIImageSymbolConfiguration *configuration =
                [UIImageSymbolConfiguration configurationWithPointSize:17 weight:UIImageSymbolWeightMedium];
        UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:bounds.size];
        for (NSUInteger kind = 0; kind < 2; kind++) {
            NSString *symbol = kind == 1 ? @"music.note.list" : @"waveform";
            UIImage *(^draw)(UIUserInterfaceStyle) = ^UIImage *(UIUserInterfaceStyle style) {
                UITraitCollection *traits = [UITraitCollection traitCollectionWithUserInterfaceStyle:style];
                UIImage *glyph = [[UIImage systemImageNamed:symbol withConfiguration:configuration]
                        imageWithTintColor:[UIColor.secondaryLabelColor resolvedColorWithTraitCollection:traits]
                             renderingMode:UIImageRenderingModeAlwaysOriginal];
                return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
                    [[UIColor.secondarySystemFillColor resolvedColorWithTraitCollection:traits] setFill];
                    [[UIBezierPath bezierPathWithRoundedRect:bounds cornerRadius:kFileTileCornerRadius] fill];
                    [glyph drawAtPoint:CGPointMake(CGRectGetMidX(bounds) - glyph.size.width / 2,
                                                   CGRectGetMidY(bounds) - glyph.size.height / 2)];
                }];
            };
            UIImage *tile = draw(UIUserInterfaceStyleLight);
            [tile.imageAsset registerImage:draw(UIUserInterfaceStyleDark)
                       withTraitCollection:[UITraitCollection traitCollectionWithUserInterfaceStyle:
                                                    UIUserInterfaceStyleDark]];
            tiles[kind] = tile;
        }
    });
    return tiles[playlist ? 1 : 0];
}

@implementation UIListContentConfiguration (VibeFileRow)

// A file or folder name: two lines, cut in the middle, so the ends that tell
// two long names apart both show.
- (void)vibeApplyFileNameStyle {
    self.textProperties.numberOfLines = 2;
    self.textProperties.lineBreakMode = NSLineBreakByTruncatingMiddle;
    self.secondaryTextProperties.numberOfLines = 1;
    self.secondaryTextProperties.color = UIColor.secondaryLabelColor;
}

- (void)vibeApplyFileIconForName:(NSString *)name folder:(BOOL)folder art:(UIImage *)art {
    self.imageProperties.reservedLayoutSize = CGSizeMake(kFileTileSide, kFileTileSide);
    self.imageProperties.maximumSize = CGSizeMake(kFileTileSide, kFileTileSide);
    self.imageProperties.tintColor = UIColor.secondaryLabelColor;
    if (folder) {
        self.image = [UIImage systemImageNamed:@"folder"];
        return;
    }
    self.image = art ?: VibeFileTileImage([PlaylistFile isPlaylistExtension:name.pathExtension.lowercaseString]);
    self.imageProperties.cornerRadius = kFileTileCornerRadius;
}

@end

@implementation UITableViewCell (VibeFileRow)

- (void)vibeApplyRowContent:(UIListContentConfiguration *)content opening:(BOOL)opening {
    static const NSInteger kOpeningSpinnerTag = 0x6f70656e;
    if (opening) {
        // The slot keeps its place under the spinner: a clear image of its size.
        CGSize size = content.imageProperties.reservedLayoutSize;
        if (size.width <= 0 || size.height <= 0) {
            size = content.image.size;
        }
        content.image = [[[UIGraphicsImageRenderer alloc] initWithSize:size]
                imageWithActions:^(UIGraphicsImageRendererContext *context) {}];
    }
    self.contentConfiguration = content;
    UIView *spinner = [self.contentView viewWithTag:kOpeningSpinnerTag];
    UILayoutGuide *slot = [self.contentView isKindOfClass:UIListContentView.class]
            ? ((UIListContentView *)self.contentView).imageLayoutGuide : nil;
    if (!opening || !slot) {
        [spinner removeFromSuperview];
        return;
    }
    if (!spinner) {
        UIActivityIndicatorView *indicator = [[UIActivityIndicatorView alloc]
                initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        indicator.tag = kOpeningSpinnerTag;
        indicator.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:indicator];
        [NSLayoutConstraint activateConstraints:@[
            [indicator.centerXAnchor constraintEqualToAnchor:slot.centerXAnchor],
            [indicator.centerYAnchor constraintEqualToAnchor:slot.centerYAnchor],
        ]];
        spinner = indicator;
    }
    // A reload can stop a kept spinner, which then hides.
    [(UIActivityIndicatorView *)spinner startAnimating];
}

- (BOOL)vibeIsInViewportOfTableView:(UITableView *)tableView {
    UIWindow *window = self.window;
    if (!window) {
        return NO;
    }
    CGRect rowInTable = [self convertRect:self.bounds toView:tableView];
    CGRect visibleInTable = CGRectIntersection(rowInTable, tableView.bounds);
    if (CGRectIsNull(visibleInTable) || CGRectIsEmpty(visibleInTable)) {
        return NO;
    }
    CGRect visibleInWindow = [tableView convertRect:visibleInTable toView:window];
    return !CGRectIsEmpty(CGRectIntersection(visibleInWindow, window.bounds));
}

@end
