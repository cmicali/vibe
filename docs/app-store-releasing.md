# Releasing Vibe to the App Store

The whole cycle, from a clean checkout to a submitted release:

```bash
make setup                                    # once per machine: brew bundle (xcodegen, jq, gh)
#  …write .release-env (once per machine, §1)…
#  …bump the version in project.yml (§2)…
make appstore-validate-copy                   # copy present, within ASC limits, captions fit
make appstore-generate-store-screenshots-all  # regenerate localized macOS screenshots (§3)
make appstore-upload-metadata \
    ARGS="--create-version 1.16"              # first run of a cycle opens the new version (§4)
make appstore-build                           # macOS: build + validate (no upload)
make appstore-upload-signed-build             # macOS: build + validate + upload
make appstore-build-ios                       # iOS: build + validate (no upload)
make appstore-upload-signed-build-ios         # iOS: build + validate + upload
#  …then in App Store Connect: attach the build and submit (§5)
```

**The `vibe-release` skill (`.claude/skills/vibe-release/SKILL.md`) is the reference for every release path.** It covers the Developer ID path, the three paths side by side, Universal Purchase and the per-platform version records, the shared API key and its Admin role, the signing traps, the Mac App Store build's missing updater, the iOS postflights, TestFlight betas, the product-page metadata loop and its traps, and what `UPLOAD SUCCEEDED` means. This page is the App Store runbook around it.

## 1. One-time setup

**Apple side**, once per team:

- An active Apple Developer Program membership on team `4UEV752JH4`.
- An app record in App Store Connect for `com.commonwealthrecordings.Vibe`, **with the platform being uploaded added to it**. ASC rejects an upload for a bundle id with no record, or for a platform not on the record.
- For iOS, a multi-platform App ID (`platform=UNIVERSAL`, which it becomes with the first signed iOS build) with the **App Groups** capability granting `group.com.commonwealthrecordings.Vibe`.
- An App Store Connect API key with the **Admin** role: Users and Access → Integrations → App Store Connect API → Team Keys → ＋. A key's role cannot be changed after creation, so make a new key if yours is wrong. Download `AuthKey_<KEYID>.p8` at once. Apple offers it only once.

**Local machine**, once per machine:

- `make setup` installs the dev tools from the Brewfile.
- Put the key at `~/.appstoreconnect/private_keys/AuthKey_<KEYID>.p8`.
- Write a `.release-env` at the repo root. It is gitignored, and it points at the key rather than holding it:

  ```
  ASC_KEY_ID=XXXXXXXXXX
  ASC_ISSUER_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
  ```

  Optional overrides, in `.release-env` or the environment: `ASC_KEY_PATH` if the `.p8` lives elsewhere, and `TEAM_ID` for another team. `scripts/asc-auth-lib.sh` resolves the key for every release script. No certificate or provisioning profile is made by hand. The first archive and export create them through `-allowProvisioningUpdates`.

## 2. Bump the version

`project.yml` is the source of truth. The export sets `manageAppVersionAndBuildNumber: false`, so Xcode cannot bump the build number at upload. Both numbers live in the `vibe-version` setting group, which both app targets pull in:

- `MARKETING_VERSION` is the store-visible version (`1.16`).
- `CURRENT_PROJECT_VERSION` is the build number. Every upload for a version needs a higher one.

Then open a version record carrying that same string on each platform you ship. `scripts/release-appstore.sh` reports the version read from the archived app's `Info.plist`, so what it prints is what it ships. Commit the bump before releasing, so `VIBE_GIT_DIRTY` stays clean.

## 3. Localize the assets

Everything the product page shows lives in `Assets/app-store/`. Its `README.md` is the reference for the file layout, the ASC limits, the caption rules, the screenshot commands and adding a language. Edit the copy for every catalog language and both platforms. Then run `make appstore-validate-copy` and regenerate the screenshots if the captions or captures changed.

## 4. Upload the product page

`make appstore-upload-metadata` writes one platform's page per run: `--platform macos` by default, `ARGS="--platform ios"` for the other. The skill has the flags and the traps.

The uploader writes only to an **editable** version: Prepare for Submission, or a rejected state. Once a release goes live, none exists, so the first upload of each cycle passes `--create-version <MARKETING_VERSION>`. Forgetting it is harmless: the run stops at "need exactly one editable macOS version" and lists every version's state. If a version is already editable, a *different* string errors rather than opening a second page. Later runs need no flag. The version made here is the same record the §5 build attaches to, so this step can run before or after §5.

**Release notes are not a field on a platform's first version.** ASC answers `Attribute 'whatsNew' cannot be edited at this time` and fails the run at its first locale, having written nothing. The tool sees that the platform has no other version, leaves the attribute out, and prints that `whats-new.txt` is not uploaded for that platform. Under Universal Purchase this is the normal case for a newly added platform.

## 5. Deploy the build

```bash
make appstore-build                    # macOS: archive → signed .pkg → ASC validation
make appstore-upload-signed-build      # macOS: same, then upload
make appstore-build-ios                # iOS:   archive → signed .ipa → ASC validation
make appstore-upload-signed-build-ios  # iOS:   same, then upload
```

One script serves both, `scripts/release-appstore.sh`, defaulting to macOS and taking `--platform ios`. Validation runs the same checks as upload, so the non-uploading target is a safe full rehearsal. The output lands in `build/appstore` or `build/appstore-ios`. Everything that differs per platform is set once, in a `case` at the top of the script. A macOS bundle nests its `Info.plist` and executable under `Contents/` and an iOS one does not, and the script reads the right depth for each.

Processing takes a few minutes after upload. The build then shows under the app's TestFlight tab and the version's Build section. To poll for it:

```bash
curl -s -g -H "Authorization: Bearer $TOKEN" \
  "https://api.appstoreconnect.apple.com/v1/builds?filter[app]=<appId>&limit=5&sort=-uploadedDate" \
  | jq -r '.data[] | "\(.attributes.version) \(.attributes.processingState)"'
```

The rest is manual, in App Store Connect:

1. On the version page, attach the processed build.
2. Check What's New, which §4 uploaded from `whats-new.txt`.
3. Submit for review.

### What the reviewer sees

This is the likeliest rejection. Vibe bundles no music. A reviewer opening the iOS app for the first time sees an empty playlist and no obvious way forward.

**`Assets/app-store/review-notes.txt` is the explanation.** Paste it into App Review Information → Notes, and into TestFlight's Beta App Review Information. Nothing uploads it. It explains the empty first launch, the four ways to get audio in, the formats, why the widget draws a placeholder until the app has played once, background audio, and the privacy answer.

**Attach `Assets/app-store/Vibe-sample-track.mp4`**, so a reviewer never has to find audio of their own.

> **Attaching it can silently fail.** ASC uploads an attachment in three steps: reserve a slot, PUT the bytes, and PATCH to commit with a checksum. A browser that completes only the first leaves a record with the right name and size but `uploaded=null`, no `sourceFileChecksum`, and `assetDeliveryState.state = AWAITING_UPLOAD`. Submission is then blocked by "There are still attachment uploads in progress" for good. Check the state before concluding the attachment is fine. The reservation's PUT slot stays open, so the upload can be completed over the API rather than deleted and added again.

Review will exercise `UIBackgroundModes: [audio]`. Verify lock-screen controls and playback with the screen off on a real device, not the simulator. Exercise the widget on a **clean install**. The app-group container is empty until the app has published once, which is exactly the state a reviewer hits.

### Privacy manifests

`Resources/PrivacyInfo.xcprivacy` is a resource of both app targets. It declares three required-reason API categories (file timestamps, `UserDefaults` and system boot time), no collected data and no tracking.

**`VibeWidget.appex` carries no manifest of its own, on purpose.** It uses no required-reason API. It resolves the app-group container, enumerates it with `includingPropertiesForKeys:nil` and reads a plist, and none of those are on Apple's lists. Copying the app's manifest into it would declare three categories the widget does not use.

Re-check this when the widget grows. Reading a shared setting (`NSUserDefaults initWithSuiteName:`) is the likely addition, and it is a required-reason API. Apple's scan runs after upload and reports a missing declaration by email (ITMS-91053), which costs a whole upload cycle.

## 6. After approval

Release the version, or let auto-release do it. The version stops being editable at submission, so a later metadata fix means `--create-version` on the next version. The next cycle starts at §2.

## Troubleshooting

Signing, credential and upload errors are in the skill: "Cloud signing permission error", "credentials not configured" in a worktree, an absent build after `UPLOAD SUCCEEDED`, and an empty `curl` reply.

- **"carries no VibeWidget.appex executable"**: the iOS export produced an app with no widget. Check that `VibeWidget` is still a dependency of the `VibeiOS` target in `project.yml`.
- **"the embedded distribution profile does not grant …"**: App Groups is missing from the App ID, or the profile predates it. Enable it in the Developer portal (§1) and re-run. Cloud signing regenerates the profile.
- **"need exactly one editable macOS version"** from `appstore-upload-metadata`: either no version is open (pass `--create-version`) or two are (finish or discard one in ASC).
- **Version or build already used** at upload: bump `CURRENT_PROJECT_VERSION` in `project.yml` (§2).
- **`appstore-validate-copy` failures** name the language, file and limit. Fix the copy, not the check.
- **"Attribute 'whatsNew' cannot be edited at this time"**: the platform's first version takes no release notes (§4). The uploader handles this itself, so seeing it means its check was wrong. Check whether the platform really has an earlier version record.
- **"There are still attachment uploads in progress"** blocking submission: an App Review attachment stuck in `AWAITING_UPLOAD` (§5, What the reviewer sees). It never resolves on its own.
- **`codesign -d --entitlements` prints an empty dict** for a simulator build. That reads the *signature*, and a simulator build carries its entitlements in the binary's `__TEXT,__entitlements` section instead. To check the app group works, ask whether `simctl get_app_container <udid> <bundle-id> groups` resolves.
