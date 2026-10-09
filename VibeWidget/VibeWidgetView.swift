//
//  VibeWidgetView.swift
//  VibeWidget
//
//  MEDIUM is the desktop header over a full-width waveform: artwork, title and
//  artist on one row with the transport right-aligned, and the whole bottom
//  given to the envelope. The waveform is the thing this app is recognised by,
//  so it gets the space rather than the chrome. SMALL follows Spotify's small
//  widget: artwork top-left with one play/pause disc beside it, the two text
//  lines across the whole bottom, and no waveform. LARGE gives its top half to
//  the artwork, with the text and the transport beside it, and its bottom half
//  to the waveform.
//
//  The waveform kinds are SMALL only. They are the medium without its header
//  row: the two text lines across the top and the envelope below. A tap on
//  the waveform seeks, and anywhere else opens the app. The second kind puts
//  the play/pause disc top-right, after the text, as the first small tile does.
//
//  The Lock Screen families draw in the system's one tint, so they use no
//  artwork and no colour. CIRCULAR is a progress ring around play/pause.
//  RECTANGULAR is the two text lines over a waveform strip. INLINE is one line
//  of text.
//
//  It is an ADAPTATION of the desktop window, not a copy. The glass, the live
//  art-tint wash and the scrolling waveform all need a live view; a widget gets
//  one archived render per timeline entry. What carries over is the
//  arrangement and the type hierarchy.
//

import AppIntents
import SwiftUI
import UIKit
import WidgetKit

private let kCornerRadius: CGFloat = 8

// Medium: the top row's height, and with it the artwork and the type that
// fills it. Everything below this row is the waveform.
private let kMediumHeaderHeight: CGFloat = 54
// Small: MEASURED off Spotify's small widget in the reference screenshot, on a
// 170pt tile — artwork 67pt at a 16pt inset, title and artist both ~22pt (bold
// and regular), ~17pt from artwork to title.
private let kSmallPadding: CGFloat = 16
private let kSmallArtworkSide: CGFloat = 67
// The play/pause disc, measured off Spotify's at 39pt.
private let kSmallPlayDiameter: CGFloat = 39
private let kSmallMinGap: CGFloat = 4
// That measured type size, and not the small family's alone: BOTH families set
// both their lines at it, so a track reads identically in either tile. At 1pt
// spacing the pair needs ~53pt, which is what keeps it inside the medium
// header's 54 — widen that spacing and the artist loses its descenders.
private let kTextSize: CGFloat = 22
// Where the text shares a row, both lines take the largest of these sizes at
// which both fit (fittedTextLines).
private let kSmallPlayTextSizes: [CGFloat] = [17, 15, 13]
private let kLargeTextSizes: [CGFloat] = [22, 19, 17, 15]
// Large: the top half is the header, the bottom half the waveform. The
// artwork is this share of the header's height, so it sits centred in it.
private let kLargeArtworkShare: CGFloat = 0.85
private let kLargeGap: CGFloat = 12

struct VibeWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: VibeEntry
    // The small family's layout; every other family has only one.
    var waveformTile = false
    var playButton = false

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

    // The desktop's header tint is the artwork's dominant colour washed behind
    // the text. Sampling one here would cost a decode per render, so the art
    // itself is blurred and dimmed instead — the same effect by a cheaper
    // route, and it degrades to flat black with no artwork.
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

    // Two lines of text filling the artwork's height, rather than small type
    // hanging from its top edge — there is no third line left to hold the
    // block down, so the two that remain take the room.
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

    // Spotify's small widget with the transport where its logo sits: artwork
    // top-left, one play/pause disc centred in the space to its right, and
    // title over artist spanning the whole bottom at the same, large size. The
    // text gets the full width, which is what lets both lines be as big as the
    // reference's. No next button here: a second control squeezed the artwork
    // on every tile but the largest.
    //
    // The artwork is a fixed 67pt — Spotify's — and the leftover height goes
    // between it and the title, which on a 170pt tile comes out at ~17pt.
    //
    // TRAP: this family insets THREE sides, and the text carries the fourth.
    // Padding the trailing side here too would end the artwork row 16pt short
    // of the tile, and a disc centred in that box sits visibly left — the eye
    // measures to the tile's edge, not to a content box it cannot see.
    private var small: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                artworkTile(side: kSmallArtworkSide)
                if state != nil {
                    // Spotify's 39pt disc, centred both ways in exactly what the
                    // artwork leaves — its right edge to the tile's right edge.
                    // The flexible frame IS the centring; there is no offset to
                    // re-tune on another tile size.
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

    // Same inset all round as the other small tile. Without the disc the type
    // is the other tile's too, so a track reads identically in both. The text
    // takes the top, and the waveform gets everything below.
    private var smallWaveform: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if playButton && state != nil {
                    fittedTextLines(sizes: kSmallPlayTextSizes)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    playPauseButton(diameter: kSmallPlayDiameter)
                } else {
                    textLines()
                        .frame(maxWidth: .infinity, alignment: .leading)
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
                // The column is the artwork's height. The text starts at its
                // top, and the transport is centred in what the text leaves.
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
        let progress = state.map { $0.progress(at: entry.date) } ?? 0
        return Gauge(value: progress) {
            EmptyView()
        } currentValueLabel: {
            if state != nil {
                Button(intent: VibePlayPauseIntent()) {
                    Image(systemName: state?.playing == true ? "pause.fill" : "play.fill")
                        .font(.system(size: 20))
                }
                .buttonStyle(.plain)
            } else {
                Image(systemName: "waveform")
            }
        }
        .gaugeStyle(.accessoryCircularCapacity)
    }

    // One small line of text, so the waveform gets most of the height.
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

    // The title, then the artist in the secondary style. The inline family
    // draws it plain.
    private var oneLine: Text {
        guard let state else { return Text(verbatim: "Vibe") }
        let title = Text(verbatim: state.title ?? "").bold()
        guard let artist = state.artist, !artist.isEmpty else { return title }
        let rest = Text(verbatim: " – \(artist)").foregroundStyle(.secondary)
        return Text("\(title)\(rest)")
    }

    // MARK: - Shared pieces

    // Title over artist, the same block in every tile. By default both lines
    // shrink to fit rather than truncating, which is what the card does on the
    // phone. At this type size a long title would otherwise lose its end to an
    // ellipsis on most tracks. A nil artist means the title is the
    // filename-derived single line, and it still takes the TITLE's colour.
    // That is the rule both apps draw by.
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

    // Both lines at the largest of sizes at which both fit, truncating only at
    // the last. TRAP: textLines' shrinking fits each line on its own, so a long
    // title came out smaller than its artist.
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

    // Play/pause is a filled disc and next a bare glyph: one primary action per
    // widget, which is what makes the row readable at a glance rather than a
    // strip of equal controls.
    private func playPauseButton(diameter: CGFloat) -> some View {
        Button(intent: VibePlayPauseIntent()) {
            ZStack {
                Circle().fill(.white.opacity(0.92))
                Image(systemName: entry.state?.playing == true ? "pause.fill" : "play.fill")
                    .font(.system(size: diameter * 0.4))
                    .foregroundStyle(.black.opacity(0.85))
            }
            .frame(width: diameter, height: diameter)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    // The glyphs are the mac's, and the mini player's.
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

    // Two baked images, not a live draw: the app renders the current track's
    // envelope twice, once in each half of the waveform theme's palette, and
    // the played one is revealed to the playhead. That is what lets the
    // playhead move without the app re-rendering anything per entry.
    //
    // On the Lock Screen the image is only a shape, which the system tints.
    // Both halves draw the PLAYED image, solid up to the playhead and dim after
    // it. TRAP: the unplayed image carries its theme's low resting alpha, so as
    // a shape it all but vanished. There are no seek zones there. Across a
    // strip that narrow they are too small to aim at.
    private func waveform(lockScreen: Bool = false) -> some View {
        GeometryReader { geometry in
            let progress = state.map { $0.progress(at: entry.date) } ?? 0
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
                if state != nil && !lockScreen {
                    seekZones
                }
            }
        }
    }

    // The waveform is the seek control, as it is in both apps — but a widget
    // gets no continuous gesture, so it is a row of invisible tap targets
    // rather than a scrubber. They cover the whole strip, including where
    // there is no waveform yet, so a tap never falls through to the widget's
    // open-the-app action and silently does the wrong thing.
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
