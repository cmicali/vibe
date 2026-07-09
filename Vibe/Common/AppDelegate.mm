//
//  AppDelegate.m
//  Vibe
//
//  Created by Christopher Micali on 12/14/19.
//  Copyright © 2019 Christopher Micali. All rights reserved.
//

#import "AppDelegate.h"
#import "NSURLUtil.h"
#import "AboutWindowController.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#if DEBUG
#import <QuartzCore/QuartzCore.h>
#import <ImageIO/ImageIO.h>
#import <notify.h>
#endif

@interface AppDelegate ()

@property (nonatomic, strong) AboutWindowController *aboutWindowController;

@end

#if DEBUG
// Debug-only window snapshot: renders the frontmost window's layer tree
// in-process and writes it to a fixed path — no window server capture, so it
// needs no screen-recording permission and works with the display asleep or
// the window occluded. Trigger from a terminal:
//
//     notifyutil -p com.vibe.debug.screenshot
//
// then read vibe-screenshot.png from the app container's tmp directory
// (the app is sandboxed, so /tmp is not writable):
//
//     ~/Library/Containers/com.commonwealthrecordings.Vibe/Data/tmp/
//
// Renders the *presentation* layer tree, so in-flight Core Animation (e.g.
// the artwork cross-fade) is captured mid-animation. Metal content (the
// About window) does not render this way.
static NSString *VibeDebugScreenshotPath(void) {
    return [NSTemporaryDirectory() stringByAppendingPathComponent:@"vibe-screenshot.png"];
}

static void VibeDumpWindowSnapshot(void) {
    NSWindow *window = NSApp.keyWindow ?: NSApp.mainWindow;
    if (!window) {
        for (NSWindow *candidate in NSApp.windows) {
            if (candidate.isVisible && candidate.contentView) {
                window = candidate;
                break;
            }
        }
    }
    NSView *view = window.contentView;
    if (!view || NSIsEmptyRect(view.bounds)) {
        LogError(@"Debug screenshot: no window content to render");
        return;
    }
    CGFloat scale = window.backingScaleFactor > 0 ? window.backingScaleFactor : 2.0;
    size_t pixelsWide = (size_t)llround(view.bounds.size.width * scale);
    size_t pixelsHigh = (size_t)llround(view.bounds.size.height * scale);
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate(NULL, pixelsWide, pixelsHigh, 8, 0, space,
            kCGImageAlphaPremultipliedFirst | (CGBitmapInfo)kCGBitmapByteOrder32Host);
    CGColorSpaceRelease(space);
    if (!ctx) {
        return;
    }
    CGContextScaleCTM(ctx, scale, scale);
    CALayer *layer = view.layer;
    if (layer) {
        // Presentation tree when available: captures animations mid-flight.
        CALayer *presentation = layer.presentationLayer ?: layer;
        [presentation renderInContext:ctx];
    }
    else {
        // Non-layer-backed fallback: AppKit drawing path.
        NSGraphicsContext *gc = [NSGraphicsContext graphicsContextWithCGContext:ctx flipped:NO];
        [NSGraphicsContext saveGraphicsState];
        [NSGraphicsContext setCurrentContext:gc];
        [view displayRectIgnoringOpacity:view.bounds inContext:gc];
        [NSGraphicsContext restoreGraphicsState];
    }
    CGImageRef image = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    if (!image) {
        return;
    }
    NSString *path = VibeDebugScreenshotPath();
    NSURL *url = [NSURL fileURLWithPath:path];
    CGImageDestinationRef dest = CGImageDestinationCreateWithURL((__bridge CFURLRef)url,
            (__bridge CFStringRef)UTTypePNG.identifier, 1, NULL);
    if (dest) {
        CGImageDestinationAddImage(dest, image, NULL);
        CGImageDestinationFinalize(dest);
        CFRelease(dest);
        LogInfo(@"Debug screenshot written to %@", path);
    }
    CGImageRelease(image);
}

static void VibeInstallDebugScreenshotHook(void) {
    static int token;
    notify_register_dispatch("com.vibe.debug.screenshot", &token, dispatch_get_main_queue(), ^(int t) {
        VibeDumpWindowSnapshot();
    });
}
#endif

@implementation AppDelegate {
    BOOL _isLoaded;
    NSMutableArray<NSURL *> *_urlsToOpen;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _urlsToOpen = [[NSMutableArray alloc] init];
        _isLoaded = NO;
        id<DDLogger> osLogger = [DDOSLogger sharedInstance];
        [DDLog addLogger:osLogger withLevel:ddLogLevel];
        LogInfo(@"Vibe starting");
    }
    return self;
}

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {

    LogInfo(@"Vibe started");

    [[AppSettings sharedInstance] applicationDidFinishLaunching];

#if DEBUG
    VibeInstallDebugScreenshotHook();
#endif

    [self cleanupLegacyCaches];

    [self.mainPlayerController showWindow:self];

    [self openCommandLineArguments];

    _isLoaded = YES;
    [self playURLs];
}

// Open file/directory paths passed as command-line arguments, e.g.
//     Vibe.app/Contents/MacOS/Vibe ~/Music/album /path/to/song.flac
// Paths resolve relative to the working directory and feed the same
// expand/filter/play pipeline as dropped files and Finder opens (directories
// are walked, unsupported files dropped). AppKit-injected "-key value"
// arguments (Xcode debug flags etc.) are skipped, and each candidate must
// exist on disk. NOTE: under the App Sandbox this only succeeds for paths the
// sandbox already permits (the container, or files opened via Launch Services
// / drag) — arbitrary argv paths may be denied at read time.
- (void)openCommandLineArguments {
    NSArray<NSString *> *args = NSProcessInfo.processInfo.arguments;
    NSFileManager *fileManager = [NSFileManager defaultManager];
    for (NSUInteger i = 1; i < args.count; i++) { // skip argv[0] (the executable)
        NSString *arg = args[i];
        if ([arg hasPrefix:@"-"]) {
            i++; // "-key value" convention: skip the value too
            continue;
        }
        NSString *path = arg.stringByExpandingTildeInPath;
        if ([fileManager fileExistsAtPath:path]) {
            [_urlsToOpen addObject:[NSURL fileURLWithPath:path]];
            LogInfo(@"Opening command-line path: %@", path);
        }
    }
}

// Superseded cache formats can hold tens of MB that would otherwise linger
// for months; delete their directories once in the background.
- (void)cleanupLegacyCaches {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSString *cachesDir = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
        if (!cachesDir) {
            return;
        }
        NSArray<NSString *> *legacyCacheNames = @[
                @"com.pinterest.PINDiskCache.Audio Track Metadata",
                @"com.pinterest.PINDiskCache.Audio Track Metadata v2",
                @"com.pinterest.PINDiskCache.audio_waveform_cache",
        ];
        for (NSString *name in legacyCacheNames) {
            [[NSFileManager defaultManager] removeItemAtPath:[cachesDir stringByAppendingPathComponent:name] error:nil];
        }
    });
}

- (void)playURLs {
    if (_isLoaded && _urlsToOpen.count > 0) {
        NSArray<NSURL*>* urls = [self->_urlsToOpen copy];
        [self->_urlsToOpen removeAllObjects];
        [NSURLUtil expandAndFilterList:urls completion:^(NSArray<NSURL *> *expanded) {
            // Nothing playable (e.g. a folder with no audio) — don't wipe the
            // current playlist with an empty list.
            if (expanded.count > 0) {
                [self.mainPlayerController play:expanded];
            }
        }];
    }
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return YES;
}

- (void)application:(NSApplication *)application openURLs:(NSArray<NSURL *> *)urls {
    [_urlsToOpen addObjectsFromArray:urls];
    [self playURLs];
}

- (IBAction)showAboutWindow:(id)sender {
    if (!self.aboutWindowController) {
        self.aboutWindowController = [[AboutWindowController alloc] init];
    }
    [self.aboutWindowController showWindow:sender];
}

- (IBAction)openDocument:(id)sender {
    NSOpenPanel* panel = [NSOpenPanel openPanel];
    panel.allowsMultipleSelection = YES;
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = YES;
    // Derive the selectable types from the CFBundleDocumentTypes declarations
    // in Info.plist so the open panel can't drift from what Launch Services
    // registers the app for.
    NSMutableArray<UTType *> *contentTypes = [NSMutableArray new];
    NSArray *documentTypes = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleDocumentTypes"];
    for (NSDictionary *documentType in documentTypes) {
        for (NSString *identifier in documentType[@"LSItemContentTypes"]) {
            UTType *type = [UTType typeWithIdentifier:identifier];
            if (type) {
                [contentTypes addObject:type];
            }
        }
    }
    // An empty allowlist would make every file unselectable; fall back to
    // no filter if the plist declarations ever go missing.
    if (contentTypes.count > 0) {
        panel.allowedContentTypes = contentTypes;
    }
    [panel beginWithCompletionHandler:^(NSInteger result){
        if (result == NSModalResponseOK) {
            [self->_urlsToOpen addObjectsFromArray:panel.URLs];
            [self performSelectorOnMainThread:@selector(playURLs) withObject:nil waitUntilDone:NO];
        }
    }];
}

@end
