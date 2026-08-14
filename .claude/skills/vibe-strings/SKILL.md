---
name: vibe-strings
description: The localization pipeline — VibeStrings.h registry conventions, the extract-strings.sh preprocessor pass and extractionState rules, catalog and InfoPlist.xcstrings mechanics, authoring translations and the untranslated-keys release gate, translation terminology and per-language conventions, the pseudolocale audit, and the localized App Store product page. Use when adding or rewording any user-facing string, translating catalog keys, editing VibeStrings.h or the .xcstrings catalogs, debugging make strings / make check-strings, testing a language, or updating App Store copy or screenshots.
---

# Localization pipeline

The always-loaded rules live in the root `CLAUDE.md` (every string is a `STR_*` in `VibeStrings.h`; `make strings` after touching UI strings; display names are never identifiers). This skill holds the machinery.

## Languages and catalogs

English is the source language; **every other language is whatever the catalogs contain** — don't hardcode the list anywhere, read it from `Resources/Localizable.xcstrings` (`jq -r '[.strings[].localizations | keys] | flatten | unique'`). Translations are authored in the catalogs and are never touched by the extraction pipeline (`normalize()` only reaches `.localizations.en`, and `xcstringstool sync` preserves other languages — verified). Translations follow Apple's own macOS terminology for standard menu items rather than literal translation (German File is `Ablage`, not `Datei`), while DJ terms keep the loanwords the hardware uses (`FX`, `Delay`, and `PITCH` outside German, which uses `TEMPO`). Test a language with `open <app> --args -AppleLanguages '(xx)'`.

`knownRegions` stays at XcodeGen's default `(Base, en)` and that is *not* a bug: it doesn't gate which languages ship. The XCStrings compiler emits every language present in the catalogs, CFBundle negotiates on the `.lproj` directories actually in the bundle, and XcodeGen derives `knownRegions` from localized file references so a spec key for it is ignored. It only affects Xcode's project UI and which languages `-exportLocalizations` defaults to.

## Authoring translations

**Coverage is checked by `make check-translations` and by nothing else.** `make check-strings` is a round-trip diff — it re-runs sync+normalize on a copy and diffs, answering "does the catalog match the source" — and `sync` never writes a language other than `en`, so a key with only an `en` unit round-trips byte-identically and passes. The build is no better: `xcstringstool compile` exits 0 on a partial key and emits an `xx.lproj` without it, the lookup misses, and the macro's default value renders English in that locale alone. Silent both ways, which is how the 1.9 features (Permissions pane, Always on Top, the playlist grant panel) reached the release cut in English across 29 locales.

`scripts/check-translations.sh` tests for **missing any catalog language**, not for "has only `en`" — a key spike-translated into el/de/ru to check layout passes the latter while the other 27 never get written, the worse failure because the key looks done. The language set is the union across all keys, so it defines itself: the first key translated into a new language makes it required everywhere. `needs_review` units are reported, never fatal — a reword flips them by design and they keep shipping. Both release paths gate on it via `asc_require_translations`, before the archive.

Translations are authored directly into the catalog JSON — there is no export/import round trip. Each unit is `localizations.<lang>.stringUnit = {"state": "translated", "value": …}`, with the language keys sorted within each entry. Formatting never needs matching by hand: merge with any tool, then run `make strings`, which re-serializes the whole catalog canonically (`jq --indent 2`). When merging programmatically, assert per language that the set of languages exactly matches the catalog's and that every `%@`/format specifier from the English value survived — a dropped specifier crashes at `stringWithFormat:` time in that locale only.

Conventions the 1.9 batch established (the 8 keys `settings.permissions*`, `*always_on_top`, `playlist.grant.*` are worked examples of all of these):

- **Register** follows modern Apple style per language: informal where Apple is informal (German du, Spanish tú, Italian tu, Dutch je, Hungarian te), formal elsewhere (French vous, Russian/Ukrainian/Bulgarian вы-forms, Greek, Indonesian Anda, Korean/Japanese polite).
- **Quote styles** around `%@` and names are the locale's own: „…“ (de, cs, sk, bg), „…” (pl, hu, ro, hr), « … » spaced (fr), «…» unspaced (ru, uk, nb, el), ”…” (sv, fi), ‘…’ (nl, ko), 「…」 (ja, zh-Hant), “…” (zh-Hans and the rest).
- **~/Music is named by its localized Finder name** (Musik, Musique, Música, Hudba, Zenék, ミュージック, 音乐/音樂, …), never transliterated.
- **Ellipsis** is the real `…` character, unspaced, in every language (`Öffnen…`).
- **Menu vs. checkbox casing**: where a language title-cases menu items (English, Turkish), the paired sentence-case settings key differs (`Her Zaman Üstte` / `Her zaman üstte`); most European languages use sentence case in both, so the pair is identical.

To verify a translation landed without eyeballing: rebuild, direct-exec the binary with `-AppleLanguages '(xx)'` in argv, and assert through the debug channel (`dump_menu` shows live localized titles — the menu bar reading `Ablage` confirms the language took). The **vibe-debug** skill has the mechanics.

## The VibeStrings.h registry

Each entry is one line: `NSLS(key, value, comment)`, a local macro that lifts out the invariant `NSLocalizedStringWithDefaultValue(key, nil, NSBundle.mainBundle, …)` scaffolding, with columns padded per `#pragma mark` section so the file reads as a table. Keys are **symbolic and stable** (`menu.file`, `label.bpm`, `waveform.style.detailed`), never the English text, so rewording a button doesn't orphan its translations: extraction rewrites the catalog's `en` from the new default and flips every other language to `needs_review` — they keep shipping while awaiting review — rather than minting a new key. The English lives in the macro's *default value*: it is the enforced source of the catalog's `en` values (`xcstringstool sync` alone only stamps `en` on first sight, so the script copies a changed default over it) AND the fallback if a lookup ever misses, so the app can never render a raw `menu.file`. Key prefixes: `menu.*`, `transport.*` (shared by menu items and the transport buttons' a11y labels), `label.*`, `a11y.*`, `error.*`, `waveform.style.*`, `settings.*`.

## Call sites

Call sites use a `STR_*` macro and nothing more — no key, no English text, no translator comment inline:

```objc
NSMenu *fileMenu = Submenu(mainMenu, STR_MENU_FILE).submenu;
NSString *bpmText = [NSString stringWithFormat:STR_LABEL_BPM, formatted];
```

`VibeNotLocalized(s)` (in the pch, no runtime effect) marks a user-visible string deliberately kept in English — format acronyms, layout punctuation, instrument-scale glyphs, product names, titles AppKit never draws. Every unwrapped `@"..."` in UI code should be one or the other.

Working the display-names-are-never-identifiers rule: `AudioWaveformRenderer` splits `+styleIdentifier` (stable; the registry key, the `NSUserDefaults` value, the menu item's `waveform_style_*` identifier) from `+displayName` (localized, display only); `AppSettings` migrates the English display names persisted before the split. `FILETYPE_*` is the inverse case — never localized, because it is compared with `isEqualToString:` and archived into the metadata cache. Locale-dependent numbers (kHz, BPM, pitch %) go through `Formatters`' `decimalString:fractionDigits:` / `signedPercentString:`, not `%.1f`.

## Extraction pipeline

`make check-strings` fails when the catalog is stale (it also catches a key whose last call site went away — `sync` marks it `extractionState: stale`). `scripts/extract-strings.sh` first runs `VibeStrings.h` through the C preprocessor — it builds a throwaway TU referencing every `STR_*` and `clang -E`s it — because `xcstringstool` matches localization macros by name AND arity, and a three-argument `NSLS(key, value, comment)` fits no shape it knows; even `-s NSLS` extracts zero keys. Parsing the real expansion is exact where a regex over the header would quietly mis-parse, and clang fails loudly on a malformed entry. It then extracts from that expansion plus every other first-party `.m`/`.mm`/`.h` (so a stray inline `NSLocalizedString` can't hide), syncs, and normalizes: source-language units get promoted `new` → `translated` (the XCStrings compiler emits a `.strings` file only for `translated` units, so without this the app would ship no `en.lproj/Localizable.strings` at all), and every live key is marked `extractionState: manual`. The manual mark is a shield, not bookkeeping: **an Xcode build emits no `.stringsdata` for ObjC, so Xcode's own catalog pass sees every non-manual key as unreferenced, flags each one stale — one warning apiece — and writes the stale marks into the checked-in catalog.** `manual` declares a key externally managed and Xcode then leaves it alone. But `xcstringstool sync` honors `manual` too — it skips such keys entirely, no comment updates and no staleness — so the script strips the marks just before syncing and re-applies them after; a key whose `VibeStrings.h` entry was deleted comes through that gap marked `stale` and stays visible (in `--check` diffs and as a single honest Xcode warning) until it is deleted from the catalog.

Extraction is deliberately NOT a build phase: Xcode has **no build-time String Catalog extraction for Objective-C** (clang emits `.stringsdata` only for Swift; the only xcstrings build task is `compile`), and a phase rewriting a checked-in file would flip `VIBE_GIT_DIRTY` on every build. Keep the stock `NSLocalizedString*` names — a custom macro would need `LOCALIZED_STRING_MACRO_NAMES`, which no shipped Xcode binary reads. One consequence of the registry living in a header: a macro nothing references still yields a catalog key, so delete the entry when the last call site goes.

## InfoPlist.xcstrings

`Resources/InfoPlist.xcstrings` carries the bundle name, the copyright, and the `CFBundleTypeName` values. Its keys are plist keys, EXCEPT the document-type names, which are keyed on the **English type name** — that is how Launch Services looks them up, and it does work (`lsregister -dump` shows the localized names). `CFBundleName` is added to this catalog by Xcode's build, not by hand: it is kept with the same value in every language so the entry stays stable instead of reappearing as an untranslated `new` unit on the next build. The copyright reaches the About window only through `objectForInfoDictionaryKey:`; plain `infoDictionary[…]` does NOT apply `InfoPlist.strings`.

## Pseudolocale audit — finding strings that escaped

Build a pseudolocale from the catalog (bracket + accent + pad every value, copying format specifiers verbatim), `xcstringstool compile … -l en-XA` it into the built app's `Contents/Resources`, rename the output to `Localizable.strings`, re-sign (`codesign -f -s - --preserve-metadata=entitlements`), and launch with `--args -AppleLanguages '(en-XA)'`. Anything rendering *without* brackets never went through the bundle. Padding also surfaces layout overflow — the menu bar and the 96pt `PITCH` label are the tightest spots.

## App Store product page

The App Store product page is localized too, from `Assets/app-store/` (copy, screenshot captions, and generated screenshots per catalog language — format in its README). `make appstore-validate-copy` validates it; `make appstore-upload-metadata` uploads it via the **vibe-release** skill's shared API key. The catalog remains the source of which languages exist; `bg` ships in-app only, because the App Store has no Bulgarian product page.

`copy/<lang>/whats-new.txt` must be **rewritten for every release in every locale** — App Store Connect blocks submission when any locale lacks it — and should stay in step with the new `CHANGELOG.md` section: same features, App Store voice, each locale's own terminology (the same register and quote conventions as Authoring translations above).
