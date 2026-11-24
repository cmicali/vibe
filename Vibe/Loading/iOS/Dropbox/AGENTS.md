# Dropbox (iOS)

**The Dropbox client and mirror are vibe-libs' `files/Dropbox`.** Its doc, `vibe-libs/files/Dropbox/AGENTS.md`, is the authority for how they work: the sign-in, the refresh token, the failure ladder, the lazy mirror, the placeholders, the index, the fetch, and every trap of theirs. A change to them lands in vibe-libs first, then in Vibe's pin. Only the iOS app lists the piece's template. The shell that draws the account is `Vibe/iOS/AGENTS.md`.

What stays here is what only Vibe knows.

| File | Owns |
| --- | --- |
| `DropboxMirror+Shared` | Vibe's one mirror, `DropboxMirror.shared`, which the screens and the remote backend share. It makes the client and the mirror with Vibe's app key, Keychain service, index xattr, directory (`Application Support/Dropbox`), and saved budget. `VibeiOSAppDelegate` installs it at launch with `installAsRemoteBackend`, beside the Links store, and calls `warmUp` once off main. |

**TRAP: Vibe's Keychain service and index xattr in `DropboxMirror+Shared.m` must never change.** They name data that a signed-in user already has (the piece's doc says what a change breaks).

## The account

**The app key is `VibeDropboxAppKey` in the generated Info.plist** (`project.yml`). The app needs **Full Dropbox** access to browse existing music outside its dedicated app folder.

**Check production status in the App Console before a release.** It is external account state, not a build setting. With additional users enabled, development apps can link up to 500 users. Reaching 50 starts a two-week deadline to obtain production approval. Dropbox can then freeze new links until approval. Applications may be submitted earlier; review normally starts at 50 users. See the [Dropbox production-approval guide](https://www.dropbox.com/developers/reference/developer-guide#production-approval).

**Build the simulator with `VIBE_SIGN_SIM=1` to test the account across a relaunch** (the `vibe-debug` skill). The default simulator build is unsigned and cannot keep the refresh token (the piece's TRAP). A device build is always signed.

**An unlink clears the playlist.** When the account changes, `PlaybackController` clears a playlist that reaches into the mirror, whole, as Clear Playlist does.

## The shell's side

- **The budget's choices are Vibe's.** The user chooses the maximum size in Settings › Files and Dropbox › Maximum Size (`kVibeDropboxDownloadBudgets` in `Common/SettingsRules.h`). Settings saves it under `VibeDropboxDownloadBudgetKey`, which the shared mirror starts from, then sets `downloadBudget`. An evicted track's card draws its cached waveform while parked (vibe-libs' `ui/PlayerCard/AGENTS.md`).
- **The shell lists before it opens.** The browser lists a folder on every visit, a search hit lists its parent before it opens, and an open lists a folder nothing has listed yet (`FolderSession`'s `listFromDropboxIfMirrored:`, which asks `hasListedDirectory:`).
- **Opens are the shell's ordinary roads.** `FolderSession` treats the mirror as a root every open covers. A file opened alone becomes its folder with it selected, and bookmarks persist.

**The simulator needs no account.** `set_fake_dropbox <directory>` (vibe-libs' `VibeFakeDropbox`) puts that directory under the client as the account, over the same HTTP boundary the tests stub. `fake_dropbox_fault` scripts the streaming cases, and `vibe-debug`'s `dropbox-streaming.sh` runs them as scenarios. `dump_dropbox` reads the account and which playlist tracks are placeholders. The real sign-in is Dropbox's web sheet, which only a human fills.
