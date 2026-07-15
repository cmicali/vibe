# Vibe build helpers. Vibe.xcodeproj is generated from project.yml by XcodeGen.

CONFIG ?= Release

.PHONY: project build release install clean run

# Generate Vibe.xcodeproj from project.yml (requires: brew install xcodegen).
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
# app. See scripts/release.sh for the required credentials.
release:
	scripts/release.sh

# Remove build/ and the generated Vibe.xcodeproj.
clean:
	scripts/clean.sh

# Launch the app, building it first only if it isn't built yet.
run:
	scripts/run.sh $(CONFIG)
