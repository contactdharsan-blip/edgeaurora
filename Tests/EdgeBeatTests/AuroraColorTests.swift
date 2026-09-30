import AppKit
import XCTest
@testable import EdgeBeat

final class AuroraColorTests: XCTestCase {
    func testOklabMatchesReferenceValues() {
        // sRGB red in Oklab, from Björn Ottosson's reference implementation.
        let red = AuroraColor.oklab(fromLinear: AuroraColor.linear(fromSRGB: SIMD3(1, 0, 0)))
        XCTAssertEqual(red.x, 0.6280, accuracy: 0.001)
        XCTAssertEqual(red.y, 0.2249, accuracy: 0.001)
        XCTAssertEqual(red.z, 0.1258, accuracy: 0.001)
        let white = AuroraColor.oklab(fromLinear: SIMD3(1, 1, 1))
        XCTAssertEqual(white.x, 1, accuracy: 0.001)
        XCTAssertEqual(hypot(white.y, white.z), 0, accuracy: 0.001)
    }

    func testOKLCHRoundTrips() {
        for color: SIMD3<Float> in [SIMD3(1, 0, 0), SIMD3(0.2, 0.6, 0.9), SIMD3(0.9, 0.8, 0.1), SIMD3(0.5, 0.5, 0.5)] {
            let back = AuroraColor.srgb(fromOKLCH: AuroraColor.oklch(fromSRGB: color))
            XCTAssertEqual(back.x, color.x, accuracy: 0.002)
            XCTAssertEqual(back.y, color.y, accuracy: 0.002)
            XCTAssertEqual(back.z, color.z, accuracy: 0.002)
        }
    }

    func testMixTakesTheShorterHueArc() {
        let degrees: (Float) -> Float = { $0 * .pi / 180 }
        let mid = AuroraColor.mixOKLCH(SIMD3(0.7, 0.15, degrees(350)), SIMD3(0.7, 0.15, degrees(10)), 0.5)
        let wrapped = atan2(sin(mid.z), cos(mid.z))
        XCTAssertEqual(wrapped, 0, accuracy: 0.01)
    }

    func testComplementaryMidpointStaysVivid() {
        // Blue and yellow: a straight RGB or Oklab mix passes through grey.
        let blue = AuroraColor.oklch(fromSRGB: SIMD3(0, 0, 1))
        let yellow = AuroraColor.oklch(fromSRGB: SIMD3(1, 1, 0))
        let mid = AuroraColor.mixOKLCH(blue, yellow, 0.5)
        XCTAssertGreaterThan(mid.y, 0.8 * min(blue.y, yellow.y))
        let rgbMid = AuroraColor.oklch(fromSRGB: SIMD3(0.5, 0.5, 0.5))
        XCTAssertLessThan(rgbMid.y, 0.01)
    }

    func testVividKeepsHueAndLiftsTowardWhite() {
        let lifted = AuroraColor.vivid(SIMD3(0.4, 0.1, 0.1))
        XCTAssertEqual(lifted.x, 1, accuracy: 0.001)
        XCTAssertEqual(lifted.y, 0.28, accuracy: 0.001)
        XCTAssertEqual(lifted.z, 0.28, accuracy: 0.001)
        let grey = AuroraColor.vivid(SIMD3(0.5, 0.51, 0.5))
        XCTAssertEqual(grey.x, grey.y, accuracy: 0.001)
    }
}
