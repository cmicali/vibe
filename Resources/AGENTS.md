# Resources

This directory holds the files the apps bundle as resources: the built-in themes, the string catalogs, the app icon, and the asset catalog. It also holds the welcome track, the privacy manifest, and the About window's shader source.

**Making or editing a built-in theme: read `Themes-README.md`, beside this file, first.** It is the authoring guide for everything in `Themes/`. A theme is one `Themes/<identifier>.json` plus any `bundled:` artwork. It needs no code change, no project edit and no xcodegen run. `make test` is its gate. To see it in the running app, use the `vibe-debug` skill: `--debug-cmd set_theme <identifier>`, then screenshot both appearances.

**TRAP: `Themes/` is a folder reference (`type: folder` in `project.yml`).** It is copied verbatim into the mac app and the test bundle, and a folder reference takes no excludes. Add nothing there that is not meant to ship: no `AGENTS.md`, no scratch files, no README. That is why this file and `Themes-README.md` sit one level up.

The string catalogs live here. `Localizable.xcstrings` gets its keys, English text and comments from extraction. Edit translations in the catalog. Run `make strings` after touching `VibeStrings.h` or translations. `InfoPlist.xcstrings` and `ThemeNames.xcstrings` are hand-managed. The `vibe-strings` skill is the reference for all three. `strings-config.sh` names the registry, the catalogs, and the widget's subset for the strings scripts. It is not bundled.

The rest are app assets owned by their features: `Assets.xcassets`, `AppIcon.icon`, `PrivacyInfo.xcprivacy`, `VectorBalls.metal.txt` and `vibe-theme.mp3`, the welcome track.
