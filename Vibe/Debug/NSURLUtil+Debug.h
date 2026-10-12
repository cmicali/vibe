//
//  NSURLUtil+Debug.h
//  Vibe
//
//  The dataless probe: makes chosen files answer isDatalessFile: as
//  placeholders, so a stress run can drive the cloud lane with no file provider
//  in reach. VibeFakeCloud is the only installer; unset means the real stat.
//  It is injected because a real file cannot be staged as one: SF_DATALESS
//  cannot be set by hand, and a file merely carrying it would not block on
//  read. Declaration-only, like AudioPlayer+Debug.h.
//

#if DEBUG

#import "NSURLUtil.h"

NS_ASSUME_NONNULL_BEGIN

typedef BOOL (^VibeDatalessProbe)(NSURL *url);

@interface NSURLUtil (Debug)

+ (void)setDatalessProbe:(nullable VibeDatalessProbe)probe;

// The lane-routing measurement for a REAL provider: while enabled, every stat
// the dataless test performs is tallied per directory (verdicts and the last
// raw st_flags, capped in directories), to confirm or rule out a provider
// whose placeholders carry no flag (see isDatalessFile:) without instrumenting
// a release. A directory's first stat also records its mount (fsType,
// mountedOn, localMount) and logs one line, which is how a phone reports it:
// iOS's --dataless-diag enables this at launch. Nothing is recorded while the
// fake probe is installed. Enabling resets the record; off, the stat path pays
// one relaxed load.
+ (void)setDatalessDiagnosticsEnabled:(BOOL)enabled;
+ (NSDictionary *)datalessDiagnostics;

@end

NS_ASSUME_NONNULL_END

#endif
