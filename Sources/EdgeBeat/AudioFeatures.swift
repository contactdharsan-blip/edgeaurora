import Foundation

/// One analysis hop's reading of the music.
///
/// BeatAnalyzer produces these on its analysis queue. The glow renderer pulls
/// the newest one on every frame through `BeatAnalyzer.latestFeatures()`, so
/// the hot path never waits on the main thread; the companion window still
/// receives a copy through `onFeatures`.
struct AudioFeatures {
    static let bandCount = 32

    var level: Double
    var bass: Double
    var mid: Double
    var treble: Double
    var beat: Bool
    var waveform: [Double]

    /// Log-spaced bands from 40 Hz to 16 kHz, index 0 lowest, each 0...1.
    /// Scaled against the song's own recent loudness, so a quiet verse stays dim
    /// instead of being stretched to full height.
    var bands: [Float] = Array(repeating: 0, count: AudioFeatures.bandCount)
    /// Short-term loudness against the last several seconds: about 0.5 in a
    /// typical passage, towards 1 in a chorus or drop, towards 0 in a breakdown.
    var intensity: Float = 0
    /// Onset serials increase by one per detected event. A reader compares them
    /// with the last value it saw, so a frame can neither miss nor double count
    /// an onset that landed between two frames.
    var kickSerial: UInt64 = 0
    var kickStrength: Float = 0
    var snareSerial: UInt64 = 0
    var snareStrength: Float = 0
    var dropSerial: UInt64 = 0
    /// `ProcessInfo.systemUptime` when this hop was analysed.
    var timestamp: TimeInterval = 0
}
