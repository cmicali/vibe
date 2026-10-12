# Future: Dropbox shared folder links on iOS

**Status: Not built.** A single-file Dropbox link already plays with no account, through Open URL (`Loading/Net/AGENTS.md`, `DropboxLinkRules.h`). This plan is folder links through a signed-in account.

Someone sends a Dropbox folder link in Messages. The person receiving it browses and plays the folder in Vibe, where it is. No "copy to my Dropbox" and no Dropbox app.

## What Dropbox allows

Read from Dropbox's published API spec (`files.stone`, `shared_links.stone`), not yet run against a real link.

| Need | Endpoint | Notes |
| --- | --- | --- |
| What a link is | `sharing/get_shared_link_metadata` | Name, file or folder, and for a file its size, `server_modified` and `rev`. Scope `sharing.read`. |
| Browse a folder link | `files/list_folder` with `shared_link: {url}` | The call the mirror already makes. `path` is relative to the link. One level per call, as the mirror lists anyway. |
| Play a file | `sharing/get_shared_link_file` with `{url, path}` | On the content host. Its `Dropbox-API-Result` header carries the size, `server_modified` and `rev` the version check reads. Scope `sharing.read`. |

**All three need a signed-in user.** None allows app-only access. A free account works, and the link need not be the listener's. Without an account, a folder link's `?dl=1` is a zip of the whole folder.

## The listener's workflow

**Phase 2 (Share → Vibe):**

1. In Messages, long-press the link, then Share…, then Vibe.
2. A card confirms "Open Vibe to listen" and closes on its own.
3. Open Vibe. The shared folder is on screen in the Files tab with its play button.

With no Dropbox account linked, step 3 shows the sign-in sheet first, then continues to the folder.

**Why step 3 is separate.** A share extension may not open its app. `NSExtensionContext`'s `openURL:` works only for widgets, and `UIApplication` is unavailable in extensions. Walking the responder chain to the application object still works in reports, but Apple calls it unsupported. It breaks the no-private-API rule in spirit, so the plan does not use it.

**Phase 3 is the one-tap version.** The sender shares from Vibe, the listener taps the link, and Vibe opens on the folder.

## Phase 0: probe a real link

Enable `sharing.read` for the app key in the Dropbox App Console, sign in, and run the three calls with `curl` against a real folder link.

- **Does `get_shared_link_file` honour `Range`?** Without it a link's track still plays while it downloads. But an interrupted download starts over, tags and art wait for the whole file, and a format that reads its end to open waits for the whole download.
- **What a listing through a link carries.** The spec says `path_lower` is present only for files in the caller's own Dropbox. Entries are expected to have `name`, `size`, `server_modified` and `rev` but no path. The plan assumes that.
- **The errors** for a revoked, expired, password-protected and team-only link, so each gets its own message.

## Phase 1: links in the mirror

Reachable by pasting a link. No new target, files or types.

**Where a link lives.** `Library/Application Support/Dropbox/<account id> links/<link name>/`, beside the account's own tree. Under the mirror root, every existing rule covers it: `containsURL:`, the placeholder fetch, the ranged tag read, Recents, Favorites, restore after relaunch and the playlist clear on sign-out. It is beside the account tree, not inside it, because a listing of the account's root deletes any folder Dropbox does not name. `pruneOtherAccounts:` keeps both directories for the linked account.

**The directory is the record.** A link directory's xattr index gains `link` (the URL), and its path is relative to the link. Its `files` map holds each file's name as Dropbox spelled it, where an account directory holds ids. A link's file is downloaded by path, and a name read back from disk is never sent to Dropbox. A subfolder made by its parent's listing carries the link too. The list of links is the listing of the links directory: no store and no defaults key.

| Where | Change |
| --- | --- |
| `DropboxRules.h` | `sharing.read` joins `VIBE_DROPBOX_SCOPES`. One function recognises a Dropbox folder share URL (`/scl/fo/`, `/sh/`) and gives its comparable form, with `dl` and `st` dropped. |
| `DropboxClient` | `makeRequestForTarget:state:completion:` takes a `{url, path}` target and sends it to `sharing/get_shared_link_file`. A path target goes to `files/download` as now. The failure ladder, resume and version check are untouched. A link's errors (revoked, expired, password, no access) get their own error code. |
| `DropboxMirror` | `listFolder:` adds `shared_link` when the directory's index names a link. `remoteTargetForURL:error:` answers `{url, path}` under a link directory. `reconcileDirectory:` composes a subfolder's path from its parent's when the entry has none. `downloadsUnder:` walks both trees, so the download budget and Remove Downloads count link downloads. One new method, `openSharedLink:completion:`, asks the metadata, makes or finds the link's directory, lists it and answers its local URL. |
| `BrowserViewController` | The root gains a **Shared with You** group of link directories, each removable by swipe, and an **Open Dropbox Link…** row under Locations. The row is an alert with a text field, so the paste is the system's own and raises no permission prompt. A link folder then browses, plays and adds as a Dropbox folder does. |
| `FolderSession` | Nothing expected. Confirm when built. |
| `VibeStrings.h` | The group title, the row, the sign-in reason and the link errors. Run `make strings`. |
| Debug | `open_dropbox_link <url>` in the iOS command table. `VibeFakeDropbox` answers the three link endpoints from a scripted directory. |
| Tests | `DropboxRulesTests`: URL recognition. `DropboxMirrorTests`: a link listed, a subfolder listed, a file fetched by `{url, path}`, an accented name, a revoked link, the budget counting both trees. |

**Signing in.** A link opened with no account presents the sign-in sheet with a reason. An account linked before this feature lacks `sharing.read`. Its first link call answers Dropbox's 400 naming the scope, which becomes "Sign in again to open shared links". Nothing changes for an account that never opens a link.

**What does not carry over.** Dropbox's search does not look inside links, so a link's songs are found by browsing. A password-protected link is refused with a message.

## Phase 2: Share → Vibe

**One new target, `VibeShare`**, a share extension embedded as `VibeWidget` is, with its sources outside `Vibe/`. It links no app class and makes no network call.

- `VibeShare/ShareViewController.m` reads the shared URL, appends it to a list in the app group's defaults (`group.com.commonwealthrecordings.Vibe`, the widget's group), shows the card for a second and completes. A URL that is not a Dropbox link shows "Not a Dropbox link" and writes nothing.
- An entitlements file with the app group, and the `project.yml` target.
- Its strings ride a `share.*` catalog, as the widget's `widget.*` catalog does.

**The app's half is one read.** When the scene becomes active, `PlaybackController` takes the pending links, clears them, hands each to `openSharedLink:` and shows the last one. It is the paste row's code path.

**Release.** The extension is a second App ID (`com.commonwealthrecordings.Vibe.Share`) with the app group. `release-appstore.sh`'s check for the widget and its group grant extends to the second appex.

**Check on a device before committing:**

- Vibe appears in the share sheet for every web link. An activation rule can ask for "one web URL" but cannot look at its host.
- The first time, Vibe may sit behind More in the share sheet's app row.
- Messages must offer Share… on a link bubble.

## Phase 3 (optional): a Vibe link, one tap

The sender long-presses a folder in Vibe, then Share, then Messages. The listener taps the link and Vibe opens on the folder.

- The link is a universal link on vibeplayer.app carrying the Dropbox link. It arrives through the scene's URL entry and then `openSharedLink:`. [Vibe links](share-links.md) plans the same domain, AASA file and scheme, so build them once.
- Without Vibe, the link is a page with an App Store button and "Open in Dropbox".
- It needs `sharing.write` on the sender's sign-in, to make or reuse the folder's share link (`sharing/create_shared_link_with_settings`), and a Share item in the browser's folder menu.

## Complexity budget

| | New files | New types | New targets |
| --- | --- | --- | --- |
| Phase 1 | 0 | 0 | 0 |
| Phase 2 | 2 (`ShareViewController.m`, entitlements) plus a derived catalog | 1 (the extension's principal class) | 1 |
| Phase 3 | 0 in the app | 0 | 0 |

Phase 1 adds a source beside the account and consolidates nothing. Phase 2's target is a cost with no offsetting removal. It is argued on the workflow alone, since the share sheet is reachable no other way.

**No new cross-directory guarantee.** The new rules (a link's file goes by its Dropbox-spelled name, and the links directory is the list of links) belong in `Vibe/iOS/Dropbox/AGENTS.md`.

## Not doing

- **Folder links with no account.** Only a zip of the whole folder is reachable.
- **Scraping a folder link's web page** to browse it without the API.
- **Opening Vibe from the share extension** through the responder chain.
- **The Mac app.** Dropbox there is the File Provider.

## Decisions needed

1. **Phase 3 or not.** It is the only road to one tap.
2. **A folder link's landing:** shown in the Files tab with its play button (planned), or played at once.
3. **Vibe in every web link's share sheet** is acceptable or not.

Before any of it, in the Dropbox App Console: enable `sharing.read` (and `sharing.write` for Phase 3). Check the app's status, since an app still in development is capped in how many accounts may link it.
