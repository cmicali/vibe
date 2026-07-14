# Vibe build helpers. Vibe.xcodeproj is generated from project.yml by XcodeGen.

CONFIG ?= Release

.PHONY: project build release clean

# Generate Vibe.xcodeproj from project.yml (requires: brew install xcodegen).
project:
	xcodegen generate

# Build the app. Regenerates the project first via the `project` prerequisite,
# so build.sh is told to skip its own generate. Override with: make build CONFIG=Debug
build: project
	SKIP_GENERATE=1 scripts/build.sh $(CONFIG)

# Build Release, then sign (Developer ID), notarize, and staple a distributable
# app. See scripts/release.sh for the required credentials.
release:
	scripts/release.sh

# Remove build/ and the generated Vibe.xcodeproj.
clean:
	scripts/clean.sh
