# Assets/Web

The Vibe marketing page: static HTML, one stylesheet, and images. There is no
build step and nothing to install. Copy the folder to any static host and it
works.

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
| `img/player.{png,webp}` | `Assets/screenshot-basic.png` |
| `img/ios.{png,webp}` | `Assets/screenshot-ios-iphone-player.png`, corners rounded at the iPhone's own radius and scaled to 560px wide |
| `img/ios-playlist.{png,webp}`, `img/ios-seek.{png,webp}` | `Assets/screenshot-ios-iphone-{playlist,seek}.png`, framed like `ios` |
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
`Assets/Web` differs from `origin/main`, so push the change first.
`make deploy-web ARGS="--dry-run"` checks the download link and lists the files
without uploading, and needs no credentials.

## Credentials, and why Cloudflare is local-only

`deploy-web` reads `CLOUDFLARE_API_TOKEN` from the gitignored `.release-env` at
the repo root, the same file the App Store Connect keys live in. The token needs
exactly one permission: **Account | Cloudflare Pages | Edit**.
`CLOUDFLARE_ACCOUNT_ID` is optional. Wrangler resolves a single-account token by
itself, and the id is needed only for a token that can reach several accounts.
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

### The stylesheet's cache TTL

Pages serves HTML as `max-age=0` but everything else at four hours. It ignores
`Cache-Control` from `_headers` for its own assets, though it honours the rest
of that file. That has two consequences, and the second is the one that bites:

1. A browser pairs fresh markup with a four-hour-old stylesheet, so a layout
   change renders under the old rules and looks broken rather than stale.
2. Fixing the TTL at the edge only helps the *next* fetch. A browser already
   holding a copy under the old TTL will not ask again until it expires, so
   the fix appears not to work for hours.

Only changing the URL solves (2). `scripts/web/web-stamp-assets.sh` writes each
asset's content hash into the `?v=` on every page that references it. That
covers the stylesheet **and every image under `img/`**, so a changed file is a
changed URL and no cache is consulted. `deploy-web.sh` runs it with `--check`
and refuses to publish a mismatch.

Each image is hashed on its own rather than sharing one stamp, so changing a
single screenshot does not force every visitor to re-fetch the rest.

With the URL versioned, a given URL's bytes never change. So a Transform Rule
on the zone caches the stamped form for a year and the unstamped form not at
all:

    /styles.css?v=…   ->  public, max-age=31536000, immutable
    /styles.css       ->  public, max-age=0, must-revalidate

**An unstamped image is not merely a stale picture.** The CDN serves the new
bytes at once (`cf-cache-status: REVALIDATED`), while a browser that visited
before keeps drawing the old image for the rest of the four-hour TTL. That
reads as a deploy that silently failed. A second deploy changes nothing and
seems to confirm that wrong diagnosis.

### The old domain

`vibe.commonwealthrecordings.com` 301s to `vibeplayer.app`. The redirect is a
Redirect Rule on the `commonwealthrecordings.com` zone, not anything in this
repo:

    when   http.host eq "vibe.commonwealthrecordings.com"
    then   301 -> concat("https://vibeplayer.app", http.request.uri.path)
           preserve query string

It is a *dynamic* redirect, so the path carries over: `/privacy/` on the old
host lands on `/privacy/`, not the front page. The hostname has to keep
resolving through Cloudflare for the rule to fire. So it needs a proxied
placeholder record (`AAAA vibe -> 100::`) while it is detached from the Pages
project.

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
