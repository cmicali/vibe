// Shared by the app and extension. AudioPlaybackIntent runs in the app process.
// TRAP: guard app references with VIBE_APP. The extension cannot link them.
// TRAP: a launch tap needs a connected scene and a settled playlist restore.
// A foreground continuation preserves the tap. An error ends the intent.

import AppIntents

// TRAP: intent titles and supportedModes must be literals for metadata extraction.
// Match title keys and defaults to STR_WIDGET_INTENT_* in VibeStrings.h.
// The extension resolves widget.* against its own catalog from make strings.
// TRAP: every seek zone is a button archived with every timeline entry.
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
            guard WidgetPublisher.trackKey(for: playback.displayedTrack) == trackKey else { return }
            // The zone's CENTRE, or every tap is biased half a zone early.
            let progress = (Double(zone) + 0.5) / Double(kVibeSeekZoneCount)
            playback.seek(toProgress: Float(progress))
        }
        #endif
        return .result()
    }
}

// A foreground intent, so the system opens the app and performs it there.
// A launch lands on the Playlist tab with the card down. So a tap that
// launches the app needs nothing when no scene has connected yet.
struct VibeShowPlaylistIntent: AppIntent {
    static var title: LocalizedStringResource =
        LocalizedStringResource("widget.intent.show_playlist", defaultValue: "Show Playlist")
    static var supportedModes: IntentModes = .foreground

    @MainActor
    func perform() async throws -> some IntentResult {
        #if VIBE_APP
        VibeiOSSceneDelegate.showPlaylist()
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
