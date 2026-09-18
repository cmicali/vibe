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
//  They are also ForegroundContinuableIntents, and that is not decoration: the
//  system launches the app in the BACKGROUND to perform them, and a background
//  launch connects no UI scene — so the scene-owned PlaybackController does not
//  exist and there is nothing to drive. Reporting success there is a button
//  that silently does nothing. Instead the intent asks to continue in the
//  foreground, which brings the app up and re-performs it against a real
//  controller. The common case, where the app is already alive, never takes
//  that path.
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
// this is only the lookup.

// A seek zone's width as a fraction of the strip. Widgets have no continuous
// gesture — the home screen forwards discrete hits and nothing else — so a
// scrub is impossible and this is the resolution of what replaces it. 32 zones
// is ~3% of a track, about 6 seconds in a three-minute one.
let kVibeSeekZoneCount = 32

struct VibePlayPauseIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource =
        LocalizedStringResource("widget.intent.play_pause", defaultValue: "Play or Pause")

    func perform() async throws -> some IntentResult {
        #if VIBE_APP
        guard await VibeWidgetTransport.playPause() else {
            throw needsToContinueInForegroundError()
        }
        #endif
        return .result()
    }
}

struct VibeNextIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource =
        LocalizedStringResource("widget.intent.next", defaultValue: "Next Track")

    func perform() async throws -> some IntentResult {
        #if VIBE_APP
        guard await VibeWidgetTransport.next() else {
            throw needsToContinueInForegroundError()
        }
        #endif
        return .result()
    }
}

struct VibeSeekIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource =
        LocalizedStringResource("widget.intent.seek", defaultValue: "Seek")

    // The zone the tap landed in, not a fraction: an integer survives the
    // intent's own encoding without rounding surprises, and the count is
    // shared by the view that lays the zones out.
    @Parameter(title: "Zone")   // never user-visible: the widget builds these itself
    var zone: Int

    init() {}

    init(zone: Int) {
        self.zone = zone
    }

    func perform() async throws -> some IntentResult {
        #if VIBE_APP
        // The zone's CENTRE, so a tap lands in the middle of what it covers
        // rather than at its leading edge — half a zone of bias otherwise, in
        // one direction, every time.
        let progress = (Double(zone) + 0.5) / Double(kVibeSeekZoneCount)
        guard await VibeWidgetTransport.seek(toProgress: progress) else {
            throw needsToContinueInForegroundError()
        }
        #endif
        return .result()
    }
}

#if VIBE_APP
// TRAP: ForegroundContinuableIntent is unavailable in application extensions,
// and this file compiles into the extension too — so the conformance is
// declared here, app-side only, rather than on the types above. The bodies
// that call needsToContinueInForegroundError() are behind the same flag, so
// the extension never names either.
extension VibePlayPauseIntent: ForegroundContinuableIntent {}
extension VibeNextIntent: ForegroundContinuableIntent {}
extension VibeSeekIntent: ForegroundContinuableIntent {}

// The app-side bodies. They hop to the main actor because PlaybackController
// is main-thread-only (its header says so), and an intent performs on whatever
// the system gives it.
//
// Each returns whether it actually drove anything. false means no scene has
// connected — a background launch — and the caller escalates to the foreground
// rather than reporting a success the user cannot hear.
enum VibeWidgetTransport {
    @MainActor
    static func playPause() -> Bool {
        guard let playback = VibeiOSSceneDelegate.connectedPlayback() else { return false }
        playback.playPause()
        return true
    }

    @MainActor
    static func next() -> Bool {
        guard let playback = VibeiOSSceneDelegate.connectedPlayback() else { return false }
        playback.next()
        return true
    }

    @MainActor
    static func seek(toProgress progress: Double) -> Bool {
        guard let playback = VibeiOSSceneDelegate.connectedPlayback() else { return false }
        playback.seek(toProgress: Float(progress))
        return true
    }
}
#endif
