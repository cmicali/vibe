# Vibe links: share a remote track, open it in Vibe

**Status: planned 2026-10-08. The app half of Phases 2 and 3 is built as Open URL, on both platforms.** It plays an http or https link through the shared HTTP transfer and a `Links` root. It rewrites Dropbox and Google Drive share links to their bytes (`System/Remote/AGENTS.md`). What remains is the link service and its landing page (Phase 1), the `vibe://` scheme and universal links, and SoundCloud (Phase 4). Phase 0 is done but for two probes, and its results are under Phases. The SoundCloud token probe waits on decision 2. Apple's CDN check waits on Phase 1's deploy. The rest of this doc is the plan and the decisions it needs.

The workflow: paste a link into a form on vibeplayer.app. The link is a Dropbox share link, a direct file URL, or a SoundCloud track. The site answers a short link, `https://vibeplayer.app/p/<id>`. A person who taps it gets Vibe, open on that track, streaming it from where it lives. Nobody downloads a file first.

Two plans in this directory touch the same ground. [Dropbox shared links](dropbox-shared-links.md) is folder links through a signed-in Dropbox account. [Streaming from any source](streaming-any-source.md) generalizes the stream's writer. This plan takes one thing from each: a single file reached by a plain HTTP URL, with no account, on both platforms.

## What exists

- **A stream that plays before its download ends.** The Dropbox fetch writes a part file from byte 0, publishes a `CloudFileAvailability`, reads the file's tail by range beside the download, and the player opens on the head (`System/AGENTS.md`, `Audio/Loading/AGENTS.md`). Every wait can be interrupted. The engine, the coordinator and both shells see only the wait.
- **The transport is already plain HTTP.** `DropboxClient`'s streamed download and ranged read are `NSURLSession` tasks with a `Range` header, a resend ladder and a part file. Dropbox adds a bearer token and a `rev` check. Everything else is what any file server needs.
- **Both shells open a file URL.** The mac's `application:openURLs:` and the iOS scene's `openURLContexts:` funnel into one open. Neither accepts anything but a file URL today.
- **The site is static on Cloudflare Pages** (`Assets/Web/README.md`). Pages serves Functions and KV from the same project, so the short-link service needs no second host.

## What the listener gets

1. A tap on `vibeplayer.app/p/<id>` with Vibe installed opens Vibe. The track appears as a one-row playlist with its title, art and the loading bar, and starts playing once its head has arrived.
2. Without Vibe installed, the same tap lands on a page: the title, the art, an App Store button, a Download for Mac button, and the original link.
3. On the mac, the same link opens the same way, through a universal link or the `vibe://` scheme the page falls back to.

## The link service

**The link is a record, not a redirect.** `/p/<id>` answers a page for a browser and a small JSON document for the app. The record holds the original URL, its kind (Dropbox, direct, SoundCloud), the title and artwork URL found at creation, and the creation time. The app resolves the record to a playable URL itself. The service never proxies audio.

| Piece | Where | What it does |
| --- | --- | --- |
| `/share` | a static page in `Assets/Web` | One text field. Posts the URL to the function below and shows the short link with a copy button. |
| `POST /api/links` | a Pages Function | Classifies the URL, fetches its metadata, writes the record to KV under a random id, answers the short link. |
| `GET /p/<id>` | a Pages Function | A browser gets the landing page with Open Graph tags, the Smart App Banner meta tag and the App Clip meta tag. A request with `Accept: application/json` gets the record. |
| `/.well-known/apple-app-site-association` | a static file in `Assets/Web` | `applinks` for `/p/*` on the app, `appclips` for the clip. Served as JSON with no redirect. |

**Classification, in the function:**

- **Dropbox.** A `dropbox.com` link to a file (`/scl/fi/`, `/s/`). The record stores the share URL with `dl=1`. That URL answers a 302 to `dl.dropboxusercontent.com`, which serves the bytes with no account. Folder links are refused with a message. A folder is the Dropbox shared links plan's work and needs an account.
- **Direct.** Any `https` URL whose `HEAD` answers an audio content type, or whose path ends in a playable extension (`Common/PlayableExtensions`). The record stores it as given.
- **SoundCloud.** A `soundcloud.com` track URL. The function reads the title and art from SoundCloud's oEmbed endpoint, which needs no key. The record stores the track URL. The stream is resolved at play time (below).

**Abuse.** The form sits behind Cloudflare Turnstile and a per-IP rate limit. A record stores no submitter data. Only `https` targets are accepted. A direct link is accepted only when its content type or extension is audio, so the service cannot be made to hand out short links to anything else. Records expire after a year of no opens.

## The app's half: an HTTP track

**One new kind of remote placeholder, one new transfer writer, and no new source model.** A link's track is a file under a new `Links` directory in the app's support directory. The directory carries, in its xattr index as the Dropbox mirror does, the record: the id, the resolved URL, the title and the art URL. The file is a remote placeholder of the remote size. Everything downstream, the placeholder stat, the part file, the availability, the loading bar, the coordinator's claim, and the metadata parse by range, is unchanged.

| Where | Change |
| --- | --- |
| `CloudFileMaterializer` | The remote backend takes a second root. `setRemoteRoot:` becomes a registration a backend makes for its own root, and the dispatch picks the backend by which root the path lies under. The Dropbox mirror registers as it does now. |
| `DropboxClient` | The streamed download and the ranged read move into a shared HTTP transfer under `Vibe/System/`, with the part file, the resend ladder, the resume by `Range`, and the tail read. Dropbox's client keeps the authorization header, the `rev` check and the account. The link backend uses the same transfer with no header and an `ETag` or `Last-Modified` check in place of `rev`. |
| `NSURLUtil` | `isRemotePlaceholderFile:` answers for any registered root. |
| `VibeiOSAppDelegate`, `AppDelegate` (mac) | At launch, the link backend registers its root, fetch, read and availability beside the mirror's. The mac has no mirror and registers only the link backend. |
| `PlaybackController`, `AppDelegate` (mac) | A `https://vibeplayer.app/p/<id>` URL, from a universal link or a `vibe://p/<id>` scheme, fetches the record, resolves it to a URL and a size with one `HEAD`, writes the placeholder and the index, and opens the file as a single-file open. The track is named from the record's title. |
| `project.yml` | `CFBundleURLTypes` for `vibe://` on both targets. The Associated Domains entitlement for `applinks:vibeplayer.app` on both. The mac gains `com.apple.security.network.client`. |
| `VibeStrings.h` | The errors: a link that no longer answers, a folder link, a stream that needs a sign-in. `make strings`. |
| Debug | `open_link <url>` on both command tables. `VibeFakeCloud` or a stubbed `NSURLProtocol`, as `DropboxMirrorTests` use, serves a scripted file, so no test needs the network. |

**Resolving at play time.** A Dropbox or direct record resolves to its stored URL. A SoundCloud record asks the service, `GET /api/resolve/<id>`. The service holds the SoundCloud credentials. It requests the track's stream with its token and answers the signed CDN URL from the redirect. For a full track that URL is an HLS playlist, which the HTTP road cannot read (SoundCloud, below). The URL is time limited, so a replay after it expires resolves again. The app never holds a SoundCloud secret.

**Version.** A Dropbox direct link answers whatever is current. The transfer pins the first response's `ETag` and fails with the Dropbox client's changed-file error when a resend sees another, exactly as the `rev` check does.

**Range.** The tail read and the resume both need the server to honour `Range`. Phase 0 measures Dropbox and SoundCloud. A server that ignores it still plays: the download runs whole, the stream opens on its head for a format that needs no tail, and the loading bar shows the rest. An MP3 waits for its last 128 bytes, an index-last M4A for its index. That is the degraded row of the Dropbox shared links plan.

## SoundCloud

SoundCloud is the hard one, and it is a product decision before it is code.

- **The API needs a registered app, and registration needs a SoundCloud Artist Pro subscription** ([register an app](https://developers.soundcloud.com/docs/api/register-app)). Client credentials cover public playback and URL resolution with no user sign-in ([API guide](https://developers.soundcloud.com/docs/api)). Play stream requests are capped at 15,000 a day per app ([rate limits](https://developers.soundcloud.com/docs/api/rate-limits)).
- **A full track streams as HLS AAC only.** SoundCloud removed the progressive MP3, HLS MP3, and HLS Opus streams after 31 December 2025 ([the deprecation notice](https://developers.soundcloud.com/blog/api-streaming-urls)). What remains is `hls_aac_160_url`, `hls_aac_96_url`, and `preview_mp3_128_url`. The preview is a 30 second MP3. Vibe has no HLS reader, so the HTTP road cannot play a full SoundCloud track. Many tracks answer only the preview, and some answer no stream at all.
- **Every streams request needs the token.** The 401 in [soundcloud/api#478](https://github.com/soundcloud/api/issues/478) came from fetching a URL that `/streams` returned without the token. SoundCloud's answer was that those requests must stay authenticated, and the issue closed in January 2026. An authenticated request answers a redirect to a signed CDN URL that needs no token. Its expiry follows the track's length. In the same thread a SoundCloud engineer wrote that playback without a user sign-in may be deprecated later.
- **The terms require attribution and forbid caching.** The track row shows the SoundCloud name and links to the track page. The part file is deleted at the end of the play, not kept under the download budget.

The oEmbed endpoint needs no key, so title and art work for every SoundCloud link whether or not the stream does. A record whose stream cannot be resolved lands on the page with the title and a button to SoundCloud, and the app shows the same.

Other services (Bandcamp, Mixcloud, YouTube) are not planned. Each has its own API terms, and none offers a plain audio URL to a third party.

## The App Clip

The bonus: play a link without installing Vibe.

**What it would be.** A second iOS target, `VibeClip`, built from `Audio/`, `Common/`, `Playlist/`, `System/`, `Util/` and one screen. It invokes from the same `/p/<id>` link, reads the record, streams the file through the same HTTP backend, and offers the full app. The 50 MB limit for a link invocation (iOS 17 and later) is room enough for the engine and its three decoders. Messages shows the clip's card from the App Store Connect default experience, not per link ([supporting invocations from your website and the Messages app](https://developer.apple.com/documentation/appclip/supporting-invocations-from-your-website-and-the-messages-app)).

**Why it is not in this plan's first cut.** An App Clip cannot use Background Modes ([choosing the right functionality for your App Clip](https://developer.apple.com/documentation/appclip/choosing-the-right-functionality-for-your-app-clip)). The audio stops when the screen locks or the person switches apps. A music player that stops at the lock screen is a demo, not a player. It is also a fourth target that recurses the shared subsystem directories, so `check-layout`'s assertion that the top of `Vibe/` is in both app targets becomes three, and every shared file must build without `UIKit`'s app-only pieces.

The landing page without the clip is one tap from the App Store and a second tap on the same link afterwards. Build the clip only if that proves to lose people, and only once the full app's link road is in users' hands. The record, the AASA file and the HTTP backend are the same either way, so nothing built here is thrown away.

## Phases

### Phase 0: probe, no app code

An afternoon with `curl`, recorded in this document.

- A real Dropbox file link with `dl=1`: the redirect chain, `Accept-Ranges`, a `Range` request answering 206, `ETag` across two requests, and whether a password or expired link answers a status the app can name.
- SoundCloud: register the app, mint a client credentials token, resolve a public track, request its streams, and fetch the progressive URL with a `Range` header. Note the expiry and whether the 401 issue reproduces.
- Cloudflare Pages Functions and KV on the `vibe` project: a function answering `/p/<id>` beside the static tree, and `deploy-web.sh` still deploying both.
- The AASA file served from `vibeplayer.app/.well-known/` with the right content type and no redirect, checked with Apple's CDN validator.

**Results, 2026-10-08.** The SoundCloud probes ran without a token. The Cloudflare probes ran locally and on a preview branch of the `vibe` project, never on production. The Dropbox probes ran on the maintainer's own links.

| Probe | Result |
| --- | --- |
| Dropbox file link | Run on a 21 MB FLAC. `dl=1` answers a 302 to `dl.dropboxusercontent.com`, with a new host and path on every request. That host answers `Range` with 206 and `Content-Range`, from byte 0 to a 128-byte suffix. The `ETag` is the same across requests and across fresh redirects. It is unquoted, so the transfer compares it as an opaque string. |
| Dropbox `If-Range` | Ignored. A wrong `ETag` in `If-Range` still answers 206 with the requested bytes. So the transfer must check the `ETag` of every response itself, as Version (above) says. |
| Dropbox type and name | Not usable. A GET answers `application/binary`, and a HEAD answers `application/json`. `Content-Disposition` names the file `unspecified`. So a Dropbox link is classified by its host, and the track's name and extension come from the share link's path. |
| Dropbox password link | Without the password, a 302 to `www.dropbox.com/sm/password…`, then a 200 HTML page. The app can name it from the redirect's path. |
| Dropbox deleted link | A 200 HTML page on `www.dropbox.com`, with no redirect. A good link always ends on `dl.dropboxusercontent.com`. So any other final host means the link is gone. |
| Dropbox redirect lifetime | One redirect URL answered 206 at once, after 5 minutes, and after 20 minutes, despite `Cache-Control: max-age=60`. Its full lifetime was not measured. So a resend reuses it, and a resend that fails on it starts again from the share link. |
| Dropbox changed file | Run on a throwaway 15 MB MP3 with an ID3v1 tail. The owner copied another file over it in Finder, through the Dropbox desktop client. The share link did not survive. It answered the "File Deleted" page, the same as a deleted link. A redirect URL taken before the replace still answered 206 with the old bytes, the old size, and the old `ETag`. A replace through the Dropbox website was not tried. |
| Google Drive file link | Run on a shared 55 MB WAV, 2026-10-09. The app rewrites `drive.google.com/file/d/<id>/view` to `drive.usercontent.google.com/download?id=<id>&export=download&confirm=t`. `confirm=t` skips the virus-scan page for a large file. A 16-byte range answers 206, `Content-Range` with the total, `Accept-Ranges: bytes`, `audio/wav`, and `Last-Modified`. It sends no `ETag`. The version is then `Last-Modified`. `Content-Disposition` carries the real file name, and the app names the track from it. |
| SoundCloud oEmbed | Works with no key. It answers the title, the author's name and URL, and a 500×500 JPEG `thumbnail_url`. A missing track answers 404. |
| SoundCloud API | Not run with a token. Registering an app needs Artist Pro ([register an app](https://developers.soundcloud.com/docs/api/register-app)). Without a token, `/resolve` answered 429 "Rate Limit Exceeded", not 401. The API guide caps client credentials tokens at 50 per 12 hours per app and 30 per hour per IP. So the resolve function must keep its token in KV and reuse it for its hour. |
| SoundCloud streams | Settled from SoundCloud's own sources. The API's schema for `/tracks/{urn}/streams` lists no progressive URL. Full tracks are HLS AAC only, and preview tracks keep a progressive MP3. The 401 issue is closed (SoundCloud, above). |
| Pages Functions | Run locally with `wrangler pages dev` (wrangler 4.148). A function at `functions/p/[id].js` answers `/p/<id>` beside the static tree. It answers JSON for `Accept: application/json`, HTML otherwise, and 404 for an unknown id. The static pages, the `/support` 301, and the `/download/latest` 302 are unchanged. The generated `_routes.json` includes only `/p/*`. So a static request never runs the function and does not count against the Workers request limit. |
| KV | The release token cannot reach KV. `wrangler kv namespace list` answers authentication error 10000, because the token has only Account, Cloudflare Pages, Edit. So the namespace was made in the dashboard and bound to the project there. The token can still read and change the project's bindings through the Pages API. A binding is per environment, Production or Preview. It reaches only deployments made after it is set. |
| Preview deploy | Run on the `links-probe` branch with `wrangler pages deploy` and the release token. The function read a record from KV and answered JSON or HTML, and 404 for an unknown id. The static pages, the `/support` 301, the `/download/latest` 302, and the `/privacy` 308 were unchanged. Production answered 404 for `/p/probe` throughout. The branch alias served the previous deployment on one request in three for a minute after a deploy. A deployment's own URL was always right, so a check after a deploy uses that URL. Both probe deployments are deleted. |
| `deploy-web.sh` | Not run. Wrangler looks for `functions/` in the directory it runs from, not in the directory it uploads. The preview deploy ran that way. Inside `Assets/Web` the functions would also upload as static files, and GitHub Pages would publish their source. So Phase 1 keeps them beside `Assets/Web`, and `deploy-web.sh` runs wrangler from their parent. |
| AASA | Today vibeplayer.app answers 404 for both AASA paths, with no redirect. Apple's CDN answers 404 for the domain. Pages serves the extensionless file as `application/octet-stream` by default. A `_headers` rule for the path makes it `application/json`, and the preview deploy answered that way with no redirect. Apple's CDN check needs the file on the production domain, so it waits for Phase 1's deploy. |
| App ID | The mac and iOS targets share one bundle id. So one AASA entry covers both: `4UEV752JH4.com.commonwealthrecordings.Vibe`. |

**What the results change.**

- SoundCloud's full tracks need an HLS reader, and Phase 4 assumed a progressive MP3. Without HLS, a SoundCloud link can play only its 30 second preview through the HTTP road. That makes decision 2 a question about HLS, not only about the subscription.
- Dropbox serves what the HTTP road needs: ranges, a suffix range, and a stable `ETag`. The degraded row in Range (above) does not apply to it.
- The link function classifies a Dropbox link by its host and takes the name from its path. The app names a password link and a deleted link by where the redirect lands, not by status.
- A file replaced in the desktop client ends its share link. So the usual outcome of a changed Dropbox file is a dead link, not a new `ETag`. The `ETag` check stays, for a replace that keeps the link.
- A redirect URL keeps serving the version it was issued for. So one play's resends reuse its redirect URL and read one version throughout. A new play starts from the share link.
- Phase 1's KV namespace is made in the dashboard, and bound for Production only when the functions ship.

### Phase 1: the service and the landing page

The form, the two functions, the KV namespace, the AASA file. Deployable and useful before the app changes: the landing page's original link opens Dropbox or SoundCloud in the browser. `deploy-web.sh` learns the functions directory and the KV binding. GitHub Pages serves the static tree only, with no functions, so `/p/` and `/share` are Cloudflare only, as `/download` is.

### Phase 2: the HTTP backend, shared

Move the transfer out of `DropboxClient` into `System/`. The Dropbox streaming tests, `dropbox-streaming.sh` and the PCM comparisons pass untouched. Done when a scripted file over a stubbed `NSURLProtocol` plays through the render pump sample-identical to the local open, seeks included.

### Phase 3: the link road, both platforms

The scheme, the universal link, the entitlements, the `Links` root, the open, the strings, the debug verb. Done when `open_link` on the simulator and on the mac plays a scripted file with the loading bar, and a device plays a real Dropbox link from Messages.

### Phase 4: SoundCloud, on Phase 0's evidence

The resolve function with the credentials in the Pages project's secrets, the attribution row, the deleted part. Phase 0 found that a full track is HLS AAC only. So this phase also needs an HLS reader, or it plays previews only.

### Phase 5: the App Clip, if asked for

## Complexity budget

| | New files | New types | New targets |
| --- | --- | --- | --- |
| Phase 1 | the form page, two functions, the AASA file | none in the app | none |
| Phase 2 | 0 | 0 | 0 |
| Phase 3 | 0 planned; the `Links` backend is a category on the shared transfer or a branch in the materializer, decided when Phase 2 shows the transfer's shape | 0 | 0 |
| Phase 4 | one function | 0 | 0 |
| Phase 5 | the clip's screen and entitlements | 1 | 1 |

**What it consolidates.** The streamed download and the ranged read leave `DropboxClient` for one shared HTTP transfer, and Dropbox becomes one caller of it with a header and a `rev` check. The remote backend stops being one root and becomes a registration, which the Dropbox shared links plan and the Google Drive study both need and neither has a home for today.

**Guarantees.** No new cross-directory guarantee. "The handle-open ceiling" holds: a link's open is a streaming open, cancellable at every wait, and the two-source bound is unchanged. "A row shows the loading bar only while a transfer is running" holds through the same registry. The mac's privacy promise does change, below.

## Costs

- **The privacy page says Vibe has no servers and the mac has no network entitlement** (`Assets/Web/privacy/index.html`). Both stop being true. The page, the App Store privacy label and the store copy must say that a Vibe link reaches vibeplayer.app for its record, and the mac reaches the link's host. The service stores no submitter data, and the app sends it nothing but the link's id.
- **A domain the links depend on.** A record that is gone is a link that is dead. KV records are kept for a year past their last open, and the Pages project is the one `deploy-web.sh` already publishes.
- **A link's bytes come from wherever the link points.** A Dropbox owner who revokes the link, or a SoundCloud artist who removes the track, ends every Vibe link to it. The app says which.
- **SoundCloud's terms and its stream limit.** The resolve function counts plays, and a day over the cap answers the page's SoundCloud button instead of a stream.

## Not doing

- **Proxying audio through vibeplayer.app.** It would make every play a cost on the service, put the service in the path of every byte, and turn the privacy page's "nothing passes through any server of mine" into its opposite.
- **Scraping SoundCloud's web client id.** It is the road most tools take, and it is against the terms, breaks on their schedule, and ends the App Store listing if noticed.
- **Playlists and folders by link.** A single track only. Folders are the Dropbox shared links plan.
- **Uploading a file to the service to share it.** Vibe is not a host.

## Decisions needed

1. **The privacy change** (Costs, first bullet). The feature does not exist without it.
2. **SoundCloud at all.** The costs are the Artist Pro subscription, the daily cap, and the preview-only tracks. A full track also needs an HLS reader that Vibe does not have. Without SoundCloud, Phase 4 is dropped and the form still accepts SoundCloud links for their page.
3. **The mac** in the first cut, or iOS first. The mac's share is the network entitlement and a URL scheme; the open road is otherwise the same code.
4. **The App Clip**, and whether a player that stops at the lock screen is worth a target.
5. **The short link's path.** `/p/<id>` here. `/t/`, `/l/` or `/play/` cost the same.
