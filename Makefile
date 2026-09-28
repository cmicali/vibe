# Vibe build helpers. Vibe.xcodeproj is generated from project.yml by XcodeGen.

CONFIG ?= Release

# Where `make test` writes its .xcresult, and where `make test-summary` reads
# it from. Under build/, so `make clean` takes it.
RESULT_BUNDLE ?= build/TestResults.xcresult

.PHONY: build-test-blackhole test-bit-perfect test-audio test-audio-summary test-audio-loopback test-audio-device setup project build build-ios install-ios test test-summary check-cloud-scenarios analyze stress torture release github-release deploy-web web-set-version appstore-build appstore-upload-signed-build appstore-build-ios appstore-upload-signed-build-ios install clean run screenshots appstore-generate-store-screenshots appstore-generate-store-screenshots-all appstore-capture-app-screenshots appstore-validate-copy appstore-upload-metadata strings check-strings check-translations check-vocabulary check-layout reset-state

# Install the dev-tool dependencies (xcodegen, jq, gh) from the Brewfile.
setup:
	brew bundle

# Generate Vibe.xcodeproj from project.yml (requires xcodegen — `make setup`).
# Under the build lock (scripts/build-lock.sh), taken per command: sessions
# share one checkout, and rewriting the project under another session's
# xcodebuild fails that build or feeds it a half-written project.
project:
	scripts/build-lock.sh xcodegen generate

# The macOS app. `project` has already regenerated, so build.sh skips its own.
build: project
	SKIP_GENERATE=1 scripts/build.sh $(CONFIG)

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

# The iOS simulator slice — CI's build-ios job, in both configurations, and the
# check that catches an AppKit leak into a shared directory. Locked: this and
# `drive-ios.sh start` write the products directory the touch driver installs
# from.
build-ios: project
	scripts/build-lock.sh xcodebuild -project Vibe.xcodeproj -scheme VibeiOS -configuration $(CONFIG) \
	    -destination 'generic/platform=iOS Simulator' \
	    -derivedDataPath build/DerivedData $(IOS_SIM_SIGN) build

# Signed for a paired device and installed over the CoreDevice tunnel; needs a
# development certificate and profile. With more than one device paired, name
# it: make install-ios DEVICE="cmicali iPhone"
install-ios: project
	SKIP_GENERATE=1 scripts/install-ios.sh $(CONFIG)

# The host-less unit tests (VibeTests) plus the cloud-runner oracle tests.
# The rm matters: xcodebuild refuses to write over an existing result bundle.
test: project check-cloud-scenarios
	rm -rf $(RESULT_BUNDLE)
	xcodebuild \
	    -project Vibe.xcodeproj \
	    -scheme Vibe \
	    -configuration Debug \
	    -derivedDataPath build/DerivedData \
	    -resultBundlePath $(RESULT_BUNDLE) \
	    -enableCodeCoverage YES \
	    -collect-test-diagnostics never \
	    test

# One compiled PCM verifier shared by hardware and device-free audio tests.
build/verify-bit-perfect: .claude/skills/vibe-debug/scripts/verify-bit-perfect.swift
	@mkdir -p build
	@swiftc -O $< -o $@

# Opt-in live acceptance, never CI: the test drivers from build-test-blackhole,
# and the Debug app already running on VibeBlackHole 16ch. See
# vibe-debug/references/test-audio.md.
.PHONY: build-test-blackhole
build-test-blackhole:
	@.claude/skills/vibe-debug/scripts/generate-test-audio.sh --blackhole-drivers

AUDIO_DEVICE ?= BlackHole 2ch
AUDIO_APP ?= $(abspath build/DerivedData/Build/Products/Debug/Vibe.app/Contents/MacOS/Vibe)
test-bit-perfect: AUDIO_DEVICE = VibeBlackHole 16ch
test-bit-perfect: build/verify-bit-perfect
	@build/verify-bit-perfect --self-test
	@.claude/skills/vibe-debug/scripts/generate-test-audio.sh --render-tests build/audio-fixtures
	@build/verify-bit-perfect --acceptance "$(abspath build/audio-fixtures)" "$(AUDIO_DEVICE)" --play-app "$(AUDIO_APP)" --require-driver-fixtures $(ARGS)

# The render suite produces real PCM without opening hardware. ARGS can narrow XCTest.
AUDIO_RESULT_BUNDLE ?= build/AudioTestResults.xcresult
test-audio: project build/verify-bit-perfect
	@build/verify-bit-perfect --self-test
	.claude/skills/vibe-debug/scripts/generate-test-audio.sh --render-tests build/audio-fixtures
	rm -rf $(AUDIO_RESULT_BUNDLE)
	scripts/build-lock.sh xcodebuild -project Vibe.xcodeproj -scheme VibeAudioTests \
	    -configuration Debug -destination 'platform=macOS' -derivedDataPath build/DerivedData \
	    -resultBundlePath $(AUDIO_RESULT_BUNDLE) -parallel-testing-enabled NO \
	    -collect-test-diagnostics never $(ARGS) test

test-audio-summary:
	scripts/test-summary.sh $(AUDIO_RESULT_BUNDLE)

# Opt-in: launch an idle, unmuted Debug app on AUDIO_DEVICE first (vibe-debug).
# Regular loopback: ARGS='--set-rate --ordinary'. Device check: bit-perfect off.
AUDIO_FILE ?= build/audio-fixtures/noise-48000-24-2.wav
AUDIO_SECONDS ?= 3

test-audio-loopback: build/verify-bit-perfect
	build/verify-bit-perfect \
	    "$(AUDIO_FILE)" "$(AUDIO_SECONDS)" "$(AUDIO_DEVICE)" --play-app "$(AUDIO_APP)" $(ARGS)

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
	scripts/test-summary.sh $(RESULT_BUNDLE)

# clang's static analyzer over both app targets; fails on any finding outside
# ThirdParty/. Findings are configuration-dependent, and CI checks Release.
analyze:
	scripts/analyze.sh $(CONFIG)

# Seeded stress/fuzz of the Debug app against a folder of real audio files, with
# oracles between batches and an NDJSON journal a failure can be shrunk from.
# See the vibe-stress skill.
#   make stress CORPUS=~/Music/big
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

# The rm matters: BSD cp -R copies INTO an existing destination directory, so
# without it a second install produces /Applications/Vibe.app/Vibe.app.
install: build
	@echo "🔊 installing to /Applications/Vibe.app"
	rm -rf /Applications/Vibe.app
	cp -R build/DerivedData/Build/Products/$(CONFIG)/Vibe.app /Applications/Vibe.app

# Build universal and arm64-only Release archives, then independently export,
# sign (Developer ID), notarize and staple both apps and their
# drag-to-Applications disk images. See scripts/release.sh for credentials.
release:
	scripts/release.sh

# Publish what `make release` produced as a GitHub release, tagged v<version>.
# See scripts/github-release.sh. ARGS reaches its [--draft|--prerelease];
# without it a beta publishes as Latest and repoints the website at it.
github-release:
	scripts/github-release.sh $(ARGS)

# Publish Assets/Web to Cloudflare Pages (the canonical vibeplayer.app).
# Local-only: the token stays out of CI secrets and the script refuses to run
# there. ARGS="--dry-run" lists what would go and needs no credentials.
deploy-web:
	scripts/deploy-web.sh $(ARGS)

# Point the page's Download button at a release: make web-set-version V=1.10.
# github-release runs this itself, so this is for repointing by hand.
web-set-version:
	scripts/web-set-version.sh $(V)

# Build a universal (arm64 + x86_64) Release signed for the Mac App Store and
# run App Store Connect's validation, WITHOUT submitting. See
# scripts/release-appstore.sh for the required credentials.
appstore-build:
	scripts/release-appstore.sh

# Same, then actually upload the build to App Store Connect.
appstore-upload-signed-build:
	scripts/release-appstore.sh --upload

# The same two steps for the iOS app (.ipa with the widget embedded). Both
# platforms share one bundle id, so these upload to the SAME app record, on a
# separate version train. The script's header has the prerequisites.
appstore-build-ios:
	scripts/release-appstore.sh --platform ios

# Same, then upload; TestFlight sees it once processing finishes.
appstore-upload-signed-build-ios:
	scripts/release-appstore.sh --platform ios --upload

# Remove build/ and the generated Vibe.xcodeproj.
clean:
	scripts/clean.sh

# Wipe Vibe's persisted state (settings, folder grants, caches, saved window
# state) so the next launch is a first launch. Prompts before deleting.
# Options pass through: make reset-state ARGS="--both -y", or ARGS=-n to preview.
reset-state:
	scripts/reset-state.sh $(ARGS)

# Launch the app, building it first only if it isn't built yet.
run:
	scripts/run.sh $(CONFIG)

# Regenerate the README screenshots in Assets/ (debug build + real screen
# capture). Needs Screen Recording and Accessibility for the terminal, and
# ALLOW_GLOBAL_INPUT=1 per run: it moves the real pointer.
screenshots:
	scripts/generate-readme-screenshots.sh

# The shipped App Store screenshots (2880x1800): the captures `screenshots`
# leaves in Assets/ composited onto generated backgrounds. Needs no app, only
# those captures; rerun `screenshots` first if the UI changed. LOCALE, not LANG
# or LANGUAGE, which make would silently import from the environment. macOS
# only; for iOS: scripts/appstore-generate-store-screenshots.sh --platform ios [LOCALE].
#   make appstore-generate-store-screenshots               # English → Assets/app-store/screenshots/en/macos/
#   make appstore-generate-store-screenshots LOCALE=de     # copy/de/macos captions → screenshots/de/macos/
appstore-generate-store-screenshots:
	scripts/appstore-generate-store-screenshots.sh $(LOCALE)

# Every catalog language (list read from Resources/Localizable.xcstrings).
appstore-generate-store-screenshots-all:
	scripts/appstore-generate-store-screenshots.sh --all

# Fail unless every catalog language has complete App Store copy for both
# platforms in Assets/app-store/copy/<lang>/<platform>/, within ASC limits,
# with every caption fitting the screenshot layout.
appstore-validate-copy:
	scripts/appstore-validate-copy.sh

# Upload the localized copy and screenshots to the editable version's product
# page on ONE platform; no build is involved. Flags are the script's:
#   make appstore-upload-metadata                          # everything, macOS
#   make appstore-upload-metadata ARGS="--dry-run"
#   make appstore-upload-metadata ARGS="--locales de,fr --skip-screenshots"
#   make appstore-upload-metadata ARGS="--platform ios"    # everything, iOS
appstore-upload-metadata: appstore-validate-copy
	scripts/appstore-upload-metadata.sh $(ARGS)

# The other App Store path: photograph the window over a staged desktop, so the
# Liquid Glass shows a real backdrop; the window stays small on the canvas,
# hence the composited path above. Same permissions as `screenshots`.
# BACKGROUND is one image for all three shots or three (player, playlist,
# pitch); it is word-split, so run the script directly for paths with spaces.
#   make appstore-capture-app-screenshots BACKGROUND=path/to/background.png
appstore-capture-app-screenshots:
	scripts/appstore-capture-app-screenshots.sh $(BACKGROUND)

# Re-extract UI strings into Resources/Localizable.xcstrings after touching any
# UI string; nothing extracts ObjC strings at build time.
strings:
	scripts/extract-strings.sh

# Fail if the catalog doesn't match the source.
check-strings:
	scripts/extract-strings.sh --check

# Fail on a break of AGENTS.md's mechanical vocabulary rules, listed in the
# script.
check-vocabulary:
	scripts/check-vocabulary.sh

# Fail if the tree breaks AGENTS.md's layout rule; the script's header states
# the four assertions.
check-layout:
	scripts/check-layout.sh

# Fail if any key is missing a catalog language; check-strings compares the
# catalog to the source and cannot see coverage. Both release paths run this.
check-translations:
	scripts/check-translations.sh
