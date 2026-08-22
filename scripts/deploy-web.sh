#!/usr/bin/env bash
#
# Publish Assets/Web to Cloudflare Pages.
#
#   scripts/deploy-web.sh [--dry-run] [--skip-link-check] [--skip-branch-check]
#                         [--wrangler-login]
#
# The site is static — no build step on either host — so this uploads the
# directory as it stands. GitHub Pages is not deployed from here: its workflow
# (.github/workflows/pages.yml) triggers on a push to main touching
# Assets/Web/**, so committing is what updates that copy. Cloudflare serves the
# canonical URL and is deployed on purpose, at release time, which is why this
# is a script and not a second push trigger.
#
# LOCAL ONLY, deliberately. This step needs a Cloudflare API token, and that
# token is not going into CI: a repository secret is readable by any workflow
# change, and the whole point of a static site is that publishing it needs no
# standing credential in a shared place. The token lives in the gitignored
# .release-env on the machine that cuts releases, beside the App Store Connect
# keys, and the script refuses to run in CI so that a later "just add it to a
# workflow" has to be a deliberate act rather than a passing convenience.
#
# GitHub Pages is the copy CI is allowed to publish, precisely because it needs
# no secret — .github/workflows/pages.yml deploys with the workflow's own OIDC
# token and nothing else.
#
# Before uploading it checks two things. That Assets/Web matches origin/main,
# because this uploads the working tree rather than a commit — being on the
# wrong branch, or holding an uncommitted edit, would otherwise put something
# on the canonical domain that is in no branch at all, and leave the two hosts
# serving different sites. And that the .dmg the page advertises actually
# resolves. A page whose Download button 404s is worse than a stale one, and
# the link is only correct because web-set-version.sh rewrote it — this is the
# check that the rewrite and the release actually happened in that order.
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

# ---------------------------------------------------------------------------
# Preflight.
# ---------------------------------------------------------------------------
[[ -f "$PAGE" ]] || { echo "error: $PAGE not found" >&2; exit 1; }

# See the header: the Cloudflare token is a local credential on purpose.
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


# What gets uploaded is the working tree, so "it is committed" is not enough —
# it has to be committed to the branch GitHub Pages publishes, or the two hosts
# diverge. Checked in two parts because they fail for different reasons and
# want different fixes.
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

# An interactive `wrangler login` on this machine is also a local-only
# credential, so it is a legitimate alternative to the token — just a less
# durable one, since the OAuth session expires. Opt in explicitly rather than
# sniffing wrangler's cache, so a release never silently changes how it
# authenticates.
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
    # The account id is only needed to disambiguate a token that can reach
    # several accounts; wrangler resolves a single-account token by itself.
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
