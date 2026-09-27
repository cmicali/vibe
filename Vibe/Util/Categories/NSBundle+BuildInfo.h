//
//  NSBundle+BuildInfo.h
//  Vibe
//

#import <Foundation/Foundation.h>

// The build identity, for the About window and the startup log, from
// compile-time macros and the DT* keys Xcode injects into Info.plist.

// Adds compiler, flags, toolchain and host to the launch banner. Defined here
// so the .m sees it; defined elsewhere, the #if would silently read 0.
#define SHOW_EXTENDED_BUILD_INFO 0

// The launch banner both app delegates print: source and build time.
void VibeLogBuildProvenance(void);

@interface NSBundle (BuildInfo)

// "1.5 (15) · Debug": CFBundleShortVersionString, CFBundleVersion, config.
@property (nonatomic, readonly) NSString *vibeVersionString;

// "de29823d6317 (main, dirty)", from the VibeGitInfo.h that
// scripts/generate-git-info.sh writes; "unknown" outside a git checkout.
@property (nonatomic, readonly) NSString *vibeGitString;

// How this binary was compiled: "clang 17.0.0 · arm64 · -O0 · ARC · NSAssert on".
@property (nonatomic, readonly) NSString *vibeCompilerString;

// The build settings behind the compile and link, from the Info.plist
// VibeBuild dictionary (project.yml) — not the literal clang argv.
@property (nonatomic, readonly) NSString *vibeBuildFlagsString;

// What compiled it: "SDK macosx26.5 (25F70) · Xcode 2650 (17F42) · min macOS 26.0 · on macOS 25F80".
@property (nonatomic, readonly) NSString *vibeToolchainString;

// The executable's mtime, which codesign sets at the end of the build. A
// heuristic: a copy that does not preserve mtime moves it.
@property (nonatomic, readonly) NSString *vibeBuildTimeString;

@end
