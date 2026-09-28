//
//  NSBundle+BuildInfo.h
//  Vibe
//

#import <Foundation/Foundation.h>

// The build identity, for the About window and the startup log, from
// compile-time macros, Info.plist and the generated git info.

// The launch banner both app delegates print: source and build time.
void VibeLogBuildProvenance(void);

@interface NSBundle (BuildInfo)

// "1.5 (15) · Debug": CFBundleShortVersionString, CFBundleVersion, config.
@property (nonatomic, readonly) NSString *vibeVersionString;

// "de29823d6317 (main, dirty)", from the VibeGitInfo.h that
// scripts/generate-git-info.sh writes; "unknown" outside a git checkout.
@property (nonatomic, readonly) NSString *vibeGitString;

// The executable's mtime, which codesign sets at the end of the build. A
// heuristic: a copy that does not preserve mtime moves it.
@property (nonatomic, readonly) NSString *vibeBuildTimeString;

@end
