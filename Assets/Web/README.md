# Assets/Web

The Vibe marketing page: one static HTML file, one stylesheet, and images. No
build step, no dependencies, nothing to install — copy the folder to any static
host and it works.

```
index.html    the page
styles.css    the page's styles
img/          app icon renditions and screenshots
```

## Preview it

```bash
python3 -m http.server 4319 --directory Assets/Web
```

Then open <http://localhost:4319>. Opening `index.html` straight from the Finder
works too.

## Where the images come from

`img/` is generated from assets already in the repo, so it is regenerated rather
than edited:

| Output | Source |
| --- | --- |
| `img/icon-*.png` | `Resources/AppIcon.icon/Assets/` — the vinyl ground and the glass waveform, composited and masked to the rounded square |
| `img/player.png` | `Assets/screenshot-basic.png` |
| `img/playlist.png` | `Assets/screenshot-playlist.png` |

The screenshots carry the window's own rounded corners and a transparent margin,
which is why the page shadows them with `filter: drop-shadow` rather than
`box-shadow` — a box shadow would trace the image rectangle instead of the window.

## Copy

The wording is the App Store copy in `Assets/app-store/copy/en/` and the feature
list in `README.md`. Keep the two in step: the store listing is the version
Apple reviews.

## Where it is deployed

Both hosts serve this directory verbatim; there is no build step on either.

| URL | Host | Trigger |
| --- | --- | --- |
| <https://vibeplayer.app> | Cloudflare Pages | `make deploy-web`, run at release time. Canonical. |
| <https://cmicali.github.io/vibe/> | GitHub Pages | `.github/workflows/pages.yml`, on any push to `main` touching `Assets/Web/**`. |

The page names the Cloudflare URL as `rel=canonical`, so the GitHub Pages copy
does not compete with it in search results.

`privacy/` is a directory with an `index.html` rather than a `privacy.html`,
deliberately: that makes `/privacy` resolve on both hosts. GitHub Pages does not
serve extensionless URLs for a bare `.html` file, so `privacy.html` would have
been reachable at `/privacy` on Cloudflare and 404 on GitHub.

`README.md` uploads with everything else and is readable at `/README.md`. It is
already public in the repo, so that costs nothing.

## The Download button's version

The button links a **direct** `.dmg` URL, not `/releases/latest`, because it
also shows the version and the two must agree. GitHub's `latest/download`
shortcut cannot help: it only redirects for an asset name that never changes,
and the release assets are named `Vibe-macOS-<version>.dmg`.

So the link is rewritten instead. `scripts/web-set-version.sh <version>` edits
the four places in `index.html` that name a version — the button's `href` and
the label under it, keyed on the `dmg-link` and `dmg-version` element ids
rather than the markup around them, and the JSON-LD `softwareVersion` and
`downloadUrl` — plus the `/download` rules in `_redirects`, erroring rather
than silently doing nothing if any of them stops matching.

`scripts/github-release.sh` runs it **before** creating the release, commits
those two files, and pushes — so the tag it then creates names a tree whose
page already points at the release. A failed push there is fatal, because
nothing has been published yet and a tag on an unpushed commit would dangle.

A draft release is skipped: its download is not public, and a draft creates no
tag until published, so there is no ordering to preserve.

### The stable link

    https://vibeplayer.app/download/latest        # /download and /download/ too

is what anything outside this repo should link — a README, a forum post, a
`curl -L` — so an external link never has to be revisited for a release. It is
a `_redirects` rule pointing at the same URL as the button, written by the same
`web-set-version.sh` run, so the branded link and the button cannot come to
name different builds. `deploy-web.sh` refuses to publish if they disagree, and
that check runs even under `--skip-link-check`: no page displays where
`/download/latest` lands, so nothing else would ever reveal it going stale.

**302, never 301.** The target moves every release, and a browser that cached a
permanent redirect would keep fetching that one version forever with nothing on
this end able to correct it. `deploy-web.sh` checks the status code too.

Cloudflare only, like `/support` — GitHub Pages ignores `_redirects`, so the
path 404s on the non-canonical copy.

## Releasing, end to end

```bash
make release            # build, sign, notarize, staple -> build/release/Vibe.dmg
make github-release     # repoint the page, push it, then tag and publish
make deploy-web         # push the same page to Cloudflare
```

`make deploy-web ARGS="--dry-run"` checks the download link and lists the files
without uploading, and needs no credentials.

## Credentials, and why Cloudflare is local-only

`deploy-web` reads `CLOUDFLARE_API_TOKEN` from the gitignored `.release-env` at
the repo root, the same file the App Store Connect keys live in. The token needs
exactly one permission: **Account | Cloudflare Pages | Edit**.
`CLOUDFLARE_ACCOUNT_ID` is optional — wrangler resolves a single-account token
by itself, and the id is only needed to disambiguate one that can reach several.
`CLOUDFLARE_PAGES_PROJECT` overrides the project name, which defaults to `vibe`.

That token deliberately does not go into CI. A repository secret is readable by
any workflow change, and publishing a static site should not need a standing
credential in a shared place — so `deploy-web.sh` refuses to run when `CI`,
`GITHUB_ACTIONS`, `GITLAB_CI` or `BUILDKITE` is set. GitHub Pages is the copy CI
publishes, precisely because its workflow needs no secret at all.

The Pages project has to exist once before the first deploy:

```bash
npx wrangler pages project create vibe --production-branch main
```

Then attach `vibeplayer.app` under the project's Custom
domains. With the zone in the same account, Cloudflare writes the CNAME and
issues the certificate itself.

### The stylesheet's cache TTL

Pages serves HTML as `max-age=0` but everything else at four hours, and it
ignores `Cache-Control` from `_headers` for its own assets (it honours
everything else in that file). Two consequences, and the second is the one that
bites:

1. A browser pairs fresh markup with a four-hour-old stylesheet, so a layout
   change renders under the old rules and looks broken rather than stale.
2. Fixing the TTL at the edge only helps the *next* fetch. A browser already
   holding a copy under the old TTL will not ask again until it expires, so
   the fix appears not to work for hours.

Only changing the URL solves (2). `scripts/web-stamp-css.sh` writes the
stylesheet's content hash into the `?v=` on every page that links it, so a
changed stylesheet is a changed URL and no cache anywhere is consulted.
`deploy-web.sh` runs it with `--check` and refuses to publish a mismatch,
because that failure looks exactly like a deploy that did nothing.

With the URL versioned, a given URL's bytes never change, so a Transform Rule
on the zone caches the stamped form for a year and the unstamped form not at
all:

    /styles.css?v=…   ->  public, max-age=31536000, immutable
    /styles.css       ->  public, max-age=0, must-revalidate

Images keep the four-hour default on purpose: they are large, they change
rarely, and a stale one is only ever a stale picture.

### The old domain

`vibe.commonwealthrecordings.com` served this site before `vibeplayer.app` was
registered, and 301s to it now. The redirect is a Redirect Rule on the
`commonwealthrecordings.com` zone, not anything in this repo:

    when   http.host eq "vibe.commonwealthrecordings.com"
    then   301 -> concat("https://vibeplayer.app", http.request.uri.path)
           preserve query string

It is a *dynamic* redirect so the path carries over — `/privacy/` on the old
host lands on `/privacy/`, not the front page. The hostname has to keep
resolving through Cloudflare for the rule to fire, so once it is detached from
the Pages project it needs a proxied placeholder record (`AAAA vibe -> 100::`)
in its place.

## App Store Connect

The three URL files under `Assets/app-store/copy/` upload to every locale with
`make appstore-upload-metadata`:

| File | Value |
| --- | --- |
| `marketing-url.txt` | `https://vibeplayer.app` |
| `support-url.txt` | `https://github.com/cmicali/vibe/issues` |
| `privacy-url.txt` | `https://vibeplayer.app/privacy` |

The privacy URL is not a version field — it lives on ASC's `appInfoLocalizations`,
per locale — but the uploader patches it there too, so it is not 29 identical
edits by hand.

What is published and what is canonical differ on purpose. The page lives at
`/privacy/`, because it is a directory (see above), and both hosts 308 or 301
`/privacy` onto it. So `rel=canonical` names `/privacy/` — the URL that answers
200 — while everything **published** uses the cleaner `/privacy`, which every
crawler and App Review follows through the one hop without complaint.
