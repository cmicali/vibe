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

// TRAP: keep coarse entries through track end if WidgetKit delays a reload.
// The app requests a reload each minute to replenish the dense entries.
private let kPlayheadStep: TimeInterval = 5
private let kDenseEntries = 24
private let kTailEntries = 8
// Pixels; the blurred background's longest side. See blurred(_:).
private let kBlurSide: CGFloat = 96

struct VibeEntry: TimelineEntry {
    let date: Date
    let state: VibeWidgetState?
    // Share decoded images across entries to stay within the extension’s memory cap.
    let artwork: UIImage?
    // Share the blur too; it is identical across entries.
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
            // Hold until the app publishes again.
            completion(Timeline(entries: [first], policy: .never))
            return
        }
        let remaining = max(0, state.duration - state.position(at: now))
        let dense = min(remaining, Double(kDenseEntries - 1) * kPlayheadStep)
        var offsets = Array(stride(from: 0, through: dense, by: kPlayheadStep))
        if dense < remaining {
            let step = max(kPlayheadStep, (remaining - dense) / Double(kTailEntries))
            offsets += stride(from: dense + step, to: remaining, by: step)
            offsets.append(remaining)
        }
        let entries = offsets.map { offset in
            VibeEntry(date: now.addingTimeInterval(offset),
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
        // Track-named images prevent a concurrent publish from pairing this title
        // with another track’s artwork.
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
                             smallLayout: .waveformPlay)
        VibeNowPlayingWidget()
        VibeNowPlayingWidget(kind: "VibeNowPlayingLarge", families: [.systemLarge])
        VibeNowPlayingWidget(kind: "VibeNowPlayingWaveform", families: [.systemSmall],
                             smallLayout: .waveform)
        VibeNowPlayingWidget(kind: "VibeNowPlayingArtwork", families: [.systemSmall],
                             smallLayout: .fullBleed)
    }
}

// One type, five kinds. They share a name and a description, but the gallery
// offers each kind as its own page, so every small layout can sit on one Home
// Screen. The app's reload is reloadAllTimelines, so it reaches every kind.
struct VibeNowPlayingWidget: Widget {
    var kind = "VibeNowPlaying"
    var families: [WidgetFamily] = [.systemSmall, .systemMedium,
                                    .accessoryCircular, .accessoryRectangular, .accessoryInline]
    var smallLayout = VibeSmallLayout.artworkTile

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: VibeProvider()) { entry in
            VibeWidgetView(entry: entry, smallLayout: smallLayout)
        }
        // Literals for the same reason the intents' titles are (VibeWidgetIntents.swift's
        // TRAP). Each MUST match its STR_WIDGET_* entry, which is what puts the key in the catalog.
        .configurationDisplayName(LocalizedStringResource("widget.name.now_playing", defaultValue: "Now Playing"))
        .description(LocalizedStringResource("widget.description", defaultValue: "What Vibe is currently playing."))
        .supportedFamilies(families)
        .contentMarginsDisabled()
    }
}
