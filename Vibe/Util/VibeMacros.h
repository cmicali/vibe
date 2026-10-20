//
//  VibeMacros.h
//
//  Macros a file imports explicitly, so it builds without an app's prefix
//  header.
//

#pragma once

// VIBE_REALTIME_CHECKED_BEGIN … VIBE_REALTIME_END compiles its body under
// -Werror=function-effects, so a CA_REALTIME_API function there cannot
// allocate, lock, log, dispatch or message. VIBE_REALTIME_UNCHECKED_BEGIN
// brackets only the one-line shims around calls the checker cannot see
// (AudioUnitRender, the vDSP FFT, the clock), each documented at its site.
#if defined(__has_warning) && __has_warning("-Wfunction-effects")
#define VIBE_REALTIME_CHECKED_BEGIN   _Pragma("clang diagnostic push") _Pragma("clang diagnostic error \"-Wfunction-effects\"")
#define VIBE_REALTIME_UNCHECKED_BEGIN _Pragma("clang diagnostic push") _Pragma("clang diagnostic ignored \"-Wfunction-effects\"")
#define VIBE_REALTIME_END             _Pragma("clang diagnostic pop")
#else
#define VIBE_REALTIME_CHECKED_BEGIN
#define VIBE_REALTIME_UNCHECKED_BEGIN
#define VIBE_REALTIME_END
#endif
