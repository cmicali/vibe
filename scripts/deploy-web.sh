#!/usr/bin/env bash
#
# Publish Assets/Web to Cloudflare Pages, which serves vibeplayer.app.
#
#   scripts/deploy-web.sh [--dry-run] [--skip-link-check] [--skip-branch-check]
#                         [--wrangler-login]
#
#   --dry-run            list what would upload; needs no credentials
#   --skip-link-check    deploy even if the page's .dmg link is not a 200
#   --skip-branch-check  deploy even if Assets/Web differs from origin/main
#   --wrangler-login     authenticate with this machine's `wrangler login`
#                        instead of CLOUDFLARE_API_TOKEN
#
# The site is static: this uploads the directory as it stands. GitHub Pages is
# the other copy, published by .github/workflows/pages.yml on a push to main.
#
# LOCAL ONLY, and it refuses to run in CI. The Cloudflare token lives in the
# gitignored .release-env rather than in CI secrets, where any workflow change
# could read it; GitHub Pages is the copy CI publishes because it needs none.
#
# Before uploading it checks that Assets/Web matches origin/main, that the
# asset stamps are current, that the page's .dmg link resolves, and that the
# /download rules in _redirects name the same file.
set -euo pipefail

cd "$(dirname "$0")/.."

DIR="Assets/Web"
PAGE="$DIR/index.html"
DRY_RUN=""
CHECK_LINK=1
CHECK_BRANCH=1
USE_LOGIN=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)         DRY_RUN=1 ;;
        --skip-link-check)   CHECK_LINK=0 ;;
        --skip-branch-check) CHECK_BRANCH=0 ;;
        --wrangler-login)    USE_LOGIN=1 ;;
        *) echo "usage: scripts/deploy-web.sh [--dry-run] [--skip-link-check] [--skip-branch-check] [--wrangler-login]" >&2; exit 64 ;;
    esac
    shift
done

[[ -f "$PAGE" ]] || { echo "error: $PAGE not found" >&2; exit 1; }

if [[ -n "${CI:-}${GITHUB_ACTIONS:-}${GITLAB_CI:-}${BUILDKITE:-}" ]]; then
    cat >&2 <<'MSG'
error: deploy-web is local-only and will not run in CI.

  It needs a Cloudflare API token, which is deliberately kept out of CI
  secrets — see the comment at the top of this script. GitHub Pages is the
  copy CI publishes, and it needs no credential at all.

  Cut the release from a machine that has .release-env.
MSG
    exit 1
fi

command -v npx >/dev/null || {
    echo "error: npx is not installed — wrangler runs through it (brew install node)" >&2
    exit 1
}

# shellcheck disable=SC1091
[[ -f .release-env ]] && source .release-env
PROJECT="${CLOUDFLARE_PAGES_PROJECT:-vibe}"


# The upload is the working tree, so it must match what GitHub Pages publishes
# or the two hosts diverge.
if [[ "$CHECK_BRANCH" == 1 ]]; then
    git fetch -q origin main 2>/dev/null || \
        echo "warning: could not reach origin — comparing against a possibly stale origin/main" >&2

    if [[ -n "$(git status --porcelain -- "$DIR")" ]]; then
        echo "error: $DIR has uncommitted or untracked changes:" >&2
        git status --short -- "$DIR" >&2
        echo >&2
        echo "  Commit and push them, or pass --skip-branch-check to deploy anyway." >&2
        exit 1
    fi

    if ! git diff --quiet origin/main -- "$DIR"; then
        echo "error: $DIR differs from origin/main:" >&2
        git diff --stat origin/main -- "$DIR" >&2
        echo >&2
        echo "  You are on '$(git branch --show-current || echo 'a detached HEAD')'. Cloudflare would get" >&2
        echo "  content GitHub Pages will not, and the two copies would disagree." >&2
        echo "  Push to main first, or pass --skip-branch-check to deploy anyway." >&2
        exit 1
    fi
fi

# A stale stamp looks like a deploy that did nothing: new markup, cached assets.
scripts/web-stamp-assets.sh --check

DMG_URL="$(perl -ne 'print $1 if /id="dmg-link"\s+href="([^"]+)"/' "$PAGE")"
if [[ -z "$DMG_URL" ]]; then
    echo "error: no id=\"dmg-link\" href in $PAGE — has the button markup changed?" >&2
    exit 1
fi

# /download/latest is what external links use, and no page shows where it
# lands. web-set-version.sh writes it and the button from one URL, so a
# mismatch is a hand edit. Free, so it runs even under --skip-link-check.
while read -r RULE TARGET CODE; do
    if [[ "$TARGET" != "$DMG_URL" ]]; then
        cat >&2 <<MSG
error: $DIR/_redirects and the Download button name different files.

  $RULE  ->  $TARGET
  button ->  $DMG_URL

  Re-run scripts/web-set-version.sh <version> to write both from one URL.
MSG
        exit 1
    fi
    if [[ "$CODE" != "302" ]]; then
        cat >&2 <<MSG
error: $DIR/_redirects sends $RULE with status $CODE, not 302.

  The target moves every release, so a 301 would be cached permanently by
  every browser that followed it — and nothing here could correct them.
MSG
        exit 1
    fi
done < <(grep '^/download' "$DIR/_redirects")

if [[ "$CHECK_LINK" == 1 ]]; then
    echo "🔊 checking the download link: $DMG_URL"
    CODE="$(curl -sIL -o /dev/null -w '%{http_code}' "$DMG_URL" || echo 000)"
    if [[ "$CODE" != "200" ]]; then
        cat >&2 <<MSG
error: the page's download link returns HTTP $CODE, not 200.

  $DMG_URL

  The release it names is probably not published yet. Publish it first
  (make github-release), or re-point the page:

      scripts/web-set-version.sh <version>

  Use --skip-link-check to deploy anyway.
MSG
        exit 1
    fi
fi

if [[ -n "$DRY_RUN" ]]; then
    echo "🔊 dry run — would upload $(find "$DIR" -type f | wc -l | tr -d ' ') files ($(du -sh "$DIR" | cut -f1)) to Pages project '$PROJECT':"
    find "$DIR" -type f | sed 's|^|     |' | sort
    exit 0
fi

# Opt-in rather than sniffed from wrangler's cache, so a release never silently
# changes how it authenticates.
if [[ -n "$USE_LOGIN" ]]; then
    echo "🔊 using this machine's wrangler login rather than a token"
elif [[ -z "${CLOUDFLARE_API_TOKEN:-}" ]]; then
    cat >&2 <<'MSG'
error: Cloudflare credentials not configured.

  Create a token at Cloudflare -> My Profile -> API Tokens -> Create Token ->
  Custom token, with exactly one permission:

      Account | Cloudflare Pages | Edit

  Your account id is on the right of any zone's Overview page. Then add both
  to the gitignored .release-env in the repo root, beside the ASC keys:

      CLOUDFLARE_API_TOKEN=...
      CLOUDFLARE_ACCOUNT_ID=...          # optional; needed only if the token
                                         # can reach more than one account
      CLOUDFLARE_PAGES_PROJECT=vibe      # optional, defaults to vibe

  (.release-env is gitignored. Never commit the token.)

  Already run `wrangler login` on this machine? Pass --wrangler-login to use
  that instead: also local-only, but the OAuth session expires, so a token is
  the better answer for something in the release path.
MSG
    exit 1
else
    # The account id only disambiguates a token that reaches several accounts.
    export CLOUDFLARE_API_TOKEN
    [[ -n "${CLOUDFLARE_ACCOUNT_ID:-}" ]] && export CLOUDFLARE_ACCOUNT_ID
fi

echo "🔊 deploying $DIR to Cloudflare Pages project '$PROJECT'"
set +e
npx --yes wrangler@latest pages deploy "$DIR" \
    --project-name "$PROJECT" \
    --branch main \
    --commit-dirty=true
STATUS=$?
set -e

if [[ $STATUS -ne 0 ]]; then
    cat >&2 <<MSG

error: wrangler failed (exit $STATUS).

  If it reported that the project does not exist, create it once:

      npx wrangler pages project create $PROJECT --production-branch main

  Then attach the custom domain in the dashboard:
  Workers & Pages -> $PROJECT -> Custom domains -> vibeplayer.app

  If it reported an auth error, the token needs Account | Cloudflare Pages | Edit.
MSG
    exit $STATUS
fi

echo "🔊 done — https://vibeplayer.app"
