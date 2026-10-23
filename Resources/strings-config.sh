# Vibe's settings for the strings scripts, which source this file. They are
# vibe-libs' tools/strings, whose AGENTS.md documents each key. Not bundled.

# Relative to this file. Every other path is relative to it.
STRINGS_ROOT=..

STRINGS_REGISTRY=Vibe/Common/VibeStrings.h
STRINGS_MACROS=STR_
STRINGS_CATALOG=Resources/Localizable.xcstrings
STRINGS_SOURCES=(Vibe)
STRINGS_SKIP=('*/Debug/*')
STRINGS_CATALOGS=(Resources/Localizable.xcstrings Resources/InfoPlist.xcstrings Resources/ThemeNames.xcstrings)
STRINGS_UPDATE='make strings'
STRINGS_GUIDE='The vibe-strings skill has the register, quote and terminology conventions.'

# The widget resolves strings against its own bundle, so its catalog is the
# widget.* subset (VibeWidget/AGENTS.md).
STRINGS_SUBSET=widget
STRINGS_SUBSET_KEYS=widget.
STRINGS_SUBSET_MACROS=STR_WIDGET_
STRINGS_SUBSET_CATALOG=VibeWidget/Localizable.xcstrings
STRINGS_SUBSET_SOURCES=(VibeWidget Vibe/iOS/Widget)
