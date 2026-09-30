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
