import AppKit
import XCTest
@testable import EdgeBeat

final class PaletteExtractorTests: XCTestCase {
    private func image(_ draw: (CGContext, Int) -> Void, size: Int = 128) throws -> NSImage {
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        let context = try XCTUnwrap(CGContext(
            data: &pixels,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        draw(context, size)
        let cgImage = try XCTUnwrap(context.makeImage())
        return NSImage(cgImage: cgImage, size: NSSize(width: size, height: size))
    }

    private func hue(of color: NSColor) throws -> CGFloat {
        let rgb = try XCTUnwrap(color.usingColorSpace(.deviceRGB))
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        rgb.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return hue
    }

    private func circularDistance(_ first: CGFloat, _ second: CGFloat) -> CGFloat {
        let difference = abs(first - second)
        return min(difference, 1 - difference)
    }

    func testFiveDistinctBlocksGiveFiveDistinctColors() throws {
        let hues: [CGFloat] = [0, 0.2, 0.4, 0.6, 0.8]
        let blocks = try hues.map { hue -> CGColor in
            let color = NSColor(calibratedHue: hue, saturation: 1, brightness: 1, alpha: 1)
            return try XCTUnwrap(color.usingColorSpace(.deviceRGB)).cgColor
        }
        let artwork = try image { context, size in
            let bandWidth = CGFloat(size) / CGFloat(blocks.count)
            for (index, block) in blocks.enumerated() {
                context.setFillColor(block)
                context.fill(CGRect(x: CGFloat(index) * bandWidth, y: 0,
                                    width: bandWidth, height: CGFloat(size)))
            }
        }

        let palette = PaletteExtractor.extract(from: artwork)
        XCTAssertEqual(palette.colors.count, 5)
        let extracted = try palette.colors.map { try hue(of: $0) }
        for first in extracted.indices {
            for second in (first + 1)..<extracted.count {
                XCTAssertGreaterThan(
                    circularDistance(extracted[first], extracted[second]), 1.0 / 24.0,
                    "hues \(extracted) are not far enough apart"
                )
            }
        }
        XCTAssertEqual(palette.primary, palette.colors[0])
        XCTAssertEqual(palette.secondary, palette.colors[1])
        XCTAssertEqual(palette.accent, palette.colors[2])
    }

    func testGrayscaleArtworkStillGivesThreeColors() throws {
        let artwork = try image { context, size in
            for row in 0..<size {
                let white = CGFloat(row) / CGFloat(size - 1)
                context.setFillColor(red: white, green: white, blue: white, alpha: 1)
                context.fill(CGRect(x: 0, y: CGFloat(row), width: CGFloat(size), height: 1))
            }
        }

        let palette = PaletteExtractor.extract(from: artwork)
        XCTAssertGreaterThanOrEqual(palette.colors.count, 3)
        XCTAssertLessThanOrEqual(palette.colors.count, 5)
    }

    private func saturation(of color: NSColor) throws -> CGFloat {
        let rgb = try XCTUnwrap(color.usingColorSpace(.deviceRGB))
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        rgb.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return saturation
    }

    func testGrayscaleArtworkFallsBackToAColourfulAurora() throws {
        let artwork = try image { context, size in
            for row in 0..<size {
                let white = CGFloat(row) / CGFloat(size - 1)
                context.setFillColor(red: white, green: white, blue: white, alpha: 1)
                context.fill(CGRect(x: 0, y: CGFloat(row), width: CGFloat(size), height: 1))
            }
        }

        let palette = PaletteExtractor.extract(from: artwork)
        for color in palette.colors {
            XCTAssertGreaterThanOrEqual(try saturation(of: color), 0.5,
                                        "a greyscale cover still has to glow in colour")
        }
    }

    func testANearGreyCoverIsBuiltAroundTheColourItDoesHave() throws {
        // A cover that is grey apart from a small red patch: the patch is the
        // only colour the artwork has, so the glow is built around it.
        let artwork = try image { context, size in
            context.setFillColor(red: 0.55, green: 0.55, blue: 0.55, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: CGFloat(size), height: CGFloat(size)))
            let area = CGFloat(size) * CGFloat(size) * 0.02
            let side = area.squareRoot()
            context.setFillColor(red: 0.85, green: 0.05, blue: 0.05, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        }

        let palette = PaletteExtractor.extract(from: artwork)
        let hues = try palette.colors.map { try hue(of: $0) }
        XCTAssertTrue(hues.contains { circularDistance($0, 0) <= 20.0 / 360.0 },
                      "expected a red-ish colour, got hues \(hues)")
        for color in palette.colors {
            XCTAssertGreaterThanOrEqual(try saturation(of: color), 0.5,
                                        "every colour in the palette has to be chromatic")
        }
    }

    /// The live failure's shape: a beige-grey cover whose one real colour sits
    /// in a hue bucket next to the beige, so the ordinary selection skips it as
    /// a neighbour and comes back holding nothing but the beige. The looser
    /// second pass has to find that colour anyway.
    func testABeigeCoverIsBuiltAroundTheColourItsSelectionSkipped() throws {
        let artwork = try image { context, size in
            // Beige at hue ~25 degrees, saturation ~0.18: over the ordinary
            // gate, under anything the eye would call a colour.
            context.setFillColor(red: 0.62, green: 0.57, blue: 0.51, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: CGFloat(size), height: CGFloat(size)))
            // An orange patch at hue ~22 degrees: the adjacent bucket.
            let side = (CGFloat(size) * CGFloat(size) * 0.03).squareRoot()
            context.setFillColor(red: 0.9, green: 0.45, blue: 0.1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        }

        let palette = PaletteExtractor.extract(from: artwork)
        for color in palette.colors {
            XCTAssertGreaterThanOrEqual(try saturation(of: color), 0.5,
                                        "a beige cover still has to glow in colour")
        }
        let hues = try palette.colors.map { try hue(of: $0) }
        XCTAssertTrue(hues.contains { circularDistance($0, 25.0 / 360.0) <= 20.0 / 360.0 },
                      "expected the orange it skipped, got hues \(hues)")
    }

    func testColorsAreOrderedByHueStartingFromThePrimary() throws {
        let hues: [CGFloat] = [0.05, 0.25, 0.45, 0.65, 0.85]
        let artwork = try image { context, size in
            let bandWidth = CGFloat(size) / CGFloat(hues.count)
            for (index, value) in hues.enumerated() {
                let color = NSColor(calibratedHue: value, saturation: 0.9, brightness: 0.95, alpha: 1)
                context.setFillColor(color.usingColorSpace(.deviceRGB)!.cgColor)
                context.fill(CGRect(x: CGFloat(index) * bandWidth, y: 0,
                                    width: bandWidth, height: CGFloat(size)))
            }
        }

        let palette = PaletteExtractor.extract(from: artwork)
        XCTAssertEqual(palette.primary, palette.colors[0])
        let extracted = try palette.colors.map { try hue(of: $0) }
        let base = extracted[0]
        let offsets = extracted.map { value -> CGFloat in
            var distance = value - base
            if distance < 0 { distance += 1 }
            return distance
        }
        XCTAssertEqual(offsets, offsets.sorted(),
                       "hues \(extracted) do not walk the colour circle from the primary")
    }

    func testMissingArtworkFallsBackToTheDefaultPalette() {
        let palette = PaletteExtractor.extract(from: nil)
        XCTAssertEqual(palette.primary, GlowPalette.default.primary)
        XCTAssertEqual(palette.colors.count, 3)
        XCTAssertEqual(GlowPalette.default.colors,
                       [GlowPalette.default.primary,
                        GlowPalette.default.secondary,
                        GlowPalette.default.accent])
    }
}
