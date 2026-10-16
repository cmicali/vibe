# Vibe build helpers. Vibe.xcodeproj is generated from project.yml by XcodeGen.

CONFIG ?= Release

# Where `make test` writes its .xcresult, and where `make test-summary` reads
# it from. Under build/, so `make clean` takes it.
RESULT_BUNDLE ?= build/TestResults.xcresult

.PHONY: help audio-test-bundle audio-fixtures compile-commands bench-components bench-components-releases bench-app bench-releases bench-report build-test-blackhole test-bit-perfect test-audio test-audio-summary test-audio-loopback test-audio-device setup project build build-ios install-ios test test-ios test-ios-summary test-summary check-cloud-scenarios analyze stress torture release github-release deploy-web web-set-version brew-set-version appstore-build appstore-upload-signed-build appstore-build-ios appstore-upload-signed-build-ios install clean run screenshots appstore-generate-store-screenshots appstore-generate-store-screenshots-all appstore-capture-app-screenshots appstore-validate-copy appstore-upload-metadata strings check-strings check-translations check-vocabulary check-layout reset-state

# Install the dev-tool dependencies (xcodegen, jq, gh) from the Brewfile.
setup:
	brew bundle

# List every target with the first sentence of the comment block above it.
# A target with no comment of its own prints with an empty description.
help:
	@awk ' \
	    /^#/ { if (!inblock) { text = ""; done = 0 } inblock = 1; \
	           line = $$0; sub(/^# ?/, "", line); \
	           if (line == "" || line ~ /^ /) done = 1; \
	           else if (!done) text = text (text == "" ? "" : " ") line; next } \
	    { inblock = 0 } \
	    /^$$/ { text = "" } \
	    /^[a-z][a-z0-9-]*:/ && !/^[^:]*:[^=]*=/ { \
	        name = substr($$0, 1, index($$0, ":") - 1); \
	        if (!(name in seen)) { seen[name] = 1; names[++n] = name; \
	            if (match(text, /\. /)) text = substr(text, 1, RSTART); \
	            desc[name] = text; if (length(name) > width) width = length(name) } \
	        text = "" } \
	    END { for (i = 1; i <= n; i++) printf "  %-" width "s  %s\n", names[i], desc[names[i]] } \
	' $(MAKEFILE_LIST)

# Generate Vibe.xcodeproj from project.yml (requires xcodegen — `make setup`).
# Under the build lock (scripts/build/build-lock.sh), taken per command: sessions
# share one checkout, and rewriting the project under another session's
# xcodebuild fails that build or feeds it a half-written project.
project:
	scripts/build/build-lock.sh xcodegen generate

# The macOS app. `project` has already regenerated, so build.sh skips its own.
# ARGS reaches xcodebuild: CI's AppStore build is ARGS='ARCHS=x86_64 ONLY_ACTIVE_ARCH=NO'.
build: project
	SKIP_GENERATE=1 scripts/build/build.sh $(CONFIG) $(ARGS)

# Unsigned by default, which is what CI wants: no credentials, no keychain.
#
# TRAP: unsigned means NO ENTITLEMENTS, so no app-group container: the app
# publishes no widget snapshot and the home-screen widget stays empty, which
# looks like a broken widget. VIBE_SIGN_SIM=1 ad-hoc signs the simulator build
# with its entitlements; the simulator validates no profile, so it still needs
# no credentials.
IOS_SIM_SIGN = CODE_SIGNING_ALLOWED=NO
ifeq ($(VIBE_SIGN_SIM),1)
IOS_SIM_SIGN = CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=-
endif

# The iOS simulator slice. It catches an AppKit leak into a shared directory.
# CI builds it on the way to `make test-ios`. arm64 only: the generic destination would add an x86_64 slice, which only an
# Intel Mac's simulator runs, and the device build is arm64 anyway. Locked:
# this and `drive-ios.sh start` write the products directory the touch driver
# installs from.
build-ios: project
	scripts/build/build-lock.sh xcodebuild -project Vibe.xcodeproj -scheme VibeiOS -configuration $(CONFIG) \
	    -destination 'generic/platform=iOS Simulator' ARCHS=arm64 \
	    -derivedDataPath build/DerivedData $(IOS_SIM_SIGN) build

# Signed for a paired device and installed over the CoreDevice tunnel; needs a
# development certificate and profile. With more than one device paired, name
# it: make install-ios DEVICE="cmicali iPhone"
install-ios: project
	SKIP_GENERATE=1 scripts/build/install-ios.sh $(CONFIG)

# Writes compile_commands.json, clang's compilation database. clangd, CLion
# and clang-tidy read it. It covers the macOS app, VibeTests and the iOS app,
# all Debug. Clang writes one fragment per file it compiles. So the build
# starts from empty derived data every time. An incremental build would drop
# every file it skipped. The entries point into build/CompileCommands for
# header maps. `make clean` breaks them until the next run.
#
# TRAP: Xcode's -include names its built prefix header, which only another
# clang of the same build can read. The merge points it back at the source, or
# every Log* macro reads as undeclared.
COMPILE_COMMANDS = build/CompileCommands
COMPILE_COMMANDS_FLAGS = -derivedDataPath $(COMPILE_COMMANDS) -configuration Debug \
    'OTHER_CFLAGS=$$(inherited) -gen-cdb-fragment-path $$(SRCROOT)/$(COMPILE_COMMANDS)/fragments'
compile-commands: project
	rm -rf $(COMPILE_COMMANDS)
	xcodebuild -project Vibe.xcodeproj -scheme Vibe -destination 'platform=macOS' \
	    $(COMPILE_COMMANDS_FLAGS) -quiet build build-for-testing
	xcodebuild -project Vibe.xcodeproj -scheme VibeiOS -destination 'generic/platform=iOS Simulator' \
	    ARCHS=arm64 CODE_SIGNING_ALLOWED=NO $(COMPILE_COMMANDS_FLAGS) -quiet build
	{ echo '['; cat $(COMPILE_COMMANDS)/fragments/*.json | sed -E -e '$$ s/,$$//' \
	    -e 's#"[^"]*/SharedPrecompiledHeaders/[0-9]+/Vibe-Prefix\.pch"#"$(CURDIR)/Vibe/Common/Vibe-Prefix.pch"#'; \
	    echo ']'; } > compile_commands.json

# The host-less unit tests (VibeTests) plus the cloud-runner oracle tests.
# The rm matters: xcodebuild refuses to write over an existing result bundle.
# `make -j3 test test-audio` runs both suites at once: test-audio has its own
# derived data, since two xcodebuilds cannot share one.
# ARGS='-only-testing:VibeTests/<Class>' narrows a run. COVERAGE=1 measures
# coverage, which test-summary reports. CI passes it. It adds about a quarter
# to a clean run's time, so it is off by default.
COVERAGE_FLAG = $(if $(filter 1,$(COVERAGE)),-enableCodeCoverage YES)
test: project check-cloud-scenarios
	rm -rf $(RESULT_BUNDLE)
	xcodebuild \
	    -project Vibe.xcodeproj \
	    -scheme Vibe \
	    -configuration Debug \
	    -derivedDataPath build/DerivedData \
	    -resultBundlePath $(RESULT_BUNDLE) \
	    -collect-test-diagnostics never \
	    $(COVERAGE_FLAG) \
	    $(ARGS) test

# The iOS shell's views and controllers (VibeiOSTests), on a simulator, hosted
# in the Debug app. Its derived data is its own, so it runs beside `make test`.
# IOS_TEST_DEVICE names the simulator. CI's runner has the default.
# ARGS='-only-testing:VibeiOSTests/<Class>' narrows a run.
IOS_TEST_DEVICE ?= iPhone 17
IOS_RESULT_BUNDLE ?= build/iOSTestResults.xcresult
test-ios: project
	rm -rf $(IOS_RESULT_BUNDLE)
	xcodebuild \
	    -project Vibe.xcodeproj \
	    -scheme VibeiOSTests \
	    -configuration Debug \
	    -destination 'platform=iOS Simulator,name=$(IOS_TEST_DEVICE)' \
	    -derivedDataPath build/iOSTestDerivedData \
	    -resultBundlePath $(IOS_RESULT_BUNDLE) \
	    -collect-test-diagnostics never \
	    $(IOS_SIM_SIGN) $(ARGS) test

# The last `make test-ios` as a markdown pass/fail table, with the skip gate.
test-ios-summary:
	scripts/checks/test-summary.sh $(IOS_RESULT_BUNDLE)

# One compiled PCM verifier shared by hardware and device-free audio tests.
build/verify-bit-perfect: scripts/test/verify-bit-perfect.swift
	@mkdir -p build
	@swiftc -O $< -o $@

# Build the VibeBlackHole driver fixtures that test-bit-perfect plays through.
# Installing them needs administrator authentication (vibe-debug).
build-test-blackhole:
	@scripts/test/generate-test-audio.sh --blackhole-drivers

AUDIO_DEVICE ?= BlackHole 2ch
AUDIO_APP ?= $(abspath build/DerivedData/Build/Products/Debug/Vibe.app/Contents/MacOS/Vibe)
# Opt-in live acceptance, never CI: the test drivers from build-test-blackhole,
# and the Debug app already running on VibeBlackHole 16ch. See
# vibe-debug/references/test-audio.md.
test-bit-perfect: AUDIO_DEVICE = VibeBlackHole 16ch
test-bit-perfect: audio-fixtures
	@build/verify-bit-perfect --acceptance "$(abspath build/audio-fixtures)" "$(AUDIO_DEVICE)" --play-app "$(AUDIO_APP)" --require-driver-fixtures $(ARGS)

# The render suite produces real PCM without opening hardware. ARGS can narrow
# XCTest, and reaches the build too, so a sanitizer flag builds what it tests.
# Under `make -j` its two prerequisites run side by side. The bundle compiles
# as the fixtures generate. COVERAGE=1 applies as for `make test`, and to
# both halves of the split.
AUDIO_RESULT_BUNDLE ?= build/AudioTestResults.xcresult
AUDIO_XCODEBUILD = scripts/build/build-lock.sh xcodebuild -project Vibe.xcodeproj -scheme VibeAudioTests \
    -configuration Debug -destination 'platform=macOS' -derivedDataPath build/AudioDerivedData \
    $(COVERAGE_FLAG)
test-audio: audio-test-bundle audio-fixtures
	rm -rf $(AUDIO_RESULT_BUNDLE)
	$(AUDIO_XCODEBUILD) -resultBundlePath $(AUDIO_RESULT_BUNDLE) -collect-test-diagnostics never \
	    $(ARGS) test-without-building

# The render suite's test bundle, built and not run.
audio-test-bundle: project
	$(AUDIO_XCODEBUILD) $(ARGS) build-for-testing

# The render suite's fixtures under build/audio-fixtures, after the PCM verifier
# checks itself. Under Actions the time it took is a notice on the run.
audio-fixtures: build/verify-bit-perfect
	@start=$$(date +%s); build/verify-bit-perfect --self-test && \
	    scripts/test/generate-test-audio.sh --render-tests build/audio-fixtures && \
	    echo "$${GITHUB_ACTIONS:+::notice title=Audio fixtures::}self-test and fixtures took $$(( $$(date +%s) - start ))s"

# The last `make test-audio` as a markdown pass/fail table.
test-audio-summary:
	scripts/checks/test-summary.sh $(AUDIO_RESULT_BUNDLE)

AUDIO_FILE ?= build/audio-fixtures/noise-48000-24-2.wav
AUDIO_SECONDS ?= 3

# Opt-in loopback through a real device: launch an idle, unmuted Debug app on
# AUDIO_DEVICE first (vibe-debug). Regular loopback: ARGS='--set-rate --ordinary'.
test-audio-loopback: build/verify-bit-perfect
	build/verify-bit-perfect \
	    "$(AUDIO_FILE)" "$(AUDIO_SECONDS)" "$(AUDIO_DEVICE)" --play-app "$(AUDIO_APP)" $(ARGS)

# Opt-in device check through the verifier, with bit-perfect off. Same launch
# as test-audio-loopback.
test-audio-device: build/verify-bit-perfect
	build/verify-bit-perfect --device-check \
	    "$(AUDIO_FILE)" "$(AUDIO_DEVICE)" --play-app "$(AUDIO_APP)" $(ARGS)

# The live cloud suite needs the app, but its oracles are pure Python: run them
# in CI so a broken oracle cannot make the live run green.
check-cloud-scenarios:
	python3 -m unittest discover -s .claude/skills/vibe-stress/tests -p 'test_*.py'

# The last `make test` as a markdown pass/fail table; CI appends it to the run
# summary.
test-summary:
	scripts/checks/test-summary.sh $(RESULT_BUNDLE)

# clang's static analyzer over both app targets; fails on any finding outside
# ThirdParty/. Findings are configuration-dependent, and CI checks Release.
analyze:
	scripts/build/analyze.sh $(CONFIG)

# Seeded stress/fuzz of the Debug app against a folder of real audio files, with
# oracles between batches and an NDJSON journal a failure can be shrunk from.
# See the vibe-stress skill.
#   make stress CORPUS=~/Music/big
#   make stress CORPUS=<simulator-app-Documents/Music> ARGS="--ios <uuid>"
#   make stress CORPUS=~/Music/big ARGS="--profile loading --duration 3600"
stress:
	@test -n "$(CORPUS)" || { echo "usage: make stress CORPUS=<folder of audio files>"; exit 64; }
	.claude/skills/vibe-stress/scripts/stress.py --corpus "$(CORPUS)" $(ARGS)

# ONE large playlist with transport hammered, so track changes outrun the
# metadata scan and the waveform load. The wrapper asserts a single verified
# instance and cold caches first; both are load-bearing (vibe-stress skill).
#   make torture PLAYLIST=~/Music/big
#   make torture PLAYLIST=~/Music/big ARGS="--rounds 40 --burst 40"
torture: APP ?= build/DerivedData/Build/Products/Debug/Vibe.app
torture:
	@test -n "$(PLAYLIST)" || { echo "usage: make torture PLAYLIST=<folder of audio files> [APP=<Vibe.app>]"; exit 64; }
	.claude/skills/vibe-stress/scripts/run-torture.sh "$(APP)" "$(PLAYLIST)" $(ARGS)

# Benchmarks: the vibe-perf skill explains each, docs/performance.md shows them.
# The component benchmarks (VibeBenchComponents) run the production code in-process, no app,
# so the Mac can be in use; the app benchmarks launch the real app over and over
# (about half an hour a version), so leave the Mac be while they run.
#   make bench-components [BASE=main]          this working tree against BASE
#   make bench-components-releases [VERSIONS=]  component benchmarks per release, page redrawn
#   make bench-app [VERSIONS=]                  app benchmarks per release, page redrawn
#   make bench-releases [VERSIONS=]             both per release, page redrawn
#   make bench-report                           the page from results.json alone
# VERSIONS: "1.16" is tag v1.16, "1.16=<ref>" any commit, "HEAD" (any ref) the
# version its project.yml declares. A version with no v<version> tag yet is
# charted as "<version> pre-release". Without VERSIONS, every version on the page.
bench-components:
	python3 .claude/skills/vibe-perf/scripts/perf.py compare $(or $(BASE),main) $(ARGS)

# The component benchmarks per release, page redrawn (VERSIONS as above).
bench-components-releases:
	python3 .claude/skills/vibe-perf/scripts/perf.py releases $(VERSIONS) $(ARGS)

# The app benchmarks per release, page redrawn. About half an hour a version.
bench-app:
	python3 scripts/bench/bench.py app $(VERSIONS) $(ARGS)

# Both benchmark suites per release, page redrawn.
bench-releases:
	python3 scripts/bench/bench.py all $(VERSIONS) $(ARGS)

# Redraw the performance page from results.json alone.
bench-report:
	python3 scripts/bench/bench.py report

# Copy the built app into /Applications. The rm matters: BSD cp -R copies INTO
# an existing destination directory, so without it a second install produces
# /Applications/Vibe.app/Vibe.app.
install: build
	@echo "🔊 installing to /Applications/Vibe.app"
	rm -rf /Applications/Vibe.app
	cp -R build/DerivedData/Build/Products/$(CONFIG)/Vibe.app /Applications/Vibe.app

# Build universal and arm64-only Release archives, then independently export,
# sign (Developer ID), notarize and staple both apps and their
# drag-to-Applications disk images. See scripts/release/release.sh for credentials.
release:
	scripts/release/release.sh

# Publish what `make release` produced as a GitHub release, tagged v<version>.
# See scripts/release/github-release.sh. ARGS reaches its [--draft|--prerelease];
# without it a beta publishes as Latest and repoints the website at it. It
# ends by running deploy-web, which publishes the page and the update feeds.
github-release:
	scripts/release/github-release.sh $(ARGS)

# Publish Assets/Web to Cloudflare Pages (the canonical vibeplayer.app).
# github-release runs it, so this is for a retry or a page-only change.
# Local-only: the token stays out of CI secrets and the script refuses to run
# there. ARGS="--dry-run" lists what would go and needs no credentials.
deploy-web:
	scripts/web/deploy-web.sh $(ARGS)

# Point the page's Download button at a release: make web-set-version V=1.10.
# github-release runs this itself, so this is for repointing by hand.
web-set-version:
	scripts/web/web-set-version.sh $(V)

# Point the Homebrew tap (cmicali/homebrew-tap) at a published stable release:
# make brew-set-version V=1.15. github-release runs it itself; ARGS="--dry-run"
# prints the cask instead.
brew-set-version:
	scripts/release/brew-set-version.sh $(V) $(ARGS)

# Build a universal (arm64 + x86_64) AppStore archive signed for the Mac App Store and
# run App Store Connect's validation, WITHOUT submitting. See
# scripts/appstore/release-appstore.sh for the required credentials.
appstore-build:
	scripts/appstore/release-appstore.sh

# Same, then actually upload the build to App Store Connect.
appstore-upload-signed-build:
	scripts/appstore/release-appstore.sh --upload

# The same two steps for the iOS app (.ipa with the widget embedded). Both
# platforms share one bundle id, so these upload to the SAME app record, on a
# separate version train. The script's header has the prerequisites.
appstore-build-ios:
	scripts/appstore/release-appstore.sh --platform ios

# Same, then upload; TestFlight sees it once processing finishes.
appstore-upload-signed-build-ios:
	scripts/appstore/release-appstore.sh --platform ios --upload

# Remove build/ and the generated Vibe.xcodeproj.
clean:
	scripts/build/clean.sh

# Wipe Vibe's persisted state (settings, folder grants, caches, saved window
# state) so the next launch is a first launch. Prompts before deleting.
# Options pass through: make reset-state ARGS="--both -y", or ARGS=-n to preview.
reset-state:
	scripts/build/reset-state.sh $(ARGS)

# Launch the app, building it first only if it isn't built yet.
run:
	scripts/build/run.sh $(CONFIG)

# Regenerate the README screenshots in Assets/readme/ (debug build + real screen
# capture). Needs Screen Recording and Accessibility for the terminal, and
# ALLOW_GLOBAL_INPUT=1 per run: it moves the real pointer.
screenshots:
	scripts/screenshots/generate-readme-screenshots.sh

# The shipped App Store screenshots (2880x1800): the captures `screenshots`
# leaves in Assets/readme/ composited onto generated backgrounds. Needs no app, only
# those captures; rerun `screenshots` first if the UI changed. LOCALE, not LANG
# or LANGUAGE, which make would silently import from the environment. macOS
# only; for iOS: scripts/appstore/appstore-generate-store-screenshots.sh --platform ios [LOCALE].
#   make appstore-generate-store-screenshots               # English → Assets/app-store/screenshots/en/macos/
#   make appstore-generate-store-screenshots LOCALE=de     # copy/de/macos captions → screenshots/de/macos/
appstore-generate-store-screenshots:
	scripts/appstore/appstore-generate-store-screenshots.sh $(LOCALE)

# Every catalog language (list read from Resources/Localizable.xcstrings).
appstore-generate-store-screenshots-all:
	scripts/appstore/appstore-generate-store-screenshots.sh --all

# Fail unless every catalog language has complete App Store copy for both
# platforms in Assets/app-store/copy/<lang>/<platform>/, within ASC limits,
# with every caption fitting the screenshot layout.
appstore-validate-copy:
	scripts/appstore/appstore-validate-copy.sh

# Upload the localized copy and screenshots to the editable version's product
# page on ONE platform; no build is involved. Flags are the script's:
#   make appstore-upload-metadata                          # everything, macOS
#   make appstore-upload-metadata ARGS="--dry-run"
#   make appstore-upload-metadata ARGS="--locales de,fr --skip-screenshots"
#   make appstore-upload-metadata ARGS="--platform ios"    # everything, iOS
appstore-upload-metadata: appstore-validate-copy
	scripts/appstore/appstore-upload-metadata.sh $(ARGS)

# The other App Store path: photograph the window over a staged desktop, so the
# Liquid Glass shows a real backdrop; the window stays small on the canvas,
# hence the composited path above. Same permissions as `screenshots`.
# BACKGROUND is one image for all three shots or three (player, playlist,
# pitch); it is word-split, so run the script directly for paths with spaces.
#   make appstore-capture-app-screenshots BACKGROUND=path/to/background.png
appstore-capture-app-screenshots:
	scripts/appstore/appstore-capture-app-screenshots.sh $(BACKGROUND)

# Re-extract UI strings into Resources/Localizable.xcstrings after touching any
# UI string; nothing extracts ObjC strings at build time.
strings:
	scripts/strings/extract-strings.sh

# Fail if the catalog doesn't match the source.
check-strings:
	scripts/strings/extract-strings.sh --check

# Fail on a break of AGENTS.md's mechanical vocabulary rules or a doc line over
# 1500 characters, all listed in the script.
check-vocabulary:
	scripts/checks/check-vocabulary.sh

# Fail if the tree breaks AGENTS.md's layout rule; the script's header states
# the assertions.
check-layout:
	scripts/checks/check-layout.sh

# Fail if any key is missing a catalog language; check-strings compares the
# catalog to the source and cannot see coverage. Both release paths run this.
check-translations:
	scripts/checks/check-translations.sh
