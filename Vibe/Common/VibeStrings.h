//
// Created by Christopher Micali on 7/25/26.
// Copyright (c) 2026 Christopher Micali. All rights reserved.
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

// Lifts out the invariant scaffolding so entries read as key/English/comment.
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

#define STR_MENU_EDIT           NSLS(@"menu.edit",           @"Edit",      @"Menu bar: the Edit menu. Holds Undo, Redo, and the two Copy items.")
#define STR_MENU_EDIT_UNDO      NSLS(@"menu.edit.undo",      @"Undo",      @"Edit menu item: undoes the last action. macOS uses this same name in every app.")
#define STR_MENU_EDIT_REDO      NSLS(@"menu.edit.redo",      @"Redo",      @"Edit menu item: redoes the last undone action. macOS uses this same name in every app.")
#define STR_MENU_EDIT_COPY_FILE NSLS(@"menu.edit.copy_file", @"Copy File", @"Edit menu item: puts the current track's audio file on the clipboard, ready to paste in the Finder. Use the same verb as the system's Edit > Copy.")
#define STR_MENU_EDIT_COPY_NAME NSLS(@"menu.edit.copy_name", @"Copy Name", @"Edit menu item: copies the current track's display name — 'Artist - Title' — as text. Use the same verb as the system's Edit > Copy.")

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
#define STR_MENU_VIEW_APPEARANCE    NSLS(@"menu.view.appearance",        @"Appearance",         @"View menu: submenu choosing the light/dark appearance.")
#define STR_MENU_APPEARANCE_SYSTEM  NSLS(@"menu.view.appearance.system", @"System default",     @"Appearance menu item: follow the system's light/dark setting.")
#define STR_MENU_APPEARANCE_LIGHT   NSLS(@"menu.view.appearance.light",  @"Light",              @"Appearance menu item: always use the light appearance.")
#define STR_MENU_APPEARANCE_DARK    NSLS(@"menu.view.appearance.dark",   @"Dark",               @"Appearance menu item: always use the dark appearance.")
#define STR_MENU_VIEW_WAVEFORM      NSLS(@"menu.view.waveform",          @"Waveform",           @"View menu: submenu choosing the waveform drawing style.")
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

#pragma mark - Context menus

#define STR_MENU_SHOW_IN_FINDER NSLS(@"menu.context.show_in_finder", @"Show in Finder", @"Context menu item: reveals the track's file in the Finder. Matches the Finder's own wording.")

#pragma mark - Waveform styles

#define STR_WAVEFORM_STYLE_BASIC           NSLS(@"waveform.style.basic",           @"Basic",                    @"Waveform style name: the simplest bar rendering.")
#define STR_WAVEFORM_STYLE_DETAILED        NSLS(@"waveform.style.detailed",        @"Detailed",                 @"Waveform style name: a higher-resolution bar rendering.")
#define STR_WAVEFORM_STYLE_SONIC_CIRRUS    NSLS(@"waveform.style.sonic_cirrus",    @"Sonic Cirrus",             @"Waveform style name: a cloud-like rendering. An invented proper name — transliterate rather than translate it literally.")
#define STR_WAVEFORM_STYLE_OVERSAMPLING_X2 NSLS(@"waveform.style.oversampling_x2", @"Oversampling Detailed x2", @"Waveform style name: detailed rendering at 2x oversampling. Keep the 'x2'.")
#define STR_WAVEFORM_STYLE_OVERSAMPLING_X4 NSLS(@"waveform.style.oversampling_x4", @"Oversampling Detailed x4", @"Waveform style name: detailed rendering at 4x oversampling. Keep the 'x4'.")
#define STR_WAVEFORM_STYLE_OVERSAMPLING_X8 NSLS(@"waveform.style.oversampling_x8", @"Oversampling Detailed x8", @"Waveform style name: detailed rendering at 8x oversampling. Keep the 'x8'.")

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

#define STR_LABEL_PLAYLIST_DRAG_HINT    NSLS(@"label.playlist.drag_hint",    @"Drag songs or folders here", @"Empty playlist pane, first hint line: invites dragging files in.")
#define STR_LABEL_PLAYLIST_OR_PRESS     NSLS(@"label.playlist.or_press",     @"or press",                   @"Empty playlist pane, second hint line: followed by a drawn ⌘O keycap, reading 'or press ⌘O'. Lower-case — it continues the first line's sentence.")
#define STR_LABEL_PLAYLIST_DROP_REPLACE NSLS(@"label.playlist.drop_replace", @"Drop to replace playlist",   @"Drop-target label shown while dragging files over a populated playlist: dropping here replaces the whole playlist.")
#define STR_LABEL_PLAYLIST_DROP_ADD     NSLS(@"label.playlist.drop_add",     @"Drop to add to playlist",    @"Drop-target label shown while dragging files over the playlist: dropping here appends to the playlist.")
#define STR_LABEL_ABOUT_VERSION      NSLS(@"label.about.version",      @"Version %@",              @"About window: %@ is the version number, e.g. '1.5 (15) · Release'.")

#pragma mark - Settings window

// The default-player pair moved here from the app menu; their keys stay
// menu.app.* so the existing translations carry over.

#define STR_SETTINGS_GENERAL            NSLS(@"settings.general",              @"General",                        @"Settings window: the General pane's toolbar item, and the window's title while that pane is selected. macOS uses this same name in every app's settings.")
#define STR_SETTINGS_ADVANCED           NSLS(@"settings.advanced",             @"Advanced",                       @"Settings window: the Advanced pane's toolbar item, and the window's title while that pane is selected. macOS uses this same name in every app's settings.")
#define STR_SETTINGS_OUTPUT_LABEL       NSLS(@"settings.general.output_label", @"Output:",                        @"Settings, General pane: label beside the dropdown selecting the audio output device. Ends with a colon.")
#define STR_SETTINGS_DEFAULT_PLAYER_SET NSLS(@"menu.app.make_default",         @"Set %@ as Default Music Player", @"Settings, General pane: button that claims every supported audio type for the app. %@ is the app name.")
#define STR_SETTINGS_DEFAULT_PLAYER_IS  NSLS(@"menu.app.is_default",           @"%@ Is the Default Music Player", @"Settings, General pane: disabled button title replacing 'Set … as Default Music Player' once the app already holds every audio type. %@ is the app name.")

#define STR_SETTINGS_PITCH_RANGE_LABEL   NSLS(@"settings.playback.pitch_range_label",           @"Pitch range:",             @"Settings, Playback pane: label beside the pitch fader range choice (8% or 16%). Ends with a colon.")
#define STR_SETTINGS_SKIP_STEPS_LABEL    NSLS(@"settings.playback.skip_steps_label",            @"Skip steps:",              @"Settings, Playback pane: label beside the dropdown choosing how many bars the three skip actions jump. Ends with a colon.")
#define STR_SETTINGS_SKIP_STEPS_OPTION   NSLS(@"settings.playback.skip_steps_option",           @"%1$ld / %2$ld / %3$ld bars", @"Settings, Playback pane: one skip-size choice, e.g. '8 / 16 / 32 bars' — the three jump sizes of the small, medium and large skip. %1$ld, %2$ld and %3$ld are the bar counts; 'bars' is the musical unit.")
#define STR_SETTINGS_CROSSFADE_LABEL     NSLS(@"settings.playback.crossfade_label",             @"Crossfade:",               @"Settings, Playback pane: label beside the dropdown choosing how long one track blends into the next on a track change. Ends with a colon.")
#define STR_SETTINGS_CROSSFADE_INSTANT   NSLS(@"settings.playback.crossfade.instant",           @"Instant",                  @"Settings, Playback pane, crossfade choice: no audible blend — the next track starts immediately. The default.")
#define STR_SETTINGS_CROSSFADE_SHORT     NSLS(@"settings.playback.crossfade.short",             @"Short (0.5s)",             @"Settings, Playback pane, crossfade choice: a half-second blend into the next track. Localize the decimal separator; 's' abbreviates seconds.")
#define STR_SETTINGS_CROSSFADE_LONG      NSLS(@"settings.playback.crossfade.long",              @"Long (2s)",                @"Settings, Playback pane, crossfade choice: a two-second blend into the next track. 's' abbreviates seconds.")
#define STR_SETTINGS_DETECT_BPM         NSLS(@"settings.playback.detect_bpm",                   @"Detect BPM automatically", @"Settings, Playback pane: checkbox enabling tempo analysis of loaded files. BPM is beats per minute; a tempo already tagged in the file always shows regardless.")

#define STR_SETTINGS_APPEARANCE_LABEL   NSLS(@"settings.appearance.appearance_label",           @"Appearance:",              @"Settings, Appearance pane: label beside the light/dark appearance choice. Ends with a colon.")
#define STR_SETTINGS_WAVEFORM_LABEL     NSLS(@"settings.appearance.waveform_label",             @"Waveform style:",          @"Settings, Appearance pane: label beside the dropdown choosing the waveform drawing style. Ends with a colon.")
#define STR_SETTINGS_TIME_LABEL         NSLS(@"settings.appearance.time_label",                 @"Time display:",            @"Settings, Appearance pane: label beside the choice between showing the track's total duration or the remaining time. Ends with a colon.")
#define STR_SETTINGS_TIME_TOTAL         NSLS(@"settings.appearance.time_total",                 @"Total duration",           @"Settings, Appearance pane, time display choice: the right time label shows the track's full length.")
#define STR_SETTINGS_TIME_REMAINING     NSLS(@"settings.appearance.time_remaining",             @"Remaining time",           @"Settings, Appearance pane, time display choice: the right time label counts down the time left, e.g. '-1:50'.")

#define STR_SETTINGS_CONVERT_DEST_LABEL  NSLS(@"settings.convert.destination_label",            @"Save converted files:",    @"Settings, Convert pane: label beside the dropdown choosing where Convert to FLAC writes its output. Ends with a colon.")
#define STR_SETTINGS_CONVERT_DEST_BESIDE NSLS(@"settings.convert.destination.beside",           @"Next to original",         @"Settings, Convert pane, converted-file destination choice: the FLAC is written into the same folder as the source file. The default.")
#define STR_SETTINGS_CONVERT_DEST_ASK    NSLS(@"settings.convert.destination.ask",              @"Ask where to save",        @"Settings, Convert pane, converted-file destination choice: every conversion shows a save panel asking where to put the FLAC.")
#define STR_SETTINGS_DELETE_ORIGINAL     NSLS(@"settings.convert.delete_original",              @"Delete original after convert", @"Settings, Convert pane: checkbox — when on, a successful conversion moves the original file to the Trash. The same setting as the Convert menu's 'Delete Original After Convert' item, in sentence case per checkbox convention.")

#define STR_SETTINGS_CACHE_LABEL          NSLS(@"settings.advanced.cache_label",                @"Cache size:",              @"Settings, Advanced pane: label beside the readout of the metadata and waveform caches' current size. Ends with a colon.")
#define STR_SETTINGS_CACHE_VALUE          NSLS(@"settings.advanced.cache_value",                @"%1$@ files, %2$@ MB",      @"Settings, Advanced pane: the cache-size readout, e.g. '312 files, 48.2 MB'. %1$@ is the already-formatted file count, %2$@ the already-formatted megabytes.")
#define STR_SETTINGS_CLEAR_CACHE          NSLS(@"settings.advanced.clear_cache",                @"Clear Cache",              @"Settings, Advanced pane: button that empties the metadata and waveform caches.")
#define STR_SETTINGS_FILES_OPENED_LABEL   NSLS(@"settings.advanced.files_opened_label",         @"Files opened:",            @"Settings, Advanced pane, playback statistics: label beside the lifetime count of files opened. Ends with a colon.")
#define STR_SETTINGS_FOLDERS_OPENED_LABEL NSLS(@"settings.advanced.folders_opened_label",       @"Folders opened:",          @"Settings, Advanced pane, playback statistics: label beside the lifetime count of folders opened. Ends with a colon.")
#define STR_SETTINGS_AUDIO_PLAYED_LABEL   NSLS(@"settings.advanced.audio_played_label",         @"Audio played:",            @"Settings, Advanced pane, playback statistics: label beside the total listening time, shown in words like '3 days, 4 hours'. Ends with a colon.")

#pragma mark - Accessibility labels

// Only the controls with no menu counterpart; the transport buttons reuse the
// STR_TRANSPORT_* strings above.

#define STR_A11Y_TOGGLE_PLAYLIST NSLS(@"a11y.playlist.toggle", @"Toggle Playlist",      @"Accessibility label for the button that shows and hides the playlist.")
#define STR_A11Y_PLAYLIST_OPEN   NSLS(@"a11y.playlist.open",   @"Open songs or folders", @"Accessibility label for the empty playlist pane's drop well, which opens the file picker when pressed.")
#define STR_A11Y_WINDOW_CLOSE    NSLS(@"a11y.window.close",    @"Close",           @"Accessibility label for the window's close button.")
#define STR_A11Y_WINDOW_MINIMIZE NSLS(@"a11y.window.minimize", @"Minimize",        @"Accessibility label for the window's minimize button.")

#pragma mark - Playback errors

// Shown inline on the artist line, over the failed track's title. Kept short:
// the title line already names the track and the full error goes to the log.

#define STR_ERROR_LOAD_TIMEOUT        NSLS(@"error.load_timeout",        @"Load timed out",           @"Inline playback error: opening the file took too long, e.g. an undownloaded cloud file.")
#define STR_ERROR_OPEN_FAILED         NSLS(@"error.open_failed",         @"Could not open file",      @"Inline playback error: the audio file could not be opened.")
#define STR_ERROR_ENGINE_START_FAILED NSLS(@"error.engine_start_failed", @"Could not start playback", @"Inline playback error: the audio engine failed to start.")
#define STR_ERROR_DEVICE_UNAVAILABLE  NSLS(@"error.device_unavailable",  @"Audio device unavailable", @"Inline playback error: no usable audio output device.")
#define STR_ERROR_PLAYBACK_GENERIC    NSLS(@"error.playback_generic",    @"Playback error",           @"Inline playback error: fallback for an unrecognized failure.")

#endif /* VibeStrings_h */
