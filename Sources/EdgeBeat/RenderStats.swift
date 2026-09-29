import Foundation

/// Frame counters the glow renderer writes and the performance monitor reads.
final class RenderStats {
    static let shared = RenderStats()

    struct Snapshot {
        var frames: UInt64
        var gpuSeconds: Double
    }

    private let lock = NSLock()
    private var frames: UInt64 = 0
    private var gpuSeconds = 0.0

    /// Called once per presented frame per display. `gpuTime` is the command
    /// buffer's GPU execution time in seconds, or 0 when unknown.
    func recordFrame(gpuTime: Double) {
        lock.lock()
        frames &+= 1
        if gpuTime.isFinite, gpuTime > 0 { gpuSeconds += gpuTime }
        lock.unlock()
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(frames: frames, gpuSeconds: gpuSeconds)
    }
}
