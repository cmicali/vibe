//
//  VibeWidgetIntents.swift
//  Vibe (iOS) and VibeWidget
//
//  The widget's three buttons. COMPILED INTO BOTH TARGETS, because the
//  extension has to name the types to put them in a Button and the app has to
//  own the bodies that run them.
//
//  They are AudioPlaybackIntents, not plain AppIntents, and that is the whole
//  design: the system performs an AudioPlaybackIntent in the APP's process,
//  launching it in the background if it is not up, and permits it to start
//  audio. A plain AppIntent would run here in the extension, where there is no
//  engine, no playlist and no audio session to drive.
//
//  A tap can be the app's LAUNCH: the system starts it in the background to
//  perform the intent. Two things are then not yet true, and the transport
//  waits for both rather than reporting a success the user cannot hear. The
//  scene-owned PlaybackController may not exist — a background launch need not
//  connect a scene — so the perform continues in the foreground, which does
//  connect one (.foreground(.dynamic) is what permits that). And whether the
//  scene came with the launch or with the continuation, its launch open — the
//  restore — is still in flight, and an action driven before it settles lands
//  on an empty playlist and does nothing. TRAP: the second wait is the one
//  that is easy to skip, because on a local folder the restore usually wins
//  the race against the intent and the tap appears to work; a cloud folder
//  loses it. And needsToContinueInForegroundError with no continuation ENDS
//  the intent — the app opens and the tap is lost — which is what the
//  continuation replaced. The common case, where the app is already alive
//  with its restore long settled, waits for nothing.
//
//  TRAP: the bodies are behind VIBE_APP because the extension cannot link a
//  single app class. In the extension these compile to a no-op — which is
//  correct only because the system never performs them here. If a button ever
//  appears to do nothing, check that its intent is still an AudioPlaybackIntent
//  before looking anywhere else.
//

import AppIntents

// TRAP: an intent's title is extracted STATICALLY by appintentsmetadataprocessor,
// which rejects anything but a literal or a direct initializer call — so unlike
// every other string in the app these cannot go through VibeStrings.h's macros,
// and the keys appear here as well. The keys and English defaults below MUST
// match their STR_WIDGET_INTENT_* entries in VibeStrings.h: that registry is
// what puts them in the catalog and what make check-translations enforces, and
// this is only the lookup. supportedModes is read the same way, which is why
// the three identical literals are not one constant.
//
// TRAP: these resolve against NSBundle.mainBundle, which inside an appex is
// the APPEX's bundle — which is why VibeWidget/Localizable.xcstrings exists,
// the widget.* subset `make strings` derives from the main catalog. Without it
// every language would fall back to the English default, and nothing — not
// the build, not make check-translations — would say so. Hence every key the
// widget reads is widget.*, which make check-strings enforces.
//
// Not a symptom: the extension logs "Failed to fetch metadata for <intent>"
// once per button on every render, for all three. The intents still reach the
// app and perform (the app-side log shows the whole pipeline), so that line
// is noise — do not chase it when a button misbehaves.

// A seek zone's width as a fraction of the strip. Widgets have no continuous
// gesture — the home screen forwards discrete hits and nothing else — so a
// scrub is impossible and this is the resolution of what replaces it. 32 zones
// is ~3% of a track, about 6 seconds in a three-minute one.
let kVibeSeekZoneCount = 32

struct VibePlayPauseIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource =
        LocalizedStringResource("widget.intent.play_pause", defaultValue: "Play or Pause")
    static var supportedModes: IntentModes = [.background, .foreground(.dynamic)]

    func perform() async throws -> some IntentResult {
        #if VIBE_APP
        try await VibeWidgetTransport.perform(self) { $0.playPause() }
        #endif
        return .result()
    }
}

struct VibeNextIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource =
        LocalizedStringResource("widget.intent.next", defaultValue: "Next Track")
    static var supportedModes: IntentModes = [.background, .foreground(.dynamic)]

    func perform() async throws -> some IntentResult {
        #if VIBE_APP
        try await VibeWidgetTransport.perform(self) { $0.next() }
        #endif
        return .result()
    }
}

struct VibeSeekIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource =
        LocalizedStringResource("widget.intent.seek", defaultValue: "Seek")
    static var supportedModes: IntentModes = [.background, .foreground(.dynamic)]

    // The zone the tap landed in, not a fraction: an integer survives the
    // intent's own encoding without rounding surprises, and the count is
    // shared by the view that lays the zones out.
    @Parameter(title: "Zone")   // never user-visible: the widget builds these itself
    var zone: Int

    // The track whose strip was tapped — VibeWidgetState.trackKey, as rendered.
    // A reload is budgeted, not immediate, so the strip on screen can be a track
    // behind what plays, and a zone applied to the wrong track seeks it by a
    // fraction of a different one.
    @Parameter(title: "Track")  // likewise
    var trackKey: String

    init() {}

    init(zone: Int, trackKey: String) {
        self.zone = zone
        self.trackKey = trackKey
    }

    func perform() async throws -> some IntentResult {
        #if VIBE_APP
        try await VibeWidgetTransport.perform(self) { playback in
            // Dropped, not escalated: the tap was on a render that no longer
            // describes anything, and there is nothing right to do with it.
            guard (playback.displayedTrack?.url as NSURL?)?.pathKey() == trackKey else { return }
            // The zone's CENTRE, so a tap lands in the middle of what it covers
            // rather than at its leading edge — half a zone of bias otherwise,
            // in one direction, every time.
            let progress = (Double(zone) + 0.5) / Double(kVibeSeekZoneCount)
            playback.seek(toProgress: Float(progress))
        }
        #endif
        return .result()
    }
}

#if VIBE_APP
// The app-side runner. It hops to the main actor because PlaybackController
// is main-thread-only (its header says so), and an intent performs on whatever
// the system gives it.
enum VibeWidgetTransport {
    // Drives the connected controller once its launch open has settled —
    // bringing the app forward first when no scene has connected, since that
    // is what connects one. `intent` is only the handle the continuation hangs
    // off. The settle wait is unconditional: see the header's TRAP.
    static func perform(_ intent: some AppIntent,
                        _ action: @escaping @MainActor (PlaybackController) -> Void) async throws {
        var playback = await connectedPlayback()
        if playback == nil {
            try await intent.continueInForeground(alwaysConfirm: false)
            playback = await connectedPlayback()
        }
        guard let playback else {
            return   // foregrounded without a scene: nothing this process can drive
        }
        await playback.launchOpenSettled()
        await action(playback)
    }

    @MainActor
    private static func connectedPlayback() -> PlaybackController? {
        VibeiOSSceneDelegate.connectedPlayback()
    }
}

private extension PlaybackController {
    // The controller's waiter as an await.
    @MainActor
    func launchOpenSettled() async {
        await withCheckedContinuation { continuation in
            performWhenLaunchOpenSettled { continuation.resume() }
        }
    }
}
#endif
