# Vibe links: share a remote track, open it in Vibe

**Status: Partly built.** The app's link road is built as Open URL on both platforms (`Loading/Net/AGENTS.md`). It plays an http or https link through the shared HTTP transfer and the `Links` root. It rewrites Dropbox and Google Drive share links to their bytes and looks up an iCloud Drive share link before each request. Not built: the link service and its landing page, the `vibe://` scheme and universal links, SoundCloud, and the App Clip.

The workflow: paste a link into a form on vibeplayer.app. The link is a Dropbox share link, a direct file URL or a SoundCloud track. The site answers a short link, `https://vibeplayer.app/p/<id>`. A tap on it opens Vibe on that track, streaming it from where it lives.

## What the listener gets

1. With Vibe installed, a tap on `vibeplayer.app/p/<id>` opens Vibe. The track appears as a one-row playlist with its title, art and the loading bar, and plays when its format has enough bytes to open.
2. Without Vibe, the tap lands on a page: the title, the art, an App Store button, a Download for Mac button and the original link.
3. On the mac, the link opens the same way, through a universal link or the `vibe://` scheme the page falls back to.

## The link service

**The link is a record, not a redirect.** `/p/<id>` answers a page for a browser and a small JSON document for the app. The record holds the original URL, its kind, the title and artwork URL found at creation, and the creation time. The app resolves the record to a playable URL itself, through Open URL's road. The service never proxies audio.

| Piece | Where | What it does |
| --- | --- | --- |
| `/share` | a static page in `Assets/Web` | One text field. Posts the URL to the function below and shows the short link with a copy button. |
| `POST /api/links` | a Pages Function | Classifies the URL, fetches its metadata, writes the record to KV under a random id, answers the short link. |
| `GET /p/<id>` | a Pages Function | A browser gets the landing page with Open Graph tags, the Smart App Banner and the App Clip meta tag. `Accept: application/json` gets the record. |
| `/.well-known/apple-app-site-association` | a static file | `applinks` for `/p/*`, and `appclips` for a clip. Served as JSON with no redirect. |

**Classification, in the function:**

- **Dropbox.** A `dropbox.com` file link (`/scl/fi/`, `/s/`). Classify by host and take the name from the link's path, since Dropbox answers `application/binary` and names the file `unspecified`. Folder links are refused. A folder is [Dropbox shared links](dropbox-shared-links.md)' work.
- **Direct.** An `https` URL whose `HEAD` answers an audio content type, or whose path ends in a playable extension (`Common/PlayableExtensions`).
- **iCloud Drive.** A `www.icloud.com/iclouddrive/<id>` file shared with anyone who has the link. Folder shares and invited-only shares are refused.
- **SoundCloud.** A `soundcloud.com` track URL. The function reads the title and art from SoundCloud's oEmbed endpoint, which needs no key.

**Abuse.** The form sits behind Cloudflare Turnstile and a per-IP rate limit. A record stores no submitter data. Only `https` targets are accepted. A direct link must have an audio content type or extension. Records expire after a year with no opens.

## The app's half

- `project.yml`: `CFBundleURLTypes` for `vibe://` on both targets, and the Associated Domains entitlement for `applinks:vibeplayer.app` on both.
- Each shell's open: a `https://vibeplayer.app/p/<id>` universal link or a `vibe://p/<id>` URL fetches the record, then opens its resolved URL as Open URL does. The track is named from the record's title.
- `VibeStrings.h`: errors for a link that no longer answers, a folder link and a stream that needs a sign-in. Run `make strings`.
- A debug verb that opens a `/p/<id>` link, over a stubbed `NSURLProtocol` so no test needs the network.

**Resolving at play time.** A Dropbox or direct record resolves to its stored URL. A SoundCloud record asks the service, `GET /api/resolve/<id>`. The service holds the SoundCloud credentials and answers the signed CDN URL. That URL expires, so a replay after it expires resolves again. The app never holds a SoundCloud secret.

## SoundCloud

SoundCloud is a product decision before it is code.

- **The API needs a registered app, and registration needs an Artist Pro subscription** ([register an app](https://developers.soundcloud.com/docs/api/register-app)). Client credentials cover public playback with no user sign-in. Play stream requests are capped at 15,000 a day per app ([rate limits](https://developers.soundcloud.com/docs/api/rate-limits)). Tokens are capped at 50 per 12 hours per app, so the resolve function reuses tokens until their reported expiry.
- **A full track streams as HLS AAC only** ([deprecation notice](https://developers.soundcloud.com/blog/api-streaming-urls)). The rest is a 30 second preview MP3. Vibe has no HLS reader, so the HTTP road can play only previews. Some tracks answer no stream at all.
- **Every streams request needs the token** ([soundcloud/api#478](https://github.com/soundcloud/api/issues/478)). The answer redirects to a signed CDN URL that needs none. SoundCloud has said playback without a user sign-in may be deprecated.
- **The terms require attribution and forbid caching.** The row shows the SoundCloud name and links to the track page. The part file is deleted at the end of the play.

Use oEmbed metadata when available. A track without a playable stream can still link to SoundCloud.

Bandcamp, Mixcloud and YouTube are not planned. None offers a plain audio URL to a third party.

## The App Clip

A second iOS target, `VibeClip`, built from the shared subsystems and one screen. It opens from the same `/p/<id>` link and offers the full app. A link invocation allows 50 MB, which fits the engine.

**Not in the first cut.** An App Clip cannot use Background Modes, so the audio stops at the lock screen. A music player that stops there is a demo. It also adds an app target over the shared directories. Update `check-layout` to check that target. Build it only if the landing page is shown to lose people.

## Implementation constraints

Use the current host-specific rules in `Vibe/Loading/Net/`. They own share-link rewriting, naming and error classification. Recheck provider behavior before building the service.

Keep Pages Functions outside the static tree. GitHub Pages serves only static files. Verify the KV binding and token permissions in each Cloudflare environment. Serve the AASA file as JSON without a redirect and check it through Apple's CDN on the production domain.

The macOS and iOS targets share `com.commonwealthrecordings.Vibe`. Confirm their signed application identifiers before writing the AASA entry.

## Phases

1. **The service and the landing page.** The form, the two functions, the KV namespace and the AASA file. Useful before the app changes, since the page's original link opens in the browser. Then run Apple's CDN check.
2. **The link road in the app.** The scheme, the universal link, the entitlements, the record fetch and the strings. Done when the debug verb plays a scripted file on the simulator and the mac, and a device plays a real Dropbox link from Messages.
3. **SoundCloud, on decision 2.** The resolve function with the credentials in the Pages project's secrets, the attribution row and the deleted part file. It needs an HLS reader, or it plays previews only.
4. **The App Clip, if asked for.**

**Budget.** Phase 1 adds the form page, two functions and the AASA file, and no app code. Phase 2 adds no files and no types. Phase 3 adds one function. Phase 4 adds a target, its screen and its entitlements. No new cross-directory guarantee: a link's open is Open URL's open.

## Costs

- **The privacy page says Vibe has no servers** (`Assets/Web/privacy/index.html`). A Vibe link reaches vibeplayer.app for its record. The page, the App Store privacy label and the store copy must say so. The service stores no submitter data, and the app sends it only the link's id.
- **The links depend on the domain.** A lost record is a dead link.
- **A link's bytes come from where it points.** A revoked Dropbox link or a removed SoundCloud track ends every Vibe link to it. Provider changes can invalidate a share link. The app must report the failure.
- **SoundCloud's terms and its stream cap.** Over the cap, the page answers its SoundCloud button instead of a stream.

## Not doing

- **Proxying audio through vibeplayer.app.** Every play would cost the service, and every byte would pass through a server.
- **Scraping SoundCloud's web client id.** It is against the terms, breaks on their schedule, and risks the App Store listing.
- **Playlists and folders by link.** A single track only.
- **Uploading a file to the service.** Vibe is not a host.

## Decisions needed

1. **The privacy change** (Costs, first bullet). The feature does not exist without it.
2. **SoundCloud at all.** The costs are Artist Pro, the daily cap and preview-only playback without an HLS reader. Without it, the form still accepts SoundCloud links for their page.
3. **The mac** in the first cut, or iOS first.
4. **The App Clip**, and whether a player that stops at the lock screen is worth a target.
5. **The short link's path.** `/p/<id>` here. `/t/`, `/l/` or `/play/` cost the same.
