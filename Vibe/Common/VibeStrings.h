//
//  VibeStrings.h
//  Vibe
//
// Every user-facing string in the app, in one place. Call sites use the STR_*
// macro and nothing else — no key, English text, or translator comment inline.
//
// Each entry is NSLS(key, value, comment), one per line however long:
//   key     — symbolic and stable (menu.file, label.bpm), never the English
//             text: rewording must not invalidate translations.
//   value   — the English text. Seeds the catalog's "en" values and is the
//             runtime fallback, so a missed lookup never renders "menu.file".
//   comment — context for the translator: where it appears, what any format
//             specifier holds.
//
// `make strings` regenerates Resources/Localizable.xcstrings from this file;
// `make check-strings` fails when the two drift. An unreferenced macro still
// yields a catalog key — delete the entry when the last call site goes.
// Deliberately-unlocalized strings are marked VibeNotLocalized(...) at their
// call sites instead of living here.
//
// The key-prefix families and the rest of the localization conventions —
// terminology, testing, the extraction pipeline — live in CLAUDE.md's
// Localization section, the single place they are documented.
//
// TRAP: named VibeStrings.h, NOT Strings.h. On the case-insensitive
// filesystem "Strings.h" shadows POSIX <strings.h> during explicit-modules
// dependency scanning (Xcode 26.6+ / CI): the SDK's CoreServices module
// includes <strings.h>, resolves it to this file, and this file's Foundation
// import completes a Foundation → CoreServices → Foundation cycle that fails
// every module build in the target.

#ifndef VibeStrings_h
#define VibeStrings_h

// TRAP: extract-strings.sh preprocesses this header and needs
// NSLocalizedStringWithDefaultValue to survive -E unexpanded — it is itself a
// Foundation macro, so importing Foundation here would expand every entry into
// its bundle-call body and extraction would find zero keys, marking the whole
// catalog stale. The script defines VIBE_STRINGS_EXTRACTION to skip this
// block; real builds see Foundation and the helper below.
#ifndef VIBE_STRINGS_EXTRACTION
#import <Foundation/Foundation.h>
#endif

// Lifts out the fixed scaffolding so entries read as key/English/comment.
// xcstringstool cannot extract a three-argument macro (it matches macros by
// name AND arity, even with -s), so extract-strings.sh preprocesses this file
// and parses the expansion.
#define NSLS(key, value, comment) NSLocalizedStringWithDefaultValue(key, nil, NSBundle.mainBundle, value, comment)

#pragma mark - Product

#define STR_APP_NAME NSLS(@"app.name", @"Vibe", @"The application's name, as shown in the app menu and as the window title. A product name — translate only if it would otherwise be unreadable in the target script.")

// The app name everywhere it appears — menu titles, the window title, "About
// %@" — so the two catalogs cannot diverge: the localized CFBundleName, which
// InfoPlist.xcstrings owns, with STR_APP_NAME as the never-nil fallback. Call
// sites use this, never STR_APP_NAME directly.
#ifndef VIBE_STRINGS_EXTRACTION
static inline NSString *VibeAppName(void) {
    return [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleName"] ?: STR_APP_NAME;
}
#endif

#pragma mark - Application menu

#define STR_MENU_APP_ABOUT       NSLS(@"menu.app.about",       @"About %@",    @"App menu item: opens the About window. %@ is the app name. Also the About window's title.")
#define STR_MENU_APP_SETTINGS    NSLS(@"menu.app.settings",    @"Settings…",   @"App menu item: opens the Settings window. macOS uses this same name in every app. Ends with a real ellipsis character (…), not three periods.")
#define STR_MENU_APP_SERVICES    NSLS(@"menu.app.services",    @"Services",    @"App menu: submenu of system Services. macOS uses this same name in every app.")
#define STR_MENU_APP_HIDE        NSLS(@"menu.app.hide",        @"Hide %@",     @"App menu item: hides the app. %@ is the app name.")
#define STR_MENU_APP_HIDE_OTHERS NSLS(@"menu.app.hide_others", @"Hide Others", @"App menu item: hides every other application.")
#define STR_MENU_APP_SHOW_ALL    NSLS(@"menu.app.show_all",    @"Show All",    @"App menu item: unhides all applications.")
#define STR_MENU_APP_QUIT        NSLS(@"menu.app.quit",        @"Quit %@",     @"App menu item: quits the app. %@ is the app name.")

#pragma mark - File menu

#define STR_MENU_FILE                   NSLS(@"menu.file",                   @"File",            @"Menu bar: the File menu.")
#define STR_MENU_FILE_OPEN              NSLS(@"menu.file.open",              @"Open…",           @"File menu item: shows the open panel. Ends with a real ellipsis character (…), not three periods.")
#define STR_MENU_FILE_OPEN_RECENT       NSLS(@"menu.file.open_recent",       @"Open Recent",     @"File menu: submenu listing recently opened files.")
#define STR_MENU_FILE_OPEN_RECENT_CLEAR NSLS(@"menu.file.open_recent.clear", @"Clear Menu",      @"Open Recent submenu: empties the list of recent files.")
#define STR_MENU_FILE_CLOSE             NSLS(@"menu.file.close",             @"Close File",      @"File menu item: unloads the current track. Becomes 'Close All Files' when more than one is loaded — two independent strings, not a plural; the count is never shown.")
#define STR_MENU_FILE_CLOSE_ALL         NSLS(@"menu.file.close_all",         @"Close All Files", @"File menu item: unloads the whole playlist. Replaces 'Close File' when more than one track is loaded.")

#pragma mark - Edit menu

// Undo/Redo are base titles only: validation retitles them from NSUndoManager
// ("Undo Convert to FLAC"), which draws the localized prefix from AppKit and
// the action name from STR_MENU_CONVERT_TO_FLAC.

#define STR_MENU_EDIT                      NSLS(@"menu.edit",                      @"Edit",                 @"Menu bar: the Edit menu. Holds Undo, Redo, the two Copy items, Remove from Playlist and Select All.")
#define STR_MENU_EDIT_UNDO                 NSLS(@"menu.edit.undo",                 @"Undo",                 @"Edit menu item: undoes the last action. macOS uses this same name in every app.")
#define STR_MENU_EDIT_REDO                 NSLS(@"menu.edit.redo",                 @"Redo",                 @"Edit menu item: redoes the last undone action. macOS uses this same name in every app.")
#define STR_MENU_EDIT_COPY_FILE            NSLS(@"menu.edit.copy_file",            @"Copy File",            @"Edit menu item: puts the current track's audio file on the clipboard, ready to paste in the Finder. Use the same verb as the system's Edit > Copy.")
#define STR_MENU_EDIT_COPY_NAME            NSLS(@"menu.edit.copy_name",            @"Copy Name",            @"Edit menu item: copies the current track's display name — 'Artist - Title' — as text. Use the same verb as the system's Edit > Copy.")
#define STR_MENU_EDIT_REMOVE_FROM_PLAYLIST NSLS(@"menu.edit.remove_from_playlist", @"Remove from Playlist", @"Edit menu item, and the same command in the playlist row menu: takes one track out of the playlist. The audio file stays on disk — nothing is deleted, moved or trashed — so use a verb that means taking something off a list, as Music does, not one that means deleting a file.")
#define STR_MENU_EDIT_SELECT_ALL           NSLS(@"menu.edit.select_all",           @"Select All",           @"Edit menu item: selects every row of the list that has keyboard focus — the playlist, or the granted-folder list in Settings > Permissions. macOS uses this same name in every app.")
#define STR_MENU_EDIT_REORDER              NSLS(@"menu.edit.reorder",              @"Reorder",              @"Undo action name for dragging playlist rows to a new position; it appears only composed into the Edit menu's Undo/Redo titles, as 'Undo Reorder' / 'Redo Reorder'. Use a noun or noun-like form that reads naturally after the system's own Undo/Redo verb in your language.")

#pragma mark - Transport

// Shared by the Playback menu items and the on-screen transport buttons'
// accessibility labels — the same actions, so the same words.

#define STR_TRANSPORT_PLAY     NSLS(@"transport.play",     @"Play",           @"Starts playback. Menu item and transport button; toggles with 'Pause'.")
#define STR_TRANSPORT_PAUSE    NSLS(@"transport.pause",    @"Pause",          @"Pauses playback. Menu item and transport button; toggles with 'Play'.")
#define STR_TRANSPORT_NEXT     NSLS(@"transport.next",     @"Next Track",     @"Jumps to the next track. Menu item and transport button.")
#define STR_TRANSPORT_PREVIOUS NSLS(@"transport.previous", @"Previous Track", @"Jumps to the previous track.")

#pragma mark - Playback menu

// "More"/"Most" are progressively larger jumps (8/16/32 bars, or 10/30/60
// seconds when the tempo is unknown) — not comparatives of a quantity.

#define STR_MENU_PLAYBACK          NSLS(@"menu.playback",                   @"Playback",          @"Menu bar: the Playback menu.")
#define STR_MENU_PLAY_SELECTED     NSLS(@"menu.playback.play_selected",     @"Play Selected Track", @"Playback menu item: play the playlist row the user has selected, rather than the one already playing.")
#define STR_MENU_SKIP_FORWARD      NSLS(@"menu.playback.skip_forward",      @"Skip Forward",      @"Playback menu item: seek forward a short step.")
#define STR_MENU_SKIP_FORWARD_MORE NSLS(@"menu.playback.skip_forward_more", @"Skip Forward More", @"Playback menu item: seek forward a medium step, larger than 'Skip Forward'.")
#define STR_MENU_SKIP_FORWARD_MOST NSLS(@"menu.playback.skip_forward_most", @"Skip Forward Most", @"Playback menu item: seek forward the largest step.")
#define STR_MENU_SKIP_BACK         NSLS(@"menu.playback.skip_back",         @"Skip Back",         @"Playback menu item: seek backward a short step.")
#define STR_MENU_SKIP_BACK_MORE    NSLS(@"menu.playback.skip_back_more",    @"Skip Back More",    @"Playback menu item: seek backward a medium step, larger than 'Skip Back'.")
#define STR_MENU_SKIP_BACK_MOST    NSLS(@"menu.playback.skip_back_most",    @"Skip Back Most",    @"Playback menu item: seek backward the largest step.")
#define STR_MENU_PITCH_RANGE       NSLS(@"menu.playback.pitch_range",       @"Pitch Range",       @"Playback menu: submenu selecting the pitch fader's range (±8% or ±16%).")
#define STR_MENU_PITCH_RANGE_8     NSLS(@"menu.playback.pitch_range.8",     @"8%",                @"Pitch Range submenu item: a ±8% fader range. Matches the printed scale on the fader itself.")
#define STR_MENU_PITCH_RANGE_16    NSLS(@"menu.playback.pitch_range.16",    @"16%",               @"Pitch Range submenu item: a ±16% fader range. Matches the printed scale on the fader itself.")

#pragma mark - FX menu

#define STR_MENU_FX                NSLS(@"menu.fx",                @"FX",             @"Menu bar: the effects menu. 'FX' is the standard DJ-console abbreviation for effects; keep it short — this is a top-level menu title.")
#define STR_MENU_FX_LOW_KILL       NSLS(@"menu.fx.low_kill",       @"Low Kill",       @"FX menu item: high-pass filter that removes the bass.")
#define STR_MENU_FX_LOW_KILL_BOOST NSLS(@"menu.fx.low_kill_boost", @"Low Kill Boost", @"FX menu item: raises the Low Kill filter's cutoff further.")
#define STR_MENU_FX_REVERB         NSLS(@"menu.fx.reverb",         @"Reverb",         @"FX menu item: reverb send.")
#define STR_MENU_FX_DELAY_8        NSLS(@"menu.fx.delay_8",        @"Delay 1/8",      @"FX menu item: delay synced to eighth notes. '1/8' is a note value — keep the fraction.")
#define STR_MENU_FX_DELAY_16       NSLS(@"menu.fx.delay_16",       @"Delay 1/16",     @"FX menu item: delay synced to sixteenth notes. '1/16' is a note value — keep the fraction.")

#pragma mark - View menu

#define STR_MENU_VIEW               NSLS(@"menu.view",                   @"View",               @"Menu bar: the View menu.")
#define STR_MENU_VIEW_PLAYLIST      NSLS(@"menu.view.playlist",          @"Show Playlist",      @"View menu item: expands the window to show the playlist.")
#define STR_MENU_VIEW_PITCH_CONTROL NSLS(@"menu.view.pitch_control",     @"Show Pitch Control", @"View menu item: shows the pitch fader panel.")
#define STR_MENU_VIEW_FILE_INFO     NSLS(@"menu.view.file_info",         @"Show File Info",     @"View menu item: checkmarked toggle showing the header's file-format readout (codec, bitrate, sample rate) and the BPM/key line.")
#define STR_MENU_VIEW_ALWAYS_ON_TOP NSLS(@"menu.view.always_on_top",     @"Always on Top",      @"View menu item: checkmarked toggle that keeps the player window above all other apps' windows.")
#define STR_MENU_VIEW_APPEARANCE    NSLS(@"menu.view.appearance",        @"Appearance",         @"View menu: submenu choosing the light/dark appearance; also the Appearance pane's label in the mac Settings window and the Appearance row on the iOS settings screen. One word for all three.")
#define STR_MENU_APPEARANCE_SYSTEM  NSLS(@"menu.view.appearance.system", @"Auto",               @"Appearance choice, View menu and Settings: follow the system's light/dark setting. macOS System Settings names this choice Auto, beside Light and Dark — use the same word.")
#define STR_MENU_APPEARANCE_LIGHT   NSLS(@"menu.view.appearance.light",  @"Light",              @"Appearance choice, View menu and Settings: always use the light appearance.")
#define STR_MENU_APPEARANCE_DARK    NSLS(@"menu.view.appearance.dark",   @"Dark",               @"Appearance choice, View menu and Settings: always use the dark appearance.")
#define STR_MENU_VIEW_THEME         NSLS(@"menu.view.theme",             @"Theme",              @"View menu: submenu selecting the appearance theme; checkmarks the active one.")
#define STR_MENU_VIEW_EDIT_THEMES   NSLS(@"menu.view.theme.edit",        @"Edit Themes…",       @"Theme submenu item: opens Settings on the theme editor. Ends with a real ellipsis character (…), not three periods.")
#define STR_MENU_VIEW_SIZE          NSLS(@"menu.view.size",              @"Size",               @"View menu: submenu choosing the window's width preset.")
#define STR_MENU_SIZE_SMALL         NSLS(@"menu.view.size.small",        @"Small",              @"Size menu item: the narrowest window width.")
#define STR_MENU_SIZE_DEFAULT       NSLS(@"menu.view.size.default",      @"Default",            @"Size menu item: the standard window width.")
#define STR_MENU_SIZE_LARGE         NSLS(@"menu.view.size.large",        @"Large",              @"Size menu item: the widest window width preset.")

#pragma mark - Convert menu

// STR_MENU_CONVERT_TO_FLAC is also the context-menu item, the save panel's
// title, and the NSUndoManager action name ("Undo Convert to FLAC") — one
// action, so one name everywhere it appears.

#define STR_MENU_CONVERT                 NSLS(@"menu.convert",                 @"Convert",                       @"Menu bar: the Convert menu.")
#define STR_MENU_CONVERT_TO_FLAC         NSLS(@"menu.convert.to_flac",         @"Convert to FLAC",               @"Convert menu item: converts the current uncompressed track to FLAC. Also the save panel's title and the undo action's name. FLAC is a format name — keep it.")
#define STR_MENU_CONVERT_CONVERTING      NSLS(@"menu.convert.converting",      @"Converting…",                   @"Convert menu item, disabled: replaces 'Convert to FLAC' while a conversion is running. Ends with a real ellipsis character (…), not three periods.")
#define STR_MENU_CONVERT_FLAC_EXISTS     NSLS(@"menu.convert.flac_exists",     @"FLAC Already Exists",           @"Convert menu item, disabled: replaces 'Convert to FLAC' when a FLAC of the same name already sits beside the source file.")
#define STR_MENU_CONVERT_DELETE_ORIGINAL NSLS(@"menu.convert.delete_original", @"Delete Original After Convert", @"Convert menu item: a checkmarked preference — when on, a successful conversion moves the original file to the Trash.")

#define STR_LABEL_CONVERT_SAVE_MESSAGE NSLS(@"label.convert.save_message", @"Choose where to save the converted FLAC.", @"Message atop the save panel that appears when the app may not write next to the source file.")

#pragma mark - Output menu

#define STR_MENU_OUTPUT              NSLS(@"menu.output",              @"Output",             @"Menu bar: the menu selecting the audio output device.")
#define STR_MENU_OUTPUT_SYSTEM_NAMED NSLS(@"menu.output.system_named", @"System Output (%@)", @"Output menu item: follow the system's default output device. %@ is that device's name.")
#define STR_MENU_OUTPUT_SYSTEM       NSLS(@"menu.output.system",       @"System Output",      @"Output menu item: follow the system's default output device, used when its name is unknown.")

#pragma mark - Help menu

#define STR_MENU_HELP         NSLS(@"menu.help",         @"Help",        @"Menu bar: the Help menu, the rightmost one. macOS uses this same name in every app.")
#define STR_MENU_HELP_SUPPORT NSLS(@"menu.help.support", @"Get Support", @"Help menu item: opens the app's support page in the browser, where a user gets help or reports a problem.")

#pragma mark - Context menus

#define STR_MENU_SHOW_IN_FINDER NSLS(@"menu.context.show_in_finder", @"Show in Finder", @"Context menu item: reveals the track's file in the Finder. Matches the Finder's own wording.")

#pragma mark - Waveform styles

#define STR_WAVEFORM_STYLE_BASIC           NSLS(@"waveform.style.basic",           @"Basic",                    @"Waveform style name: the simplest bar rendering.")
#define STR_WAVEFORM_STYLE_DETAILED        NSLS(@"waveform.style.detailed",        @"Detailed",                 @"Waveform style name: a higher-resolution bar rendering.")
#define STR_WAVEFORM_STYLE_SONIC_CIRRUS    NSLS(@"waveform.style.sonic_cirrus",    @"Sonic Cirrus",             @"Waveform style name: a cloud-like rendering. An invented proper name — transliterate rather than translate it literally.")
#define STR_WAVEFORM_STYLE_OVERSAMPLING_X2 NSLS(@"waveform.style.oversampling_x2", @"Oversampling Detailed x2", @"Waveform style name: detailed rendering at 2x oversampling. Keep the 'x2'.")
#define STR_WAVEFORM_STYLE_OVERSAMPLING_X4 NSLS(@"waveform.style.oversampling_x4", @"Oversampling Detailed x4", @"Waveform style name: detailed rendering at 4x oversampling. Keep the 'x4'.")
#define STR_WAVEFORM_STYLE_OVERSAMPLING_X8 NSLS(@"waveform.style.oversampling_x8", @"Oversampling Detailed x8", @"Waveform style name: detailed rendering at 8x oversampling. Keep the 'x8'.")

#pragma mark - Themes

#define STR_THEME_NAME_CUSTOM     NSLS(@"theme.name.custom",     @"Custom",     @"Default name for the user theme created on upgrade: it carries the appearance settings the user had customized before themes existed.")

#pragma mark - Header and readout labels

#define STR_LABEL_TRACK_ARTIST_TITLE NSLS(@"label.track.artist_title", @"%1$@ - %2$@",             @"Single-line track label when artist and title are both known. %1$@ is the artist, %2$@ the title — reorder them if that reads better.")
#define STR_LABEL_BITRATE            NSLS(@"label.bitrate",            @"%@ kbps",                 @"Codec label: bitrate in kilobits per second, e.g. '320 kbps'. %@ is the already-formatted number.")
#define STR_LABEL_SAMPLE_RATE        NSLS(@"label.sample_rate",        @"%@ kHz",                  @"Codec label: sample rate in kilohertz, e.g. '44.1 kHz'. %@ is the already-formatted number.")
#define STR_LABEL_BPM                NSLS(@"label.bpm",                @"%@ BPM",                  @"Tempo label: beats per minute, e.g. '128.0 BPM'. %@ is the already-formatted number.")
#define STR_LABEL_TIME_UNKNOWN       NSLS(@"label.time.unknown",       @"--:--",                   @"Placeholder in the elapsed/total time labels when the time is not yet known.")
#define STR_LABEL_PITCH              NSLS(@"label.pitch",              @"PITCH",                   @"Label above the pitch fader. Upper-case, like the printed legend on a DJ turntable. Very tight space — about 8 characters.")
#define STR_LABEL_DROP_HINT          NSLS(@"label.drop_hint",          @"Drop a file or press %@", @"Empty-state hint shown when no track is loaded. %@ is the Open shortcut, rendered as key glyphs (⌘O) — keep it as a placeholder, don't spell it out.")

// The empty playlist pane's drop well. The two-line rest hint is drawn text,
// not a text field: line one, then "or press" beside a drawn ⌘O keycap.

#define STR_LABEL_PLAYLIST_DRAG_HINT    NSLS(@"label.playlist.drag_hint",    @"Drag tracks or folders here", @"Empty playlist pane, first hint line: invites dragging files in.")
#define STR_LABEL_PLAYLIST_OR_PRESS     NSLS(@"label.playlist.or_press",     @"or press",                   @"Empty playlist pane, second hint line: followed by a drawn ⌘O keycap, reading 'or press ⌘O'. Lower-case — it continues the first line's sentence.")
#define STR_LABEL_PLAYLIST_DROP_REPLACE NSLS(@"label.playlist.drop_replace", @"Drop to replace playlist",   @"Drop-target label shown while dragging files over a populated playlist: dropping here replaces the whole playlist.")
#define STR_LABEL_PLAYLIST_DROP_ADD     NSLS(@"label.playlist.drop_add",     @"Drop to add to playlist",    @"Drop-target label shown while dragging files over the playlist: dropping here appends to the playlist.")
#define STR_LABEL_ABOUT_VERSION      NSLS(@"label.about.version",      @"Version %@",              @"About window, and the About screen on both platforms: %@ is the version number, e.g. '1.5 (15) · Release'.")

#pragma mark - Settings window

#define STR_SETTINGS_GENERAL            NSLS(@"settings.general",               @"General",                        @"Settings window: the General pane's toolbar item, and the window's title while that pane is selected. macOS uses this same name in every app's settings.")
#define STR_SETTINGS_ADVANCED           NSLS(@"settings.advanced",              @"Advanced",                       @"Settings window: the Advanced pane's toolbar item, and the window's title while that pane is selected. macOS uses this same name in every app's settings.")
#define STR_SETTINGS_AUDIO_SECTION      NSLS(@"settings.general.audio_section", @"Audio",                          @"Settings, General pane: heading above the audio rows — the output-device choice.")
#define STR_SETTINGS_WINDOW_SECTION     NSLS(@"settings.general.window_section", @"Window",                        @"Settings: heading above the window rows — always on top and waveform drag in the General pane, appearance and tint in the Appearance pane. One key for both, the word being the same; the key keeps its historical settings.general prefix.")
#define STR_SETTINGS_OUTPUT_LABEL       NSLS(@"settings.general.output_label",  @"Output:",                        @"Settings, General pane, Audio group: row beside the dropdown selecting the audio output device. Ends with a colon, stripped at display.")
#define STR_SETTINGS_DEFAULT_PLAYER_LABEL NSLS(@"settings.general.default_player_label", @"Default music player:",     @"Settings, General pane: row title beside the button that makes the app the system's default player for audio files. Ends with a colon, stripped at display.")
#define STR_SETTINGS_DEFAULT_PLAYER_SET NSLS(@"settings.general.default_player.set",     @"Set %@ as default",          @"Settings, General pane, 'Default music player' row: button that claims every supported audio type for the app. %@ is the app name.")
#define STR_SETTINGS_DEFAULT_PLAYER_IS  NSLS(@"settings.general.default_player.is",      @"%@ is the default",          @"Settings, General pane, 'Default music player' row: disabled button title replacing 'Set … as default' once the app already holds every audio type. %@ is the app name.")
#define STR_SETTINGS_ALWAYS_ON_TOP      NSLS(@"settings.general.always_on_top", @"Always on top",                  @"Settings, General pane: checkbox that keeps the player window above all other apps' windows. The same setting as the View menu's 'Always on Top' item, in sentence case per checkbox convention.")

#define STR_SETTINGS_ON_END_LABEL        NSLS(@"settings.playback.on_end_label",                @"On track end:",            @"Settings, Playback pane: label beside the dropdown choosing what happens when a track finishes playing. Ends with a colon.")
#define STR_SETTINGS_ON_END_PLAY_NEXT    NSLS(@"settings.playback.on_end.play_next",            @"Play next track in playlist", @"Settings, Playback pane, choice for what happens when a track finishes: playback continues with the following track in the playlist. The default.")
#define STR_SETTINGS_ON_END_PAUSE        NSLS(@"settings.playback.on_end.pause",                @"Pause",                    @"Settings, Playback pane, choice for what happens when a track finishes: playback stops on the finished track instead of continuing.")
#define STR_SETTINGS_PITCH_RANGE_LABEL   NSLS(@"settings.playback.pitch_range_label",           @"Pitch range:",             @"Settings, Playback pane: label beside the pitch fader range choice (8% or 16%). Ends with a colon.")
#define STR_SETTINGS_SKIP_STEPS_LABEL    NSLS(@"settings.playback.skip_steps_label",            @"Skip steps:",              @"Settings, Playback pane: label beside the dropdown choosing how many bars the three skip actions jump. Ends with a colon.")
#define STR_SETTINGS_SKIP_STEPS_OPTION   NSLS(@"settings.playback.skip_steps_option",           @"%1$ld / %2$ld / %3$ld bars", @"Settings, Playback pane: one skip-size choice, e.g. '8 / 16 / 32 bars' — the three jump sizes of the small, medium and large skip. %1$ld, %2$ld and %3$ld are the bar counts; 'bars' is the musical unit.")
#define STR_SETTINGS_CROSSFADE_LABEL     NSLS(@"settings.playback.crossfade_label",             @"Crossfade:",               @"Settings, Playback pane: label beside the dropdown choosing how long one track blends into the next on a track change. Ends with a colon.")
#define STR_SETTINGS_CROSSFADE_INSTANT   NSLS(@"settings.playback.crossfade.instant",           @"Instant",                  @"Settings, Playback pane, crossfade choice: no audible blend — the next track starts immediately. The default.")
#define STR_SETTINGS_CROSSFADE_SHORT     NSLS(@"settings.playback.crossfade.short",             @"Short (0.5s)",             @"Settings, Playback pane, crossfade choice: a half-second blend into the next track. Localize the decimal separator; 's' abbreviates seconds.")
#define STR_SETTINGS_CROSSFADE_LONG      NSLS(@"settings.playback.crossfade.long",              @"Long (2s)",                @"Settings, Playback pane, crossfade choice: a two-second blend into the next track. 's' abbreviates seconds.")
#define STR_SETTINGS_ENABLE_FX          NSLS(@"settings.playback.enable_fx",                    @"Enable audio FX",          @"Settings, Playback pane: checkbox choosing whether the DJ performance effects (low kill, reverb, delay) are available. 'FX' is the DJ term for effects, left untranslated.")
#define STR_SETTINGS_ENABLE_FX_RESTART  NSLS(@"settings.playback.enable_fx_restart",            @"Takes effect after %@ is reopened.", @"Settings, Playback pane: small caption shown only when this run has no audio-FX graph, explaining that enabling FX requires reopening. %@ is the app name.")
#define STR_SETTINGS_ANALYSIS_SECTION   NSLS(@"settings.playback.analysis_section",             @"Analysis",                 @"Settings, Playback pane: heading above the group of rows enabling automatic tempo and key analysis.")
#define STR_SETTINGS_DETECT_BPM         NSLS(@"settings.playback.detect_bpm",                   @"Detect BPM automatically", @"Settings, Playback pane: checkbox enabling tempo analysis of loaded files. BPM is beats per minute; a tempo already tagged in the file always shows regardless.")
#define STR_SETTINGS_DETECT_KEY         NSLS(@"settings.playback.detect_key",                   @"Detect key automatically", @"Settings, Playback pane: checkbox enabling musical-key analysis of loaded files. A key already tagged in the file always shows regardless.")
#define STR_SETTINGS_SHOW_BPM           NSLS(@"settings.appearance.show_bpm",                   @"Show BPM",                 @"Settings, Appearance pane: switch showing or hiding the header's tempo readout. BPM is beats per minute. Off leaves detection and tags untouched.")
#define STR_SETTINGS_SHOW_KEY           NSLS(@"settings.appearance.show_key",                   @"Show key",                 @"Settings, Appearance pane: switch showing or hiding the header's musical-key readout. Off dims the key notation and key color rows below it, which then have nothing to govern.")
#define STR_SETTINGS_KEY_NOTATION_LABEL NSLS(@"settings.appearance.key_notation_label",         @"Key notation:",            @"Settings, Appearance pane: label beside the choice of how the musical key is written. Ends with a colon.")
#define STR_SETTINGS_KEY_NOTATION_CAMELOT NSLS(@"settings.appearance.key_notation.camelot",     @"Camelot (8A)",             @"Settings, Appearance pane, key notation choice: the Camelot wheel numbers DJs use for harmonic mixing. Keep 'Camelot' and the '8A' example untranslated — they are notation. The default.")
#define STR_SETTINGS_KEY_NOTATION_MUSICAL NSLS(@"settings.appearance.key_notation.musical",     @"Musical (Am)",             @"Settings, Appearance pane, key notation choice: standard musical note names. Keep the 'Am' example untranslated — it is notation.")
#define STR_SETTINGS_KEY_COLORS         NSLS(@"settings.appearance.key_colors",                 @"Color keys with Camelot colors", @"Settings, Appearance pane: checkbox — when on, the key readout is drawn bold and in the color that key occupies on the Camelot wheel. 'Camelot' is the name of that wheel, a proper noun, left untranslated.")

#define STR_SETTINGS_APPEARANCE_LABEL   NSLS(@"settings.appearance.appearance_label",           @"Appearance:",              @"Settings, Appearance pane: label beside the light/dark appearance choice. Ends with a colon.")
#define STR_SETTINGS_SHOW_TRAFFIC_LIGHTS NSLS(@"settings.appearance.show_traffic_lights",       @"Show traffic lights",      @"Settings, Appearance pane, Window group: switch showing or hiding the main window's custom close and minimize buttons. The buttons are the red and yellow macOS-style dots. The default is on.")
#define STR_SETTINGS_BACKGROUND_TINT_LABEL NSLS(@"settings.appearance.window_tint_label",      @"Background tint",          @"Settings, Appearance pane, Window group: row beside the dropdown choosing the translucent color wash laid over the player window's header background.")
#define STR_SETTINGS_WINDOW_TINT_NONE   NSLS(@"settings.appearance.window_tint.mono",           @"None",                     @"Settings, background tint choice: no color wash — the window's plain glass, the same under every track.")
#define STR_SETTINGS_WINDOW_TINT_ARTWORK NSLS(@"settings.appearance.window_tint.artwork",       @"Artwork color",            @"Settings, window tint choice: the header is washed with the dominant color of the playing track's cover artwork. The default.")
#define STR_SETTINGS_WINDOW_TINT_CUSTOM NSLS(@"settings.appearance.window_tint.custom",         @"Custom",                   @"Settings, window tint choice: the user picks the wash color with a color well.")
#define STR_SETTINGS_WINDOW_TINT_CUSTOM_DARK_LABEL NSLS(@"settings.appearance.window_tint_custom_dark_label", @"Dark color:", @"Settings, Appearance pane: label beside the custom window tint color well used while the app is in dark mode. Ends with a colon.")
#define STR_SETTINGS_WINDOW_TINT_CUSTOM_LIGHT_LABEL NSLS(@"settings.appearance.window_tint_custom_light_label", @"Light color:", @"Settings, Appearance pane: label beside the custom window tint color well used while the app is in light mode. Ends with a colon.")
#define STR_SETTINGS_WAVEFORM_SECTION   NSLS(@"settings.appearance.waveform_section",           @"Waveform",                 @"Settings, Appearance pane: heading above the group of waveform rows — style, color theme, custom colors and drag behavior.")
#define STR_SETTINGS_WAVEFORM_LABEL     NSLS(@"settings.appearance.waveform_label",             @"Style",                    @"Settings, Appearance pane, Waveform group: row beside the dropdown choosing the waveform drawing style.")
#define STR_SETTINGS_WAVEFORM_THEME_LABEL NSLS(@"settings.appearance.waveform_theme_label",     @"Color theme",              @"Settings, Appearance pane, Waveform group: row beside the dropdown choosing the waveform's color palette (as opposed to its drawing style).")
#define STR_SETTINGS_WAVEFORM_GRADIENT  NSLS(@"settings.appearance.theme.waveform_gradient",   @"Gradient",                 @"Settings, theme editor, Waveform group: switch enabling the vertical gradient shading on the waveform bars; off draws them in flat color.")
#define STR_SETTINGS_WAVEFORM_THEME_MONO NSLS(@"settings.appearance.waveform_theme.mono",       @"Mono",                     @"Settings, waveform color theme choice: the monochrome default — white-based in dark mode, black-based in light. 'Mono' as in monochrome, not monaural audio. The default.")
#define STR_SETTINGS_WAVEFORM_THEME_ORANGE NSLS(@"settings.appearance.waveform_theme.orange",   @"Orange",                   @"Settings, waveform color theme choice: the played part of the waveform draws in orange.")
#define STR_SETTINGS_WAVEFORM_THEME_ALBUM_ART NSLS(@"settings.appearance.waveform_theme.album_art", @"Album art",            @"Settings, waveform color theme choice: the not-yet-played part of the waveform draws in a color derived from the track's cover artwork, under a white (dark mode) or black (light mode) played part.")
#define STR_SETTINGS_WAVEFORM_THEME_CUSTOM NSLS(@"settings.appearance.waveform_theme.custom",   @"Custom",                   @"Settings, waveform color theme choice: the user picks the two waveform colors with color wells.")
#define STR_SETTINGS_WAVEFORM_CUSTOM_DARK_LABEL NSLS(@"settings.appearance.waveform_custom_dark_label", @"Dark colors:",     @"Settings, Appearance pane: label beside the custom waveform color wells used while the app is in dark mode. Ends with a colon.")
#define STR_SETTINGS_WAVEFORM_CUSTOM_LIGHT_LABEL NSLS(@"settings.appearance.waveform_custom_light_label", @"Light colors:",  @"Settings, Appearance pane: label beside the custom waveform color wells used while the app is in light mode. Ends with a colon.")
#define STR_SETTINGS_WAVEFORM_CUSTOM_PLAYED NSLS(@"settings.appearance.waveform_custom.played", @"Played",                   @"Settings, custom waveform colors: caption beside the color well for the part of the waveform already played.")
#define STR_SETTINGS_WAVEFORM_CUSTOM_UNPLAYED NSLS(@"settings.appearance.waveform_custom.unplayed", @"Unplayed",             @"Settings, custom waveform colors: caption beside the color well for the part of the waveform not yet played.")
#define STR_SETTINGS_WAVEFORM_CUSTOM_PLAYED_DARK NSLS(@"settings.appearance.waveform_custom.played_dark", @"Played (dark)",  @"iOS settings screen, custom waveform colors: row holding the color well for the played part of the waveform in dark mode.")
#define STR_SETTINGS_WAVEFORM_CUSTOM_UNPLAYED_DARK NSLS(@"settings.appearance.waveform_custom.unplayed_dark", @"Unplayed (dark)", @"iOS settings screen, custom waveform colors: row holding the color well for the not-yet-played part of the waveform in dark mode.")
#define STR_SETTINGS_WAVEFORM_CUSTOM_PLAYED_LIGHT NSLS(@"settings.appearance.waveform_custom.played_light", @"Played (light)", @"iOS settings screen, custom waveform colors: row holding the color well for the played part of the waveform in light mode.")
#define STR_SETTINGS_WAVEFORM_CUSTOM_UNPLAYED_LIGHT NSLS(@"settings.appearance.waveform_custom.unplayed_light", @"Unplayed (light)", @"iOS settings screen, custom waveform colors: row holding the color well for the not-yet-played part of the waveform in light mode.")
#define STR_SETTINGS_WAVEFORM_DRAG_LABEL NSLS(@"settings.appearance.waveform_drag_label",       @"Waveform drag:",           @"Settings, General pane, Window group: row beside the dropdown choosing what dragging the mouse on the waveform does. Ends with a colon, stripped at display. The key keeps its historical settings.appearance prefix.")
#define STR_SETTINGS_WAVEFORM_DRAG_WINDOW NSLS(@"settings.appearance.waveform_drag.window",     @"Move window",              @"Settings, Appearance pane, waveform drag choice: dragging on the waveform moves the whole window, and only a click without movement jumps playback. The default.")
#define STR_SETTINGS_WAVEFORM_DRAG_SEEK NSLS(@"settings.appearance.waveform_drag.seek",         @"Seek",                     @"Settings, Appearance pane, waveform drag choice: dragging on the waveform scrubs through the track like a slider — playback jumps to where the mouse is released — and the window stays put.")
#define STR_SETTINGS_ARTWORK_DRAG_LABEL NSLS(@"settings.general.artwork_drag_label",           @"Artwork drag:",            @"Settings, General pane, Window group: row beside the dropdown choosing what dragging the album artwork out of the window hands to the app it is dropped on. Ends with a colon, stripped at display.")
#define STR_SETTINGS_ARTWORK_DRAG_FILE NSLS(@"settings.general.artwork_drag.copy_file",          @"Copy file",                @"Settings, General pane, artwork drag choice: the drop receives the song file itself, so dropping on the Finder copies the file. The default.")
#define STR_SETTINGS_ARTWORK_DRAG_PATH NSLS(@"settings.general.artwork_drag.copy_path",          @"Copy file path",           @"Settings, General pane, artwork drag choice: the drop receives the song file's location on disk as text, e.g. '/Users/me/Music/song.flac'.")
#define STR_SETTINGS_ARTWORK_DRAG_NAME NSLS(@"settings.general.artwork_drag.copy_artist_title",  @"Copy artist / title",      @"Settings, General pane, artwork drag choice: the drop receives the track's name as text — 'Artist - Title' when both are tagged. Use the words for the performer and the track's name, separated by a slash.")
#define STR_SETTINGS_FILE_INFO          NSLS(@"settings.appearance.file_info",                  @"Show file info",           @"Settings, Appearance pane, and the iOS settings screen: checkbox showing the header's file-format readout (codec, bitrate, sample rate) and, on macOS, the BPM/key line. The same setting as the View menu's 'Show File Info' item, in sentence case per checkbox convention.")
#define STR_SETTINGS_THEMES_SECTION            NSLS(@"settings.appearance.themes_section",            @"Themes",                       @"Settings, Appearance pane: heading above the theme list and its buttons.")
#define STR_SETTINGS_THEME_GROUP_BUILT_IN      NSLS(@"settings.appearance.theme.group_built_in",      @"Built-in",                     @"Settings, Appearance pane: header row in the theme list, above the themes that ship with the app.")
#define STR_SETTINGS_THEME_GROUP_USER          NSLS(@"settings.appearance.theme.group_user",          @"User",                         @"Settings, Appearance pane: header row in the theme list, above the themes the user created, duplicated or imported. Shown only once at least one exists.")
#define STR_SETTINGS_THEME_ADD                 NSLS(@"settings.appearance.theme.add",                 @"Add",                          @"Settings, Appearance pane: pull-down button over the ways to add a theme — new, duplicate, import.")
#define STR_SETTINGS_THEME_ADD_NEW             NSLS(@"settings.appearance.theme.add_new",             @"New Theme",                    @"Add menu item: creates a theme from the current appearance. Also the created theme's default name.")
#define STR_SETTINGS_THEME_DUPLICATE           NSLS(@"settings.appearance.theme.duplicate",           @"Duplicate",                    @"Add menu item, and the button on a built-in theme's read-only editor page: copies the selected theme into an editable one.")
#define STR_SETTINGS_THEME_IMPORT              NSLS(@"settings.appearance.theme.import",              @"Import…",                      @"Add menu item: opens a file chooser for a theme JSON file. Ends with a real ellipsis character (…), not three periods.")
#define STR_SETTINGS_THEME_EXPORT              NSLS(@"settings.appearance.theme.export",              @"Export…",                      @"Settings, Appearance pane: button that saves the selected theme as a JSON file. Ends with a real ellipsis character (…), not three periods.")
#define STR_SETTINGS_THEME_EDIT                NSLS(@"settings.appearance.theme.edit",                @"Edit…",                        @"Settings, Appearance pane: button that opens the selected theme's editor page. Ends with a real ellipsis character (…), not three periods.")
#define STR_SETTINGS_THEME_REMOVE              NSLS(@"settings.appearance.theme.remove",              @"Remove",                       @"Settings, Appearance pane: button that deletes the selected theme. Built-in themes cannot be removed.")
#define STR_SETTINGS_THEME_BACK                NSLS(@"settings.appearance.theme.back",                @"Back",                         @"Settings toolbar: the back half of the navigation control — returns from the theme editor page to the theme list. Accessibility label.")
#define STR_SETTINGS_THEME_FORWARD             NSLS(@"settings.appearance.theme.forward",             @"Forward",                      @"Settings toolbar: the forward half of the navigation control — returns to the theme editor page just left. Accessibility label.")
#define STR_SETTINGS_THEME_NAME_LABEL          NSLS(@"settings.appearance.theme.name_label",          @"Name",                         @"Theme editor: row beside the theme's editable name field.")
#define STR_SETTINGS_THEME_BUILT_IN_CAPTION    NSLS(@"settings.appearance.theme.built_in_caption",    @"Built-in themes can't be edited.", @"Theme editor: caption on a built-in theme's read-only page, shown beside a Duplicate button that makes an editable copy.")
#define STR_SETTINGS_THEME_APPEARANCE          NSLS(@"settings.appearance.theme.appearance",          @"Appearance",                   @"Theme editor, Window group: row beside the dropdown choosing whether the theme keeps one color set used in every appearance (single mode) or separate colors for light and dark.")
#define STR_SETTINGS_THEME_MODE_DUAL           NSLS(@"settings.appearance.theme.mode_dual",           @"Light & Dark Modes",           @"Theme editor, Appearance dropdown: the theme keeps separate colors for the light and dark appearances and follows whichever the window has.")
#define STR_SETTINGS_THEME_MODE_SINGLE         NSLS(@"settings.appearance.theme.mode_single",         @"Single Mode",                  @"Theme editor, Appearance dropdown: the theme keeps one color per field and always uses it, whatever the system or Vibe appearance setting says.")
#define STR_SETTINGS_THEME_BACKGROUND_LABEL    NSLS(@"settings.appearance.theme.background_label",    @"Background",                   @"Theme editor, Window group: row beside the dropdown choosing the window background — the glass look, or a solid color.")
#define STR_SETTINGS_THEME_BACKGROUND_GLASS    NSLS(@"settings.appearance.theme.background.glass",    @"Glass",                        @"Window background choice: the translucent glass look the app ships with.")
#define STR_SETTINGS_THEME_BACKGROUND_SOLID    NSLS(@"settings.appearance.theme.background.solid",    @"Solid color",                  @"Window background choice: a picked color covers the glass; the color's opacity decides how much glass still shows.")
#define STR_SETTINGS_THEME_BACKGROUND_COLORS   NSLS(@"settings.appearance.theme.background_colors",   @"Background colors",            @"Theme editor, Window group: row beside the solid background's two color wells, one per appearance.")
#define STR_SETTINGS_THEME_CORNER_RADIUS       NSLS(@"settings.appearance.theme.corner_radius",       @"Corner radius",                @"Theme editor, Window group: row beside the slider rounding the window's corners.")
#define STR_SETTINGS_THEME_COLOR_TITLE         NSLS(@"settings.appearance.theme.color_title",         @"Title color",                  @"Theme editor, Window group: row beside the title text's color wells. Governs the header title and the playlist titles.")
#define STR_SETTINGS_THEME_COLOR_ARTIST        NSLS(@"settings.appearance.theme.color_artist",        @"Artist color",                 @"Theme editor, Window group: row beside the secondary text's color wells — the artist lines and the playlist's number and length columns.")
#define STR_SETTINGS_THEME_COLOR_INFO          NSLS(@"settings.appearance.theme.color_info",          @"Info color",                   @"Theme editor, Window group: row beside the color wells for the header's codec and BPM/key readouts.")
#define STR_SETTINGS_THEME_COLOR_TIMES         NSLS(@"settings.appearance.theme.color_times",         @"Time color",                   @"Theme editor, Window group: row beside the color wells for the two time labels.")
#define STR_SETTINGS_THEME_DARK                NSLS(@"settings.appearance.theme.dark",                @"Dark",                         @"Theme editor: caption after a color well — the color used while the app is in dark mode.")
#define STR_SETTINGS_THEME_LIGHT               NSLS(@"settings.appearance.theme.light",               @"Light",                        @"Theme editor: caption after a color well — the color used while the app is in light mode.")
#define STR_SETTINGS_PLAYLIST_SECTION          NSLS(@"settings.appearance.playlist_section",          @"Playlist",                     @"Theme editor: heading above the playlist background and row-color rows.")
#define STR_SETTINGS_PLAYER_SECTION            NSLS(@"settings.appearance.player_section",            @"Player",                       @"Theme editor: heading above the player rows — the label colors and the info-display choices.")
#define STR_SETTINGS_THEME_CORNER_RADIUS_VALUE NSLS(@"settings.appearance.theme.corner_radius_value", @"%ld px",                       @"Theme editor: the corner-radius slider's live readout, e.g. '20 px'. %ld is the radius in pixels.")
#define STR_SETTINGS_THEME_PLAYLIST_BACKGROUND NSLS(@"settings.appearance.theme.playlist_background", @"Playlist background",          @"Theme editor, Playlist group: row beside the dropdown choosing the playlist background — the frosted glass look, or a solid color.")
#define STR_SETTINGS_THEME_PLAYLIST_BACKGROUND_COLORS NSLS(@"settings.appearance.theme.playlist_background_colors", @"Playlist background colors", @"Theme editor, Playlist group: row beside the solid playlist background's two color wells, one per appearance.")
#define STR_SETTINGS_THEME_PLAYLIST_TINT       NSLS(@"settings.appearance.theme.playlist_tint_label", @"Playlist background tint",     @"Theme editor, Playlist group: row beside the dropdown choosing the translucent color wash laid over the playlist background — the same choices as the window's background tint.")
#define STR_SETTINGS_THEME_PLAYING_ROW         NSLS(@"settings.appearance.theme.playing_row",         @"Playing row",                  @"Theme editor, Playlist group: row beside the color wells filling the playing track's row.")
#define STR_SETTINGS_THEME_SELECTED_ROW        NSLS(@"settings.appearance.theme.selected_row",        @"Selected row",                 @"Theme editor, Playlist group: row beside the color wells filling selected rows.")
#define STR_SETTINGS_FONTS_SECTION             NSLS(@"settings.appearance.fonts_section",             @"Fonts",                        @"Theme editor: heading above the three font rows.")
#define STR_SETTINGS_THEME_FONT_MAIN           NSLS(@"settings.appearance.theme.font_main",           @"Main font",                    @"Theme editor, Fonts group: row for the title and artist font.")
#define STR_SETTINGS_THEME_FONT_INFO           NSLS(@"settings.appearance.theme.font_info",           @"Info font",                    @"Theme editor, Fonts group: row for the font of the times and the codec and BPM/key readouts.")
#define STR_SETTINGS_THEME_FONT_PLAYLIST       NSLS(@"settings.appearance.theme.font_playlist",       @"Playlist font",                @"Theme editor, Fonts group: row for the playlist rows' font.")
#define STR_SETTINGS_THEME_FONT_PLAYLIST_DURATION NSLS(@"settings.appearance.theme.font_playlist_duration", @"Playlist duration",     @"Theme editor, Fonts group: row for the font of the playlist's duration column.")
#define STR_SETTINGS_THEME_PLAYLIST_ARTWORK    NSLS(@"settings.appearance.theme.playlist_artwork",    @"Artwork column",               @"Theme editor, Playlist group: switch showing or hiding the playlist's album-art column.")
#define STR_SETTINGS_THEME_PLAYLIST_DURATION_COLUMN NSLS(@"settings.appearance.theme.playlist_duration_column", @"Duration column",    @"Theme editor, Playlist group: switch showing or hiding the playlist's track-duration column.")
#define STR_SETTINGS_THEME_FONT_SELECT         NSLS(@"settings.appearance.theme.font_select",         @"Select…",                      @"Theme editor, Fonts group: button opening the system font panel for that row's font. Ends with a real ellipsis character (…), not three periods.")
#define STR_SETTINGS_THEME_FONT_VALUE          NSLS(@"settings.appearance.theme.font_value",          @"%1$@ %2$ld pt",                @"Theme editor, Fonts group: the current choice, e.g. 'Helvetica Neue 23 pt'. %1$@ is the font's name, %2$ld its size in points.")
#define STR_SETTINGS_THEME_IMPORT_FAILED       NSLS(@"settings.appearance.theme.import_failed",       @"This file isn't a Vibe theme.", @"Alert shown when an imported file could not be read as a theme JSON.")
#define STR_THEME_NAME_IMPORTED                NSLS(@"theme.name.imported",                           @"Imported Theme",               @"Default name for an imported theme whose file carried no name.")
#define STR_SETTINGS_TIME_LABEL         NSLS(@"settings.appearance.time_label",                 @"Time display:",            @"Settings, Appearance pane: label beside the choice between showing the track's total time or the remaining time. Ends with a colon.")
#define STR_SETTINGS_TIME_TOTAL         NSLS(@"settings.appearance.time_total",                 @"Total time",               @"Settings, Appearance pane, and the iOS settings screen, time display choice: the right time label shows the track's full length. Pairs with 'Remaining time' — use the same noun in both.")
#define STR_SETTINGS_TIME_REMAINING     NSLS(@"settings.appearance.time_remaining",             @"Remaining time",           @"Settings, Appearance pane, and the iOS settings screen, time display choice: the right time label counts down the time left, e.g. '-1:50'. Pairs with 'Total time' — use the same noun in both.")

#define STR_SETTINGS_CONVERT_ENABLED     NSLS(@"settings.convert.enabled",                      @"Enabled",                  @"Settings, Convert pane: switch showing or hiding the whole Convert feature — off removes the Convert menu from the menu bar and the Convert to FLAC item from the context menus.")
#define STR_SETTINGS_CONVERT_DEST_LABEL  NSLS(@"settings.convert.destination_label",            @"Save converted files:",    @"Settings, Convert pane: label beside the dropdown choosing where Convert to FLAC writes its output. Ends with a colon.")
#define STR_SETTINGS_CONVERT_DEST_BESIDE NSLS(@"settings.convert.destination.beside",           @"Next to original",         @"Settings, Convert pane, converted-file destination choice: the FLAC is written into the same folder as the source file. The default.")
#define STR_SETTINGS_CONVERT_DEST_ASK    NSLS(@"settings.convert.destination.ask",              @"Ask where to save",        @"Settings, Convert pane, converted-file destination choice: every conversion shows a save panel asking where to put the FLAC.")
#define STR_SETTINGS_DELETE_ORIGINAL     NSLS(@"settings.convert.delete_original",              @"Delete original after convert", @"Settings, Convert pane: checkbox — when on, a successful conversion moves the original file to the Trash. The same setting as the Convert menu's 'Delete Original After Convert' item, in sentence case per checkbox convention.")

// The Files pane holds the granted-folder list and the folder-artwork setting.
// The folder strings keep their settings.permissions.* keys, unchanged in
// meaning and translation; only the pane's own title is a new key, since
// reusing one would keep shipping the translated word "Permissions" until every
// language was revisited.
#define STR_SETTINGS_FILES                NSLS(@"settings.files",                               @"Files",                    @"Settings window: the Files pane's toolbar item, and the window's title while that pane is selected; also the Files row on the iOS settings screen. The pane covers where the app looks for album art and which folders it keeps access to.")
#define STR_SETTINGS_FOLDER_SORT_LABEL    NSLS(@"settings.files.folder_sort_label",             @"When opening a folder:",   @"Settings, Files pane: label beside the dropdown choosing the order a folder's songs are added to the playlist when that folder is opened. Ends with a colon.")
#define STR_SETTINGS_FOLDER_SORT_NAME     NSLS(@"settings.files.folder_sort.name",              @"Sort by name",             @"Settings, Files pane, folder open sort choice: order the songs by filename, counting numbers in a filename as numbers. The default.")
#define STR_SETTINGS_FOLDER_SORT_NEWEST_FIRST NSLS(@"settings.files.folder_sort.newest_first", @"Newest first",             @"Settings, Files pane, folder open sort choice: order the songs by the date each file was last changed, most recent first — the same date the Finder and the iPhone Files app call Date Modified.")
#define STR_SETTINGS_FOLDER_SORT_AS_RECEIVED  NSLS(@"settings.files.folder_sort.as_received",  @"Keep folder order",        @"Settings, Files pane, folder open sort choice: do not reorder the songs at all — keep whatever order the disk or the cloud storage service listed them in.")
#define STR_SETTINGS_ALBUM_ART_LABEL      NSLS(@"settings.files.album_art_label",               @"Album art:",               @"Settings, Files pane: label beside the dropdown choosing where the cover image shown for a song comes from. Ends with a colon.")
#define STR_SETTINGS_ALBUM_ART_FILE_ONLY  NSLS(@"settings.files.album_art.file_only",           @"Load from file only",      @"Settings, Files pane, album art choice: use only the artwork stored inside the song file, and show nothing for a song carrying none.")
#define STR_SETTINGS_ALBUM_ART_FOLDER     NSLS(@"settings.files.album_art.folder",              @"File first, then search folder", @"Settings, Files pane, album art choice: prefer the artwork stored inside the track's own file, and for a track carrying none use a cover image file sitting beside it in the same folder. The default.")
#define STR_SETTINGS_PERMISSIONS_LABEL    NSLS(@"settings.permissions.label",                   @"Permissions:",             @"Settings, Files pane: label beside the list of folders the app may read, and the paragraph above it. Ends with a colon.")
#define STR_SETTINGS_PERMISSIONS_EXPLAIN  NSLS(@"settings.permissions.explain",                 @"%@ can read music in these folders. Add the ones you use often to avoid repeated permission prompts.", @"Settings, Files pane: explanatory text above the list of granted folders. %@ is the app name.")
#define STR_SETTINGS_ADD_FOLDER           NSLS(@"settings.permissions.add_folder",              @"Add Folder…",              @"Settings, Files pane: button that opens a folder chooser to grant the app access to another folder. Ends with a real ellipsis character (…), not three periods.")
#define STR_SETTINGS_ADD_COMMON_FOLDER    NSLS(@"settings.permissions.add_common_folder",       @"Add Common Folder",        @"Settings, Files pane: pull-down button whose menu grants the app access to one of the usual music locations — the home folder, Documents, iCloud Drive or Dropbox.")
#define STR_SETTINGS_FOLDER_HOME          NSLS(@"settings.permissions.folder.home",             @"Home Folder",              @"Settings, Files pane, Add Common Folder menu: the user's home folder. Use the name the Finder gives it in this language.")
#define STR_SETTINGS_FOLDER_DOCUMENTS     NSLS(@"settings.permissions.folder.documents",        @"Documents",                @"Settings, Files pane, Add Common Folder menu: the Documents folder inside the user's home folder. Use the name the Finder gives it in this language.")
#define STR_SETTINGS_FOLDER_NOT_FOUND     NSLS(@"settings.permissions.folder.not_found",        @"%@ (Not found)",           @"Settings, Files pane, Add Common Folder menu: a disabled entry for a folder that does not exist on this Mac. %@ is the folder's name, e.g. 'Dropbox'.")
#define STR_SETTINGS_FOLDER_ALREADY_ADDED NSLS(@"settings.permissions.folder.already_added",    @"%@ (Already accessible)",  @"Settings, Files pane, Add Common Folder menu: a disabled entry for a folder the app can already read, because it or a folder above it is in the list. %@ is the folder's name, e.g. 'Documents'.")
#define STR_SETTINGS_FOLDER_UNAVAILABLE   NSLS(@"settings.permissions.folder.unavailable",      @"%@ (Unavailable)",         @"Settings, Files pane, granted-folder list: a dimmed row for a folder the app can no longer reach, because it was deleted or renamed or its disk is not connected. %@ is the folder's path.")
#define STR_SETTINGS_FOLDER_UNAVAILABLE_TIP NSLS(@"settings.permissions.folder.unavailable.tip", @"This folder is missing, or on a disk that isn’t connected. %@ keeps its permission and will use it again if it comes back.", @"Settings, Files pane, granted-folder list: tooltip on a dimmed row, explaining why an unreachable folder is still listed. %@ is the app name. Uses a curly apostrophe (’).")
#define STR_SETTINGS_FOLDER_GRANT_MESSAGE NSLS(@"settings.permissions.folder_grant.message",    @"Grant %1$@ access to “%2$@”, so it can read music anywhere inside it.", @"Message atop the folder-picker panel opened from the Add Common Folder menu, which starts in the chosen folder. %1$@ is the app name, %2$@ that folder's name, e.g. 'Documents'.")
#define STR_SETTINGS_FOLDER_GRANT_BUTTON  NSLS(@"settings.permissions.folder_grant.button",     @"Grant Access",             @"Confirm button of the folder-picker panel opened from the Add Common Folder menu.")
#define STR_SETTINGS_REMOVE_FOLDER        NSLS(@"settings.permissions.remove",                  @"Remove",                   @"Settings, Files pane: button that removes the selected folder from the granted list, giving up the app's access to it.")

#define STR_SETTINGS_REFRESH_RATE_LABEL   NSLS(@"settings.advanced.refresh_rate_label",         @"Playhead refresh:",        @"Settings, Advanced pane: label beside the dropdown choosing how often the playhead — the marker moving across the waveform — is redrawn. Ends with a colon.")
#define STR_SETTINGS_REFRESH_RATE_LOW     NSLS(@"settings.advanced.refresh_rate.low",           @"Low (3 Hz)",               @"Settings, Advanced pane, playhead refresh choice: the slowest and cheapest, three redraws a second. Hz is the international unit symbol for times per second and is not translated.")
#define STR_SETTINGS_REFRESH_RATE_NORMAL  NSLS(@"settings.advanced.refresh_rate.normal",        @"Normal (30 Hz)",           @"Settings, Advanced pane, playhead refresh choice: up to thirty redraws a second. The default. Hz is the international unit symbol for times per second and is not translated.")
#define STR_SETTINGS_REFRESH_RATE_HIGH    NSLS(@"settings.advanced.refresh_rate.high",          @"High (60 Hz)",             @"Settings, Advanced pane, playhead refresh choice: up to sixty redraws a second, the smoothest and the most power-hungry. Hz is the international unit symbol for times per second and is not translated.")

#define STR_SETTINGS_FACTORY_RESET_LABEL  NSLS(@"settings.advanced.factory_reset_label",         @"Factory reset:",           @"Settings, Advanced pane: label beside the Reset to Defaults button, which restores every setting and the window shape to their shipping state. The term a consumer device uses for restoring factory settings. Ends with a colon.")
#define STR_SETTINGS_RESET_DEFAULTS       NSLS(@"settings.advanced.reset_defaults",             @"Reset to Defaults",        @"Settings, Advanced pane: button that returns every setting to its default value. Disabled while nothing has been changed.")
#define STR_SETTINGS_CACHE_LABEL          NSLS(@"settings.advanced.cache_label",                @"Cache size:",              @"Settings, Advanced pane: label beside the readout of the metadata and waveform caches' current size. Ends with a colon.")
#define STR_SETTINGS_CACHE_VALUE          NSLS(@"settings.advanced.cache_value",                @"%1$@ files, %2$@ MB",      @"Settings, Advanced pane: the cache-size readout, e.g. '312 files, 48.2 MB'. %1$@ is the already-formatted file count, %2$@ the already-formatted megabytes.")
#define STR_SETTINGS_CLEAR_CACHE          NSLS(@"settings.advanced.clear_cache",                @"Clear Cache",              @"Settings, Advanced pane: button that empties the metadata and waveform caches.")
#define STR_SETTINGS_STATS_SECTION        NSLS(@"settings.advanced.stats_section",              @"Statistics",               @"Settings, About pane on both platforms: heading above the group of lifetime playback-statistics rows.")
#define STR_SETTINGS_FILES_OPENED_LABEL   NSLS(@"settings.advanced.files_opened_label",         @"Files opened:",            @"Settings, About pane on both platforms, statistics: label beside the lifetime count of files opened. Ends with a colon, dropped where the layout puts the value in its own column.")
#define STR_SETTINGS_FOLDERS_OPENED_LABEL NSLS(@"settings.advanced.folders_opened_label",       @"Folders opened:",          @"Settings, About pane on both platforms, statistics: label beside the lifetime count of folders opened. Ends with a colon, dropped where the layout puts the value in its own column.")
#define STR_SETTINGS_AUDIO_PLAYED_LABEL   NSLS(@"settings.advanced.audio_played_label",         @"Audio played:",            @"Settings, About pane on both platforms, statistics: label beside the total listening time, shown in words like '3 days, 4 hours'. Ends with a colon, dropped where the layout puts the value in its own column.")

#define STR_SETTINGS_BUILD_SECTION        NSLS(@"settings.advanced.build_section",              @"Build",                    @"Settings, Advanced pane: heading above the rows describing this exact build of the app — version, source revision and languages. 'Build' as the software-development noun.")
#define STR_SETTINGS_VERSION_LABEL        NSLS(@"settings.advanced.version_label",              @"Version:",                 @"Settings, Advanced pane, Build group: label beside the app's version number. Ends with a colon.")
#define STR_SETTINGS_GIT_LABEL            NSLS(@"settings.advanced.git_label",                  @"Git hash:",                @"Settings, Advanced pane, Build group: label beside the source-control revision the app was built from. 'Git' is the version-control system's name and is not translated. Ends with a colon.")
#define STR_SETTINGS_LANGUAGE_LABEL       NSLS(@"settings.advanced.language_label",             @"Language:",                @"Settings, Advanced pane, Build group: label beside the language the app is currently running in. Ends with a colon.")
#define STR_SETTINGS_LANGUAGES_LABEL      NSLS(@"settings.advanced.languages_label",            @"Available languages:",     @"Settings, Advanced pane, Build group: label beside the row of flags for every language this build ships. Ends with a colon.")

#define STR_SETTINGS_ABOUT                NSLS(@"settings.about",                               @"About",                    @"Settings window: the About pane's sidebar item, and the window's title while that pane is selected; also the About row and screen title on iOS. It shows the app icon, version, project links and lifetime statistics. Use the word Apple uses for an app's About screen in this language.")
#define STR_SETTINGS_ABOUT_WEB            NSLS(@"settings.about.web",                           @"Web",                      @"Settings, About pane on both platforms: row title beside the link to the app's website. Short label for a website address; keep it to one word.")
#define STR_SETTINGS_ABOUT_SUPPORT        NSLS(@"settings.about.support",                       @"Support",                  @"Settings, About pane on both platforms: row title beside the link to the app's support page, where a user gets help or reports a problem.")

#pragma mark - Accessibility labels

// Only the controls with no menu counterpart; the transport buttons reuse the
// STR_TRANSPORT_* strings above.

#define STR_A11Y_TOGGLE_PLAYLIST NSLS(@"a11y.playlist.toggle", @"Toggle Playlist",      @"Accessibility label for the button that shows and hides the playlist.")
#define STR_A11Y_PLAYLIST_OPEN   NSLS(@"a11y.playlist.open",   @"Open tracks or folders", @"Accessibility label for the empty playlist pane's drop well, which opens the file picker when pressed.")
#define STR_A11Y_WINDOW_CLOSE    NSLS(@"a11y.window.close",    @"Close",           @"Accessibility label for the window's close button.")
#define STR_A11Y_WINDOW_MINIMIZE NSLS(@"a11y.window.minimize", @"Minimize",        @"Accessibility label for the window's minimize button.")
#define STR_A11Y_WAVEFORM        NSLS(@"a11y.waveform",        @"Playback Position", @"Accessibility label for the waveform, which is a slider: it shows where playback has reached in the track and seeks when adjusted. Read aloud by a screen reader, never drawn on screen. Both platforms.")
#define STR_A11Y_PITCH_FADER     NSLS(@"a11y.pitch_fader",     @"Pitch",           @"Accessibility label for the pitch fader, the slider that speeds the track up or slows it down like a turntable's. Read aloud by a screen reader, never drawn on screen; the drawn legend is the separate upper-case 'PITCH'.")

#pragma mark - Playback errors

// Shown inline on the artist line, over the failed track's title. Kept short:
// the title line already names the track and the full error goes to the log.

#define STR_ERROR_LOAD_TIMEOUT        NSLS(@"error.load_timeout",        @"Load timed out",           @"Inline playback error: opening the file took too long, e.g. an undownloaded cloud file.")
#define STR_ERROR_OPEN_FAILED         NSLS(@"error.open_failed",         @"Could not open file",      @"Inline playback error: the audio file could not be opened.")
#define STR_ERROR_ENGINE_START_FAILED NSLS(@"error.engine_start_failed", @"Could not start playback", @"Inline playback error: the audio engine failed to start.")
#define STR_ERROR_DEVICE_UNAVAILABLE  NSLS(@"error.device_unavailable",  @"Audio device unavailable", @"Inline playback error: no usable audio output device.")
#define STR_ERROR_PLAYBACK_GENERIC    NSLS(@"error.playback_generic",    @"Playback error",           @"Inline playback error: fallback for an unrecognized failure.")

#pragma mark - Playlist files (CUE, M3U)

#define STR_PLAYLIST_GRANT_MESSAGE NSLS(@"playlist.grant.message", @"%1$@ needs permission to read the audio files listed in “%2$@”. Select the folder that contains them.", @"Message atop the folder-picker panel shown when a playlist file's (CUE, M3U) audio files are not readable under the sandbox. %1$@ is the app name, %2$@ the playlist file's name.")
#define STR_PLAYLIST_GRANT_BUTTON  NSLS(@"playlist.grant.button",  @"Grant Access", @"Confirm button of the folder-picker panel that grants access to a playlist file's folder.")

#pragma mark - iOS

#define STR_LABEL_SEARCH        NSLS(@"label.search",        @"Search",                      @"iOS: title and placeholder of the search screen, which searches both the current playlist and the files in reach.")

#define STR_SEARCH_SECTION_PLAYLIST NSLS(@"search.section.playlist", @"Playlist",         @"iOS: header of the search results section listing matches among the tracks queued to play.")
#define STR_SEARCH_SECTION_FILES    NSLS(@"search.section.files",    @"Files",            @"iOS: header of the search results section listing matching audio files found elsewhere in the user's files, which are not in the playlist yet.")
#define STR_SEARCH_FILES_SCANNING   NSLS(@"search.files.scanning",   @"Searching files…", @"iOS: shown under the search results while the app is still looking through the user's files, so a short list reads as incomplete rather than final. Ends with an ellipsis character.")
#define STR_ERROR_FOLDER_EMPTY  NSLS(@"error.folder_empty",  @"No audio files in this folder",  @"iOS: shown after picking a folder that contains no playable audio files.")

#define STR_SETTINGS_TITLE            NSLS(@"settings.title",            @"Settings",       @"iOS: title of the settings screen, and the label of the gear button on the playlist screen that opens it. Use the name Apple gives the Settings app in this language.")
#define STR_SETTINGS_SECTION_WAVEFORM NSLS(@"settings.section.waveform", @"Waveform style", @"iOS settings screen: heading above the list of waveform drawing styles.")
#define STR_SETTINGS_SECTION_WAVEFORM_THEME NSLS(@"settings.section.waveform_theme", @"Waveform theme", @"iOS settings screen: heading above the list of waveform color themes.")
#define STR_SETTINGS_SECTION_TIME     NSLS(@"settings.section.time",     @"Time display",   @"iOS settings screen: heading above the choice between showing the track's total duration and the time remaining.")

#define STR_SETTINGS_SECTION_FOLDER_SORT    NSLS(@"settings.section.folder_sort",    @"When opening a folder", @"iOS settings screen: heading above the choice of what order a folder's songs are added to the playlist in when that folder is opened.")
#define STR_SETTINGS_SECTION_SEARCH_FOLDERS NSLS(@"settings.section.search_folders", @"Folders to search", @"iOS settings screen: heading above the list of folders the user has given the app permission to search.")
#define STR_SETTINGS_SEARCH_FOLDERS_FOOTER  NSLS(@"settings.search_folders.footer",  @"Search looks through the folder you have open and anything you add here, including subfolders. %@ cannot search your files without being given a folder first.", @"iOS settings screen: explanation under the list of searchable folders. %@ is the app name. Says what search already covers, that subfolders are included, and why adding a folder is necessary — iOS gives an app no access to files the user has not handed it.")
#define STR_SETTINGS_SEARCH_FOLDERS_ADD     NSLS(@"settings.search_folders.add",     @"Add Folder…",       @"iOS settings screen: the last row under the searchable folders, which opens the system folder picker. Ends with a real ellipsis character (…), not three periods.")
#define STR_SETTINGS_SEARCH_FOLDERS_COVERED NSLS(@"settings.search_folders.covered", @"That folder is already inside one you added, so it is being searched already.", @"iOS settings screen: alert message shown when the user adds a folder that sits inside a folder already on the list. Permission to a folder covers everything inside it, so nothing needed to be added.")
#define STR_BUTTON_OK                       NSLS(@"button.ok",                       @"OK",                @"Dismiss button of an alert that only reports something, with nothing to choose. Use the wording the system uses for this button in this language.")

#define STR_TAB_PLAYLIST        NSLS(@"tab.playlist",        @"Playlist",                    @"iOS: title of the tab showing the tracks queued to play.")
#define STR_TAB_FAVORITES       NSLS(@"tab.favorites",       @"Favorites",                   @"iOS: title of the tab listing the folders the user starred, to reopen one in a tap.")
#define STR_TAB_FILES           NSLS(@"tab.files",           @"Files",                       @"iOS: title of the tab showing the system file browser, for picking music to play.")
#define STR_BUTTON_OPEN         NSLS(@"button.open",         @"Open",                        @"iOS: button that opens the system document picker to choose a folder or file to play.")
#define STR_LABEL_EMPTY_TITLE   NSLS(@"label.library.empty.title",   @"Nothing to Play",     @"iOS: headline of the empty library screen, shown when no folder or file has been opened.")
#define STR_LABEL_EMPTY_MESSAGE NSLS(@"label.library.empty.message", @"Choose a folder or file to get started.", @"iOS: explanatory line under the empty library headline, above the Open button.")

#define STR_LABEL_FAVORITES_EMPTY_TITLE   NSLS(@"label.favorites.empty.title",   @"No Favorites", @"iOS: headline of the empty favorites screen, shown when the user has not starred any folder yet.")
#define STR_LABEL_FAVORITES_EMPTY_MESSAGE NSLS(@"label.favorites.empty.message", @"Star a folder you have open to keep it here.", @"iOS: explanatory line under the empty favorites headline. It says how a favorite is made: open a folder, then tap the star button on the playlist screen.")
#define STR_ERROR_FAVORITE_UNAVAILABLE    NSLS(@"error.favorite.unavailable",    @"This folder can’t be opened right now. It may have been moved or deleted, or its cloud service may be signed out.", @"iOS: alert message shown when tapping a favorite whose folder could not be found. The alert’s title is the folder’s name. Uses a curly apostrophe (’).")

#define STR_A11Y_MINIPLAYER_EXPAND NSLS(@"a11y.miniplayer.expand", @"Now Playing",  @"iOS: accessibility label for the mini player strip above the tab bar; activating it opens the full-screen player.")
#define STR_A11Y_PLAYER_MINIMIZE   NSLS(@"a11y.player.minimize",   @"Minimize",     @"iOS: accessibility label for the full-screen player's grabber, which returns it to the mini player strip.")
#define STR_A11Y_PLAYER_OUTPUT_ROUTE NSLS(@"a11y.player.output_route", @"Output Device", @"iOS: accessibility label for the button on the full-screen player that opens the system list of AirPlay and Bluetooth devices to play through.")
#define STR_A11Y_ADD_FAVORITE      NSLS(@"a11y.favorite.add",      @"Add to Favorites",      @"iOS: accessibility label for the star button on the playlist screen, when the open folder is not starred yet; activating it adds the folder to the Favorites tab.")
#define STR_A11Y_REMOVE_FAVORITE   NSLS(@"a11y.favorite.remove",   @"Remove from Favorites", @"iOS: accessibility label for the star button on the playlist screen, when the open folder is already starred; activating it takes the folder off the Favorites tab.")

#endif /* VibeStrings_h */
