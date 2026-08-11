# Dev-tool dependencies — install with `brew bundle` (or `make setup`).
# These are build/debug tooling only: the app itself has no package manager;
# all third-party code it ships is vendored under Vibe/ThirdParty/.

# Generates Vibe.xcodeproj from project.yml (required to build at all).
brew "xcodegen"

# JSON filtering for the vibe-debug skill's --debug-cmd replies. macOS 15+
# ships /usr/bin/jq, so this just guarantees a modern copy everywhere.
brew "jq"

# GitHub CLI — `make github-release` publishes the notarized build with it.
brew "gh"
