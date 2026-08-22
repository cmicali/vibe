# Releasing Vibe to the Mac App Store

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
make appstore-build                           # build + validate (no upload)
make appstore-upload-signed-build             # build + validate + upload the binary
#  …then in App Store Connect: attach the build, What's New, submit (§5)
```

This is the App Store path only. The direct-download path (`make release`:
Developer ID + notarize + staple) is a different product with different
certificates — see `scripts/release.sh` and the `vibe-release` skill. The two
are not interchangeable.

## 1. One-time setup

**Apple side** (once per team, mostly done already):

- An active Apple Developer Program membership on team `4UEV752JH4`.
- An app record in App Store Connect for `com.commonwealthrecordings.Vibe`
  (Apps → ＋ → New macOS App). Uploads for a bundle id without a record are
  rejected.
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

## 4. Upload the product page

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
make appstore-build                # archive → export signed .pkg → App Store validation
make appstore-upload-signed-build  # same, then actually upload
```

`scripts/release-appstore.sh` regenerates the Xcode project, archives Release
(unsigned — `CODE_SIGN_IDENTITY: "-"`, so everyday builds need no
credentials), exports re-signed with Apple Distribution + Mac Installer via
cloud signing, validates the `.pkg` with App Store Connect, and with
`--upload` submits it. Validation runs the same checks as upload, so `make
appstore-build` alone is a safe full rehearsal.

Processing takes a few minutes after upload; the build then appears in App
Store Connect under the app's TestFlight tab and the version's Build section.

**The remaining steps are manual, in App Store Connect** (the API uploads
neither of these):

1. On the version page, attach the processed build.
2. Write the What's New text (source it from `CHANGELOG.md`).
3. Submit for review.

## 6. After approval

Release the version (or let auto-release do it). The version stops being
editable at submission — later metadata fixes mean `--create-version` on the
next version. Then the next cycle starts at §2.

## Troubleshooting

- **"Cloud signing permission error"** during export — xcodebuild hides
  Apple's real 403 in a temp log; the script reprints it with guidance. It
  almost always means the API key is not Admin (§1).
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
