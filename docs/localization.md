# Localization

English is the source language. All user-facing strings live in `Vibe/Common/VibeStrings.h`; translations live in `Resources/Localizable.xcstrings` (plus `Resources/InfoPlist.xcstrings` for the bundle name, copyright, and document-type names). The app ships every language present in those catalogs — to see the current set, run `jq -r '[.strings[].localizations | keys] | flatten | unique' Resources/Localizable.xcstrings`.

## Adding or changing a string

1. Add (or edit) a one-line `NSLS(key, value, comment)` entry in `Vibe/Common/VibeStrings.h` — symbolic key (`menu.file`), English text, translator comment. Use the `STR_*` macro at the call site; never an inline `NSLocalizedString` or bare literal (mark deliberately-English strings `VibeNotLocalized(...)`).
2. Run `make strings` to sync the catalog (needs `jq` — `make setup`). This is a manual step; the build does not extract strings.
3. Translate the new key into every shipping language in `Resources/Localizable.xcstrings` (Xcode's catalog editor, or edit the JSON). Extraction never touches the *text* of non-English translations; rewording a string's English flips them to `needs_review` (they keep shipping until re-reviewed).

`make check-strings` fails if the catalog is out of sync (including keys whose last call site was removed — delete their `VibeStrings.h` entries).

## Adding a language

1. Open `Resources/Localizable.xcstrings` in Xcode and add the language (or add the language's `stringUnit` per key in the JSON, `state: "translated"`). Do the same for `Resources/InfoPlist.xcstrings`. Follow Apple's own macOS terminology for the standard menu items rather than translating literally — the menus should read like the rest of the system.
2. Rebuild. Nothing else changes — no `project.yml` or `knownRegions` edits; the build ships every language present in the catalogs.
3. Test it by launching with that language code (see below) and check the tight spots: the menu bar, the 96pt pitch-panel title, the drop hint, and the inline error text.

## Running in a specific language

Pass the language as a launch argument — it overrides the app for that run only, changing nothing system-wide:

```bash
open build/DerivedData/Build/Products/Debug/Vibe.app --args -AppleLanguages '(fr)'
```

Quit any running instance first, or `open` will just front the existing one. To open a file too, put it before `--args`.
