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
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
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
        let harness = Harness()
        harness.features.bands = bands { _ in 1 }
        harness.features.level = 1
        harness.features.kickSerial = 0
        harness.run(seconds: 0.1)
        harness.features.kickSerial = 1
        harness.features.kickStrength = 1
        harness.run(seconds: 1.0 / 30.0)
        let image = try render(harness)
        try save(image, name: "03-full-kick")

        XCTAssertEqual(alpha(image, 756, 475), 0)
        let depth = Int(GlowAnimator.stripDepth(thickness: 1))
        // Last row of the bottom strip and last column of the left strip: the
        // glow must have faded out before the strip ends, or it shows as a line.
        XCTAssertLessThan(alpha(image, 756, 949 - depth), 0.02)
        XCTAssertLessThan(alpha(image, depth - 1, 475), 0.02)
        XCTAssertGreaterThan(alpha(image, 756, 948), 0.5)
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
        let probe = (20, 475)
        XCTAssertGreaterThan(alpha(loudImage, probe.0, probe.1), 1.5 * alpha(quietImage, probe.0, probe.1))
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
