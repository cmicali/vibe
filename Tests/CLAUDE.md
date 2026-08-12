# Unit tests

`make test` runs these. The `VibeTests` target is defined in `project.yml`; editing the source list there means re-running `xcodegen generate`.

(`iOSDriver/` is not part of this suite: it is the vibe-debug skill's interactive touch driver — a resident XCUITest started by `drive-ios.sh`, never run as a test. It lives under `Tests/` only because anything under `Vibe/` is swept into the app targets.)

## What belongs here

Pure logic only — code that is a function of its inputs and needs no running app: sample and geometry math, archive encode/decode and its validation, string and duration formatting, precedence and fallback rules, cache-key derivation. The suite is **host-less** (no `TEST_HOST`), so it runs in seconds with no window server, no audio hardware, no permissions, and no Vibe instance running.

## What does NOT belong here

Anything that needs the app running — transport, FX, menus, drag-and-drop, layout, rendering, Now Playing, device switching. That is the `vibe-debug` skill's command channel, which can drive a live app and read back state as JSON. A unit test that boots `AVAudioEngine` or a `CALayer` tree would be testing the frameworks, not us.

## Two rules that are easy to get wrong

**Never put test files under `Vibe/`.** The app target's sources are `- path: Vibe`, a bare directory reference that XcodeGen recurses unconditionally — a test file there gets compiled into the shipping app binary. `/Tests` at the repo root is invisible to that glob. (`**/*.md` is already excluded, so this file is safe either way.)

**Sources under test are compiled into the test target, not linked from the app.** Adding a test for a new file means adding that file to the `VibeTests` source list. Keep the list curated and keep TagLib out of it: nothing here needs it today, and pulling in the vendored subset would dominate the build. Where a test needs an `AudioTrackMetadata`, use a duck-typed fake cast to the property type — `objc_msgSend` doesn't care about the static type, and `AudioTrack` only ever sends messages to its metadata, never names the class.
