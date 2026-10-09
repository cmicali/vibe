//
//  VibeWidgetIntents.swift
//  Vibe (iOS) and VibeWidget
//
//  The widget's buttons, COMPILED INTO BOTH TARGETS: the extension names
//  the types, the app owns the bodies. They are AudioPlaybackIntents, which
//  the system performs in the APP's process (launching it in the background)
//  and lets start audio; a plain AppIntent would run in the extension.
//
//  A tap can be the app's LAUNCH, so the transport waits for two things. No
//  scene may have connected, so the perform continues in the foreground
//  (.foreground(.dynamic)), which connects one. And the launch restore may
//  still be in flight, so it waits for the settle. TRAP: the second wait is
//  easy to skip — a local restore usually wins the race and the tap seems to
//  work; a cloud folder loses it and the tap lands on an empty playlist.
//  needsToContinueInForegroundError instead of a continuation ENDS the intent
//  and loses the tap.
//
//  TRAP: the bodies are behind VIBE_APP because the extension cannot link an
//  app class, so there they are no-ops — correct only because the system
//  never performs them there. A button that does nothing: first check its
//  intent is still an AudioPlaybackIntent.
//

import AppIntents

// TRAP: appintentsmetadataprocessor extracts a title STATICALLY and accepts
// only a literal or a direct initializer, so these bypass VibeStrings.h's
// macros. Keys and English defaults MUST match their STR_WIDGET_INTENT_*
// entries, which put them in the catalog. supportedModes is read the same way.
// So each intent spells it out as a literal rather than sharing one constant.
//
// TRAP: inside the appex these resolve against the APPEX's bundle, hence
// VibeWidget/Localizable.xcstrings, the widget.* subset `make strings`
// derives; without it every language silently falls back to English. Every
// key the widget reads must therefore be widget.* (extract-strings.sh
// enforces it).
//
// Noise: the extension logs "Failed to fetch metadata for <intent>" per button
// per render; the intents still perform.

// Widgets get discrete hits only, so seek zones replace a scrub. 16 is about
// 11 seconds of a three-minute track. TRAP: each zone is a button the system
// archives with every timeline entry. On a phone, 32 zones cost a medium
// widget about 40ms an entry, a second for its 24 entries, and 16 about 24ms.
let kVibeSeekZoneCount = 16

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

struct VibePreviousIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource =
        LocalizedStringResource("widget.intent.previous", defaultValue: "Previous Track")
    static var supportedModes: IntentModes = [.background, .foreground(.dynamic)]

    func perform() async throws -> some IntentResult {
        #if VIBE_APP
        try await VibeWidgetTransport.perform(self) { $0.previous() }
        #endif
        return .result()
    }
}

struct VibeSeekIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource =
        LocalizedStringResource("widget.intent.seek", defaultValue: "Seek")
    static var supportedModes: IntentModes = [.background, .foreground(.dynamic)]

    // An integer survives the intent's encoding without rounding surprises.
    @Parameter(title: "Zone")   // never user-visible
    var zone: Int

    // VibeWidgetState.trackKey as rendered: a reload is budgeted, so the strip
    // can be a track behind what plays.
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
            // A stale render's tap is dropped.
            guard WidgetPublisher.trackKey(for: playback.displayedTrack) == trackKey else { return }
            // The zone's CENTRE, or every tap is biased half a zone early.
            let progress = (Double(zone) + 0.5) / Double(kVibeSeekZoneCount)
            playback.seek(toProgress: Float(progress))
        }
        #endif
        return .result()
    }
}

#if VIBE_APP
// Hops to the main actor: PlaybackController is main-thread-only.
enum VibeWidgetTransport {
    // `intent` is only the continuation's handle. The settle wait is
    // unconditional (see the header).
    static func perform(_ intent: some AppIntent,
                        _ action: @escaping @MainActor (PlaybackController) -> Void) async throws {
        var playback = await connectedPlayback()
        if playback == nil {
            try await intent.continueInForeground(alwaysConfirm: false)
            playback = await connectedPlayback()
        }
        guard let playback else {
            return   // foregrounded without a scene
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
    @MainActor
    func launchOpenSettled() async {
        await withCheckedContinuation { continuation in
            performWhenLaunchOpenSettled { continuation.resume() }
        }
    }
}
#endif
