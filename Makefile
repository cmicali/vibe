# Vibe build helpers. Vibe.xcodeproj is generated from project.yml by XcodeGen.

CONFIG ?= Release

.PHONY: setup project build release appstore appstore-upload install clean run screenshots app-store-screenshots

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
	scripts/generate-screenshots.sh

# Regenerate the App Store screenshots (2880x1800, app composited onto a
# background image) into Assets/app-store/. Same permissions as `screenshots`.
#   make app-store-screenshots BACKGROUND=path/to/background.png
app-store-screenshots:
	scripts/generate-app-store-screenshots.sh "$(BACKGROUND)"
