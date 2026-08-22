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

`scripts/github-release.sh` runs it **before** creating the release, commits
that one file, and pushes — so the tag it then creates names a tree whose page
already points at the release. A failed push there is fatal, because nothing
has been published yet and a tag on an unpushed commit would dangle.

A draft release is skipped: its download is not public, and a draft creates no
tag until published, so there is no ordering to preserve.

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

Then attach `vibe.commonwealthrecordings.com` under the project's Custom
domains. With the zone in the same account, Cloudflare writes the CNAME and
issues the certificate itself.

## App Store Connect

The three URL files under `Assets/app-store/copy/` upload to every locale with
`make appstore-upload-metadata`:

| File | Value |
| --- | --- |
| `marketing-url.txt` | `https://vibe.commonwealthrecordings.com` |
| `support-url.txt` | `https://github.com/cmicali/vibe/issues` |
| `privacy-url.txt` | `https://vibe.commonwealthrecordings.com/privacy/` |

The privacy URL is not a version field — it lives on ASC's `appInfoLocalizations`,
per locale — but the uploader patches it there too, so it is not 29 identical
edits by hand. Note the trailing slash: `/privacy` 308-redirects to it, and the
page names the redirect target as its canonical URL.
