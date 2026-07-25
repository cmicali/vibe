//
// Created by Christopher Micali on 7/25/26.
// Copyright (c) 2026 Christopher Micali. All rights reserved.
//

#import <Foundation/Foundation.h>

// Build identity, for the About window and the startup log. Everything here is
// already in the binary — compile-time macros plus the DT* keys Xcode injects
// into Info.plist — so nothing has to be plumbed through the build.
@interface NSBundle (BuildInfo)

// "1.5 (15) · Debug": CFBundleShortVersionString, CFBundleVersion, config.
@property (nonatomic, readonly) NSString *vibeVersionString;

// The source this was built from: "de29823d6317 (master, dirty)", from the
// VibeGitInfo.h that scripts/generate-git-info.sh writes at build time. All
// fields read "unknown" when the tree has no git (exported tarball).
@property (nonatomic, readonly) NSString *vibeGitString;

// How this binary was compiled: "clang 17.0.0 · arm64 · -O0 · ARC · NSAssert on".
@property (nonatomic, readonly) NSString *vibeCompilerString;

// The build settings the compile/link commands were derived from, carried in
// via the Info.plist VibeBuild dictionary (see project.yml): defines, extra
// C/C++/linker flags, language standards, and the sandbox/hardening switches.
// NOT the literal clang argv — that lives only in the build log.
@property (nonatomic, readonly) NSString *vibeBuildFlagsString;

// What compiled it: "SDK macosx26.5 (25F70) · Xcode 2650 (17F42) · min macOS 26.0 · on macOS 25F80".
@property (nonatomic, readonly) NSString *vibeToolchainString;

// When it was linked, from the executable's mtime — the build's last write to
// it (codesign rewrites the binary at the end of the build). A heuristic, not a
// stamp: any later copy that doesn't preserve mtime moves it. "unknown" if the
// attribute can't be read.
@property (nonatomic, readonly) NSString *vibeBuildTimeString;

@end
