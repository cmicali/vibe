
import AppIntents
import SwiftUI
import UIKit
import WidgetKit

private let kCornerRadius: CGFloat = 8
// The scrubber's (kVibePlayheadLineWidth), the height of the strip.
private let kPlayheadLineWidth: CGFloat = 2

private let kMediumHeaderHeight: CGFloat = 54
private let kSmallPadding: CGFloat = 16
private let kSmallArtworkSide: CGFloat = 67
private let kSmallPlayDiameter: CGFloat = 39
private let kSmallMinGap: CGFloat = 4
// The 1pt line spacing keeps both lines within the 54pt medium header.
private let kTextSize: CGFloat = 22
// Where the text shares a row, both lines take the largest of these sizes at
// which both fit (fittedTextLines).
private let kSmallPlayTextSizes: [CGFloat] = [17, 15, 13]
private let kLargeTextSizes: [CGFloat] = [kTextSize, 19, 17, 15]
private let kLargeArtworkShare: CGFloat = 0.85
private let kLargeGap: CGFloat = 12

struct VibeWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: VibeEntry
    // The small family's layout; every other family has only one.
    var waveformTile = false
    var playButton = false

    private var progress: Double {
        state.map { $0.progress(at: entry.date) } ?? 0
    }

    private var playGlyph: String {
        state?.playing == true ? "pause.fill" : "play.fill"
    }

    private var state: VibeWidgetState? {
        guard let state = entry.state, state.hasTrack else { return nil }
        return state
    }

    var body: some View {
        Group {
            switch family {
            case .systemSmall where waveformTile: smallWaveform
            case .systemSmall: small
            case .systemLarge: large
            case .accessoryCircular: circular
            case .accessoryRectangular: rectangular
            case .accessoryInline: inline
            default: medium
            }
        }
        .containerBackground(for: .widget) {
            switch family {
            case .accessoryCircular: AccessoryWidgetBackground()
            case .accessoryRectangular, .accessoryInline: Color.clear
            default: background
            }
        }
    }

    private var background: some View {
        ZStack {
            Color.black
            if let blurred = entry.blurredArtwork {
                Image(uiImage: blurred)
                    .resizable()
                    .scaledToFill()
                    .opacity(0.55)
            }
            LinearGradient(colors: [.black.opacity(0.25), .black.opacity(0.7)],
                           startPoint: .top, endPoint: .bottom)
        }
    }

    // MARK: - Medium

    private var medium: some View {
        VStack(spacing: 8) {
            mediumHeader
            waveform()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(12)
    }

    private var mediumHeader: some View {
        HStack(spacing: 10) {
            artworkTile(side: kMediumHeaderHeight)
            textLines()
                .frame(maxHeight: .infinity, alignment: .center)
            Spacer(minLength: 4)
            if state != nil {
                playPauseButton(diameter: 38)
                skipButton(VibeNextIntent(), systemName: "forward.end.fill", diameter: 34)
            }
        }
        .frame(height: kMediumHeaderHeight)
    }

    // MARK: - Small

    // TRAP: only the text has trailing padding. The disc centers between
    // the artwork and tile edge. Padding the whole row shifts it left.
    private var small: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                artworkTile(side: kSmallArtworkSide)
                if state != nil {
                    playPauseButton(diameter: kSmallPlayDiameter)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(height: kSmallArtworkSide)
            Spacer(minLength: kSmallMinGap)
            textLines()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, kSmallPadding)   // the side body does not inset
        }
        .padding(.leading, kSmallPadding)
        .padding(.vertical, kSmallPadding)
    }

    private var smallWaveform: some View {
        let showsPlay = playButton && state != nil
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Group {
                    if showsPlay {
                        fittedTextLines(sizes: kSmallPlayTextSizes)
                    } else {
                        textLines()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if showsPlay {
                    playPauseButton(diameter: kSmallPlayDiameter)
                }
            }
            waveform()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(kSmallPadding)
    }

    // MARK: - Large

    private var large: some View {
        GeometryReader { geometry in
            let half = (geometry.size.height - kLargeGap) / 2
            let side = half * kLargeArtworkShare
            VStack(spacing: kLargeGap) {
                HStack(alignment: .top, spacing: 14) {
                    artworkTile(side: side)
                    VStack(alignment: .leading, spacing: 0) {
                        fittedTextLines(sizes: kLargeTextSizes)
                        if state != nil {
                            HStack(spacing: 14) {
                                skipButton(VibePreviousIntent(), systemName: "backward.end.fill", diameter: 40)
                                playPauseButton(diameter: 48)
                                skipButton(VibeNextIntent(), systemName: "forward.end.fill", diameter: 40)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: side, alignment: .top)
                }
                .frame(height: half)
                waveform()
                    .frame(height: half)
            }
        }
        .padding(kSmallPadding)
    }

    // MARK: - Lock Screen

    private var circular: some View {
        Gauge(value: progress) {
            EmptyView()
        } currentValueLabel: {
            if state != nil {
                Button(intent: VibePlayPauseIntent()) {
                    Image(systemName: playGlyph)
                        .font(.system(size: 20))
                }
                .buttonStyle(.plain)
            } else {
                Image(systemName: "waveform")
            }
        }
        .gaugeStyle(.accessoryCircularCapacity)
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 4) {
            oneLine
                .font(.footnote)
                .lineLimit(1)
            if state != nil {
                waveform(lockScreen: true)
                    .frame(maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var inline: some View {
        Label {
            oneLine
        } icon: {
            Image(systemName: "waveform")
        }
    }

    private var oneLine: Text {
        guard let state else { return Text(verbatim: "Vibe") }
        let title = Text(verbatim: state.title ?? "").bold()
        guard let artist = state.artist, !artist.isEmpty else { return title }
        let rest = Text(verbatim: " – \(artist)").foregroundStyle(.secondary)
        return Text("\(title)\(rest)")
    }

    // MARK: - Shared pieces

    // A filename-derived single line keeps the title color.
    private func textLines(size: CGFloat = kTextSize, shrinks: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(state?.title ?? "Vibe")
                .font(.system(size: size, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(shrinks ? 0.6 : 1)
            if let artist = state?.artist, !artist.isEmpty {
                Text(artist)
                    .font(.system(size: size))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                    .minimumScaleFactor(shrinks ? 0.7 : 1)
            }
        }
    }

    // TRAP: independent shrinking can make the title smaller than the artist.
    private func fittedTextLines(sizes: [CGFloat]) -> some View {
        ViewThatFits(in: .horizontal) {
            ForEach(sizes, id: \.self) { size in
                textLines(size: size, shrinks: false)
            }
        }
    }

    private func artworkTile(side: CGFloat) -> some View {
        Group {
            if let artwork = entry.artwork {
                Image(uiImage: artwork).resizable().scaledToFill()
            } else {
                ZStack {
                    Color.white.opacity(0.08)
                    Image(systemName: "waveform")
                        .font(.system(size: side * 0.32))
                        .foregroundStyle(.white.opacity(0.35))
                }
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: kCornerRadius, style: .continuous))
    }

    private func playPauseButton(diameter: CGFloat) -> some View {
        Button(intent: VibePlayPauseIntent()) {
            ZStack {
                Circle().fill(.white.opacity(0.92))
                Image(systemName: playGlyph)
                    .font(.system(size: diameter * 0.4))
                    .foregroundStyle(.black.opacity(0.85))
            }
            .frame(width: diameter, height: diameter)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    private func skipButton(_ intent: some AppIntent, systemName: String, diameter: CGFloat) -> some View {
        Button(intent: intent) {
            Image(systemName: systemName)
                .font(.system(size: diameter * 0.46))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: diameter, height: diameter)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // Reveal the played image without baking the envelope for each entry.
    // A playhead line uses the played image across the whole strip.
    // TRAP: Lock Screen halves need the played image's alpha as a tintable shape.
    private func waveform(lockScreen: Bool = false) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                if lockScreen, let played = entry.played {
                    Image(uiImage: played)
                        .resizable()
                        .renderingMode(.template)
                        .opacity(0.35)
                } else if let unplayed = entry.unplayed {
                    Image(uiImage: unplayed).resizable()
                }
                if let played = entry.played {
                    Image(uiImage: played)
                        .resizable()
                        .renderingMode(lockScreen ? .template : .original)
                        .mask(alignment: .leading) {
                            Rectangle().frame(width: geometry.size.width * progress)
                        }
                }
                if state?.playheadLine == true, entry.played != nil {
                    Rectangle()
                        .fill(.white)
                        .frame(width: kPlayheadLineWidth)
                        .offset(x: max(0, min(geometry.size.width - kPlayheadLineWidth,
                                              geometry.size.width * progress - kPlayheadLineWidth / 2)))
                }
                if state != nil && !lockScreen {
                    seekZones
                }
            }
        }
    }

    // Cover the strip even before its image arrives. Empty areas must seek
    // instead of falling through to the widget's open-app action.
    private var seekZones: some View {
        // Each zone names the track whose strip it sits on, so a tap on a render
        // WidgetKit has not yet replaced cannot seek the track that followed.
        let trackKey = state?.trackKey ?? ""
        return HStack(spacing: 0) {
            ForEach(0..<kVibeSeekZoneCount, id: \.self) { zone in
                Button(intent: VibeSeekIntent(zone: zone, trackKey: trackKey)) {
                    Rectangle().fill(.clear).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

}
