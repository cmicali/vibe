//
//  NSBundle+BuildInfo.h
//  Vibe
//

#import <Foundation/Foundation.h>

// The build identity, for the About window and the startup log. Everything
// here is already in the binary — compile-time macros, plus the DT* keys Xcode
// injects into Info.plist — so nothing has to be plumbed through the build.
// The launch banner both app delegates print, so a log excerpt identifies the
// build it came from the same way on either platform. Source and build time
// always; the compiler, flags, toolchain and host only under
// SHOW_EXTENDED_BUILD_INFO, which is where the expensive sysctl lives. The
// switch lives here so the implementation actually sees it — defined anywhere
// else, the #if reads an undefined macro and the flip is silently inert.
#define SHOW_EXTENDED_BUILD_INFO 0

void VibeLogBuildProvenance(void);

@interface NSBundle (BuildInfo)

// "1.5 (15) · Debug": CFBundleShortVersionString, CFBundleVersion, config.
@property (nonatomic, readonly) NSString *vibeVersionString;

// The source this was built from, as "de29823d6317 (master, dirty)", taken from
// the VibeGitInfo.h that scripts/generate-git-info.sh writes at build time.
// Every field reads "unknown" when the tree has no git, as in an exported
// tarball.
@property (nonatomic, readonly) NSString *vibeGitString;

// How this binary was compiled: "clang 17.0.0 · arm64 · -O0 · ARC · NSAssert on".
@property (nonatomic, readonly) NSString *vibeCompilerString;

// The build settings the compile and link commands were derived from, carried
// in through the Info.plist VibeBuild dictionary; see project.yml. They cover
// the defines, the extra C, C++ and linker flags, the language standards and
// the sandbox and hardening switches. This is not the literal clang argv,
// which lives only in the build log.
@property (nonatomic, readonly) NSString *vibeBuildFlagsString;

// What compiled it: "SDK macosx26.5 (25F70) · Xcode 2650 (17F42) · min macOS 26.0 · on macOS 25F80".
@property (nonatomic, readonly) NSString *vibeToolchainString;

// When it was linked, taken from the executable's mtime, which is the build's
// last write to it, since codesign rewrites the binary at the end of the build.
// It is a heuristic rather than a stamp: any later copy that does not preserve
// the mtime moves it. It reads "unknown" if the attribute cannot be read.
@property (nonatomic, readonly) NSString *vibeBuildTimeString;

@end
