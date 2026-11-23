// Shared by the app and extension. AudioPlaybackIntent runs in the app process.
// The app installs its VibeWidgetActions at launch, and the bodies act through
// them. The extension installs none, so there they do nothing.
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
        try await VibeWidgetTransport.perform(self) { $0.widgetPlayPause() }
        return .result()
    }
}

struct VibeNextIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource =
        LocalizedStringResource("widget.intent.next", defaultValue: "Next Track")
    static var supportedModes: IntentModes = [.background, .foreground(.dynamic)]

    func perform() async throws -> some IntentResult {
        try await VibeWidgetTransport.perform(self) { $0.widgetNext() }
        return .result()
    }
}

struct VibePreviousIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource =
        LocalizedStringResource("widget.intent.previous", defaultValue: "Previous Track")
    static var supportedModes: IntentModes = [.background, .foreground(.dynamic)]

    func perform() async throws -> some IntentResult {
        try await VibeWidgetTransport.perform(self) { $0.widgetPrevious() }
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
        try await VibeWidgetTransport.perform(self) { actions in
            guard actions.widgetDisplayedTrackKey == trackKey else { return }
            // The zone's CENTRE, or every tap is biased half a zone early.
            let progress = (Double(zone) + 0.5) / Double(kVibeSeekZoneCount)
            actions.widgetSeek(toProgress: Float(progress))
        }
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
        VibeWidgetIntents.installed?.widgetShowPlaylist()
        return .result()
    }
}

// What the buttons do, in the app's terms. Main thread only.
@MainActor
@objc(VibeWidgetActions)
public protocol VibeWidgetActions: NSObjectProtocol {
    // Whether a scene has connected, so a tap can act without the foreground.
    var widgetHasPlayback: Bool { get }
    // Runs block once the launch's playlist restore has settled.
    func widgetWhenRestored(_ block: @escaping () -> Void)
    func widgetPlayPause()
    func widgetNext()
    func widgetPrevious()
    // The key WidgetPublisher writes for the track on screen
    // (trackKeyForTrack:), nil with none.
    var widgetDisplayedTrackKey: String? { get }
    func widgetSeek(toProgress progress: Float)
    // Lowers the card and shows the playlist, unless a sheet or alert is up.
    func widgetShowPlaylist()
}

// public: an internal class does not reach the app's -Swift.h.
@MainActor
@objc(VibeWidgetIntents)
public final class VibeWidgetIntents: NSObject {
    @objc public static var installed: VibeWidgetActions?
}

enum VibeWidgetTransport {
    // `intent` is only the continuation's handle. The settle wait is
    // unconditional (see the header).
    @MainActor
    static func perform(_ intent: some AppIntent,
                        _ action: @MainActor (VibeWidgetActions) -> Void) async throws {
        guard let actions = VibeWidgetIntents.installed else {
            return   // the extension, which never acts
        }
        if !actions.widgetHasPlayback {
            try await intent.continueInForeground(alwaysConfirm: false)
        }
        guard actions.widgetHasPlayback else {
            return   // foregrounded without a scene
        }
        await withCheckedContinuation { continuation in
            actions.widgetWhenRestored { continuation.resume() }
        }
        action(actions)
    }
}
