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

// TRAP: spread the entry budget over the remaining track. A fixed step can
// freeze the playhead early. WidgetKit schedules .atEnd refreshes itself.
private let kPlayheadStep: TimeInterval = 5
private let kMaxEntries = 24
// Pixels; the blurred background's longest side. See blurred(_:).
private let kBlurSide: CGFloat = 96

struct VibeEntry: TimelineEntry {
    let date: Date
    let state: VibeWidgetState?
    // Decoded once per timeline and shared by every entry, rather than read
    // from disk per render: the same three files back all of them, and the
    // extension's memory limit is small.
    let artwork: UIImage?
    // Pre-blurred once per timeline rather than per entry: the background is
    // pixel-identical across every entry, and a blur in a process with a hard
    // memory cap is not something to repeat 24 times for one result.
    let blurredArtwork: UIImage?
    let played: UIImage?
    let unplayed: UIImage?

    static let empty = VibeEntry(date: Date(), state: nil, artwork: nil,
                                 blurredArtwork: nil, played: nil, unplayed: nil)
}

struct VibeProvider: TimelineProvider {
    // Reuse the Metal context across timelines in this memory-limited process.
    private static let blurContext = CIContext()

    func placeholder(in context: Context) -> VibeEntry { .empty }

    func getSnapshot(in context: Context, completion: @escaping (VibeEntry) -> Void) {
        completion(loadEntry(at: Date(), family: context.family))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<VibeEntry>) -> Void) {
        let now = Date()
        let first = loadEntry(at: now, family: context.family)
        guard let state = first.state, state.hasTrack, state.playing, state.duration > 0 else {
            // Paused, parked or empty: one entry, held until the app publishes
            // again. Nothing moves, so nothing needs re-rendering.
            completion(Timeline(entries: [first], policy: .never))
            return
        }
        // Use the minimum step for short remainders. The last entry can fall
        // less than one minimum step before the end.
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

    private func loadEntry(at date: Date, family: WidgetFamily) -> VibeEntry {
        guard let state = VibeWidgetState.load() else { return .empty }
        // The Lock Screen draws in the system's tint: no artwork, no
        // background, and only the played image, as a shape.
        let lockScreen = [.accessoryCircular, .accessoryRectangular, .accessoryInline].contains(family)
        // The state's OWN images, named by its track: three separate reads,
        // but a publish landing between them can only make one of these nil,
        // never hand this title another track's cover.
        let artwork = lockScreen ? nil : image(state.artworkURL)
        return VibeEntry(date: date, state: state,
                         artwork: artwork,
                         blurredArtwork: artwork.map(blurred),
                         played: image(state.waveformPlayedURL),
                         unplayed: lockScreen ? nil : image(state.waveformUnplayedURL))
    }

    private func image(_ url: URL?) -> UIImage? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    // Downsample before the blur to limit intermediate image memory.
    private func blurred(_ artwork: UIImage) -> UIImage {
        guard let full = CIImage(image: artwork) else { return artwork }
        let scale = min(1, kBlurSide / max(full.extent.width, full.extent.height))
        let input = full.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let filter = CIFilter(name: "CIGaussianBlur",
                                    parameters: [kCIInputImageKey: input,
                                                 kCIInputRadiusKey: max(input.extent.width,
                                                                        input.extent.height) * 40 / 256]),
              let output = filter.outputImage,
              let cgImage = Self.blurContext.createCGImage(output, from: input.extent)
        else { return artwork }
        return UIImage(cgImage: cgImage)
    }
}

// TRAP: a placed widget belongs to its kind. Keep the shipped small and
// medium families on the original kind.
@main
struct VibeWidgetBundle: WidgetBundle {
    var body: some Widget {
        VibeNowPlayingWidget(kind: "VibeNowPlayingWaveformPlay", families: [.systemSmall],
                             waveformTile: true, playButton: true)
        VibeNowPlayingWidget()
        VibeNowPlayingWidget(kind: "VibeNowPlayingLarge", families: [.systemLarge])
        VibeNowPlayingWidget(kind: "VibeNowPlayingWaveform", families: [.systemSmall],
                             waveformTile: true)
    }
}

// One type, four kinds. They share a name and a description, but the gallery
// offers each kind as its own page, so every small layout can sit on one Home
// Screen. The app's reload is reloadAllTimelines, so it reaches every kind.
struct VibeNowPlayingWidget: Widget {
    var kind = "VibeNowPlaying"
    var families: [WidgetFamily] = [.systemSmall, .systemMedium,
                                    .accessoryCircular, .accessoryRectangular, .accessoryInline]
    var waveformTile = false
    var playButton = false

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: VibeProvider()) { entry in
            VibeWidgetView(entry: entry, waveformTile: waveformTile, playButton: playButton)
        }
        // Literals for the same reason the intents' titles are (VibeWidgetIntents.swift's
        // TRAP). Each MUST match its STR_WIDGET_* entry, which is what puts the key in the catalog.
        .configurationDisplayName(LocalizedStringResource("widget.name.now_playing", defaultValue: "Now Playing"))
        .description(LocalizedStringResource("widget.description", defaultValue: "What Vibe is currently playing."))
        .supportedFamilies(families)
        .contentMarginsDisabled()
    }
}
