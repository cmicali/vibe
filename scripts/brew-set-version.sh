#!/usr/bin/env bash
#
# Point the Homebrew tap at a release, so `brew install cmicali/tap/vibe` and
# `brew upgrade` deliver it.
#
#   scripts/brew-set-version.sh <version> [--dry-run]     # e.g. 1.15
#
# Writes the tap's Casks/vibe.rb whole from the template below, so the tap holds
# nothing edited by hand and a cask change is reviewed here, beside the code
# that decides it (the zap paths are the sandbox's containers). Each DMG's
# sha256 is the digest GitHub computed for the published asset, so this runs
# for any published stable release with no build products on disk.
# github-release.sh runs it after publishing; a beta or a draft is refused,
# since the tap must never hand out a test build.
#
# --dry-run prints the cask instead of committing it to the tap.
set -euo pipefail

cd "$(dirname "$0")/.."

REPO="cmicali/vibe"
TAP="cmicali/homebrew-tap"
CASK_PATH="Casks/vibe.rb"
VERSION="${1:-}"
DRY_RUN=""
case "${2:-}" in
    --dry-run) DRY_RUN=1 ;;
    "") ;;
    *) echo "usage: scripts/brew-set-version.sh <version> [--dry-run]" >&2; exit 64 ;;
esac

[[ -n "$VERSION" ]] || {
    echo "usage: scripts/brew-set-version.sh <version> [--dry-run]   (e.g. 1.15)" >&2
    exit 64
}
VERSION="${VERSION#v}"
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+)*$ ]] || {
    echo "error: '$VERSION' is not a stable version number like 1.15" >&2
    exit 64
}
command -v gh >/dev/null || {
    echo "error: gh (GitHub CLI) is not installed — brew bundle installs it (see Brewfile)" >&2
    exit 1
}

RELEASE="$(gh api "repos/$REPO/releases/tags/v$VERSION")" || {
    echo "error: no published release v$VERSION on $REPO" >&2
    exit 1
}
[[ "$(jq -r '.prerelease' <<< "$RELEASE")" == "false" ]] || {
    echo "error: v$VERSION is a prerelease — the tap only carries stable releases" >&2
    exit 1
}

asset_sha256() {
    local name="Vibe-macOS-$1-$VERSION.dmg"
    local digest
    digest="$(jq -r --arg name "$name" \
        '.assets[] | select(.name == $name) | .digest // empty' <<< "$RELEASE")"
    [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || {
        echo "error: v$VERSION has no sha256 digest for $name" >&2
        exit 1
    }
    echo "${digest#sha256:}"
}
ARM64_SHA="$(asset_sha256 arm64)"
UNIVERSAL_SHA="$(asset_sha256 universal)"

CASK="$(mktemp)"
trap 'rm -f "$CASK"' EXIT
cat > "$CASK" <<EOF
cask "vibe" do
  arch arm: "arm64", intel: "universal"

  version "$VERSION"
  sha256 arm:   "$ARM64_SHA",
         intel: "$UNIVERSAL_SHA"

  url "https://github.com/$REPO/releases/download/v#{version}/Vibe-macOS-#{arch}-#{version}.dmg"
  name "Vibe"
  desc "Native music player"
  homepage "https://vibeplayer.app/"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :ventura

  app "Vibe.app"

  zap trash: [
    "~/Library/Application Scripts/com.commonwealthrecordings.Vibe",
    "~/Library/Containers/com.commonwealthrecordings.Vibe",
    "~/Library/Group Containers/4UEV752JH4.com.commonwealthrecordings.Vibe",
  ]
end
EOF

if [[ -n "$DRY_RUN" ]]; then
    cat "$CASK"
    exit 0
fi

# The contents API's sha is the file's git blob id, so an identical cask is
# detected without fetching it, and a re-run leaves no empty commit.
CURRENT_SHA="$(gh api "repos/$TAP/contents/$CASK_PATH" -q .sha 2>/dev/null || true)"
if [[ "$CURRENT_SHA" == "$(git hash-object "$CASK")" ]]; then
    echo "🔊 Homebrew tap already at $VERSION"
    exit 0
fi
gh api -X PUT "repos/$TAP/contents/$CASK_PATH" \
    -f message="vibe $VERSION" \
    -f content="$(base64 < "$CASK")" \
    ${CURRENT_SHA:+-f sha="$CURRENT_SHA"} >/dev/null
echo "🔊 Homebrew tap pointed at $VERSION — brew install cmicali/tap/vibe"
