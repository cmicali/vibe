
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

// The mac's transport row over its 150pt art (MainPlayerContentViewInternal.h),
// scaled to the tile. The frames overlap, as on the mac.
private let kMacArtSide: CGFloat = 150
private let kMacTransportX: CGFloat = 4
private let kMacTransportBottom: CGFloat = 3
private let kMacTransportButtonSize: CGFloat = 50
private let kMacTransportSpacing: CGFloat = 46
private let kMacTransportSymbolSize: CGFloat = 31
// SymbolButton's resting and disabled white.
private let kMacTransportRestingOpacity = 0.55
private let kMacTransportDisabledOpacity = 0.19
// The mac's darkening gradient over the art's lower edge, bottom up.
private let kMacTransportGradient = Gradient(stops: [
    .init(color: .black.opacity(0.96), location: 0),
    .init(color: .black.opacity(0.55), location: 0.35),
    .init(color: .black.opacity(0), location: 0.62),
])

// The small family's layouts; every other family has only one.
enum VibeSmallLayout {
    case artworkTile, waveform, waveformPlay, fullBleed
}

struct VibeWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: VibeEntry
    var smallLayout = VibeSmallLayout.artworkTile

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
            case .systemSmall:
                switch smallLayout {
                case .artworkTile: small
                case .waveform, .waveformPlay: smallWaveform
                case .fullBleed: fullBleed
                }
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
            case .systemSmall where smallLayout == .fullBleed: fullBleedBackground
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
                glyphButton(VibeNextIntent(), systemName: "forward.end.fill", diameter: 34)
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
        let showsPlay = smallLayout == .waveformPlay && state != nil
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

    // The art and gradient are the container background, so the system clips
    // them to the tile and drops them in the tinted modes.
    private var fullBleedBackground: some View {
        ZStack {
            Color.black
            artworkFill(glyphSize: kMacArtSide * 0.32)
            LinearGradient(gradient: kMacTransportGradient, startPoint: .bottom, endPoint: .top)
        }
    }

    // Like the mac, the buttons show without a track, and play and next are
    // disabled. Playlist opens the app on the Playlist tab.
    private var fullBleed: some View {
        GeometryReader { geometry in
            let scale = min(geometry.size.width, geometry.size.height) / kMacArtSide
            let side = kMacTransportButtonSize * scale
            let glyphScale = kMacTransportSymbolSize / kMacTransportButtonSize
            let opacity = state != nil ? kMacTransportRestingOpacity : kMacTransportDisabledOpacity
            HStack(spacing: (kMacTransportSpacing - kMacTransportButtonSize) * scale) {
                glyphButton(VibeShowPlaylistIntent(), systemName: "list.bullet", diameter: side,
                            glyphScale: glyphScale, opacity: kMacTransportRestingOpacity)
                Group {
                    glyphButton(VibePlayPauseIntent(), systemName: playGlyph, diameter: side,
                                glyphScale: glyphScale, opacity: opacity)
                    glyphButton(VibeNextIntent(), systemName: "forward.end.fill", diameter: side,
                                glyphScale: glyphScale, opacity: opacity)
                }
                .disabled(state == nil)
            }
            .padding(.leading, kMacTransportX * scale)
            .padding(.bottom, kMacTransportBottom * scale)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
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
                                glyphButton(VibePreviousIntent(), systemName: "backward.end.fill", diameter: 40)
                                playPauseButton(diameter: 48)
                                glyphButton(VibeNextIntent(), systemName: "forward.end.fill", diameter: 40)
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
        artworkFill(glyphSize: side * 0.32)
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: kCornerRadius, style: .continuous))
    }

    // Fills the offered size and crops the art to it. Drawn as an overlay, a
    // tall image cannot grow the view past what it was offered.
    private func artworkFill(glyphSize: CGFloat) -> some View {
        Color.white.opacity(0.08)
            .overlay {
                if let artwork = entry.artwork {
                    Image(uiImage: artwork).resizable().scaledToFill()
                } else {
                    Image(systemName: "waveform")
                        .font(.system(size: glyphSize))
                        .foregroundStyle(.white.opacity(0.35))
                }
            }
            .clipped()
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

    private func glyphButton(_ intent: some AppIntent, systemName: String, diameter: CGFloat,
                             glyphScale: CGFloat = 0.46, opacity: Double = 0.85) -> some View {
        Button(intent: intent) {
            Image(systemName: systemName)
                .font(.system(size: diameter * glyphScale))
                .foregroundStyle(.white.opacity(opacity))
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
