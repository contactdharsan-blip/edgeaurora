import Foundation
import XCTest
@testable import EdgeBeat

/// Synthetic, deterministic signals only — no live audio, no wall clock.
/// Every case drives `analyzeForTesting`, which runs the production hop
/// pipeline with timestamps taken from the sample position.
final class BeatAnalyzerTests: XCTestCase {
    private let sampleRate = 48_000.0

    // MARK: - Signal generators

    /// A tiny LCG, so every run sees the same "noise".
    private struct Noise {
        private var state: UInt64 = 0x2545F4914F6CDD1D

        mutating func next() -> Float {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let bits = Float(Int32(truncatingIfNeeded: Int64(state >> 32)))
            return bits / Float(Int32.max)
        }
    }

    private func whiteNoise(seconds: Double, amplitude: Float, sampleRate: Double) -> [Float] {
        var noise = Noise()
        return (0..<Int(seconds * sampleRate)).map { _ in noise.next() * amplitude }
    }

    /// Paul Kellet's pinking filter: about −3 dB per octave, which the
    /// analyser's +3 dB/octave tilt should flatten out.
    private func pinkNoise(seconds: Double, amplitude: Float, sampleRate: Double) -> [Float] {
        var noise = Noise()
        var b0: Float = 0, b1: Float = 0, b2: Float = 0
        var out = [Float]()
        out.reserveCapacity(Int(seconds * sampleRate))
        for _ in 0..<Int(seconds * sampleRate) {
            let white = noise.next()
            b0 = 0.99765 * b0 + white * 0.0990460
            b1 = 0.96300 * b1 + white * 0.2965164
            b2 = 0.57000 * b2 + white * 1.0526913
            out.append((b0 + b1 + b2 + white * 0.1848) * 0.2 * amplitude)
        }
        return out
    }

    private func sine(seconds: Double, frequency: Double, amplitude: Float,
                      sampleRate: Double) -> [Float] {
        (0..<Int(seconds * sampleRate)).map { index in
            amplitude * Float(sin(2 * .pi * frequency * Double(index) / sampleRate))
        }
    }

    /// A 55 Hz burst with an 80 ms decay on top of whatever is already there.
    private func addKicks(to signal: inout [Float], startingAt first: Double,
                          interval: Double, sampleRate: Double) -> [Double] {
        var starts: [Double] = []
        var start = first
        while Int(start * sampleRate) < signal.count {
            starts.append(start)
            let origin = Int(start * sampleRate)
            for offset in 0..<Int(0.25 * sampleRate) {
                let index = origin + offset
                guard index < signal.count else { break }
                let time = Double(offset) / sampleRate
                let envelope = exp(-time / 0.08)
                signal[index] += Float(0.9 * envelope * sin(2 * .pi * 55 * time))
            }
            start += interval
        }
        return starts
    }

    private func analyzer() throws -> BeatAnalyzer {
        try XCTUnwrap(BeatAnalyzer())
    }

    private func meanBand(_ features: [AudioFeatures], range: Range<Int>) -> Float {
        guard !features.isEmpty else { return 0 }
        var sum: Float = 0
        for feature in features {
            for band in range { sum += feature.bands[band] }
        }
        return sum / Float(features.count * range.count)
    }

    // MARK: - 1. Kick train

    func testKickTrainFiresOncePerKick() throws {
        var signal = whiteNoise(seconds: 10, amplitude: 0.01, sampleRate: sampleRate)
        let starts = addKicks(to: &signal, startingAt: 0.25, interval: 0.5, sampleRate: sampleRate)
        XCTAssertEqual(starts.count, 20)

        let features = try analyzer().analyzeForTesting(samples: signal, sampleRate: sampleRate)
        let fired = onsetTimes(features, serial: \.kickSerial)
        XCTAssertEqual(Double(features.last?.kickSerial ?? 0), 20, accuracy: 2,
                       "detected \(fired.count) kicks at \(fired.prefix(5))")

        for (time, strength) in fired {
            let nearest = starts.min { abs($0 - time) < abs($1 - time) } ?? -1
            XCTAssertLessThan(abs(time - nearest), 0.035,
                              "onset at \(time)s is too far from the burst at \(nearest)s")
            XCTAssertGreaterThanOrEqual(strength, 0.3)
            XCTAssertLessThanOrEqual(strength, 1)
        }
    }

    private func onsetTimes(_ features: [AudioFeatures],
                            serial: KeyPath<AudioFeatures, UInt64>)
        -> [(time: TimeInterval, strength: Float)] {
        var result: [(TimeInterval, Float)] = []
        var previous: UInt64 = 0
        for feature in features where feature[keyPath: serial] != previous {
            previous = feature[keyPath: serial]
            result.append((feature.timestamp, feature.kickStrength))
        }
        return result
    }

    // MARK: - 2. Frequency maps onto the band array

    func testBandsFollowToneFrequency() throws {
        let low = try analyzer().analyzeForTesting(
            samples: sine(seconds: 3, frequency: 60, amplitude: 0.7, sampleRate: sampleRate),
            sampleRate: sampleRate
        )
        let lowBottom = meanBand(low, range: 0..<6)
        let lowTop = meanBand(low, range: 24..<32)
        XCTAssertGreaterThan(lowBottom, 3 * lowTop, "60 Hz: bottom \(lowBottom) top \(lowTop)")

        let high = try analyzer().analyzeForTesting(
            samples: sine(seconds: 3, frequency: 8_000, amplitude: 0.7, sampleRate: sampleRate),
            sampleRate: sampleRate
        )
        let highBottom = meanBand(high, range: 0..<6)
        let highTop = meanBand(high, range: 24..<32)
        XCTAssertGreaterThan(highTop, 3 * highBottom, "8 kHz: bottom \(highBottom) top \(highTop)")
    }

    // MARK: - 3. A quiet passage reads quiet

    func testQuietPassageReadsQuieterThanTheLoudOne() throws {
        var signal = pinkNoise(seconds: 8, amplitude: 1, sampleRate: sampleRate)
        signal += pinkNoise(seconds: 3, amplitude: 0.1, sampleRate: sampleRate)

        let features = try analyzer().analyzeForTesting(samples: signal, sampleRate: sampleRate)
        let loud = features.filter { $0.timestamp >= 5 && $0.timestamp < 8 }
        let quiet = features.filter { $0.timestamp >= 9 }
        XCTAssertFalse(loud.isEmpty)
        XCTAssertFalse(quiet.isEmpty)

        let loudMean = meanBand(loud, range: 0..<AudioFeatures.bandCount)
        let quietMean = meanBand(quiet, range: 0..<AudioFeatures.bandCount)
        XCTAssertLessThanOrEqual(quietMean, 0.6 * loudMean,
                                 "quiet \(quietMean) vs loud \(loudMean)")
    }

    // MARK: - 4. A steady tone is not a rhythm

    func testSteadyToneFiresNoOnsets() throws {
        let features = try analyzer().analyzeForTesting(
            samples: sine(seconds: 5, frequency: 440, amplitude: 0.7, sampleRate: sampleRate),
            sampleRate: sampleRate
        )
        let settled = features.filter { $0.timestamp >= 0.5 }
        XCTAssertFalse(settled.isEmpty)
        let firstKick = settled.first?.kickSerial ?? 0
        let firstSnare = settled.first?.snareSerial ?? 0
        XCTAssertEqual(settled.last?.kickSerial, firstKick)
        XCTAssertEqual(settled.last?.snareSerial, firstSnare)
    }

    // MARK: - 5. A lift out of a quiet section is a drop

    func testLoudSectionAfterQuietSectionFiresADrop() throws {
        var signal = pinkNoise(seconds: 6, amplitude: 0.063, sampleRate: sampleRate)
        var loud = pinkNoise(seconds: 4, amplitude: 1, sampleRate: sampleRate)
        _ = addKicks(to: &loud, startingAt: 0.25, interval: 0.5, sampleRate: sampleRate)
        signal += loud

        let features = try analyzer().analyzeForTesting(samples: signal, sampleRate: sampleRate)
        let intensities = features.map(\.intensity)
        XCTAssertGreaterThanOrEqual(features.last?.dropSerial ?? 0, 1,
                                    "intensity range \(intensities.min() ?? 0)...\(intensities.max() ?? 0)")
    }

    // MARK: - 6. Silence

    func testDigitalSilenceReadsSilent() throws {
        let features = try analyzer().analyzeForTesting(
            samples: [Float](repeating: 0, count: Int(3 * sampleRate)),
            sampleRate: sampleRate
        )
        XCTAssertFalse(features.isEmpty)
        for feature in features {
            XCTAssertEqual(feature.bands.max() ?? 0, 0)
            XCTAssertEqual(feature.level, 0, accuracy: 1e-9)
            XCTAssertEqual(feature.bass, 0, accuracy: 1e-9)
            XCTAssertEqual(feature.treble, 0, accuracy: 1e-9)
        }
        XCTAssertEqual(features.last?.kickSerial, 0)
        XCTAssertEqual(features.last?.snareSerial, 0)
    }

    // MARK: - 7. Hop rate

    func testHopRateIsSixtyPerSecond() throws {
        for rate in [48_000.0, 44_100.0] {
            let features = try analyzer().analyzeForTesting(
                samples: whiteNoise(seconds: 10, amplitude: 0.2, sampleRate: rate),
                sampleRate: rate
            )
            XCTAssertEqual(Double(features.count), 600, accuracy: 12,
                           "\(features.count) hops at \(rate) Hz")
        }
    }

    // MARK: - 8. latestFeatures follows the session

    func testLatestFeaturesTracksTheActiveSession() throws {
        let analyzer = try self.analyzer()
        XCTAssertNil(analyzer.latestFeatures())

        analyzer.beginSession(7)
        let published = expectation(description: "features published")
        // Half a second of audio publishes up to 15 times; any one proves it.
        published.assertForOverFulfill = false
        analyzer.onFeatures = { _, _ in published.fulfill() }
        analyzer.consume(
            samples: whiteNoise(seconds: 0.5, amplitude: 0.3, sampleRate: sampleRate),
            sampleRate: sampleRate,
            session: 7
        )
        wait(for: [published], timeout: 2)
        XCTAssertNotNil(analyzer.latestFeatures())

        analyzer.endSession(7)
        XCTAssertNil(analyzer.latestFeatures())
    }

    // MARK: - 10. Sanity performance

    func testTenSecondsAnalysesQuickly() throws {
        let signal = whiteNoise(seconds: 10, amplitude: 0.3, sampleRate: sampleRate)
        let analyzer = try self.analyzer()
        let started = Date()
        _ = analyzer.analyzeForTesting(samples: signal, sampleRate: sampleRate)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }
}
