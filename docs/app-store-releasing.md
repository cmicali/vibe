# Releasing Vibe to the App Store

The whole cycle, from a clean checkout to a submitted release:

```bash
make setup                                    # once per machine: brew bundle (xcodegen, jq)
#  …write .release-env (once per machine, see §1)…
#  …bump the version in project.yml (§2)…
make appstore-validate-copy                   # copy present, within ASC limits, captions fit
make appstore-generate-store-screenshots-all  # regenerate localized screenshots
make appstore-upload-metadata \
    ARGS="--create-version 1.8"               # FIRST run of a cycle: open the new
                                              # version, then upload copy + screenshots.
                                              # Later re-syncs: no ARGS needed (§4)
make appstore-build                           # macOS: build + validate (no upload)
make appstore-upload-signed-build             # macOS: build + validate + upload
make appstore-build-ios                       # iOS: build + validate (no upload)
make appstore-upload-signed-build-ios         # iOS: build + validate + upload
#  …then in App Store Connect: attach the build, What's New, submit (§5)
```

**Both apps ship under one bundle id**, `com.commonwealthrecordings.Vibe`.
That is Universal Purchase: ONE app record, with the name, subtitle, category,
age rating and privacy answers shared, and a **separate version train per
platform** under it. `project.yml` declares the version once for both targets
(§2), so a release cuts the same number on each — but each platform's version
record is opened, filled and submitted on its own, and neither waits for the
other.

This is the App Store path only. The direct-download path (`make release`:
Developer ID + notarize + staple) produces universal and arm64-only products
and uses a different certificate — see `scripts/release.sh` and the
`vibe-release` skill. That path is **macOS-only**; there is no direct download
for iOS, so the store is the only way the iOS app ships. The macOS App Store
build stays explicitly universal (`arm64` + `x86_64`) and the iOS one arm64;
none of the signing paths are interchangeable.

## 1. One-time setup

**Apple side** (once per team, mostly done already):

- An active Apple Developer Program membership on team `4UEV752JH4`.
- An app record in App Store Connect for `com.commonwealthrecordings.Vibe`,
  **with the platform being uploaded added to it**. Uploads for a bundle id
  with no record — or for a platform not on that record — are rejected.
- For iOS, the App ID in the Developer portal must be multi-platform
  (`platform=UNIVERSAL`, which it becomes the first time a signed iOS build is
  made) and must carry the **App Groups** capability granting
  `group.com.commonwealthrecordings.Vibe`. The widget draws nothing but what
  it reads from that container, so §5's export postflight refuses to ship a
  build whose distribution profile does not grant it.
- An App Store Connect API key with the **Admin** role:
  Users and Access → Integrations → App Store Connect API → Team Keys → ＋.
  Admin is required, not preferred: cloud-managed distribution certificates
  are Admin-gated, so an App Manager key authenticates and uploads fine but
  the signing export dies with a 403. A key's role cannot be changed after
  creation — if you have the wrong one, make a new key.
  Download `AuthKey_<KEYID>.p8` immediately; Apple offers it exactly once.

**Local machine** (once per machine):

- `make setup` installs the dev tools from the Brewfile.
- Put the key at `~/.appstoreconnect/private_keys/AuthKey_<KEYID>.p8`.
- Write a `.release-env` at the repo root (gitignored — it is a pointer to
  the key, not the key):

  ```
  ASC_KEY_ID=XXXXXXXXXX
  ASC_ISSUER_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
  ```

  Optional overrides: `ASC_KEY_PATH` if the `.p8` lives elsewhere, `TEAM_ID`
  if not the default. Resolution lives in `scripts/asc-auth-lib.sh`; every
  release script sources it, so this one file covers cloud signing,
  validation, metadata upload, and binary upload. No certificates or
  provisioning profiles need to be created by hand — the first archive/export
  creates them via `-allowProvisioningUpdates`.

## 2. Bump the version

`project.yml` is the source of truth — the export sets
`manageAppVersionAndBuildNumber: false` precisely so Xcode cannot silently
bump the build number at upload. Both numbers live in the **`vibe-version`
setting group**, which each app target pulls in, so there is one of each for
both platforms:

- `MARKETING_VERSION` — the store-visible version (e.g. `1.8`).
- `CURRENT_PROJECT_VERSION` — the build number; every upload for a given
  version needs a higher one.

Editing those two lines is the whole bump. They were per-target once, which is
how the iOS target sat at `1.0 (1)` while the mac shipped `1.10 (110)`.

**Then open a version record carrying that same string on each platform you
are shipping.** A build whose `CFBundleShortVersionString` does not match an
editable version record has nothing to attach to. The trap is a platform newly
added to the app record: ASC creates it at whatever version it likes — a fresh
iOS platform opened as `1.0` against a `1.12` build — and the mismatch only
surfaces when you go looking for the build on the version page.

`scripts/release-appstore.sh` reports the version it is uploading, read from
the **archived app's `Info.plist`** rather than from this file, so what it
prints is what it ships. Commit the bump before releasing so `VIBE_GIT_DIRTY`
stays clean.

## 3. Localize the assets

Everything the product page shows lives in `Assets/app-store/` (format
details: its README). `copy/<lang>/` is the tracked source of truth, one
directory per catalog language:

```
copy/<lang>/promotional-text.txt   one line, ≤170 chars
copy/<lang>/description.txt        plain text, uploads verbatim — no markdown
copy/<lang>/keywords.txt           one comma-separated line, ≤100 chars
copy/<lang>/screenshots.json       captions per shot, App Store display order
screenshots/<lang>/                generated 2880x1800 PNGs (en tracked, rest not)
```

**All of this is the macOS product page.** ASC localizations hang off a
*version*, and versions are per platform, so the iOS page needs its own
description, keywords, promotional text, what's-new and screenshots — and
neither `Assets/app-store/` nor the uploader carries them yet (`ASCUpload.swift`
filters `.platform([.macOS])` and writes the `APP_DESKTOP` screenshot set).
Until they do, **the iOS page is edited by hand in App Store Connect.**

Do not paste the macOS description into it. That copy sells BPM and key
analysis, the pitch fader and the FX rack, and says the formats are "decoded
by macOS" — all three features are macOS-only by construction (root
`CLAUDE.md`, "Three features are macOS-only"), and a product page describing
features the app does not have is a review rejection, not a cosmetic problem.

The app's string catalogs (`Resources/Localizable.xcstrings`) remain the
single source of *which* languages exist — `scripts/catalog-languages.sh`
reads the list, nothing hardcodes it. The uploader maps catalog codes to ASC
locales (`ascLocale` in `scripts/asc-upload/Sources/asc-upload/ASCUpload.swift`);
a language the store has no product page for maps to nil and is skipped with
a warning (`bg` ships in-app only).

After editing copy or captions, or when the app UI changed:

```bash
make appstore-validate-copy                         # limits, structure, captions fit the layout
make screenshots                                    # ONLY if the UI changed: re-capture windows
                                                    # (debug build + Screen Recording permission)
make appstore-generate-store-screenshots-all        # composite every language's screenshots
make appstore-generate-store-screenshots LOCALE=de  # …or just one while iterating
```

The overlay step is cheap and headless — every language shares the same
English window captures (the window shows only song titles and artwork), so
only the caption text differs. A missing translation fails loudly rather than
shipping English captions silently.

**Adding a language**: localize the app first (`make strings`, fill the
catalogs), then add `Assets/app-store/copy/<lang>/`, and extend `ascLocale`
if the tool asks for a mapping. `make appstore-validate-copy` will hold the door
until the copy is complete.

## 4. Upload the product page (macOS only)

`appstore-upload-metadata` targets the macOS version train and nothing else —
see §3 for what that means for the iOS page.

The uploader only ever writes to an **editable** macOS version — Prepare for
Submission or a rejected state. The moment a release goes live, no such
version exists, so the *first* metadata upload of every cycle must open the
next version's page explicitly. Use the same version string you put in
`MARKETING_VERSION` (§2):

```bash
make appstore-upload-metadata ARGS="--create-version 1.8"        # first run of the cycle
```

Forgetting it is harmless: the run stops at "need exactly one editable macOS
version" with every version's state listed, and nothing is uploaded. The flag
is also idempotent-by-refusal — if a version is already editable, passing a
*different* string errors rather than opening a second page.

Once the version exists (created here, or by hand in ASC), every later run
re-syncs edits without any flag:

```bash
make appstore-upload-metadata                                    # everything
make appstore-upload-metadata ARGS="--dry-run"                   # preview, upload nothing
make appstore-upload-metadata ARGS="--locales de,fr"             # narrow to some locales
make appstore-upload-metadata ARGS="--skip-screenshots"          # text only
make appstore-upload-metadata ARGS="--skip-text"                 # screenshots only
```

`make appstore-validate-copy` runs first automatically. The tool
(`scripts/asc-upload/`, Swift + Bagbutik, built on demand) PATCHes text
fields only when they differ; screenshots replace the locale's desktop set
wholesale, ordered by file name. No build is involved, so this can run at any
point before submission, in either order relative to §5 — the version created
here is the same record the §5 build attaches to.

## 5. Deploy the build

```bash
make appstore-build                    # macOS: archive → signed .pkg → ASC validation
make appstore-upload-signed-build      # macOS: same, then actually upload
make appstore-build-ios                # iOS:   archive → signed .ipa → ASC validation
make appstore-upload-signed-build-ios  # iOS:   same, then actually upload
```

One script serves both: `scripts/release-appstore.sh`, defaulting to macOS and
taking `--platform ios`. It regenerates the Xcode project, archives Release
unsigned (`CODE_SIGN_IDENTITY: "-"`, so everyday builds need no credentials),
exports re-signed via cloud signing, validates with App Store Connect, and with
`--upload` submits. Validation runs the same checks as upload, so the
non-uploading target alone is a safe full rehearsal.

What differs per platform is decided once, in a `case` at the top of the
script, and read from there by everything below:

| | `--platform macos` (default) | `--platform ios` |
|---|---|---|
| scheme | `Vibe` | `VibeiOS` |
| architectures | `arm64` + `x86_64`, asserted exactly | `arm64`, asserted exactly |
| signed with | Apple Distribution + Mac Installer | Apple Distribution |
| product | `Vibe.pkg` | `Vibe.ipa` (widget in `PlugIns/`) |
| build dir | `build/appstore` | `build/appstore-ios` |

**The bundle layout is the trap the script exists to absorb**: a macOS bundle
nests its payload under `Contents/`, an iOS one does not, so the same
`Products/Applications/Vibe.app` holds its `Info.plist` and executable at
different depths. The version it reports is read from the archived bundle, so
what it prints is what it ships, whichever platform that is.

After the iOS export, two postflights run on the `.ipa` — both check things
that do not exist until the archive has been re-signed for distribution, and
neither is visible anywhere earlier:

1. `PlugIns/VibeWidget.appex/VibeWidget` is present.
2. The embedded provisioning profile grants
   `group.com.commonwealthrecordings.Vibe`. A distribution profile that
   silently dropped the entitlement ships a permanently blank widget to every
   user; the decoded profile is left at
   `build/appstore-ios/embedded.mobileprovision.plist` when this fails.

Processing takes a few minutes after upload; the build then appears in App
Store Connect under the app's TestFlight tab and the version's Build section.

**The remaining steps are manual, in App Store Connect** (the API uploads
neither of these):

1. On the version page, attach the processed build.
2. Write the What's New text (source it from `CHANGELOG.md`).
3. Submit for review.

**Betas differ by platform.** macOS betas go out as GitHub prereleases from
the Developer ID path (the `vibe-release` skill); iOS has no such path, so an
iOS beta is TestFlight. Internal testing — the auto-created "App Store Connect
Users" group, anyone on the team, up to 100 — needs no beta review and is
available minutes after processing. External testing needs Beta App Review for
the first build of each version train, plus a beta description, a feedback
email and Beta App Review Information. Write that review information once: it
is the same content the App Store reviewer needs (below).

### What the reviewer sees

Worth stating because it is the likeliest rejection: Vibe bundles no music and
streams nothing, so a reviewer opening the iOS app for the first time sees an
empty playlist and no obvious way forward. The review notes have to say how to
get audio in — the Files tab, open-in-place from the share sheet, or dropping
a file into the Vibe folder in the Files app — and are worth a sample track.
`UIBackgroundModes: [audio]` is also a claim review will exercise: lock-screen
controls and playback with the screen off should be verified on a real device,
not the simulator.

## 6. After approval

Release the version (or let auto-release do it). The version stops being
editable at submission — later metadata fixes mean `--create-version` on the
next version. Then the next cycle starts at §2.

## Troubleshooting

- **"Cloud signing permission error"** during export — xcodebuild hides
  Apple's real 403 in a temp log; the script reprints it with guidance. It
  almost always means the API key is not Admin (§1).
- **"App Store Connect API credentials not configured"** from a script that
  worked yesterday — you are in a git worktree. `.release-env` is gitignored,
  so it exists only in the checkout you wrote it in. Release from the main
  checkout, or pass `ASC_KEY_ID` / `ASC_ISSUER_ID` in the environment.
- **"carries no VibeWidget.appex executable"** — the iOS export produced an
  app with no widget. Check that `VibeWidget` is still a dependency of the
  `VibeiOS` target in `project.yml`.
- **"the embedded distribution profile does not grant …"** — App Groups is
  missing from the App ID, or the profile predates it. Enable it in the
  Developer portal (§1) and re-run; cloud signing regenerates the profile.
- **"need exactly one editable macOS version"** from `appstore-upload-metadata` —
  either no version is open (pass `--create-version`) or two are (finish or
  discard one in ASC).
- **Version/build already used** at upload — bump `CURRENT_PROJECT_VERSION`
  in `project.yml` (§2).
- **`appstore-validate-copy` failures** name the language, file, and limit — fix the
  copy, not the check. A caption that "does not fit the layout" must be
  shortened; the compositor refuses to render text below 72% of nominal size.
- Signing/notarization details and the Developer ID path: the
  `vibe-release` skill (`.claude/skills/vibe-release/`).
