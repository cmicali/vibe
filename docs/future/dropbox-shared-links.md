# Dropbox shared links on iOS: plan

Someone sends a Dropbox share link in Messages. The person receiving it listens in Vibe: no "copy to my Dropbox", no Dropbox app, the folder browsed and played where it is. Nothing here is built; this is the plan and the decisions it needs.

## What Dropbox allows

Read from Dropbox's published API spec (`dropbox/dropbox-api-spec`, `files.stone` and `shared_links.stone`), not yet run against a real link.

| Need | Endpoint | Notes |
| --- | --- | --- |
| What a link is | `sharing/get_shared_link_metadata` | Name, file or folder, and for a file its size, `server_modified` and `rev`. Scope `sharing.read`. |
| Browse a folder link | `files/list_folder` with `shared_link: {url}` | The call the mirror already makes. `path` is relative to the link; one level per call (no recursive mode), which is how the mirror lists anyway. |
| Play a file | `sharing/get_shared_link_file` with `{url, path}` | A download-style endpoint on the content host; its `Dropbox-API-Result` header carries the same size, `server_modified` and `rev` the client's version check reads. Scope `sharing.read`. |

**All three need a signed-in user.** None allows app-only access, so the listener needs a Dropbox account linked in Vibe. A free one works, and the link does not have to be theirs. Without an account the only thing reachable is a single-file link's `?dl=1` download; a folder link's `?dl=1` is a zip of the whole folder. That path is not planned (see Not doing).

## The listener's workflow

**Phase 2 (Share → Vibe):**

1. In Messages, long-press the link → Share… → Vibe.
2. A card confirms: "Open Vibe to listen". It closes on its own.
3. Open Vibe. The shared folder is on screen in the Files tab with its play button; a single-file link starts playing.

First time only: if no Dropbox account is linked, step 3 shows the sign-in sheet first ("Sign in to Dropbox to open shared links"), then continues to the folder.

**Why step 3 is a separate step.** A share extension is not allowed to open its app. `NSExtensionContext`'s `openURL:` works only for widgets, and `UIApplication` is marked unavailable in extensions. The workaround many apps use (walk the responder chain to the application object and call `open:` on it) still launched the app on iOS 26 in reports, but Apple's engineers call it unsupported, and it reaches an API the extension is told it may not use. It breaks this repo's no-private-API rule in spirit, and an App Review rejection or an OS update can remove it. The plan does not use it.

**Phase 3 (a Vibe link) is the one-tap version**, if the three steps above are not simple enough: the sender shares from Vibe, the listener taps the link and Vibe opens on the folder. It costs a domain and one more Dropbox permission; see Phase 3.

## Phase 0: probe a real link (an hour, no app code)

Enable `sharing.read` for the app key in the Dropbox App Console, sign in, and run the three calls with `curl` against a real folder link. The answers decide details below:

- **Does `get_shared_link_file` honour `Range`?** Dropbox documents range requests for its download-style endpoints in general, but nothing names this one. With it, a link's track behaves like any Dropbox track. Without it, a link's track still starts playing while it downloads, but three things degrade: an interrupted download starts over, tags and art appear only once a file has been downloaded, and a format that needs its end to open (an MP3's last 128 bytes, an M4A with its index last) waits for the whole download.
- **What a listing through a link carries.** The spec says `path_lower` is present only for files in the caller's own Dropbox, so entries are expected to have `name`, `size`, `server_modified` and `rev` but no path. The plan below assumes that.
- **The errors** for a revoked, expired, password-protected and team-only link, so each gets its own message.

## Phase 1: links in the mirror

Everything a listener can do, reachable by pasting a link. No new target, no new files, no new types.

**Where a link lives.** `Library/Application Support/Dropbox/<account id> links/<link name>/`, beside the account's own tree. Under the mirror root, so every existing rule covers it without change: `containsURL:`, the placeholder fetch, the ranged tag read, Recents, Favorites, restore after relaunch, and the playlist clear on sign-out. Beside the account tree and not inside it, because a listing of the account's root would delete a folder Dropbox does not name. `pruneOtherAccounts:` keeps the pair of directories for the linked account.

**The directory is the record.** A link directory's xattr index already holds its Dropbox path; it gains `link` (the URL) and its path is relative to the link. Its `files` map holds each file's name as Dropbox spelled it, where an account directory holds ids, because a link's file is downloaded by path and the rule that a name read back from disk is never sent to Dropbox still holds. A subfolder made by its parent's listing carries the link too. The list of links a user has added is the listing of the links directory: no store, no defaults key.

**The changes, each a branch in a method that exists:**

| Where | Change |
| --- | --- |
| `DropboxRules.h` | `sharing.read` joins `VIBE_DROPBOX_SCOPES`. One function recognises a Dropbox share URL (`dropbox.com` hosts, `/scl/fo/`, `/scl/fi/`, `/sh/`, `/s/`) and gives its comparable form (`dl` and `st` parameters dropped). |
| `DropboxClient` | `downloadPath:` and `readPath:` take the request's arguments, not a path string: `{path}` goes to `files/download` as now, `{url, path}` to `sharing/get_shared_link_file`. The failure ladder, resume, rev check and delegate session are untouched. A link's errors (revoked, expired, password, no access) get their own error code so the shell can say which. |
| `DropboxMirror` | `listFolder:` adds `shared_link` when the directory's index names a link. `downloadArgumentForURL:` answers the arguments dictionary. `reconcileDirectory:` composes a subfolder's path from its parent's when the entry has none. `downloadsUnder:` walks both trees, so the download budget and Remove Downloads count link downloads. One new method, `openSharedLink:completion:`: asks the metadata, makes or finds the link's directory by URL, lists it, answers its local URL (a file link: a directory holding that one placeholder, and the file's URL). |
| `BrowserViewController` | The root gains a **Shared with You** group listing the link directories, each removable by swipe (which deletes the directory), and an **Open Dropbox Link…** row under Locations: an alert with a text field, so the paste is the system's own and raises no permission prompt. A link folder then browses, relists, plays and adds exactly as a Dropbox folder does. |
| `FolderSession` | Nothing expected: `listFromDropboxIfMirrored:` goes through the mirror's own lookups. To confirm when built. |
| `VibeStrings.h` | The group title, the row, the sign-in reason and the link errors; `make strings`. |
| Debug | `open_dropbox_link <url>` in the iOS command table; `VibeFakeDropbox` answers the three link endpoints from a scripted directory, so the simulator needs no account and no real link. |
| Tests | `DropboxRulesTests`: URL recognition, the arguments encoding. `DropboxMirrorTests`: a link listed, a subfolder listed, a file fetched by `{url, path}`, an accented name, a revoked link, a file link, the budget counting both trees. |

**Signing in.** A link opened with no account presents the sign-in sheet with the reason, then continues. An account linked before this feature lacks `sharing.read`: the first link call answers Dropbox's plain-text 400 naming the scope, which becomes "Sign in again to open shared links" with the sheet behind it. Nothing changes for an account that never opens a link.

**What does not carry over.** Dropbox's search does not look inside links, so a link's songs are found by browsing, not by the Dropbox search scope. A password-protected link is refused with a message; storing the password is a later step if anyone asks.

## Phase 2: Share → Vibe

**One new target, `VibeShare`**, a share extension, embedded as `VibeWidget` is and with its sources outside `Vibe/` for the same reason. It links no app class and makes no network call:

- One file, `VibeShare/ShareViewController.m`: reads the shared URL from the extension item, appends it to a list in the app group's defaults (`group.com.commonwealthrecordings.Vibe`, the group the widget already uses), shows the confirmation card for a second and completes. A URL that is not a Dropbox link shows "Not a Dropbox link" and writes nothing.
- An entitlements file carrying the app group, and the `project.yml` target (its Info.plist is generated, as the widget's is).
- Its two strings ride a `share.*` catalog derived by `make strings`, the way the widget's `widget.*` catalog is.

**The app's half** is one read: when the scene becomes active, `PlaybackController` takes the pending links from the group defaults, clears them, hands each to `openSharedLink:` and shows the last one (a folder pushed in the Files tab, a file played). The same code path as the paste row.

**Release.** The extension is a second App ID (`com.commonwealthrecordings.Vibe.Share`) with the app group; automatic signing creates it as it did the widget's. `release-appstore.sh`'s check that the IPA carries the widget and its group grant is extended to the second appex. `make build-ios`, `install-ios.sh` and CI build it through the app's dependency.

**Known limits, to check on a device before committing to this phase:**

- **Vibe appears in the share sheet for every web link, not only Dropbox's.** An activation rule can ask for "one web URL" but cannot look at the URL's host.
- **The first time, Vibe may sit behind More** in the share sheet's app row until the user moves it up. That is iOS's ordering.
- **Messages must offer Share… on a link bubble.** It does on a long press today; confirm on iOS 26.

## Phase 3 (optional): a Vibe link, one tap

The sender long-presses a folder in Vibe → Share → Messages. The listener taps the link and Vibe opens on the folder.

- The link is `https://<a domain you own>/l#<the Dropbox link>`. iOS opens Vibe directly for it (universal links), arriving through the scene's existing URL entry and then `openSharedLink:`.
- Without Vibe installed, the same link is a small static page: an App Store button and "Open in Dropbox".
- Costs: a domain serving one static file (`apple-app-site-association`) and one page; the Associated Domains entitlement on the app; `sharing.write` on the sender's sign-in, to make or reuse the folder's share link (`sharing/create_shared_link_with_settings`); a Share item in the browser's folder menu.
- A plain Dropbox link pasted or shared the Phase 2 way keeps working; this only adds the faster road.

## Complexity budget

| | New files | New types | New targets |
| --- | --- | --- | --- |
| Phase 1 | 0 | 0 | 0 |
| Phase 2 | 2 (`ShareViewController.m`, entitlements) plus a derived catalog | 1 (the extension's principal class, which the extension point requires) | 1 (`VibeShare`) |
| Phase 3 | 0 in the app; a page and a JSON file on the domain | 0 | 0 |

**What it consolidates:** the client's download and ranged read stop being "a Dropbox path" and become "the arguments of a download", one shape for both sources, and the mirror's two path lookups become one that answers those arguments. Beyond that, nothing: this is a new source added beside the account, and Phase 2's target is a cost with no offsetting removal. It is argued for on the workflow alone, since the share sheet is reachable no other way.

**No new cross-directory guarantee.** The new rules (a link's file goes by its Dropbox-spelled name; the links directory is the list of links) have one home, `Vibe/iOS/Dropbox/AGENTS.md`.

## Not doing

- **Listening with no Dropbox account.** Only single-file links could work, through a separate plain-HTTP download with none of the client's version checks, and folders never could. A free account is the answer.
- **Scraping a folder link's web page** to browse it without the API.
- **Opening Vibe from the share extension** through the responder chain (above).
- **The Mac app.** Dropbox there is the File Provider; nothing here applies.

## Decisions needed

1. **Phase 3 or not**, and on which domain. It is the only road to one tap.
2. **A folder link's landing:** shown in the Files tab with its play button (planned, and what a folder does everywhere else in the app), or played at once.
3. **Vibe in every web link's share sheet** is acceptable (Phase 2's first known limit).

To do in the Dropbox App Console before any of it: enable `sharing.read` (and `sharing.write` for Phase 3), and check the app's status, since a Dropbox app still in development is capped in how many accounts may link it, which matters once links go to other people.
