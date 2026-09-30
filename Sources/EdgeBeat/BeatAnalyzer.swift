import Accelerate
import Foundation

/// Reads the music one overlapping window at a time.
///
/// Every incoming sample lands in a 2048-sample ring buffer and an analysis runs
/// once per hop — 60 hops a second, 30 in Low Power Mode — so nothing between
/// frames is thrown away. Loudness is scaled against one global reference that
/// falls slowly, which is what makes a quiet passage look quiet instead of being
/// stretched to full height by a per-frame peak.
///
/// Timing is counted in samples, never in wall clock: refractory periods, the
/// flux history and the drop window all advance with the audio, so the test hook
/// and the live path run the identical pipeline and only the reported
/// `timestamp` differs.
final class BeatAnalyzer {
    var onFeatures: ((AudioFeatures, UInt64) -> Void)?

    // MARK: - Tuning

    private static let fftSize = 2048
    private static let bandCount = AudioFeatures.bandCount
    private static let lowestBandHz = 40.0
    private static let highestBandHz = 16_000.0
    /// Band values span this many dB below the running reference.
    private static let dynamicRangeDb: Float = 42
    /// The reference never falls below this, so silence reads as silence.
    private static let referenceFloorDb: Float = -18
    private static let referenceReleaseDbPerSecond: Float = 2
    private static let silenceDb: Float = -120
    private static let kickRefractorySeconds = 0.110
    private static let snareRefractorySeconds = 0.090
    private static let onsetFluxMinimumDb: Float = 6
    private static let onsetBandFloor: Float = 0.05
    private static let dropRiseThreshold: Float = 0.75
    private static let dropQuietThreshold: Float = 0.35
    private static let dropLookbackSeconds = 4.0
    private static let dropSpacingSeconds = 6.0
    private static let publishHz = 30.0

    /// How a band reads its power out of the spectrum. Low bands are narrower
    /// than one bin (about 23.4 Hz at 48 kHz), so they interpolate between
    /// neighbours rather than sitting structurally empty.
    private enum BandTap {
        case mean(first: Int, last: Int)
        case interpolate(bin: Int, fraction: Float)
        case silent
    }

    // MARK: - Session state

    private let analysisQueue = DispatchQueue(label: "com.chaitanya.edgebeat.analysis", qos: .userInitiated)
    private let sessionLock = NSLock()
    private var activeSessionGeneration: UInt64 = 0
    private var latest: AudioFeatures?
    private var latestGeneration: UInt64 = 0

    // MARK: - Fixed buffers

    private let log2Size: vDSP_Length
    private let fftSetup: FFTSetup
    private let window: UnsafeMutablePointer<Float>
    private let windowPowerSum: Float
    private let ring: UnsafeMutablePointer<Float>
    private let frame: UnsafeMutablePointer<Float>
    private let windowed: UnsafeMutablePointer<Float>
    private let realPart: UnsafeMutablePointer<Float>
    private let imaginaryPart: UnsafeMutablePointer<Float>
    private let binPower: UnsafeMutablePointer<Float>
    private let bandDb: UnsafeMutablePointer<Float>
    private let previousBandDb: UnsafeMutablePointer<Float>
    private let bandValue: UnsafeMutablePointer<Float>
    private let tiltDb: UnsafeMutablePointer<Float>

    // MARK: - Derived from the sample rate

    private var taps = [BandTap](repeating: .silent, count: AudioFeatures.bandCount)
    private var configuredSampleRate = 0.0
    private var lowPowerMode = false
    private var hopSize = 800
    private var hopSeconds = 1.0 / 60.0
    private var shortLoudnessCoefficient: Float = 0
    private var longLoudnessCoefficient: Float = 0
    private var kickRefractoryHops = 0
    private var snareRefractoryHops = 0
    private var dropSpacingHops = 0
    private var publishIntervalSamples = 0
    private var fluxHistoryCapacity = 60
    private var intensityHistoryCapacity = 240

    // MARK: - Running analysis state

    private var ringWrite = 0
    private var samplesSinceHop = 0
    private var samplePosition = 0
    private var hopIndex = 0
    private var timeOrigin: TimeInterval?
    private var referenceDb: Float = BeatAnalyzer.referenceFloorDb
    private var hasPreviousBands = false
    private var smoothedLevel = 0.0
    private var previousWaveform = [Double](repeating: 0, count: 128)
    private var shortLoudnessDb: Float = 0
    private var longLoudnessDb: Float = 0
    private var kickFluxHistory: [Float] = []
    private var snareFluxHistory: [Float] = []
    private var intensityHistory: [Float] = []
    private var lastKickHop = Int.min / 2
    private var lastSnareHop = Int.min / 2
    private var lastDropHop = Int.min / 2
    private var kickSerial: UInt64 = 0
    private var kickStrength: Float = 0
    private var snareSerial: UInt64 = 0
    private var snareStrength: Float = 0
    private var dropSerial: UInt64 = 0
    private var pendingBeat = false
    private var lastPublishPosition = Int.min / 2

    // MARK: - Lifecycle

    init?() {
        let size = Self.fftSize
        log2Size = vDSP_Length(log2(Float(size)))
        guard let setup = vDSP_create_fftsetup(log2Size, FFTRadix(kFFTRadix2)) else { return nil }
        fftSetup = setup

        window = .allocate(capacity: size)
        vDSP_hann_window(window, vDSP_Length(size), Int32(vDSP_HANN_NORM))
        var powerSum: Float = 0
        vDSP_svesq(window, 1, &powerSum, vDSP_Length(size))
        windowPowerSum = max(powerSum, .leastNormalMagnitude)

        ring = .allocate(capacity: size)
        ring.initialize(repeating: 0, count: size)
        frame = .allocate(capacity: size)
        frame.initialize(repeating: 0, count: size)
        windowed = .allocate(capacity: size)
        windowed.initialize(repeating: 0, count: size)
        realPart = .allocate(capacity: size / 2)
        realPart.initialize(repeating: 0, count: size / 2)
        imaginaryPart = .allocate(capacity: size / 2)
        imaginaryPart.initialize(repeating: 0, count: size / 2)
        binPower = .allocate(capacity: size / 2)
        binPower.initialize(repeating: 0, count: size / 2)

        let bands = Self.bandCount
        bandDb = .allocate(capacity: bands)
        bandDb.initialize(repeating: Self.silenceDb, count: bands)
        previousBandDb = .allocate(capacity: bands)
        previousBandDb.initialize(repeating: Self.silenceDb, count: bands)
        bandValue = .allocate(capacity: bands)
        bandValue.initialize(repeating: 0, count: bands)
        tiltDb = .allocate(capacity: bands)
        for band in 0..<bands {
            let center = Self.bandCenterHz(band)
            tiltDb[band] = 3 * Float(log2(center / 1_000))
        }
        kickFluxHistory.reserveCapacity(256)
        snareFluxHistory.reserveCapacity(256)
        intensityHistory.reserveCapacity(1_024)
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
        window.deallocate()
        ring.deallocate()
        frame.deallocate()
        windowed.deallocate()
        realPart.deallocate()
        imaginaryPart.deallocate()
        binPower.deallocate()
        bandDb.deallocate()
        previousBandDb.deallocate()
        bandValue.deallocate()
        tiltDb.deallocate()
    }

    // MARK: - Public surface

    static func isValidSampleRate(_ sampleRate: Double) -> Bool {
        sampleRate.isFinite && sampleRate > 0
    }

    func beginSession(_ generation: UInt64) {
        sessionLock.lock()
        activeSessionGeneration = generation
        latest = nil
        sessionLock.unlock()
        analysisQueue.async { [weak self] in
            guard let self, self.isActive(generation) else { return }
            self.resetAnalysisState()
        }
    }

    func endSession(_ generation: UInt64) {
        sessionLock.lock()
        guard activeSessionGeneration == generation else {
            sessionLock.unlock()
            return
        }
        activeSessionGeneration &+= 1
        latest = nil
        sessionLock.unlock()
        analysisQueue.sync { [weak self] in
            self?.resetAnalysisState()
        }
    }

    func consume(samples: [Float], sampleRate: Double, session: UInt64) {
        guard Self.isValidSampleRate(sampleRate) else { return }
        analysisQueue.async { [weak self] in
            self?.consumeOnAnalysisQueue(samples: samples, sampleRate: sampleRate, session: session)
        }
    }

    func setLowPowerMode(_ enabled: Bool) {
        analysisQueue.async { [weak self] in
            guard let self, self.lowPowerMode != enabled else { return }
            self.lowPowerMode = enabled
            self.configuredSampleRate = 0
        }
    }

    /// The newest hop's reading, for a renderer that pulls once per frame.
    /// Safe from any thread; nil until the active session has produced a hop.
    func latestFeatures() -> AudioFeatures? {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        guard let latest, latestGeneration == activeSessionGeneration else { return nil }
        return latest
    }

    /// Runs the production pipeline synchronously on the calling thread and
    /// returns every hop, with timestamps taken from the sample position so a
    /// test never depends on the wall clock. Resets the analysis state first.
    func analyzeForTesting(samples: [Float], sampleRate: Double) -> [AudioFeatures] {
        guard Self.isValidSampleRate(sampleRate) else { return [] }
        resetAnalysisState()
        var collected: [AudioFeatures]? = []
        samples.withUnsafeBufferPointer { buffer in
            if let base = buffer.baseAddress {
                process(input: base, count: buffer.count, sampleRate: sampleRate,
                        session: nil, collected: &collected)
            }
        }
        return collected ?? []
    }

    // MARK: - Ingest

    private func consumeOnAnalysisQueue(samples: [Float], sampleRate: Double, session: UInt64) {
        guard isActive(session), Self.isValidSampleRate(sampleRate) else { return }
        var collected: [AudioFeatures]?
        samples.withUnsafeBufferPointer { buffer in
            if let base = buffer.baseAddress {
                process(input: base, count: buffer.count, sampleRate: sampleRate,
                        session: session, collected: &collected)
            }
        }
    }

    /// The one path both `consume` and `analyzeForTesting` run. `session` is nil
    /// in the test hook, which skips session gating and publishing.
    private func process(input: UnsafePointer<Float>, count: Int, sampleRate: Double,
                         session: UInt64?, collected: inout [AudioFeatures]?) {
        configureIfNeeded(sampleRate: sampleRate)
        if session != nil, timeOrigin == nil {
            timeOrigin = ProcessInfo.processInfo.systemUptime - Double(samplePosition) / sampleRate
        }
        let size = Self.fftSize
        var offset = 0
        while offset < count {
            let chunk = min(hopSize - samplesSinceHop, size - ringWrite, count - offset)
            (ring + ringWrite).update(from: input + offset, count: chunk)
            ringWrite = (ringWrite + chunk) % size
            samplesSinceHop += chunk
            samplePosition += chunk
            offset += chunk
            if samplesSinceHop >= hopSize {
                samplesSinceHop = 0
                let features = runHop(sampleRate: sampleRate)
                collected?.append(features)
                if let session {
                    store(features, session: session)
                    publish(features, session: session)
                }
            }
        }
    }

    private func store(_ features: AudioFeatures, session: UInt64) {
        sessionLock.lock()
        if activeSessionGeneration == session {
            latest = features
            latestGeneration = session
        }
        sessionLock.unlock()
    }

    /// At most 30 deliveries a second to the companion window, and a kick that
    /// lands on a hop nobody asked for is carried into the next delivery rather
    /// than dropped.
    private func publish(_ features: AudioFeatures, session: UInt64) {
        pendingBeat = pendingBeat || features.beat
        guard samplePosition - lastPublishPosition >= publishIntervalSamples else { return }
        lastPublishPosition = samplePosition
        var outgoing = features
        outgoing.beat = pendingBeat
        pendingBeat = false
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isActive(session) else { return }
            self.onFeatures?(outgoing, session)
        }
    }

    private func isActive(_ generation: UInt64) -> Bool {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        return activeSessionGeneration == generation
    }

    // MARK: - Configuration

    private func configureIfNeeded(sampleRate: Double) {
        guard sampleRate != configuredSampleRate else { return }
        configuredSampleRate = sampleRate
        let hopRate = lowPowerMode ? 30.0 : 60.0
        hopSize = max(1, Int((sampleRate / hopRate).rounded()))
        hopSeconds = Double(hopSize) / sampleRate
        shortLoudnessCoefficient = Float(exp(-hopSeconds / 0.3))
        longLoudnessCoefficient = Float(exp(-hopSeconds / 6.0))
        // The smallest whole number of hops that is at least the refractory,
        // so the gap between two onsets is never shorter than specified.
        kickRefractoryHops = Int((Self.kickRefractorySeconds / hopSeconds).rounded(.up))
        snareRefractoryHops = Int((Self.snareRefractorySeconds / hopSeconds).rounded(.up))
        dropSpacingHops = Int((Self.dropSpacingSeconds / hopSeconds).rounded(.up))
        publishIntervalSamples = max(1, Int((sampleRate / Self.publishHz).rounded()) - 1)
        fluxHistoryCapacity = max(8, Int((1.0 / hopSeconds).rounded()))
        intensityHistoryCapacity = max(8, Int((Self.dropLookbackSeconds / hopSeconds).rounded()))
        rebuildBandTaps(sampleRate: sampleRate)
        if samplesSinceHop >= hopSize { samplesSinceHop = 0 }
    }

    private static func bandEdgeHz(_ index: Int) -> Double {
        let ratio = highestBandHz / lowestBandHz
        return lowestBandHz * pow(ratio, Double(index) / Double(bandCount))
    }

    private static func bandCenterHz(_ band: Int) -> Double {
        sqrt(bandEdgeHz(band) * bandEdgeHz(band + 1))
    }

    private func rebuildBandTaps(sampleRate: Double) {
        let binWidth = sampleRate / Double(Self.fftSize)
        let lastUsableBin = Self.fftSize / 2 - 1
        for band in 0..<Self.bandCount {
            let low = Self.bandEdgeHz(band)
            let high = Self.bandEdgeHz(band + 1)
            let first = max(1, Int((low / binWidth).rounded(.up)))
            let last = min(lastUsableBin, Int((high / binWidth).rounded(.down)))
            if first <= last {
                taps[band] = .mean(first: first, last: last)
                continue
            }
            let center = sqrt(low * high) / binWidth
            let bin = Int(center.rounded(.down))
            guard bin >= 1, bin + 1 <= lastUsableBin else {
                taps[band] = bin < 1 ? .mean(first: 1, last: 1) : .silent
                continue
            }
            taps[band] = .interpolate(bin: bin, fraction: Float(center - Double(bin)))
        }
    }

    private func resetAnalysisState() {
        ring.update(repeating: 0, count: Self.fftSize)
        for band in 0..<Self.bandCount {
            bandDb[band] = Self.silenceDb
            previousBandDb[band] = Self.silenceDb
            bandValue[band] = 0
        }
        ringWrite = 0
        samplesSinceHop = 0
        samplePosition = 0
        hopIndex = 0
        timeOrigin = nil
        referenceDb = Self.referenceFloorDb
        hasPreviousBands = false
        smoothedLevel = 0
        previousWaveform = [Double](repeating: 0, count: previousWaveform.count)
        // Assume full scale until the song says otherwise: a quiet opening then
        // reads quiet, and the first genuinely loud passage reads as a lift.
        shortLoudnessDb = 0
        longLoudnessDb = 0
        kickFluxHistory.removeAll(keepingCapacity: true)
        snareFluxHistory.removeAll(keepingCapacity: true)
        intensityHistory.removeAll(keepingCapacity: true)
        lastKickHop = Int.min / 2
        lastSnareHop = Int.min / 2
        lastDropHop = Int.min / 2
        kickSerial = 0
        kickStrength = 0
        snareSerial = 0
        snareStrength = 0
        dropSerial = 0
        pendingBeat = false
        lastPublishPosition = Int.min / 2
    }

    // MARK: - One hop

    private func runHop(sampleRate: Double) -> AudioFeatures {
        let size = Self.fftSize
        let head = size - ringWrite
        (frame).update(from: ring + ringWrite, count: head)
        if ringWrite > 0 { (frame + head).update(from: ring, count: ringWrite) }

        let waveform = makeWaveform()
        vDSP_vmul(frame, 1, window, 1, windowed, 1, vDSP_Length(size))
        computeSpectrum()
        computeBandDb()
        updateReference()
        computeBandValues()

        var rms: Float = 0
        vDSP_rmsqv(frame, 1, &rms, vDSP_Length(size))
        let loudnessDb = max(Self.silenceDb, 20 * log10(rms + 1e-12))
        shortLoudnessDb = loudnessDb + (shortLoudnessDb - loudnessDb) * shortLoudnessCoefficient
        longLoudnessDb = loudnessDb + (longLoudnessDb - loudnessDb) * longLoudnessCoefficient
        let intensity = clamp01(0.5 + (shortLoudnessDb - longLoudnessDb) / 12)

        let kick = detectOnset(
            bands: Self.kickBands, history: &kickFluxHistory,
            lastHop: &lastKickHop, refractoryHops: kickRefractoryHops
        )
        if kick.fired {
            kickSerial &+= 1
            kickStrength = kick.strength
        }
        let snare = detectOnset(
            bands: Self.snareBands, history: &snareFluxHistory,
            lastHop: &lastSnareHop, refractoryHops: snareRefractoryHops
        )
        if snare.fired {
            snareSerial &+= 1
            snareStrength = snare.strength
        }
        updateDrop(intensity: intensity)

        for band in 0..<Self.bandCount { previousBandDb[band] = bandDb[band] }
        hasPreviousBands = true

        let bass = mean(of: bandValue, in: Self.bassBands)
        let mid = mean(of: bandValue, in: Self.midBands)
        let treble = mean(of: bandValue, in: Self.trebleBands)
        let overall = Double(mean(of: bandValue, in: 0..<Self.bandCount))
        let coefficient = overall > smoothedLevel ? 0.5 : 0.15
        smoothedLevel += (overall - smoothedLevel) * coefficient

        var bands = [Float](repeating: 0, count: Self.bandCount)
        for band in 0..<Self.bandCount { bands[band] = bandValue[band] }

        hopIndex += 1
        return AudioFeatures(
            level: smoothedLevel,
            bass: Double(bass),
            mid: Double(mid),
            treble: Double(treble),
            beat: kick.fired,
            waveform: waveform,
            bands: bands,
            intensity: intensity,
            kickSerial: kickSerial,
            kickStrength: kickStrength,
            snareSerial: snareSerial,
            snareStrength: snareStrength,
            dropSerial: dropSerial,
            timestamp: (timeOrigin ?? 0) + Double(samplePosition) / sampleRate
        )
    }

    private func computeSpectrum() {
        let size = Self.fftSize
        windowed.withMemoryRebound(to: DSPComplex.self, capacity: size / 2) { complexInput in
            var split = DSPSplitComplex(realp: realPart, imagp: imaginaryPart)
            vDSP_ctoz(complexInput, 2, &split, 1, vDSP_Length(size / 2))
            vDSP_fft_zrip(fftSetup, &split, 1, log2Size, FFTDirection(FFT_FORWARD))
            vDSP_zvmags(&split, 1, binPower, 1, vDSP_Length(size / 2))
        }
    }

    /// Band power in dB, referred to a full-scale white signal, then tilted
    /// +3 dB per octave about 1 kHz so pink-ish music reads level across bands.
    private func computeBandDb() {
        // vDSP_fft_zrip returns twice the standard transform, hence the 4.
        let scale = 1 / (4 * windowPowerSum)
        for band in 0..<Self.bandCount {
            var power: Float
            switch taps[band] {
            case let .mean(first, last):
                var sum: Float = 0
                vDSP_sve(binPower + first, 1, &sum, vDSP_Length(last - first + 1))
                power = sum / Float(last - first + 1)
            case let .interpolate(bin, fraction):
                power = binPower[bin] * (1 - fraction) + binPower[bin + 1] * fraction
            case .silent:
                power = 0
            }
            power *= scale
            let db = max(Self.silenceDb, 10 * log10(power + 1e-12))
            bandDb[band] = db + tiltDb[band]
        }
    }

    /// One global reference for every band: instant attack, slow release, and a
    /// hard floor. Nothing is normalised to this frame's own peak, so a quiet
    /// passage stays dim instead of being stretched back to full height.
    private func updateReference() {
        var peak = Self.silenceDb
        for band in 0..<Self.bandCount { peak = max(peak, bandDb[band]) }
        let released = referenceDb - Self.referenceReleaseDbPerSecond * Float(hopSeconds)
        referenceDb = max(peak, max(released, Self.referenceFloorDb))
    }

    private func computeBandValues() {
        let range = Self.dynamicRangeDb
        let base = referenceDb - range
        for band in 0..<Self.bandCount {
            bandValue[band] = clamp01((bandDb[band] - base) / range)
        }
    }

    // MARK: - Onsets

    private static let kickBands = bandRange(from: 40, to: 150)
    private static let snareBands = bandRange(from: 1_500, to: 8_000)
    private static let bassBands = bandRange(from: 40, to: 180)
    private static let midBands = bandRange(from: 180, to: 2_000)
    private static let trebleBands = bandRange(from: 2_000, to: 10_000)

    private static func bandRange(from lowHz: Double, to highHz: Double) -> Range<Int> {
        var first = bandCount
        var last = -1
        for band in 0..<bandCount {
            let center = bandCenterHz(band)
            guard center >= lowHz, center <= highHz else { continue }
            first = min(first, band)
            last = max(last, band)
        }
        guard last >= first else { return 0..<1 }
        return first..<(last + 1)
    }

    private func detectOnset(bands: Range<Int>, history: inout [Float],
                             lastHop: inout Int, refractoryHops: Int)
        -> (fired: Bool, strength: Float) {
        var flux: Float = 0
        if hasPreviousBands {
            for band in bands { flux += max(0, bandDb[band] - previousBandDb[band]) }
        }

        var fluxMean: Float = 0
        var fluxDeviation: Float = 0
        if !history.isEmpty {
            for value in history { fluxMean += value }
            fluxMean /= Float(history.count)
            for value in history { fluxDeviation += (value - fluxMean) * (value - fluxMean) }
            fluxDeviation = (fluxDeviation / Float(history.count)).squareRoot()
        }
        let threshold = max(fluxMean + 1.5 * fluxDeviation, Self.onsetFluxMinimumDb)

        // Until a full window of real audio has arrived the ring is still part
        // zeros, so the rise from one hop to the next is the buffer filling up
        // rather than a drum. Those hops are kept out of the statistics too,
        // and detection waits for enough of them to make a threshold mean
        // anything at all.
        let warmedUp = hasPreviousBands && samplePosition >= Self.fftSize
        if warmedUp {
            history.append(flux)
            if history.count > fluxHistoryCapacity { history.removeFirst() }
        }

        guard warmedUp,
              history.count >= max(8, fluxHistoryCapacity / 3),
              hopIndex - lastHop >= refractoryHops,
              mean(of: bandValue, in: bands) > Self.onsetBandFloor,
              flux > threshold else { return (false, 0) }
        lastHop = hopIndex
        let excess = (flux / threshold) - 1
        return (true, 0.3 + 0.7 * clamp01(excess / 2))
    }

    private func updateDrop(intensity: Float) {
        let wasQuiet = intensityHistory.contains { $0 < Self.dropQuietThreshold }
        if intensity > Self.dropRiseThreshold,
           wasQuiet,
           hopIndex - lastDropHop >= dropSpacingHops {
            dropSerial &+= 1
            lastDropHop = hopIndex
            intensityHistory.removeAll(keepingCapacity: true)
        }
        intensityHistory.append(intensity)
        if intensityHistory.count > intensityHistoryCapacity { intensityHistory.removeFirst() }
    }

    // MARK: - Helpers

    private func mean(of values: UnsafeMutablePointer<Float>, in range: Range<Int>) -> Float {
        guard !range.isEmpty else { return 0 }
        var sum: Float = 0
        for index in range { sum += values[index] }
        return sum / Float(range.count)
    }

    private func clamp01(_ value: Float) -> Float {
        min(1, max(0, value))
    }

    private func makeWaveform() -> [Double] {
        let pointCount = previousWaveform.count
        let size = Self.fftSize
        let binSize = max(1, size / pointCount)
        var waveform = [Double](repeating: 0, count: pointCount)

        for point in 0..<pointCount {
            let start = point * binSize
            let end = min(size, start + binSize)
            guard start < end else { continue }
            var energy = 0.0
            for index in start..<end {
                let sample = Double(frame[index])
                energy += sample * sample
            }
            waveform[point] = (energy / Double(end - start)).squareRoot()
        }

        let peak = waveform.max() ?? 0
        if peak > 0.0001 {
            for index in waveform.indices { waveform[index] /= peak }
        }

        if waveform.count > 2 {
            // Smoothed in place, carrying the value each step overwrote, so the
            // hop allocates nothing but the array it returns.
            var previous = waveform[0]
            for index in 1..<(waveform.count - 1) {
                let current = waveform[index]
                waveform[index] = (previous + current * 2 + waveform[index + 1]) / 4
                previous = current
            }
        }

        for index in waveform.indices {
            waveform[index] = previousWaveform[index] * 0.58 + waveform[index] * 0.42
        }
        previousWaveform = waveform
        return waveform
    }
}
