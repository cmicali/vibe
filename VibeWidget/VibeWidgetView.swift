//
//  VibeWidgetView.swift
//  VibeWidget
//
//  Two families, one arrangement. MEDIUM is the desktop header over a full-
//  width waveform: artwork, title and artist on one row with the transport
//  right-aligned, and the whole bottom given to the envelope — the waveform is
//  the thing this app is recognised by, so it gets the space rather than the
//  chrome. SMALL follows Spotify's small widget: artwork top-left with one
//  play/pause disc beside it, the two text lines across the whole bottom, and
//  no waveform — a square is too narrow to draw one as anything but texture.
//
//  It is an ADAPTATION of the desktop window, not a copy. The glass, the live
//  art-tint wash and the scrolling waveform all need a live view; a widget gets
//  one archived render per timeline entry. What carries over is the
//  arrangement and the type hierarchy.
//

import AppIntents
import SwiftUI
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

struct VibeWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: VibeEntry

    private var state: VibeWidgetState? {
        guard let state = entry.state, state.hasTrack else { return nil }
        return state
    }

    var body: some View {
        Group {
            if family == .systemSmall { small } else { medium }
        }
        .containerBackground(for: .widget) { background }
    }

    // The tinted modes — the mac desktop whenever a window covers it, the iOS
    // tinted and clear Home Screens — remove this background and tint
    // everything else; the images opt into keeping their pictures.
    //
    // The desktop's header tint is the artwork's dominant colour washed behind
    // the text. Sampling one here would cost a decode per render, so the art
    // itself is blurred and dimmed instead — the same effect by a cheaper
    // route, and it degrades to flat black with no artwork.
    private var background: some View {
        ZStack {
            Color.black
            if let blurred = entry.blurredArtwork {
                Image(decorative: blurred, scale: 1)
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
            waveform
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
            textLines
                .frame(maxHeight: .infinity, alignment: .center)
            Spacer(minLength: 4)
            if state != nil {
                playPauseButton(diameter: 38)
                nextButton(diameter: 34)
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
            textLines
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, kSmallPadding)   // the side body does not inset
        }
        .padding(.leading, kSmallPadding)
        .padding(.vertical, kSmallPadding)
    }

    // MARK: - Shared pieces

    // Title over artist, the same block in both families. Both lines shrink to
    // fit rather than truncating, which is what the card does on the phone: at
    // this type size a long title would otherwise lose its end to an ellipsis
    // on most tracks. A nil artist means the title is the filename-derived
    // single line, and it still takes the TITLE's colour — the rule both apps
    // draw by.
    private var textLines: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(state?.title ?? "Vibe")
                .font(.system(size: kTextSize, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let artist = state?.artist, !artist.isEmpty {
                Text(artist)
                    .font(.system(size: kTextSize))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
    }

    private func artworkTile(side: CGFloat) -> some View {
        Group {
            if let artwork = entry.artwork {
                // The cover keeps its colours in the tinted modes — the mac
                // desktop is in one whenever a window covers it, which is most
                // of the time, and a tinted cover reads as a broken one.
                Image(decorative: artwork, scale: 1)
                    .resizable()
                    .widgetAccentedRenderingMode(.fullColor)
                    .scaledToFill()
            } else {
                ZStack {
                    Color.white.opacity(0.08)
                    Image(systemName: "music.note")
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

    private func nextButton(diameter: CGFloat) -> some View {
        Button(intent: VibeNextIntent()) {
            Image(systemName: "forward.end.fill")   // the mac's glyph, and the mini player's
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
    private var waveform: some View {
        GeometryReader { geometry in
            let progress = state.map { $0.progress(at: entry.date) } ?? 0
            ZStack(alignment: .leading) {
                // Baked at 3x; the scale only matters for layout, which the
                // resizable frame overrides.
                if let unplayed = entry.unplayed {
                    Image(decorative: unplayed, scale: 3)
                        .resizable()
                        .widgetAccentedRenderingMode(.accentedDesaturated)
                }
                if let played = entry.played {
                    Image(decorative: played, scale: 3)
                        .resizable()
                        .widgetAccentedRenderingMode(.accentedDesaturated)
                        .mask(alignment: .leading) {
                            Rectangle().frame(width: geometry.size.width * progress)
                        }
                }
                if state != nil {
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
