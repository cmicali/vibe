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
//  TRAP: the bodies are behind VIBE_APP because the extension cannot link a
//  single app class. In the extension these compile to a no-op — which is
//  correct only because the system never performs them here. If a button ever
//  appears to do nothing, check that its intent is still an AudioPlaybackIntent
//  before looking anywhere else.
//

import AppIntents

// A seek zone's width as a fraction of the strip. Widgets have no continuous
// gesture — the home screen forwards discrete hits and nothing else — so a
// scrub is impossible and this is the resolution of what replaces it. 32 zones
// is ~3% of a track, about 6 seconds in a three-minute one.
let kVibeSeekZoneCount = 32

struct VibePlayPauseIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Play or Pause"

    func perform() async throws -> some IntentResult {
        #if VIBE_APP
        await VibeWidgetTransport.playPause()
        #endif
        return .result()
    }
}

struct VibeNextIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Next Track"

    func perform() async throws -> some IntentResult {
        #if VIBE_APP
        await VibeWidgetTransport.next()
        #endif
        return .result()
    }
}

struct VibeSeekIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Seek"

    // The zone the tap landed in, not a fraction: an integer survives the
    // intent's own encoding without rounding surprises, and the count is
    // shared by the view that lays the zones out.
    @Parameter(title: "Zone")
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
        await VibeWidgetTransport.seek(toProgress: progress)
        #endif
        return .result()
    }
}

#if VIBE_APP
// The app-side bodies. They hop to the main actor because PlaybackController
// is main-thread-only (its header says so), and an intent performs on whatever
// the system gives it.
//
// A nil controller means the app was launched with no scene — nothing to
// drive, and nothing worth guessing about. Doing nothing is right: the tap
// cost the user a launch, not a wrong track.
enum VibeWidgetTransport {
    @MainActor
    static func playPause() {
        VibeiOSSceneDelegate.connectedPlayback()?.playPause()
    }

    @MainActor
    static func next() {
        VibeiOSSceneDelegate.connectedPlayback()?.next()
    }

    @MainActor
    static func seek(toProgress progress: Double) {
        VibeiOSSceneDelegate.connectedPlayback()?.seek(toProgress: Float(progress))
    }
}
#endif
