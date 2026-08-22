# Vibe build helpers. Vibe.xcodeproj is generated from project.yml by XcodeGen.

CONFIG ?= Release

# Where `make test` writes its .xcresult, and where `make test-summary` reads
# it from. Under build/, so `make clean` takes it.
RESULT_BUNDLE ?= build/TestResults.xcresult

.PHONY: setup project build build-ios install-ios test test-summary analyze stress release github-release deploy-web web-set-version appstore-build appstore-upload-signed-build install clean run screenshots appstore-generate-store-screenshots appstore-generate-store-screenshots-all appstore-capture-app-screenshots appstore-validate-copy appstore-upload-metadata strings check-strings check-translations check-vocabulary check-layout reset-state

# Install the dev-tool dependencies (xcodegen, jq) from the Brewfile.
setup:
	brew bundle

# Generate Vibe.xcodeproj from project.yml (requires xcodegen — `make setup`).
#
# Under the build lock: several agent sessions share one checkout, and
# rewriting the project file while another session's xcodebuild has it open
# fails that build or, worse, feeds it a half-written one. The lock is taken
# per command, so this waits for a build in flight and releases before the next
# recipe runs — see scripts/build-lock.sh.
project:
	scripts/build-lock.sh xcodegen generate

# Build the app. Regenerates the project first via the `project` prerequisite,
# so build.sh is told to skip its own generate. Override with: make build CONFIG=Debug
build: project
	SKIP_GENERATE=1 scripts/build.sh $(CONFIG)

# The iOS app, simulator slice, unsigned — what CI's build-ios job runs, and
# the check that catches an AppKit leak into a shared directory. The
# destination is generic, so nothing has to be booted. CI passes CONFIG=Debug;
# the default stays Release to match `build`.
# Locked too: this and `drive-ios.sh start` build into the same products
# directory, and the simulator app the touch driver installs from is the one
# they both write.
build-ios: project
	scripts/build-lock.sh xcodebuild -project Vibe.xcodeproj -scheme VibeiOS -configuration $(CONFIG) \
	    -destination 'generic/platform=iOS Simulator' \
	    -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build

# The iOS app built for a paired physical device, signed, and installed over
# the CoreDevice tunnel. Needs a development certificate and a profile for the
# bundle ID — build-ios above is the unsigned simulator slice and installs
# nothing. The single paired device is picked automatically; with more than one
# connected, name it: make install-ios DEVICE="cmicali iPhone"
install-ios: project
	SKIP_GENERATE=1 scripts/install-ios.sh $(CONFIG)

# Run the unit tests (Tests/, VibeTests target). Always Debug — the suite is
# host-less pure-logic only, so it needs no window server, no audio hardware,
# no permissions, and no running Vibe instance. Anything requiring the running
# app belongs in the vibe-debug skill's command channel instead.
#
# The rm matters: xcodebuild refuses to write over an existing result bundle.
test: project
	rm -rf $(RESULT_BUNDLE)
	xcodebuild \
	    -project Vibe.xcodeproj \
	    -scheme Vibe \
	    -configuration Debug \
	    -derivedDataPath build/DerivedData \
	    -resultBundlePath $(RESULT_BUNDLE) \
	    test

# Pass/fail counts and failure messages from the last `make test`, as a
# markdown table. CI appends it to the run summary; run it by hand after a
# local `make test` for the same table on stdout.
test-summary:
	scripts/test-summary.sh $(RESULT_BUNDLE)

# Run clang's static analyzer over the app target and FAIL on any finding
# outside ThirdParty/. project.yml turns the analyzer's checks on
# (CLANG_ANALYZER_NONNULL, CLANG_ANALYZER_NUMBER_OBJECT_CONVERSION), and this
# is what makes them a gate rather than a setting nobody runs. Vendored code is
# other authors' and is excluded, as it is from every other check here.
analyze:
	scripts/analyze.sh $(CONFIG)

# Stress/fuzz the RUNNING app against a folder of real audio files. Seeded and
# reproducible; it checks check_consistency and dump_health between batches and
# writes an NDJSON journal a failure can be shrunk from. Needs a Debug build
# (the whole debug channel compiles out of Release). See the vibe-stress skill.
#   make stress CORPUS=~/Music/big
#   make stress CORPUS=~/Music/big ARGS="--profile loading --duration 3600"
stress:
	@test -n "$(CORPUS)" || { echo "usage: make stress CORPUS=<folder of audio files>"; exit 64; }
	.claude/skills/vibe-stress/scripts/stress.py --corpus "$(CORPUS)" $(ARGS)

# The other shape: ONE large playlist with transport hammered, so track changes
# outrun the metadata scan and the waveform load. The wrapper asserts a single
# verified instance and cold caches first — both are load-bearing, see the
# vibe-stress skill. APP defaults to the Debug build.
#   make torture PLAYLIST=~/Music/big
#   make torture PLAYLIST=~/Music/big ARGS="--rounds 40 --burst 40"
torture: APP ?= build/DerivedData/Build/Products/Debug/Vibe.app
torture:
	@test -n "$(PLAYLIST)" || { echo "usage: make torture PLAYLIST=<folder of audio files> [APP=<Vibe.app>]"; exit 64; }
	.claude/skills/vibe-stress/scripts/run-torture.sh "$(APP)" "$(PLAYLIST)" $(ARGS)

# Build (Release by default) then copy the app into /Applications, replacing
# any existing copy. The rm matters: BSD cp -R copies INTO an existing
# destination directory, so without it a second install produces
# /Applications/Vibe.app/Vibe.app.
install: build
	@echo "🔊 installing to /Applications/Vibe.app"
	rm -rf /Applications/Vibe.app
	cp -R build/DerivedData/Build/Products/$(CONFIG)/Vibe.app /Applications/Vibe.app

# Build Release, then sign (Developer ID), notarize and staple a distributable
# app, and package it as a drag-to-Applications disk image — itself signed,
# notarized and stapled. See scripts/release.sh for the required credentials.
release:
	scripts/release.sh

# Publish what `make release` produced as a GitHub release: tags HEAD as
# v<MARKETING_VERSION>, attaches Vibe-macOS-<version>.dmg and
# Vibe-macOS-<arch>-<version>.zip, notes from the App Store whats-new.txt.
# See scripts/github-release.sh.
github-release:
	scripts/github-release.sh

# Publish Assets/Web to Cloudflare Pages, which serves the canonical
# vibeplayer.app. Local-only on purpose: the API token stays
# out of CI secrets, and the script refuses to run there. GitHub Pages is the
# copy CI publishes, from a workflow that needs no credential. Refuses to
# upload a page whose Download button does not resolve; ARGS="--dry-run" lists
# what would go, and needs no credentials.
deploy-web:
	scripts/deploy-web.sh $(ARGS)

# Point the page's Download button at a release: make web-set-version V=1.10.
# github-release runs this itself, so this is for repointing by hand.
web-set-version:
	scripts/web-set-version.sh $(V)

# Build Release signed for the Mac App Store and run App Store Connect's
# validation, WITHOUT submitting. See scripts/release-appstore.sh for the
# required App Store Connect API credentials.
appstore-build:
	scripts/release-appstore.sh

# Same, then actually upload the build to App Store Connect.
appstore-upload-signed-build:
	scripts/release-appstore.sh --upload

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
# capture; needs Screen Recording permission for the terminal).
screenshots:
	scripts/generate-readme-screenshots.sh

# Regenerate the App Store screenshots (2880x1800) by compositing the window
# captures `screenshots` leaves in Assets/ onto generated backgrounds — the
# captures show nothing localized, so every language shares them. This is the
# path the shipped shots use. It needs no app, no debug build and no
# permissions — only those captures, so run `screenshots` first if the UI has
# changed. LOCALE deliberately, not LANG or LANGUAGE — both are real
# environment variables make would silently import.
#   make appstore-generate-store-screenshots               # English → Assets/app-store/screenshots/en/
#   make appstore-generate-store-screenshots LOCALE=de     # copy/de captions → Assets/app-store/screenshots/de/
appstore-generate-store-screenshots:
	scripts/appstore-generate-store-screenshots.sh $(LOCALE)

# Every catalog language (list read from Resources/Localizable.xcstrings).
appstore-generate-store-screenshots-all:
	scripts/appstore-generate-store-screenshots.sh --all

# Fail unless every catalog language has complete App Store copy in
# Assets/app-store/copy/, within ASC limits, and every caption fits the
# screenshot layout. For review/CI.
appstore-validate-copy:
	scripts/appstore-validate-copy.sh

# Upload the localized App Store copy and screenshots to App Store Connect
# (the editable macOS version's product page — no build is involved). Runs
# appstore-validate-copy first. See scripts/appstore-upload-metadata.sh for flags:
#   make appstore-upload-metadata                          # everything
#   make appstore-upload-metadata ARGS="--dry-run"
#   make appstore-upload-metadata ARGS="--locales de,fr --skip-screenshots"
appstore-upload-metadata: appstore-validate-copy
	scripts/appstore-upload-metadata.sh $(ARGS)

# The other App Store path: photograph the window over a staged desktop, so the
# Liquid Glass shows a real backdrop rather than a composited one. Honest, but
# it can only show the window at its captured size, which leaves the UI small
# on a 2880x1800 canvas — hence `appstore-generate-store-screenshots` above. Same
# permissions as `screenshots`. BACKGROUND is one background for all three
# shots, or three (player, playlist, pitch); it is word-split, so run the
# script directly for paths with spaces.
#   make appstore-capture-app-screenshots BACKGROUND=path/to/background.png
appstore-capture-app-screenshots:
	scripts/appstore-capture-app-screenshots.sh $(BACKGROUND)

# Re-extract UI strings into Resources/Localizable.xcstrings. Run after
# touching any UI string (no build-time extraction exists for ObjC; see script).
strings:
	scripts/extract-strings.sh

# Fail if the catalog doesn't match the source. For review/CI.
check-strings:
	scripts/extract-strings.sh --check

# Fail if a name breaks CLAUDE.md's Vocabulary section: a bare generation
# counter, 'claim' used for OS role registration, or a header-only seam whose
# suffix does not say whether it returns a decision or a number. For review/CI.
check-vocabulary:
	scripts/check-vocabulary.sh

# Fail if the tree stops matching CLAUDE.md's layout rule: a feature-named
# exclude, a platform path in the wrong target, a shared subsystem missing from
# one of them, a new top-level directory nothing names, or a shared source
# importing a header only one platform's tree has. For review/CI.
check-layout:
	scripts/check-layout.sh

# Fail if any key is missing a catalog language. Distinct from check-strings,
# which compares the catalog to the source and cannot see coverage at all.
# Both release paths run this; see the script for why nothing else catches it.
check-translations:
	scripts/check-translations.sh
