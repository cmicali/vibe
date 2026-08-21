# Unit tests

`make test` runs these (always Debug). The `VibeTests` target is defined in `project.yml`; editing its source list means re-running `xcodegen generate`.

`iOSDriver/` is **not** part of this suite — it is the `vibe-debug` skill's interactive touch driver, a resident XCUITest started by `drive-ios.sh` and never run as a test. It has its own target (`VibeiOSDriver`) and is excluded from `VibeTests`' `Tests` source entry.

## What belongs here

Pure logic only — code that is a function of its inputs and needs no running app: sample and geometry math, archive encode/decode and validation, string and duration formatting, precedence and fallback rules, cache-key derivation. The suite is **host-less** (no `TEST_HOST`), so it runs in seconds with no window server, no audio hardware, no permissions and no Vibe instance — and it does not inherit the app's sandbox, which is what lets it read fixtures from the repo.

Anything that needs the app running — transport, FX, menus, drag-and-drop, layout, rendering, Now Playing, device switching — belongs in the `vibe-debug` skill's command channel instead, which drives a live app and reads back state as JSON.

**Where the engine is the whole class, extract the arithmetic into a seam.** `AudioPlayer` and `AudioFX` own `AVAudioEngine` graphs and are unreachable from a host-less suite, so their decisions live in header-only `*Rules.h` / `*Math.h` files that the shipping class **calls** rather than restates: `FadeMath.h` (`VibeIncomingFadeMilliseconds`, `VibeFadeStepsForMilliseconds`, called from `AudioPlayer.m` and `+Fades.m`), `AudioFXMath.h` (called from `AudioFX.m`), `GaplessSpliceMath.h`, `TransportMath.h`, `NowPlayingRules.h`, `PlayerScreenRules.h`. Reach for that before concluding a class cannot be tested.

**The line is the engine, not the framework.** `AVFAudioWaveformLoaderTests` writes a WAV with `AVAudioFile` and reads it back through the real loader — `AVAudioFile` is file I/O with no engine, no device and nothing to configure. `AVAudioEngine` is the other side of that line and stays out.

## Rules that are easy to get wrong

**Never put test files under `Vibe/`.** Both app targets list whole shared subsystem directories (`- path: Vibe/Audio`, `- path: Vibe/Util`, …), recursed unconditionally — a test file dropped into one is compiled into the shipping binaries of both apps. `/Tests` at the repo root is named by no app target. (`**/*.md` is excluded everywhere, so this file is safe either way.)

**Sources under test are compiled into the test target, not linked from the app.** Adding a test for a new file means adding that file to the `VibeTests` source list in `project.yml`. Keep the list curated, and keep TagLib out of it — nothing here needs it, and the vendored subset would dominate the build.

**Where a test needs an `AudioTrackMetadata`, use a duck-typed fake cast to the property type.** `AudioTrackTests.m` declares `FakeTrackMetadata : NSObject` and installs it through `AudioTrackInternal.h` — `objc_msgSend` does not care about the static type, and `AudioTrack` only ever sends messages to its metadata, never names the class.

**Where the thing under test is a private class method, share it through an `*Internal.h` the implementation file imports too** (`NSURLUtilInternal.h`), rather than re-declaring selectors in the test: a rename then breaks the build instead of the run.

**A temp-directory fixture has two spellings, and both turn up.** `NSTemporaryDirectory()` hands back `/var/folders/…`, `/var` is a symlink to `/private/var`, and a directory walk answers in the resolved form while anything that standardizes a path drops the `/private` prefix again. `URLByResolvingSymlinksInPath` does not settle it — it leaves the temporary directory's prefix as it found it. Use `realpath(3)` on the fixture root at setup and be ready to strip either spelling when comparing (`NSURLUtilTests.m`).
