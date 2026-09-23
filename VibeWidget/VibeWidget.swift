//
//  VibeWidget.swift
//  VibeWidget
//
//  The widget's timeline. Everything it can know is VibeWidgetState, written
//  by the app into the shared container; this process has no engine, no
//  playlist and no audio session, and never reads an audio file.
//

import CoreImage
import ImageIO
import SwiftUI
import WidgetKit

// A widget is not a live view: WidgetKit renders each entry once, ahead of
// time, and the home screen shows the entry whose date has arrived. So motion
// costs entries, and entries are budgeted. The budget is spread over whatever
// is left of the track: the step is the finest that still reaches the end,
// never finer than kPlayheadStep. TRAP: a fixed step ran out — 24 entries at
// 5 s is 115 s — and a longer track's head then FROZE there, because ordinary
// playback publishes nothing (the widget's own arithmetic is the playhead) and
// .atEnd asks for a fresh timeline on WidgetKit's schedule, not the track's.
private let kPlayheadStep: TimeInterval = 5
private let kMaxEntries = 24

struct VibeEntry: TimelineEntry {
    let date: Date
    let state: VibeWidgetState?
    // Decoded once per timeline and shared by every entry, rather than read
    // from disk per render: the same three files back all of them, and the
    // extension's memory limit is small. CGImage rather than either platform's
    // image type, so this file and the view are one source for both.
    let artwork: CGImage?
    // Pre-blurred once per timeline rather than per entry: the background is
    // pixel-identical across every entry, and a 40pt blur in a process with a
    // hard memory cap is not something to repeat 24 times for one result.
    let blurredArtwork: CGImage?
    let played: CGImage?
    let unplayed: CGImage?

    static let empty = VibeEntry(date: Date(), state: nil, artwork: nil,
                                 blurredArtwork: nil, played: nil, unplayed: nil)
}

struct VibeProvider: TimelineProvider {
    // One per process, not per timeline: a CIContext is a Metal device and its
    // pipelines, tens of milliseconds and several MB, in a process with a hard
    // memory cap.
    private static let blurContext = CIContext()

    func placeholder(in context: Context) -> VibeEntry { .empty }

    func getSnapshot(in context: Context, completion: @escaping (VibeEntry) -> Void) {
        completion(loadEntry(at: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<VibeEntry>) -> Void) {
        let now = Date()
        let first = loadEntry(at: now)
        guard let state = first.state, state.hasTrack, state.playing, state.duration > 0 else {
            // Paused, parked or empty: one entry, held until the app publishes
            // again. Nothing moves, so nothing needs re-rendering.
            completion(Timeline(entries: [first], policy: .never))
            return
        }
        // Step the playhead to the end of the track within the entry budget:
        // 5 s apart on a short remainder, minutes apart on an hour-long mix,
        // always landing the last entry at the end. The app reloads on every
        // transport event, and the track's end is one, so .atEnd is only the
        // fallback for an app killed mid-track.
        let remaining = max(0, state.duration - state.position(at: now))
        let step = max(kPlayheadStep, remaining / Double(kMaxEntries - 1))
        let steps = min(kMaxEntries, Int(remaining / step) + 1)
        let entries = (0..<steps).map { index in
            VibeEntry(date: now.addingTimeInterval(Double(index) * step),
                      state: state, artwork: first.artwork,
                      blurredArtwork: first.blurredArtwork,
                      played: first.played, unplayed: first.unplayed)
        }
        completion(Timeline(entries: entries, policy: .atEnd))
    }

    private func loadEntry(at date: Date) -> VibeEntry {
        guard let state = VibeWidgetState.load() else { return .empty }
        // The state's OWN images, named by its track: three separate reads,
        // but a publish landing between them can only make one of these nil,
        // never hand this title another track's cover.
        let artwork = image(state.artworkURL)
        return VibeEntry(date: date, state: state,
                         artwork: artwork,
                         blurredArtwork: artwork.map(blurred),
                         played: image(state.waveformPlayedURL),
                         unplayed: image(state.waveformUnplayedURL))
    }

    private func image(_ url: URL?) -> CGImage? {
        guard let url, let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private func blurred(_ artwork: CGImage) -> CGImage {
        let input = CIImage(cgImage: artwork)
        guard let filter = CIFilter(name: "CIGaussianBlur",
                                    parameters: [kCIInputImageKey: input,
                                                 kCIInputRadiusKey: 40]),
              let output = filter.outputImage,
              let cgImage = Self.blurContext.createCGImage(output, from: input.extent)
        else { return artwork }
        return cgImage
    }
}

@main
struct VibeWidgetBundle: WidgetBundle {
    var body: some Widget { VibeNowPlayingWidget() }
}

struct VibeNowPlayingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "VibeNowPlaying", provider: VibeProvider()) { entry in
            VibeWidgetView(entry: entry)
        }
        .configurationDisplayName("Vibe")
        // A literal for the same reason the intents' titles are (VibeWidgetIntents.swift's
        // TRAP); it MUST match STR_WIDGET_DESCRIPTION, which is what puts the key in the catalog.
        .description(LocalizedStringResource("widget.description", defaultValue: "What Vibe is playing."))
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
    }
}
