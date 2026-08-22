#!/usr/bin/env bash
#
# Publish Assets/Web to Cloudflare Pages.
#
#   scripts/deploy-web.sh [--dry-run] [--skip-link-check]
#
# The site is static — no build step on either host — so this uploads the
# directory as it stands. GitHub Pages is not deployed from here: its workflow
# (.github/workflows/pages.yml) triggers on a push to main touching
# Assets/Web/**, so committing is what updates that copy. Cloudflare serves the
# canonical URL and is deployed on purpose, at release time, which is why this
# is a script and not a second push trigger.
#
# Before uploading it checks that the .dmg the page advertises actually
# resolves. A page whose Download button 404s is worse than a stale one, and
# the link is only correct because web-set-version.sh rewrote it — this is the
# check that the rewrite and the release actually happened in that order.
set -euo pipefail

cd "$(dirname "$0")/.."

DIR="Assets/Web"
PAGE="$DIR/index.html"
DRY_RUN=""
CHECK_LINK=1

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)         DRY_RUN=1 ;;
        --skip-link-check) CHECK_LINK=0 ;;
        *) echo "usage: scripts/deploy-web.sh [--dry-run] [--skip-link-check]" >&2; exit 64 ;;
    esac
    shift
done

# ---------------------------------------------------------------------------
# Preflight.
# ---------------------------------------------------------------------------
[[ -f "$PAGE" ]] || { echo "error: $PAGE not found" >&2; exit 1; }

command -v npx >/dev/null || {
    echo "error: npx is not installed — wrangler runs through it (brew install node)" >&2
    exit 1
}

# shellcheck disable=SC1091
[[ -f .release-env ]] && source .release-env
PROJECT="${CLOUDFLARE_PAGES_PROJECT:-vibe}"


# The button's href is the one thing on the page that can be wrong in a way a
# visitor notices immediately.
if [[ "$CHECK_LINK" == 1 ]]; then
    DMG_URL="$(perl -ne 'print $1 if /id="dmg-link"\s+href="([^"]+)"/' "$PAGE")"
    if [[ -z "$DMG_URL" ]]; then
        echo "error: no id=\"dmg-link\" href in $PAGE — has the button markup changed?" >&2
        exit 1
    fi
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

# ---------------------------------------------------------------------------
# Deploy.
# ---------------------------------------------------------------------------
if [[ -n "$DRY_RUN" ]]; then
    echo "🔊 dry run — would upload $(find "$DIR" -type f | wc -l | tr -d ' ') files ($(du -sh "$DIR" | cut -f1)) to Pages project '$PROJECT':"
    find "$DIR" -type f | sed 's|^|     |' | sort
    exit 0
fi


PROJECT="${CLOUDFLARE_PAGES_PROJECT:-vibe}"

if [[ -z "${CLOUDFLARE_API_TOKEN:-}" || -z "${CLOUDFLARE_ACCOUNT_ID:-}" ]]; then
    cat >&2 <<'MSG'
error: Cloudflare credentials not configured.

  Create a token at Cloudflare -> My Profile -> API Tokens -> Create Token ->
  Custom token, with exactly one permission:

      Account | Cloudflare Pages | Edit

  Your account id is on the right of any zone's Overview page. Then add both
  to the gitignored .release-env in the repo root, beside the ASC keys:

      CLOUDFLARE_API_TOKEN=...
      CLOUDFLARE_ACCOUNT_ID=...
      CLOUDFLARE_PAGES_PROJECT=vibe     # optional, defaults to vibe

  (.release-env is gitignored. Never commit the token.)
MSG
    exit 1
fi
export CLOUDFLARE_API_TOKEN CLOUDFLARE_ACCOUNT_ID

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
  Workers & Pages -> $PROJECT -> Custom domains -> vibe.commonwealthrecordings.com

  If it reported an auth error, the token needs Account | Cloudflare Pages | Edit.
MSG
    exit $STATUS
fi

echo "🔊 done — https://vibe.commonwealthrecordings.com"
