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
| <https://vibe.commonwealthrecordings.com> | Cloudflare Pages | `make deploy-web`, run at release time. Canonical. |
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
the two places in `index.html` that name a version, keying on the `dmg-link`
and `dmg-version` element ids rather than the markup around them, and erroring
rather than silently doing nothing if either stops matching.
`scripts/github-release.sh` calls it with the version it just published, then
commits and pushes that one file — so a release updates GitHub Pages by itself,
and `make deploy-web` carries the same change to Cloudflare.

A draft release is skipped: its download is not public yet, and `deploy-web`
refuses to upload a page whose button does not return 200.

## Releasing, end to end

```bash
make release            # build, sign, notarize, staple -> build/release/Vibe.dmg
make github-release     # publish; repoints the page and pushes it
make deploy-web         # push the same page to Cloudflare
```

`make deploy-web ARGS="--dry-run"` checks the download link and lists the files
without uploading, and needs no credentials.

## Credentials

`deploy-web` reads `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID` from the
gitignored `.release-env` at the repo root, the same file the App Store Connect
keys live in. The token needs exactly one permission: **Account | Cloudflare
Pages | Edit**. `CLOUDFLARE_PAGES_PROJECT` overrides the project name, which
defaults to `vibe`.

The Pages project has to exist once before the first deploy:

```bash
npx wrangler pages project create vibe --production-branch main
```

Then attach `vibe.commonwealthrecordings.com` under the project's Custom
domains. With the zone in the same account, Cloudflare writes the CNAME and
issues the certificate itself.

## Before it goes live

- `Assets/app-store/copy/marketing-url.txt` is what App Store Connect links to.
  Update it if this page replaces the current marketing URL.
- The App Store privacy policy URL should point at
  <https://vibe.commonwealthrecordings.com/privacy>.
