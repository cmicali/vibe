# Assets/Web

The Vibe marketing page: static HTML, one stylesheet, and images. There is no
build step and nothing to install. Copy the folder to any static host and it
works. On Cloudflare, two Pages Functions in the repo root's `functions/` also
count update checks (Update checks, below).

```
index.html              the page
404.html                the not-found page
privacy/index.html      the privacy policy (a directory; see below)
styles.css              the pages' styles
img/                    app icon renditions and screenshots, PNG and WebP
_headers, _redirects    Cloudflare Pages rules; GitHub Pages ignores both
appcast.xml             the update feed for the universal direct download
appcast-arm64.xml       the same for the arm64-only one; github-release.sh writes both
robots.txt, sitemap.xml, llms.txt
```

## Preview it

```bash
python3 -m http.server 4319 --directory Assets/Web
```

Then open <http://localhost:4319>. Opening `index.html` straight from the Finder
works too.

## Where the images come from

`scripts/web/web-build-images.sh` derives the screenshots in `img/` from captures
already in the repo, so they are regenerated rather than edited. Run it after
any screenshot change. `--check` fails when a derivative no longer matches its
source. Nothing else notices a stale one.

| Output | Source |
| --- | --- |
| `img/player.{png,webp}` | `Assets/readme/screenshot-basic.png` |
| `img/ios.{png,webp}` | `Assets/readme/screenshot-ios-iphone-player.png`, corners rounded at the iPhone's own radius and scaled to 560px wide |
| `img/ios-playlist.{png,webp}`, `img/ios-seek.{png,webp}` | `Assets/readme/screenshot-ios-iphone-{playlist,seek}.png`, framed like `ios` |
| `img/store-*.webp` | the English macOS App Store screenshots in `Assets/app-store/screenshots/en/macos/`, 1600px wide, for the carousel |

**The icons and the badge are outside the script**, so a passing `--check` says
nothing about them. `img/icon-*.png` and `img/icon-512.webp` are made by hand
from `Resources/AppIcon.icon/Assets/`: the vinyl ground and the glass waveform,
composited and masked to the rounded square. `img/app-store-badge.svg` is
Apple's file from its marketing toolkit, copied as is. Do not edit it, since
Apple's guidelines set its clear space and proportions. Replace it only with a
newer file from the same source.

The screenshots carry the window's own rounded corners and a transparent margin.
So the page shadows them with `filter: drop-shadow`, since `box-shadow` would
trace the image rectangle instead of the window. A simulator capture is a plain
rectangle, so the script gives `img/ios.png` the same corners and margin. It
rounds at full resolution first and scales after, or the corner stair-steps.

`.shot-phone` caps the phone at 300px. The window shots run to `.shot`'s 800px,
which on a portrait image would be nearly 1800px tall.

## Copy

The wording is the App Store copy in `Assets/app-store/copy/en/macos/` and the feature
list in `README.md`. Keep the two in step: the store listing is the version
Apple reviews.

## Where it is deployed

Both hosts serve this directory as is, with no build step.

| URL | Host | Trigger |
| --- | --- | --- |
| <https://vibeplayer.app> | Cloudflare Pages | `deploy-web.sh`, which `make github-release` runs. Canonical. |
| <https://cmicali.github.io/vibe/> | GitHub Pages | `.github/workflows/pages.yml`, on any push to `main` touching `Assets/Web/**`. |

The page names the Cloudflare URL as `rel=canonical`, so the GitHub Pages copy
does not compete with it in search results.

`privacy/` is a directory with an `index.html` rather than a `privacy.html`, so
that `/privacy` resolves on both hosts. GitHub Pages does not serve an
extensionless URL for a bare `.html` file. A `privacy.html` would answer
`/privacy` on Cloudflare and 404 on GitHub.

`README.md` uploads with everything else and is readable at `/README.md`. It is
already public in the repo, so that costs nothing.

## The Download button's version

The button links a **direct** `.dmg` URL, not `/releases/latest`, because it
also shows the version and the two must agree. GitHub's `latest/download`
shortcut cannot help: it only redirects for an asset name that never changes,
and the default release asset is named
`Vibe-macOS-universal-<version>.dmg`.

That DMG is the universal (`arm64` + `x86_64`) build, matching the page's
Apple-silicon-and-Intel promise. The release also carries
`Vibe-macOS-arm64-<version>.dmg` for Apple silicon, plus architecture-named
ZIPs; those are GitHub alternatives rather than the website default.

So the link is rewritten instead. `scripts/web/web-set-version.sh <version>` edits
the four places in `index.html` that name a version. Two are the button's
`href` and the label under it, keyed on the `dmg-link` and `dmg-version`
element ids rather than the markup around them. The other two are the JSON-LD
`softwareVersion` and `downloadUrl`. It also rewrites the `/download` rules in
`_redirects`. It errors if any of them stops matching.

When `make github-release` runs it, and how a draft or a `--prerelease` skips
it, is the `vibe-release` skill's.

### The stable link

    https://vibeplayer.app/download/latest        # /download and /download/ too

is what anything outside this repo should link: a README, a forum post, a
`curl -L`. An external link then never needs revisiting for a release. It is a
`_redirects` rule pointing at the same URL as the button, written by the same
`web-set-version.sh` run, so the two cannot name different builds.
`deploy-web.sh` refuses to publish if they disagree. That check runs even under
`--skip-link-check`, because no page shows where `/download/latest` lands.

**302, never 301.** The target moves every release. A browser that cached a
permanent redirect would keep fetching one version forever. `deploy-web.sh`
checks the status code too.

It works on Cloudflare only, like `/support`. GitHub Pages ignores
`_redirects`, so the path 404s on the non-canonical copy.

## Deploying

`make github-release` repoints the page, publishes the release and then runs
`deploy-web.sh` itself (the `vibe-release` skill). Run `make deploy-web` by hand
only to retry, or to publish a page change between releases. It refuses when
`Assets/Web` or `functions/` differs from `origin/main`. Push the change first.
`make deploy-web ARGS="--dry-run"` checks the download link and lists the files
without uploading, and needs no credentials.

## Credentials, and why Cloudflare is local-only

`deploy-web` reads `CLOUDFLARE_API_TOKEN` from the gitignored `.release-env` at
the repo root, the same file the App Store Connect keys live in. The token needs
exactly one permission: **Account | Cloudflare Pages | Edit**.
`CLOUDFLARE_ACCOUNT_ID` is optional for deploying. Wrangler resolves a
single-account token by itself. Deploying needs the id only for a token that
can reach several accounts. Reading the update-check counts always needs it.
`CLOUDFLARE_PAGES_PROJECT` overrides the project name, which defaults to `vibe`.
`ARGS="--wrangler-login"` uses this machine's `wrangler login` instead of the
token.

That token stays out of CI on purpose. Any workflow change can read a
repository secret, and publishing a static site should not need a standing
credential in a shared place. So `deploy-web.sh` refuses to run when `CI`,
`GITHUB_ACTIONS`, `GITLAB_CI` or `BUILDKITE` is set. GitHub Pages is the copy CI
publishes, because its workflow needs no secret at all.

The Pages project has to exist once before the first deploy:

```bash
npx wrangler pages project create vibe --production-branch main
```

Then attach `vibeplayer.app` under the project's Custom
domains. With the zone in the same account, Cloudflare writes the CNAME and
issues the certificate itself.

### Asset caching

Run `scripts/web/web-stamp-assets.sh` after changing the stylesheet or images.
It puts each file's content hash in its local `src`, `href` and `srcset` URLs.
A changed asset gets a new URL. Unchanged assets keep their cached copies.
Deployment runs the stamp script with `--check` and refuses stale references.

Cloudflare cache rules and the old-domain redirect are configured outside this
repo. Check the zone configuration when changing them. No cache rule may cover
the update feeds (Update checks, below).

## Update checks

The Mac direct download checks `appcast.xml` (or `appcast-arm64.xml`) once a
day by default. On Cloudflare each check runs a Pages Function,
`functions/appcast.xml.js`. It writes one Workers Analytics Engine row and
then serves the static feed unchanged. GitHub Pages runs no Functions.
Sparkle reads the feed only from vibeplayer.app.

The Function counts only Sparkle's requests. It knows them by Sparkle's
User-Agent, `Vibe/<version> Sparkle/<version>`. The User-Agent also names the
version of a build that sends no parameters. The app adds the other columns as
query parameters (`feedParametersForUpdater:` in
`Vibe/Mac/App/AppDelegate+Updates.m`). It writes no IP address and no
identifier.

| Column | Value | Source |
| --- | --- | --- |
| `blob1` | `universal` or `arm64`, the feed | the path |
| `blob2` | the app version, such as `1.16-beta5` | the User-Agent |
| `blob3` | the macOS version, such as `15.4` | `os` |
| `blob4` | `arm64` or `x86_64`, the running slice | `arch` |
| `blob5` | `beta` or `stable` | `channel` |
| `blob6` | the two-letter country | Cloudflare's `request.cf.country` |
| `blob7` | the language Vibe runs in, such as `de` or `pt-BR` | `lang`, else the first `Accept-Language` tag |
| `blob8` | `1` on the copy's first check in the UTC day, else empty | `d` |
| `blob9` | `1` on the copy's first check in the ISO week, else empty | `w` |
| `blob10` | `1` on the copy's first check in the UTC month, else empty | `m` |

**The three flags count active copies without an identifier.** The app
remembers the day, ISO week, and month of the last check whose feed loaded. A
check in a new period sets that period's flag. A check that fails offline
saves nothing, so the next check flags the same periods.

**A failed count must never fail the feed.** Every installed copy reads it.
So the Function catches its own errors and always serves the file. With no
binding it records nothing. A preview deployment is unbound and counts
nothing.

**TRAP: no cache rule may cover `/appcast.xml` or `/appcast-arm64.xml`.**
Cloudflare serves a cached response before the Function runs. A cached check
goes uncounted. Both feeds should answer `cf-cache-status: DYNAMIC`:

```bash
curl -sI https://vibeplayer.app/appcast.xml | grep -i cf-cache-status
```

**The privacy policy lists every column.** Adding one means changing
`privacy/index.html` in the same commit.

### One-time setup

This is done in the Cloudflare dashboard, and only once.

1. Workers & Pages → `vibe` → Settings → Bindings → Add → Analytics Engine.
   Set the variable name to `UPDATE_CHECKS` and the dataset to
   `vibe_update_checks`, for Production only. Cloudflare creates the dataset
   on the first write.
2. Under the project's Functions settings, confirm that the failure mode for
   the daily request limit is fail open. It is Cloudflare's default. Then a
   request over the Workers Free limit still gets the static feed, uncounted.
3. Deploy again (`make deploy-web`). A binding applies only to deployments
   made after it was added.
4. Send one test check, and look for it in a minute or two (Reading the
   counts, below):

   ```bash
   curl -s -o /dev/null -w '%{http_code}\n' -A 'Vibe/0-test Sparkle/2.10.0' \
       'https://vibeplayer.app/appcast.xml?os=0.0&arch=test&channel=test'
   ```

   Filter it out of later queries with `WHERE blob2 != '0-test'`.

### Reading the counts

Queries go to the Analytics Engine SQL API. They need a second token with
exactly one permission, **Account | Account Analytics | Read**. Keep it apart
from the deploy token. Add it to `.release-env` as
`CLOUDFLARE_ANALYTICS_TOKEN`. The query URL also needs `CLOUDFLARE_ACCOUNT_ID`.
Set it even though deploying can work without it.

```bash
source .release-env
curl -s "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/analytics_engine/sql" \
    -H "Authorization: Bearer $CLOUDFLARE_ANALYTICS_TOKEN" \
    --data "SELECT blob2 AS version, SUM(_sample_interval) AS checks
            FROM vibe_update_checks
            WHERE timestamp > NOW() - INTERVAL '1' DAY
            GROUP BY version ORDER BY checks DESC"
```

Count with `SUM(_sample_interval)`, never `COUNT()`. Analytics Engine may
sample, and each row then stands for several checks. Group by `blob3`,
`blob4`, `blob5`, `blob6`, or `blob7` for macOS, architecture, channel,
country, or language. Group by `toStartOfInterval(timestamp, INTERVAL '1' DAY)`
for a daily trend.

`blob7` has two forms. A build that sends `lang` gives the localization Vibe
runs in, such as `de`. An older build gives its first Accept-Language tag,
such as `de-DE`. One language can then show as two rows until those builds
update.

Check for Updates… is counted too. Cloudflare sets how long it keeps the rows
(the Analytics Engine limits page).

Update downloads come from GitHub, not from this site. GitHub counts each
release asset's downloads. The `.zip` assets are the ones Sparkle downloads.
A person can also download them from the release page:

```bash
gh api repos/cmicali/vibe/releases --paginate \
    --jq '.[] | .tag_name as $t | .assets[] | select(.name | endswith(".zip")) | "\($t)  \(.name)  \(.download_count)"'
```

### Active installs

Each flag counts a copy once per period. Send these queries with the `curl`
command in Reading the counts. Monthly is the headline number:

```sql
SELECT formatDateTime(timestamp, '%Y-%m') AS month, SUM(_sample_interval) AS installs
FROM vibe_update_checks
WHERE blob10 = '1'
GROUP BY month ORDER BY month
```

Weekly groups by the ISO week, such as `2026-W42`, the same week the app uses:

```sql
SELECT formatDateTime(timestamp, '%G-W%V') AS week, SUM(_sample_interval) AS installs
FROM vibe_update_checks
WHERE blob9 = '1'
GROUP BY week ORDER BY week
```

Daily:

```sql
SELECT formatDateTime(timestamp, '%Y-%m-%d') AS day, SUM(_sample_interval) AS installs
FROM vibe_update_checks
WHERE blob8 = '1'
GROUP BY day ORDER BY day
```

The timestamps are UTC, like the app's periods. `toStartOfWeek` starts weeks
on Sunday, so it does not match the app's weeks.

The three numbers have limits.

- **Monthly is the reliable count.** It misses copies set to Never. A copy
  set to Monthly checks every 30 days, so it can skip a calendar month.
- **Weekly counts a copy set to Monthly only in the week it checks.**
- **Daily is a lower bound.** Sparkle's daily interval is 24 hours since the
  last check, not a calendar day. A copy used only in the hours before its
  next check is not counted that day. A copy set to Weekly or Monthly is
  counted only on the days it checks.
- **A period's number is final only after the period ends.**
- **Older builds send no flags.** They check weekly by default. Their checks
  over the last 7 days approximate the old copies active that week. Use the
  version query with `INTERVAL '7' DAY` and read the versions without flags.
  An old copy set to Daily counts once per check.

## App Store Connect

The three URL files under `Assets/app-store/copy/` upload to every locale and
both platforms with `make appstore-upload-metadata`:

| File | Value |
| --- | --- |
| `marketing-url.txt` | `https://vibeplayer.app` |
| `support-url.txt` | `https://vibeplayer.app/support` (a `_redirects` 301 to the GitHub issues) |
| `privacy-url.txt` | `https://vibeplayer.app/privacy` |

What is published and what is canonical differ on purpose. The page lives at
`/privacy/`, because it is a directory (above), and both hosts redirect
`/privacy` onto it with a 308 or 301. So `rel=canonical` names `/privacy/`, the
URL that answers 200. Everything **published** uses the cleaner `/privacy`,
which crawlers and App Review follow through the one hop.
