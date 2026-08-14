# Unit tests

`make test` runs these. The `VibeTests` target is defined in `project.yml`; editing the source list there means re-running `xcodegen generate`.

## What belongs here

Pure logic only — code that is a function of its inputs and needs no running app: sample and geometry math, archive encode/decode and its validation, string and duration formatting, precedence and fallback rules, cache-key derivation. The suite is **host-less** (no `TEST_HOST`), so it runs in seconds with no window server, no audio hardware, no permissions, and no Vibe instance running.

## What does NOT belong here

Anything that needs the app running — transport, FX, menus, drag-and-drop, layout, rendering, Now Playing, device switching. That is the `vibe-debug` skill's command channel, which can drive a live app and read back state as JSON. A unit test that boots `AVAudioEngine` or a `CALayer` tree would be testing the frameworks, not us.

## Two rules that are easy to get wrong

**Never put test files under `Vibe/`.** The app target's sources are `- path: Vibe`, a bare directory reference that XcodeGen recurses unconditionally — a test file there gets compiled into the shipping app binary. `/Tests` at the repo root is invisible to that glob. (`**/*.md` is already excluded, so this file is safe either way.)

**A temp-directory fixture has two spellings, and both turn up.** `NSTemporaryDirectory()` hands back a `/var/folders/…` path, `/var` is a symlink to `/private/var`, and a directory walk answers in the resolved form while anything that standardizes a path drops the `/private` prefix again. `URLByResolvingSymlinksInPath` will not settle it — it leaves the temporary directory's prefix exactly as it found it — so `realpath(3)` the fixture root at setup and be ready to strip either spelling when comparing (`NSURLUtilTests`).

**Sources under test are compiled into the test target, not linked from the app.** Adding a test for a new file means adding that file to the `VibeTests` source list. Keep the list curated and keep TagLib out of it: nothing here needs it today, and pulling in the vendored subset would dominate the build. Where a test needs an `AudioTrackMetadata`, use a duck-typed fake cast to the property type — `objc_msgSend` doesn't care about the static type, and `AudioTrack` only ever sends messages to its metadata, never names the class. Where the thing under test is a private class method, share it through an `*Internal.h` the implementation file imports too (`NSURLUtilInternal.h`), rather than re-declaring the selectors in the test: a rename then breaks the build instead of the run.
