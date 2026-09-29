import Darwin
import Foundation

/// Samples real OS counters for CPU time, energy, memory footprint and the
/// renderer's frame/GPU-time counters, and turns two samples into
/// human-readable "right now" and "since launch" rates. Sampling only runs
/// while the menu is open; the pure `read`/`rates` core is unit-testable
/// without a timer or a menu.
final class PerformanceMonitor {
    struct Reading {
        var cpuSeconds: Double
        var energyJoules: Double
        var footprintBytes: UInt64
        var frames: UInt64
        var gpuSeconds: Double
        var uptime: TimeInterval
    }

    struct Rates {
        var cpuPercent: Double
        var watts: Double
        var fps: Double
        var gpuMsPerFrame: Double?
        var footprintMB: Double
    }

    private let launchReading: Reading?
    private var lastReading: Reading?
    private var timer: Timer?

    init() {
        launchReading = Self.read()
        lastReading = launchReading
    }

    /// Reads `proc_pid_rusage` for the current process plus the renderer's
    /// frame/GPU-time counters. Returns nil when the kernel call fails.
    static func read() -> Reading? {
        // rusage_info_t is typedef'd as `void *`, but the kernel writes the
        // rusage_info_v6 struct directly at the address passed in — callers
        // allocate the struct themselves and pass its address, rebound to
        // the (over-narrow) `rusage_info_t *` parameter type.
        var info = rusage_info_v6()
        let result = withUnsafeMutablePointer(to: &info) { pointer -> Int32 in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V6, $0)
            }
        }
        guard result == 0 else { return nil }

        var timebase = mach_timebase_info(numer: 0, denom: 0)
        mach_timebase_info(&timebase)
        let numer = Double(timebase.numer)
        let denom = Double(timebase.denom)
        func machTimeToSeconds(_ machTime: UInt64) -> Double {
            guard denom > 0 else { return 0 }
            let nanoseconds = Double(machTime) * numer / denom
            return nanoseconds / 1_000_000_000
        }

        let cpuSeconds = machTimeToSeconds(info.ri_user_time)
            + machTimeToSeconds(info.ri_system_time)
        let energyJoules = Double(info.ri_energy_nj) / 1_000_000_000
        let footprintBytes = info.ri_phys_footprint

        let snapshot = RenderStats.shared.snapshot()

        return Reading(
            cpuSeconds: cpuSeconds,
            energyJoules: energyJoules,
            footprintBytes: footprintBytes,
            frames: snapshot.frames,
            gpuSeconds: snapshot.gpuSeconds,
            uptime: ProcessInfo.processInfo.systemUptime
        )
    }

    /// Turns two readings into rates. Guards against a non-positive interval
    /// and non-finite inputs so the result is always safe to format.
    static func rates(from start: Reading, to end: Reading) -> Rates {
        let deltaTime = end.uptime - start.uptime
        guard deltaTime > 0, deltaTime.isFinite else {
            return Rates(cpuPercent: 0, watts: 0, fps: 0, gpuMsPerFrame: nil, footprintMB: 0)
        }

        let deltaCPU = max(0, end.cpuSeconds - start.cpuSeconds)
        let deltaEnergy = max(0, end.energyJoules - start.energyJoules)
        let deltaFrames = end.frames >= start.frames ? end.frames - start.frames : 0
        let deltaGPU = max(0, end.gpuSeconds - start.gpuSeconds)

        let cpuPercent = deltaCPU.isFinite ? (deltaCPU / deltaTime) * 100 : 0
        let watts = deltaEnergy.isFinite ? deltaEnergy / deltaTime : 0
        let fps = Double(deltaFrames) / deltaTime

        var gpuMsPerFrame: Double? = nil
        if deltaFrames > 0 {
            let ms = (deltaGPU / Double(deltaFrames)) * 1_000
            if ms.isFinite { gpuMsPerFrame = ms }
        }

        let footprintMB = Double(end.footprintBytes) / (1_024 * 1_024)

        return Rates(
            cpuPercent: cpuPercent.isFinite ? cpuPercent : 0,
            watts: watts.isFinite ? watts : 0,
            fps: fps.isFinite ? fps : 0,
            gpuMsPerFrame: gpuMsPerFrame,
            footprintMB: footprintMB.isFinite ? footprintMB : 0
        )
    }

    /// Formats the "right now" line, e.g. "2.1% CPU · 0.14 W · 60 fps · 0.4 ms GPU".
    /// Below 0.5 fps the fps field reads "idle".
    static func formatCurrent(_ rates: Rates) -> String {
        let fpsText = rates.fps < 0.5 ? "idle" : String(format: "%.0f fps", rates.fps)
        var parts = [
            String(format: "%.1f%% CPU", rates.cpuPercent),
            String(format: "%.2f W", rates.watts),
            fpsText
        ]
        if let gpuMsPerFrame = rates.gpuMsPerFrame {
            parts.append(String(format: "%.1f ms GPU", gpuMsPerFrame))
        }
        return parts.joined(separator: " · ")
    }

    /// Formats the "since launch" line, e.g. "Since launch: 1.8% CPU · 0.12 W avg · 58 MB".
    static func formatSinceLaunch(_ rates: Rates) -> String {
        "Since launch: " + String(format: "%.1f%% CPU · %.2f W avg · %.0f MB",
                                   rates.cpuPercent, rates.watts, rates.footprintMB)
    }

    /// Starts a 1 s repeating timer, in `.common` run-loop mode so it keeps
    /// firing while the menu is tracking, and reports formatted (current,
    /// sinceLaunch) lines on each tick. Before the first delta is available,
    /// `onUpdate` is called once with ("Measuring…", sinceLaunchLine).
    func start(onUpdate: @escaping (String, String) -> Void) {
        stop()

        let sinceLaunchLine: String
        if let launchReading, let current = Self.read() {
            sinceLaunchLine = Self.formatSinceLaunch(Self.rates(from: launchReading, to: current))
            // Reset the baseline to now, so the first 1s tick computes a
            // delta over the last second rather than since the menu last
            // opened (or since launch).
            lastReading = current
        } else {
            sinceLaunchLine = "Since launch: —"
        }
        onUpdate("Measuring…", sinceLaunchLine)

        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.tick(onUpdate: onUpdate)
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick(onUpdate: @escaping (String, String) -> Void) {
        guard let current = Self.read() else { return }
        defer { lastReading = current }

        guard let previous = lastReading else { return }
        let currentLine = Self.formatCurrent(Self.rates(from: previous, to: current))

        let sinceLaunchLine: String
        if let launchReading {
            sinceLaunchLine = Self.formatSinceLaunch(Self.rates(from: launchReading, to: current))
        } else {
            sinceLaunchLine = "Since launch: —"
        }

        onUpdate(currentLine, sinceLaunchLine)
    }

    /// Stops sampling. Costs nothing while the menu is closed.
    func stop() {
        timer?.invalidate()
        timer = nil
    }
}
