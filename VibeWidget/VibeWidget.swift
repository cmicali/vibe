//
//  VibeWidget.swift
//  VibeWidget
//
//  The widget's timeline. Everything it can know is VibeWidgetState, written
//  by the app into the shared container; this process has no engine, no
//  playlist and no audio session, and never reads an audio file.
//

import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import WidgetKit

// A widget is not a live view: WidgetKit renders each entry once, ahead of
// time, and the home screen shows the entry whose date has arrived. So motion
// costs entries, and entries are budgeted. These two numbers are that trade —
// a step fine enough that the playhead visibly moves, over a horizon long
// enough that a track played through does not run out of timeline before the
// app publishes again.
private let kPlayheadStep: TimeInterval = 5
private let kMaxEntries = 24

struct VibeEntry: TimelineEntry {
    let date: Date
    let state: VibeWidgetState?
    // Decoded once per timeline and shared by every entry, rather than read
    // from disk per render: the same three files back all of them, and the
    // extension's memory limit is small.
    let artwork: UIImage?
    // Pre-blurred once per timeline rather than per entry: the background is
    // pixel-identical across every entry, and a 40pt blur in a process with a
    // hard memory cap is not something to repeat 24 times for one result.
    let blurredArtwork: UIImage?
    let played: UIImage?
    let unplayed: UIImage?

    static let empty = VibeEntry(date: Date(), state: nil, artwork: nil,
                                 blurredArtwork: nil, played: nil, unplayed: nil)
}

struct VibeProvider: TimelineProvider {
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
        // Step the playhead to the end of the track or the entry budget,
        // whichever comes first. The app reloads on every transport event, so
        // running out of timeline only happens when it was killed mid-track —
        // and .atEnd then asks for a fresh one.
        let remaining = max(0, state.duration - state.position(at: now))
        let steps = min(kMaxEntries, max(1, Int(remaining / kPlayheadStep)))
        let entries = (0..<steps).map { step in
            VibeEntry(date: now.addingTimeInterval(Double(step) * kPlayheadStep),
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

    private func image(_ url: URL?) -> UIImage? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    private func blurred(_ artwork: UIImage) -> UIImage {
        guard let input = CIImage(image: artwork),
              let filter = CIFilter(name: "CIGaussianBlur",
                                    parameters: [kCIInputImageKey: input,
                                                 kCIInputRadiusKey: 40]),
              let output = filter.outputImage,
              let cgImage = CIContext().createCGImage(output, from: input.extent)
        else { return artwork }
        return UIImage(cgImage: cgImage)
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
        .description(LocalizedStringResource(stringLiteral: VibeWidgetStrings.widgetDescription))
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
    }
}
