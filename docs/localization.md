# Localization

English is the source language. Every user-facing string is declared in `Vibe/Common/VibeStrings.h`. Translations live in three catalogs in `Resources/`: `Localizable.xcstrings` for the app's strings, `InfoPlist.xcstrings` for bundle metadata, the local-network usage description and document-type names, and `ThemeNames.xcstrings` for the built-in themes' names. The widget's catalog is derived from `widget.*` by `make strings`. The app ships the catalog languages. To list them, run `jq -r '[.strings[].localizations | keys] | flatten | unique' Resources/Localizable.xcstrings`.

The `vibe-strings` skill (`.claude/skills/vibe-strings/SKILL.md`) has the full pipeline and the translation conventions.

## Adding or changing a string

1. Add or edit a one-line `NSLS(key, value, comment)` entry in `VibeStrings.h`. The key is symbolic (`menu.file`), the value is the English text, and the comment is for translators. Call sites use the `STR_*` macro, never an inline `NSLocalizedString` or a bare literal. Mark a deliberately English string with `VibeNotLocalized(...)`.
2. Run `make strings` to sync the catalog. It needs `jq` (`make setup`). The build does not extract strings.
3. Translate the new key into every language in `Resources/Localizable.xcstrings`, in Xcode's catalog editor or in the JSON. Extraction never changes a translation's text. Rewording the English flips its translations to `needs_review`, and they keep shipping until reviewed.

`make check-strings` fails when the catalog is out of sync with the source. Extraction expands every registry macro. When its last call site is removed, delete its `VibeStrings.h` entry and catalog key too. `make check-translations` fails when any key in any catalog is missing a language. Both release paths run it.

## Adding a language

1. Add the language to all three catalogs, in Xcode or as a `stringUnit` per key in the JSON with `"state": "translated"`. Follow Apple's own terminology for the standard menu items rather than translating literally, so the menus read like the rest of the system.
2. Rebuild. Nothing else changes. The build ships every language in the catalogs, with no `project.yml` or `knownRegions` edit.
3. Run the app in that language (below) and check the tight spots: the menu bar, the 96pt pitch panel title, the drop hint and the inline error text.

## Running in a specific language

Pass the language as a launch argument. It applies to that run only and changes nothing system-wide:

```bash
open -a build/DerivedData/Build/Products/Debug/Vibe.app --args -AppleLanguages '(fr)'
```

Quit any running copy first, or `open` just brings the existing one to the front. To open a file too, put it before `--args`.
