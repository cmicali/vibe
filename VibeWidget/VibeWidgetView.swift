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
import UIKit
import WidgetKit

private let kCornerRadius: CGFloat = 8

// Medium: the top row's height, and with it the artwork and the type that
// fills it. Everything below this row is the waveform.
private let kMediumHeaderHeight: CGFloat = 54
// Small: MEASURED off Spotify's small widget in the reference screenshot, on a
// 170pt tile — artwork 67pt at a 16pt inset, title and artist both ~22pt (bold
// and regular), ~17pt from artwork to title. The artwork side is a CAP, not a
// floor: it is Spotify's size on the device the reference came from, and gives
// way only on a tile too short to hold it plus the two text lines.
private let kSmallPadding: CGFloat = 16
private let kSmallArtworkSide: CGFloat = 67
private let kSmallArtworkMin: CGFloat = 52
// The play/pause disc, measured off Spotify's at 39pt, and the width it
// reserves beside the artwork so the two can never touch.
private let kSmallPlayDiameter: CGFloat = 39
private let kSmallTransportWidth: CGFloat = kSmallPlayDiameter + 16
private let kSmallTextSize: CGFloat = 22
private let kSmallTextHeight: CGFloat = 53       // two ~22pt lines plus their 1pt spacing
private let kSmallMinGap: CGFloat = 4

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

    // The desktop's header tint is the artwork's dominant colour washed behind
    // the text. Sampling one here would cost a decode per render, so the art
    // itself is blurred and dimmed instead — the same effect by a cheaper
    // route, and it degrades to flat black with no artwork.
    private var background: some View {
        ZStack {
            Color.black
            if let artwork = entry.artwork {
                Image(uiImage: artwork)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: 40, opaque: true)
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
            VStack(alignment: .leading, spacing: 2) {
                titleText(size: 20)
                artistText(size: 15)
            }
            .frame(maxHeight: .infinity, alignment: .center)
            Spacer(minLength: 4)
            if state != nil {
                transportButton(.playPause, diameter: 38)
                transportButton(.next, diameter: 34)
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
    // The artwork is a fixed 67pt — Spotify's — except where a tile cannot hold
    // that and the two text lines, when it gives way rather than the text. It
    // is boxed in on two sides: the disc caps its WIDTH and the text block caps
    // its HEIGHT, and which binds depends on the tile, so both are checked. The
    // leftover height goes between artwork and title, which on a 170pt tile
    // comes out at Spotify's ~17pt.
    //
    // TRAP: this family insets THREE sides, and the text carries the fourth.
    // Padding the trailing side here too would end the artwork row 16pt short
    // of the tile, and a disc centred in that box sits visibly left — the eye
    // measures to the tile's edge, not to a content box it cannot see.
    private var small: some View {
        GeometryReader { geometry in
            let side = min(kSmallArtworkSide,
                           max(kSmallArtworkMin,
                               min(geometry.size.width - kSmallTransportWidth,
                                   geometry.size.height - kSmallTextHeight - kSmallMinGap)))
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    artworkTile(side: side)
                    if state != nil {
                        // Spotify's 39pt disc, centred both ways in exactly what
                        // the artwork leaves — artwork's right edge to the
                        // tile's right edge. The flexible frame IS the centring;
                        // there is no offset to re-tune on another tile size.
                        transportButton(.playPause, diameter: kSmallPlayDiameter)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(height: side)
                Spacer(minLength: kSmallMinGap)
                VStack(alignment: .leading, spacing: 1) {
                    titleText(size: kSmallTextSize, weight: .bold)
                    artistText(size: kSmallTextSize)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, kSmallPadding)   // the side body does not inset
            }
        }
        .padding(.leading, kSmallPadding)
        .padding(.vertical, kSmallPadding)
    }

    // MARK: - Shared pieces

    // Both lines shrink to fit rather than truncating, which is what the card
    // does on the phone: at this type size a long title would otherwise lose
    // its end to an ellipsis on most tracks.
    private func titleText(size: CGFloat, weight: Font.Weight = .semibold) -> some View {
        // A nil artist means the title is the filename-derived single line, and
        // it still takes the TITLE's colour — the rule both apps draw by.
        Text(state?.title ?? "Vibe")
            .font(.system(size: size, weight: weight))
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
    }

    @ViewBuilder
    private func artistText(size: CGFloat) -> some View {
        if let artist = state?.artist, !artist.isEmpty {
            Text(artist)
                .font(.system(size: size))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    private func artworkTile(side: CGFloat) -> some View {
        Group {
            if let artwork = entry.artwork {
                Image(uiImage: artwork).resizable().scaledToFill()
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

    private enum Transport { case playPause, next }

    // Play/pause is a filled disc and next is a bare glyph: one primary action
    // per widget, which is what makes the row readable at a glance rather than
    // a strip of equal controls.
    private func transportButton(_ kind: Transport, diameter: CGFloat) -> some View {
        let playing = entry.state?.playing == true
        let name = kind == .next ? "forward.end.fill" : (playing ? "pause.fill" : "play.fill")
        return Group {
            if kind == .playPause {
                Button(intent: VibePlayPauseIntent()) {
                    ZStack {
                        Circle().fill(.white.opacity(0.92))
                        Image(systemName: name)
                            .font(.system(size: diameter * 0.4))
                            .foregroundStyle(.black.opacity(0.85))
                    }
                    .frame(width: diameter, height: diameter)
                    .contentShape(Circle())
                }
            } else {
                Button(intent: VibeNextIntent()) {
                    Image(systemName: name)
                        .font(.system(size: diameter * 0.46))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: diameter, height: diameter)
                        .contentShape(Rectangle())
                }
            }
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
                if let unplayed = entry.unplayed {
                    Image(uiImage: unplayed).resizable()
                }
                if let played = entry.played {
                    Image(uiImage: played)
                        .resizable()
                        .mask(alignment: .leading) {
                            Rectangle().frame(width: geometry.size.width * progress)
                        }
                }
                seekZones
            }
        }
    }

    // The waveform is the seek control, as it is in both apps — but a widget
    // gets no continuous gesture, so it is a row of invisible tap targets
    // rather than a scrubber. They cover the whole strip, including where
    // there is no waveform yet, so a tap never falls through to the widget's
    // open-the-app action and silently does the wrong thing.
    private var seekZones: some View {
        HStack(spacing: 0) {
            ForEach(0..<kVibeSeekZoneCount, id: \.self) { zone in
                Button(intent: VibeSeekIntent(zone: zone)) {
                    Rectangle().fill(.clear).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .opacity(state == nil ? 0 : 1)   // nothing to seek in the empty state
    }


}
