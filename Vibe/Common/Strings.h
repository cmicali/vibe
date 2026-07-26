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

#ifndef Strings_h
#define Strings_h

// Lifts out the invariant scaffolding so entries read as key/English/comment.
// xcstringstool cannot extract a three-argument macro (it matches macros by
// name AND arity, even with -s), so extract-strings.sh preprocesses this file
// and parses the expansion.
#define NSLS(key, value, comment) NSLocalizedStringWithDefaultValue(key, nil, NSBundle.mainBundle, value, comment)

#pragma mark - Product

#define STR_APP_NAME NSLS(@"app.name", @"Vibe", @"The application's name, as shown in the app menu and as the window title. A product name — translate only if it would otherwise be unreadable in the target script.")

#pragma mark - Application menu

#define STR_MENU_APP_ABOUT       NSLS(@"menu.app.about",       @"About %@",    @"App menu item: opens the About window. %@ is the app name. Also the About window's title.")
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
#define STR_LABEL_BITRATE            NSLS(@"label.bitrate",            @"%@ kbps",                 @"Codec label: bitrate in kilobits per second. %@ is the number.")
#define STR_LABEL_SAMPLE_RATE        NSLS(@"label.sample_rate",        @"%@ kHz",                  @"Codec label: sample rate in kilohertz, e.g. '44.1 kHz'. %@ is the already-formatted number.")
#define STR_LABEL_BPM                NSLS(@"label.bpm",                @"%@ BPM",                  @"Tempo label: beats per minute, e.g. '128.0 BPM'. %@ is the already-formatted number.")
#define STR_LABEL_TIME_UNKNOWN       NSLS(@"label.time.unknown",       @"--:--",                   @"Placeholder in the elapsed/total time labels when the time is not yet known.")
#define STR_LABEL_PITCH              NSLS(@"label.pitch",              @"PITCH",                   @"Label above the pitch fader. Upper-case, like the printed legend on a DJ turntable. Very tight space — about 8 characters.")
#define STR_LABEL_DROP_HINT          NSLS(@"label.drop_hint",          @"Drop a file or press %@", @"Empty-state hint shown when no track is loaded. %@ is the Open shortcut, rendered as key glyphs (⌘O) — keep it as a placeholder, don't spell it out.")
#define STR_LABEL_ABOUT_VERSION      NSLS(@"label.about.version",      @"Version %@",              @"About window: %@ is the version number, e.g. '1.5 (15) · Release'.")

#pragma mark - Accessibility labels

// Only the controls with no menu counterpart; the transport buttons reuse the
// STR_TRANSPORT_* strings above.

#define STR_A11Y_TOGGLE_PLAYLIST NSLS(@"a11y.playlist.toggle", @"Toggle Playlist", @"Accessibility label for the button that shows and hides the playlist.")
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

#endif /* Strings_h */
