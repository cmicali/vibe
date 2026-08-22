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

| URL | Host | How |
| --- | --- | --- |
| <https://vibe.commonwealthrecordings.com> | Cloudflare Pages | The Pages project watches `main` and publishes `Assets/Web`. Canonical. |
| <https://cmicali.github.io/vibe/> | GitHub Pages | `.github/workflows/pages.yml`, on any push to `main` touching `Assets/Web/**`. |

The page names the Cloudflare URL as `rel=canonical`, so the GitHub Pages copy
does not compete with it in search results.

`privacy/` is a directory with an `index.html` rather than a `privacy.html`,
deliberately: that makes `/privacy` resolve on both hosts. GitHub Pages does not
serve extensionless URLs for a bare `.html` file, so `privacy.html` would have
been reachable at `/privacy` on Cloudflare and 404 on GitHub.

## Before it goes live

- `Assets/app-store/copy/marketing-url.txt` is what App Store Connect links to.
  Update it if this page replaces the current marketing URL.
- The App Store privacy policy URL should point at
  <https://vibe.commonwealthrecordings.com/privacy>.
