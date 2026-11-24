// Draws the widget's view in every family and layout, playing and empty.
// No test can place a widget, so the view is given its family directly
// (familyOverride). The tests assert facts about the pixels and keep no
// stored image. A view outside a widget draws no container background, so
// each image sits on black.

import SwiftUI
import UIKit
import WidgetKit
import XCTest

@MainActor
final class VibeWidgetViewTests: XCTestCase {
    private struct Layout {
        let name: String
        let family: WidgetFamily
        let small: VibeSmallLayout
        let size: CGSize
    }

    // Points, as an iPhone 17's Home Screen and Lock Screen size them.
    private let layouts: [Layout] = [
        Layout(name: "small", family: .systemSmall, small: .artworkTile, size: CGSize(width: 170, height: 170)),
        Layout(name: "small-waveform", family: .systemSmall, small: .waveform, size: CGSize(width: 170, height: 170)),
        Layout(name: "small-waveform-play", family: .systemSmall, small: .waveformPlay,
               size: CGSize(width: 170, height: 170)),
        Layout(name: "small-artwork", family: .systemSmall, small: .fullBleed, size: CGSize(width: 170, height: 170)),
        Layout(name: "medium", family: .systemMedium, small: .artworkTile, size: CGSize(width: 364, height: 170)),
        Layout(name: "large", family: .systemLarge, small: .artworkTile, size: CGSize(width: 364, height: 382)),
        Layout(name: "lock-circular", family: .accessoryCircular, small: .artworkTile,
               size: CGSize(width: 76, height: 76)),
        Layout(name: "lock-rectangular", family: .accessoryRectangular, small: .artworkTile,
               size: CGSize(width: 172, height: 76)),
        Layout(name: "lock-inline", family: .accessoryInline, small: .artworkTile,
               size: CGSize(width: 234, height: 26)),
    ]

    func testEveryFamilyDrawsAtItsSize() throws {
        for (entryName, entry) in [("playing", playingEntry()), ("empty", VibeEntry.empty)] {
            for layout in layouts {
                let label = "\(layout.name) \(entryName)"
                let image = try render(entry, layout.family, layout.small, layout.size, label)
                XCTAssertEqual(image.width, Int(layout.size.width), label)
                XCTAssertEqual(image.height, Int(layout.size.height), label)
                XCTAssertGreaterThan(Self.shareUnlikeCorner(image), 0.005, "\(label) drew a blank or uniform image")
            }
        }
    }

    // The family reaches the view's switch: drawn at one size, no two layouts
    // draw the same picture. Without the override, every family but small's
    // other layouts would draw the environment's default family.
    func testEachLayoutDrawsItsOwnPicture() throws {
        let entry = playingEntry()
        let size = CGSize(width: 364, height: 170)
        var drawn: [(String, [UInt8])] = []
        for layout in layouts {
            let picture = try Self.pixels(render(entry, layout.family, layout.small, size, layout.name))
            for (name, other) in drawn {
                XCTAssertTrue(picture != other, "\(layout.name) drew the same picture as \(name)")
            }
            drawn.append((layout.name, picture))
        }
    }

    // MARK: - Drawing

    private func render(_ entry: VibeEntry, _ family: WidgetFamily, _ small: VibeSmallLayout,
                        _ size: CGSize, _ label: String) throws -> CGImage {
        let view = VibeWidgetView(entry: entry, smallLayout: small, familyOverride: family)
            .frame(width: size.width, height: size.height)
            .background(Color.black)
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        return try XCTUnwrap(renderer.cgImage, "\(label) drew nothing")
    }

    // RGBA, 8 bits a channel, in the image's own size.
    private static func pixels(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                                    bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }

    // The share of pixels whose color differs from the top-left corner's.
    private static func shareUnlikeCorner(_ image: CGImage) -> Double {
        let bytes = pixels(image)
        let corner = Array(bytes[0..<4])
        var unlike = 0
        for start in stride(from: 0, to: bytes.count, by: 4) {
            let distance = (0..<4).map { abs(Int(bytes[start + $0]) - Int(corner[$0])) }.max() ?? 0
            if distance > 24 {
                unlike += 1
            }
        }
        return Double(unlike) / Double(image.width * image.height)
    }

    // MARK: - The entry

    // A track 40% of the way through, with art and both strips.
    private func playingEntry() -> VibeEntry {
        let state = VibeWidgetState()
        state.hasTrack = true
        state.title = "Widget One"
        state.artist = "Widget Artist"
        state.playing = true
        state.duration = 200
        state.position = 80
        state.positionDate = Date()
        state.trackKey = "/snapshot/01 Widget One.m4a"
        let art = image(CGSize(width: 576, height: 576)) { context, size in
            let colors = [UIColor.systemIndigo.cgColor, UIColor.systemTeal.cgColor] as CFArray
            let gradient = CGGradient(colorsSpace: nil, colors: colors, locations: nil)!
            context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height),
                                       options: [])
        }
        return VibeEntry(date: state.positionDate!, state: state, artwork: art, blurredArtwork: art,
                         played: strip(.white), unplayed: strip(UIColor.white.withAlphaComponent(0.3)))
    }

    // The strip's bars at the publisher's aspect, 320 by 64.
    private func strip(_ color: UIColor) -> UIImage {
        image(CGSize(width: 960, height: 192)) { context, size in
            context.setFillColor(color.cgColor)
            let bars = 120
            let width = size.width / CGFloat(bars)
            for bar in 0..<bars {
                let level = 0.25 + 0.7 * abs(sin(Double(bar) * 0.37) * cos(Double(bar) * 0.11))
                let height = size.height * 0.75 * CGFloat(level)
                context.fill(CGRect(x: CGFloat(bar) * width + 1, y: (size.height - height) / 2,
                                    width: width - 2, height: height))
            }
        }
    }

    private func image(_ size: CGSize, _ draw: (CGContext, CGSize) -> Void) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { draw($0.cgContext, size) }
    }
}
