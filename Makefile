# Vibe build helpers. Vibe.xcodeproj is generated from project.yml by XcodeGen.

CONFIG ?= Release

.PHONY: setup project build test release appstore appstore-upload install clean run screenshots app-store-overlays app-store-screenshots

# Install the dev-tool dependencies (xcodegen, jq) from the Brewfile.
setup:
	brew bundle

# Generate Vibe.xcodeproj from project.yml (requires xcodegen — `make setup`).
project:
	xcodegen generate

# Build the app. Regenerates the project first via the `project` prerequisite,
# so build.sh is told to skip its own generate. Override with: make build CONFIG=Debug
build: project
	SKIP_GENERATE=1 scripts/build.sh $(CONFIG)

# Run the unit tests (Tests/, VibeTests target). Always Debug — the suite is
# host-less pure-logic only, so it needs no window server, no audio hardware,
# no permissions, and no running Vibe instance. Anything requiring the running
# app belongs in the vibe-debug skill's command channel instead.
test: project
	xcodebuild \
	    -project Vibe.xcodeproj \
	    -scheme Vibe \
	    -configuration Debug \
	    -derivedDataPath build/DerivedData \
	    test

# Build (Release by default) then copy the app into /Applications, replacing
# any existing copy. The rm matters: BSD cp -R copies INTO an existing
# destination directory, so without it a second install produces
# /Applications/Vibe.app/Vibe.app.
install: build
	@echo "🔊 installing to /Applications/Vibe.app"
	rm -rf /Applications/Vibe.app
	cp -R build/DerivedData/Build/Products/$(CONFIG)/Vibe.app /Applications/Vibe.app

# Build Release, then sign (Developer ID), notarize, and staple a distributable
# app for direct download. See scripts/release.sh for the required credentials.
release:
	scripts/release.sh

# Build Release signed for the Mac App Store and run App Store Connect's
# validation, WITHOUT submitting. See scripts/release-appstore.sh for the
# required App Store Connect API credentials.
appstore:
	scripts/release-appstore.sh

# Same, then actually upload the build to App Store Connect.
appstore-upload:
	scripts/release-appstore.sh --upload

# Remove build/ and the generated Vibe.xcodeproj.
clean:
	scripts/clean.sh

# Launch the app, building it first only if it isn't built yet.
run:
	scripts/run.sh $(CONFIG)

# Regenerate the README screenshots in Assets/ (debug build + real screen
# capture; needs Screen Recording permission for the terminal).
screenshots:
	scripts/generate-readme-screenshots.sh

# Regenerate the App Store screenshots (2880x1800) into Assets/app-store/ by
# compositing the captures `screenshots` leaves in Assets/ onto generated
# backgrounds. This is the path the shipped shots use. It needs no app, no
# debug build and no permissions — only those captures, so run `screenshots`
# first if the UI has changed. Headline copy lives in the script.
app-store-overlays:
	scripts/generate-app-store-overlays.sh

# The other App Store path: photograph the window over a staged desktop, so the
# Liquid Glass shows a real backdrop rather than a composited one. Honest, but
# it can only show the window at its captured size, which leaves the UI small
# on a 2880x1800 canvas — hence `app-store-overlays` above. Same permissions as
# `screenshots`. BACKGROUND is one background for all three shots, or three
# (player, playlist, pitch); it is word-split, so run the script directly for
# paths with spaces.
#   make app-store-screenshots BACKGROUND=path/to/background.png
app-store-screenshots:
	scripts/generate-app-store-screenshots.sh $(BACKGROUND)
