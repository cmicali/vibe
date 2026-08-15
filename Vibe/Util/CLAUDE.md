# Util

Code with **no feature**. That is the entire admission test, and it is stricter than it sounds: if you can name the feature a file serves, it belongs in that feature's directory, however utility-shaped it looks. The UI update timer read like a utility and served exactly one screen.

What passes the test: the `NS*` categories (`Categories/`), the app's typography (`Fonts`), the display formatters (`Formatters`), the one window-chrome timing every window the app resizes shares (`WindowAnimation.h` — the main window and the settings window, so no single feature owns it), the prefix header's small change (`HelperMacros.h` — control-state and main-thread shorthands, `clampMin`; it reaches every translation unit through the `.pch`, so anything added there is paid for everywhere), and the URL walking below.

## NSURLUtil is the disk walk, and it stays ignorant on purpose

`NSURLUtil` expands whatever the user opened — a file, a folder, a playlist file — into an ordered list of audio URLs, on background workers, never the main thread. Two things it discovers along the way are wanted elsewhere, and it reports both through **handler blocks the app installs at launch** rather than calling anyone:

- the grant a playlist file needs, when its entries turn out to live somewhere unreadable (`Vibe/App/`'s `FolderAccessManager+GrantPanel`);
- the folders it listed and the covers it saw in them, which the folder-art resolver takes for free rather than paying for its own I/O (`Vibe/Audio/Metadata/`).

The indirection is not portability — the app has one platform. It is that a walk which called an app singleton behind a user setting, a sandbox grant and a modal panel could not be exercised in a test, and this one is, including a fuzz suite. **Unset handlers mean the walk still works and simply throws the extra facts away**, which is exactly what the tests install.

So the rule is narrower than "imports nothing from a feature", and worth stating exactly, because two imports here look like violations and are not: **what `Util/` may not call is anything stateful** — a singleton, a setting, a grant, a panel. Stateless code is fair game wherever it lives, so `NSURLUtil.m` imports `PlaylistFile` (a `+`-only CUE/M3U parser, itself unit- and fuzz-tested) and `FolderArtRules.h` (`static inline` decisions, no linkage) directly. Neither can make the walk untestable, which is the property the handlers exist to protect.

## Categories

Behavior added to a foreign class is a category (`NSURL+Hash`, `NSImage+Util`), never a free function taking that class as its first argument — see the root `CLAUDE.md`'s suffix rules. A category on an AppKit class still belongs here; a category on one of the app's own classes belongs beside that class.
