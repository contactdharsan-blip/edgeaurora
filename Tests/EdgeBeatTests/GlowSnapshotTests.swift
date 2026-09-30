import AppKit
import Metal
import XCTest
@testable import EdgeBeat

/// Renders the glow offscreen through the same strips, animator and shader the
/// app uses, then checks the pixels. Set EDGEBEAT_SNAPSHOT_DIR to also write
/// each scene as a PNG over a dark backdrop for eyeballing.
final class GlowSnapshotTests: XCTestCase {
    private let size = CGSize(width: 1512, height: 949)
    private let notch = DisplayNotch(minX: 662, maxX: 850, depth: 32, cornerRadius: 10)

    private final class Harness {
        let preferences: AppPreferences
        let renderState = RenderState()
        var features = AudioFeatures(level: 0, bass: 0, mid: 0, treble: 0, beat: false, waveform: [])
        lazy var animator = GlowAnimator(preferences: preferences, renderState: renderState,
                                         featureSource: { [unowned self] in self.features })
        var time: CFTimeInterval = 100

        init() {
            let suite = "edgebeat-snapshot-\(UUID().uuidString)"
            preferences = AppPreferences(defaults: UserDefaults(suiteName: suite)!)
            preferences.thickness = 1
            preferences.intensity = 1
            renderState.update(track: NowPlayingTrack(
                source: .music, title: "Test", artist: "Artist", album: "Album",
                artwork: nil, artworkRevision: "", identifier: "t", state: .playing,
                processID: nil, duration: 180, position: 0, isShuffleEnabled: false))
        }

        func run(seconds: Double) {
            let frames = Int(seconds * 60)
            for _ in 0..<max(1, frames) {
                time += 1.0 / 60.0
                features.timestamp = time
                animator.advance(to: time)
            }
        }
    }

    private func bands(_ shape: (Float) -> Float) -> [Float] {
        (0..<AudioFeatures.bandCount).map { shape(Float($0) / Float(AudioFeatures.bandCount - 1)) }
    }

    /// Renders the four strips and composites them into one RGBA image (premultiplied).
    private func render(_ harness: Harness) throws -> [UInt8] {
        let renderer = try XCTUnwrap(GlowRenderer.shared)
        let width = Int(size.width), height = Int(size.height)
        var image = [UInt8](repeating: 0, count: width * height * 4)
        let depth = GlowAnimator.stripDepth(thickness: harness.preferences.thickness)
        for rect in GlowView.stripFrames(size: size, depth: depth, notchDepth: notch.depth) {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: GlowRenderer.pixelFormat, width: Int(rect.width),
                height: Int(rect.height), mipmapped: false)
            descriptor.usage = [.renderTarget]
            descriptor.storageMode = .shared
            let texture = try XCTUnwrap(renderer.device.makeTexture(descriptor: descriptor))
            let buffer = try XCTUnwrap(renderer.makeCommandBuffer())
            renderer.encode(harness.animator.uniforms(screenSize: size, strip: rect, notch: notch),
                            into: buffer, target: texture)
            buffer.commit()
            buffer.waitUntilCompleted()
            var pixels = [UInt8](repeating: 0, count: Int(rect.width) * Int(rect.height) * 4)
            texture.getBytes(&pixels, bytesPerRow: Int(rect.width) * 4,
                             from: MTLRegionMake2D(0, 0, Int(rect.width), Int(rect.height)),
                             mipmapLevel: 0)
            for y in 0..<Int(rect.height) {
                for x in 0..<Int(rect.width) {
                    let source = (y * Int(rect.width) + x) * 4
                    let target = ((y + Int(rect.minY)) * width + x + Int(rect.minX)) * 4
                    // BGRA → RGBA
                    image[target] = pixels[source + 2]
                    image[target + 1] = pixels[source + 1]
                    image[target + 2] = pixels[source]
                    image[target + 3] = pixels[source + 3]
                }
            }
        }
        return image
    }

    private func alpha(_ image: [UInt8], _ x: Int, _ y: Int) -> Double {
        Double(image[(y * Int(size.width) + x) * 4 + 3]) / 255
    }

    private func save(_ image: [UInt8], name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["EDGEBEAT_SNAPSHOT_DIR"] else { return }
        let width = Int(size.width), height = Int(size.height)
        var composite = [UInt8](repeating: 255, count: width * height * 4)
        for index in stride(from: 0, to: image.count, by: 4) {
            let a = Double(image[index + 3]) / 255
            for channel in 0..<3 {
                let backdrop = 18.0
                composite[index + channel] = UInt8(min(255, Double(image[index + channel]) + backdrop * (1 - a)))
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(composite) as CFData))
        let cgImage = try XCTUnwrap(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.displayP3)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let data = try XCTUnwrap(NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
    }

    func testBassLightsBottomAndTrebleLightsTop() throws {
        let bass = Harness()
        bass.features.bands = bands { max(0, 1 - $0 * 2) }
        bass.features.level = 0.7
        bass.run(seconds: 0.5)
        let bassImage = try render(bass)
        try save(bassImage, name: "01-bass")

        let treble = Harness()
        treble.features.bands = bands { max(0, $0 * 2 - 1) }
        treble.features.level = 0.7
        treble.run(seconds: 0.5)
        let trebleImage = try render(treble)
        try save(trebleImage, name: "02-treble")

        let bottomProbe = (756, 949 - 40)
        let topProbe = (400, 40)
        XCTAssertGreaterThan(alpha(bassImage, bottomProbe.0, bottomProbe.1),
                             3 * alpha(bassImage, topProbe.0, topProbe.1))
        XCTAssertGreaterThan(alpha(trebleImage, topProbe.0, topProbe.1),
                             3 * alpha(trebleImage, bottomProbe.0, bottomProbe.1))
    }

    func testCentreStaysClearAndStripEdgesFadeToZero() throws {
        // Every Thickness the menu slider allows, not just the one the other
        // scenes use: fixed-size halos once overran thin strips (verifier,
        // 2026-09-29, 0.149 alpha on the last row at thickness 0).
        for thickness in [0.0, 0.1, 0.45, 1.0] {
            let harness = Harness()
            harness.preferences.thickness = thickness
            harness.features.bands = bands { _ in 1 }
            harness.features.level = 1
            harness.features.kickSerial = 0
            harness.run(seconds: 1)
            harness.features.kickSerial = 1
            harness.features.kickStrength = 1
            harness.run(seconds: 1.0 / 30.0)
            let image = try render(harness)
            try save(image, name: String(format: "03-full-kick-thickness-%.2f", thickness))

            XCTAssertEqual(alpha(image, 756, 475), 0)
            let depth = Int(GlowAnimator.stripDepth(thickness: thickness))
            // Last row of the bottom strip and last column of the left strip:
            // the glow must have faded out before the strip ends, or it shows
            // as a line. Check the whole row, not one pixel.
            let lastRow = Int(size.height) - depth
            // Between the corners only: there the side glow legitimately lights
            // the bottom strip's last row.
            let rowMax = stride(from: depth, to: Int(size.width) - depth, by: 2)
                .map { alpha(image, $0, lastRow) }.max() ?? 0
            let columnMax = stride(from: depth, to: Int(size.height) - depth, by: 2)
                .map { alpha(image, depth - 1, $0) }.max() ?? 0
            XCTAssertLessThan(rowMax, 0.02, "bottom strip edge at thickness \(thickness)")
            XCTAssertLessThan(columnMax, 0.02, "left strip edge at thickness \(thickness)")
            // The ribbon floats a few points in from the edge; somewhere across
            // the bottom band it must be solidly lit.
            let bottomBand = (Int(size.height) - depth)..<Int(size.height)
            XCTAssertGreaterThan(bottomBand.map { alpha(image, 756, $0) }.max() ?? 0, 0.3,
                                 "lit at thickness \(thickness)")
        }
    }

    func testQuietPassageIsDimmerThanLoudOne() throws {
        let loud = Harness()
        loud.features.bands = bands { _ in 0.9 }
        loud.features.level = 0.9
        loud.run(seconds: 0.5)
        let quiet = Harness()
        quiet.features.bands = bands { _ in 0.15 }
        quiet.features.level = 0.15
        quiet.run(seconds: 0.5)
        let loudImage = try render(loud)
        let quietImage = try render(quiet)
        try save(quietImage, name: "04-quiet")
        // The body keeps its colour in quiet passages by design; what a quiet
        // passage changes is how far the ribbon reaches, so compare lit area.
        func litArea(_ image: [UInt8]) -> Int {
            stride(from: 3, to: image.count, by: 4).filter { image[$0] > 25 }.count
        }
        XCTAssertGreaterThan(Double(litArea(loudImage)), 1.2 * Double(litArea(quietImage)))
    }

    /// Mean depth, over the bottom edge, of the deepest pixel lit above
    /// `threshold`. A low threshold follows the faint halo, a higher one the
    /// visible rays.
    /// With `percentile`, the reach at that percentile of columns instead of
    /// the mean: rays are sparse, so the mean mostly measures the gaps.
    private func rayReach(_ image: [UInt8], threshold: Double = 0.03,
                          percentile: Double? = nil) -> Double {
        let height = Int(size.height)
        var reaches: [Int] = []
        for x in stride(from: 200, to: Int(size.width) - 200, by: 3) {
            var reach = 0
            for depth in stride(from: 200, through: 0, by: -1)
                where alpha(image, x, height - 1 - depth) > threshold {
                reach = depth
                break
            }
            reaches.append(reach)
        }
        guard let percentile else {
            return Double(reaches.reduce(0, +)) / Double(reaches.count)
        }
        let sorted = reaches.sorted()
        return Double(sorted[min(sorted.count - 1, Int(Double(sorted.count) * percentile))])
    }

    private func steadyScene(band: Float, level: Double, name: String,
                             configure: (AppPreferences) -> Void = { _ in }) throws -> [UInt8] {
        try steadyFrames(band: band, level: level, name: name, frames: 1, configure: configure)[0]
    }

    /// Several frames of a steady scene, 0.3 s apart. Rays live and die on
    /// their own clocks, so a ray's length is its longest over a few frames.
    private func steadyFrames(band: Float, level: Double, name: String, frames: Int,
                              configure: (AppPreferences) -> Void = { _ in }) throws -> [[UInt8]] {
        let harness = Harness()
        configure(harness.preferences)
        harness.features.bands = bands { _ in band }
        harness.features.level = level
        harness.run(seconds: 2)
        var images: [[UInt8]] = []
        for index in 0..<frames {
            if index > 0 { harness.run(seconds: 0.3) }
            images.append(try render(harness))
        }
        try save(images[0], name: name)
        return images
    }

    /// Per column, the longest ray reach across frames.
    private func rayReach(_ frames: [[UInt8]], threshold: Double, percentile: Double? = nil) -> Double {
        let height = Int(size.height)
        var reaches: [Int] = []
        for x in stride(from: 200, to: Int(size.width) - 200, by: 3) {
            var reach = 0
            for image in frames {
                for depth in stride(from: 200, through: reach, by: -1)
                    where alpha(image, x, height - 1 - depth) > threshold {
                    reach = max(reach, depth)
                    break
                }
            }
            reaches.append(reach)
        }
        guard let percentile else {
            return Double(reaches.reduce(0, +)) / Double(reaches.count)
        }
        let sorted = reaches.sorted()
        return Double(sorted[min(sorted.count - 1, Int(Double(sorted.count) * percentile))])
    }

    func testRaysReachFurtherWhenTheMusicIsLoud() throws {
        // Smoke off: this measures rays, and the smoked glass would read as reach.
        let quiet = rayReach(try steadyFrames(band: 0.15, level: 0.15, name: "07-rays-quiet",
                                              frames: 6) { $0.smoke = 0 }, threshold: 0.03)
        let loud = rayReach(try steadyFrames(band: 0.9, level: 0.9, name: "08-rays-loud",
                                             frames: 6) { $0.smoke = 0 }, threshold: 0.03)
        XCTAssertGreaterThan(loud, quiet * 1.6, "loud \(loud) vs quiet \(quiet)")
    }

    func testRayLengthSliderScalesTheRays() throws {
        // How far rays stick out past the ribbon: the 95th-percentile reach
        // (the rays) minus the median (the ribbon's own edge, since rays are
        // sparse). Total reach would dilute the rays with the ribbon's depth.
        func protrusion(rayLength: Double, name: String) throws -> Double {
            let frames = try steadyFrames(band: 0.7, level: 0.7, name: name, frames: 6) {
                $0.rayLength = rayLength
                $0.smoke = 0
            }
            return rayReach(frames, threshold: 0.12, percentile: 0.95)
                - rayReach(frames, threshold: 0.12, percentile: 0.5)
        }
        let short = try protrusion(rayLength: 0, name: "09-raylength-0")
        let long = try protrusion(rayLength: 1, name: "10-raylength-1")
        XCTAssertGreaterThan(long, short * 1.8, "long \(long) vs short \(short)")
    }

    func testDefaultTuningKeepsTheTunedLook() throws {
        // The sliders' midpoints must reproduce the look the owner signed off on.
        XCTAssertEqual(AppPreferences.tuningMultiplier(0.5), 1, accuracy: 1e-9)
        let defaults = try steadyScene(band: 0.6, level: 0.6, name: "11-tuning-default")
        let explicit = try steadyScene(band: 0.6, level: 0.6, name: "12-tuning-explicit") {
            $0.reactivity = 0.5
            $0.rayLength = 0.5
        }
        XCTAssertEqual(defaults, explicit)
    }

    func testReactivityWidensTheKickSwing() throws {
        func kickSwing(reactivity: Double) throws -> Double {
            let harness = Harness()
            harness.preferences.reactivity = reactivity
            harness.features.bands = bands { _ in 0.6 }
            harness.features.level = 0.6
            harness.run(seconds: 1.5)
            let before = rayReach(try render(harness))
            harness.features.kickSerial = 1
            harness.features.kickStrength = 1
            harness.run(seconds: 1.0 / 20.0)
            return rayReach(try render(harness)) - before
        }
        let calm = try kickSwing(reactivity: 0)
        let lively = try kickSwing(reactivity: 1)
        XCTAssertGreaterThan(lively, calm * 1.5 + 0.5, "lively \(lively) vs calm \(calm)")
    }

    func testComplementaryGradientNeverTurnsGrey() throws {
        // Blue and yellow are complementary: blended straight, the gradient
        // between them passes through grey. Blended in OKLCH it must not.
        let image = try steadyScene(band: 0.6, level: 0.6, name: "13-blue-yellow") {
            $0.colorSource = .custom
            $0.colorMode = .gradient
            $0.primaryColor = NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
            $0.secondaryColor = NSColor(srgbRed: 1, green: 1, blue: 0, alpha: 1)
        }
        var saturations: [Double] = []
        for index in stride(from: 0, to: image.count, by: 4 * 7) {
            let a = Double(image[index + 3]) / 255
            guard a > 0.3 else { continue }
            let rgb = (0..<3).map { Double(image[index + $0]) / 255 / a }
            let high = rgb.max()!, low = rgb.min()!
            saturations.append(high > 0 ? (high - low) / high : 0)
        }
        XCTAssertGreaterThan(saturations.count, 1000)
        let tenth = saturations.sorted()[saturations.count / 10]
        XCTAssertGreaterThan(tenth, 0.25, "10th-percentile saturation \(tenth)")
    }

    func testTrackChangeCrossfadesThePalette() throws {
        let harness = Harness()
        harness.preferences.colorSource = .custom
        harness.preferences.colorMode = .single
        harness.preferences.primaryColor = .systemRed
        harness.run(seconds: 0.5)
        func fade() -> Float {
            harness.animator.uniforms(screenSize: size, strip: .zero, notch: nil).blend.y
        }
        XCTAssertEqual(fade(), 1, "the first palette appears without a fade")
        harness.preferences.primaryColor = .systemBlue
        harness.run(seconds: 0.1)
        XCTAssertLessThan(fade(), 0.2)
        harness.run(seconds: 0.65)
        XCTAssertGreaterThan(fade(), 0.3)
        XCTAssertLessThan(fade(), 0.8)
        harness.run(seconds: 0.9)
        XCTAssertEqual(fade(), 1)
    }

    /// Mean ray reach down from the top edge, away from the notch.
    private func topReach(_ image: [UInt8], threshold: Double = 0.08) -> Double {
        var reaches: [Int] = []
        for x in Array(stride(from: 200, to: 600, by: 3)) + Array(stride(from: 912, to: 1312, by: 3)) {
            var reach = 0
            for depth in stride(from: 200, through: 0, by: -1) where alpha(image, x, depth) > threshold {
                reach = depth
                break
            }
            reaches.append(reach)
        }
        return Double(reaches.reduce(0, +)) / Double(reaches.count)
    }

    func testSnareSparksRaysAcrossTheTop() throws {
        let harness = Harness()
        harness.preferences.smoke = 0
        harness.features.bands = bands { _ in 0.6 }
        harness.features.level = 0.6
        harness.run(seconds: 1.5)
        let before = try render(harness)
        harness.features.snareSerial = 1
        harness.features.snareStrength = 1
        harness.run(seconds: 1.0 / 30.0)
        let after = try render(harness)
        try save(after, name: "14-snare-spark")
        let topGain = topReach(after) - topReach(before)
        let bottomGain = rayReach(after, threshold: 0.08) - rayReach(before, threshold: 0.08)
        XCTAssertGreaterThan(topGain, 2, "top \(topGain)")
        XCTAssertGreaterThan(topGain, bottomGain * 2, "top \(topGain) vs bottom \(bottomGain)")
    }

    func testQuietPassagesBreatheAndLoudOnesDoNot() {
        let quiet = Harness()
        quiet.features.bands = bands { _ in 0.1 }
        quiet.features.level = 0.1
        quiet.run(seconds: 10)
        XCTAssertGreaterThan(quiet.animator.quietnessLevel, 0.7)
        let loud = Harness()
        loud.features.bands = bands { _ in 0.9 }
        loud.features.level = 0.9
        loud.run(seconds: 10)
        XCTAssertLessThan(loud.animator.quietnessLevel, 0.05)
    }

    func testSmokeDarkensUnderTheBandAndZeroTurnsItOff() throws {
        func bottomBand(_ image: [UInt8]) -> (alpha: Double, luminance: Double) {
            var alphaSum = 0.0, lumaSum = 0.0, count = 0.0
            for y in (Int(size.height) - 70)..<Int(size.height) {
                for x in stride(from: 300, to: 1200, by: 5) {
                    let index = (y * Int(size.width) + x) * 4
                    let a = Double(image[index + 3]) / 255
                    alphaSum += a
                    if a > 0.01 {
                        lumaSum += (Double(image[index]) + Double(image[index + 1]) + Double(image[index + 2])) / 765 / a
                        count += 1
                    }
                }
            }
            return (alphaSum, count > 0 ? lumaSum / count : 0)
        }
        let clear = bottomBand(try steadyScene(band: 0.5, level: 0.5, name: "15-smoke-0") { $0.smoke = 0 })
        let smoked = bottomBand(try steadyScene(band: 0.5, level: 0.5, name: "16-smoke-1") { $0.smoke = 1 })
        XCTAssertGreaterThan(smoked.alpha, clear.alpha * 1.15, "smoke adds shade")
        XCTAssertLessThan(smoked.luminance, clear.luminance, "and the shade is dark")
    }

    func testShockwaveClimbsTheSides() throws {
        let harness = Harness()
        harness.features.bands = bands { _ in 0.35 }
        harness.features.level = 0.5
        harness.run(seconds: 0.2)
        harness.features.kickSerial = 1
        harness.features.kickStrength = 1
        harness.run(seconds: 0.25)
        let image = try render(harness)
        try save(image, name: "05-shockwave")
    }

    func testWaveFlowDrawsOnlyTheComet() throws {
        let harness = Harness()
        harness.preferences.waveFlowEnabled = true
        harness.features.bands = bands { _ in 0.6 }
        harness.features.level = 0.6
        harness.run(seconds: 1.2)
        let image = try render(harness)
        try save(image, name: "06-waveflow")
        var lit = 0, total = 0
        for x in stride(from: 0, to: Int(size.width), by: 8) {
            total += 2
            if alpha(image, x, 2) > 0.2 { lit += 1 }
            if alpha(image, x, 946) > 0.2 { lit += 1 }
        }
        XCTAssertLessThan(Double(lit) / Double(total), 0.7)
    }

    func testIdleRendersNothing() throws {
        let harness = Harness()
        harness.renderState.update(track: .empty)
        harness.run(seconds: 3)
        XCTAssertFalse(harness.animator.isActive)
        let image = try render(harness)
        XCTAssertEqual(image.lazy.enumerated().filter { $0.offset % 4 == 3 && $0.element > 0 }.count, 0)
    }
}
