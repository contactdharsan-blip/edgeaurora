import Foundation
import XCTest
@testable import EdgeBeat

final class PerformanceMonitorTests: XCTestCase {
    func testCPUDeltaReflectsBurnedTime() throws {
        let start = try XCTUnwrap(PerformanceMonitor.read())

        // Burn 0.3 s of this thread's CPU time, measured by the thread's own
        // clock rather than the wall clock: on a busy machine the thread can
        // be descheduled for most of a wall-clock window. This proves the
        // mach-time -> seconds conversion: were it off by the numer/denom
        // ratio (~41.67x on Apple silicon) the delta would land far outside
        // the asserted range.
        let burnStart = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        var sink: Double = 0
        while clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - burnStart < 300_000_000 {
            sink += sink.squareRoot() + 1
        }
        XCTAssertTrue(sink.isFinite)

        let end = try XCTUnwrap(PerformanceMonitor.read())
        let deltaCPU = end.cpuSeconds - start.cpuSeconds

        // Process time includes other test threads, so it can exceed 0.3 s.
        XCTAssertGreaterThan(deltaCPU, 0.28)
        XCTAssertLessThan(deltaCPU, 1.5)
    }

    func testEnergyIsMonotonicNonDecreasing() throws {
        let first = try XCTUnwrap(PerformanceMonitor.read())
        Thread.sleep(forTimeInterval: 0.05)
        let second = try XCTUnwrap(PerformanceMonitor.read())

        XCTAssertGreaterThanOrEqual(second.energyJoules, first.energyJoules)
    }

    func testRatesAreFiniteAndNonNegative() throws {
        let start = try XCTUnwrap(PerformanceMonitor.read())
        Thread.sleep(forTimeInterval: 0.05)
        let end = try XCTUnwrap(PerformanceMonitor.read())

        let rates = PerformanceMonitor.rates(from: start, to: end)

        XCTAssertTrue(rates.cpuPercent.isFinite)
        XCTAssertTrue(rates.watts.isFinite)
        XCTAssertTrue(rates.fps.isFinite)
        XCTAssertTrue(rates.footprintMB.isFinite)
        XCTAssertGreaterThanOrEqual(rates.cpuPercent, 0)
        XCTAssertGreaterThanOrEqual(rates.watts, 0)
        XCTAssertGreaterThanOrEqual(rates.fps, 0)
        XCTAssertGreaterThanOrEqual(rates.footprintMB, 0)
        if let gpuMsPerFrame = rates.gpuMsPerFrame {
            XCTAssertTrue(gpuMsPerFrame.isFinite)
            XCTAssertGreaterThanOrEqual(gpuMsPerFrame, 0)
        }
    }

    func testZeroIntervalReturnsZeroedRatesNotNaN() {
        let reading = PerformanceMonitor.Reading(
            cpuSeconds: 1,
            energyJoules: 1,
            footprintBytes: 1024,
            frames: 10,
            gpuSeconds: 1,
            uptime: 100
        )

        let rates = PerformanceMonitor.rates(from: reading, to: reading)

        XCTAssertEqual(rates.cpuPercent, 0)
        XCTAssertEqual(rates.watts, 0)
        XCTAssertEqual(rates.fps, 0)
        XCTAssertNil(rates.gpuMsPerFrame)
        XCTAssertEqual(rates.footprintMB, 0)
    }

    func testNoFramesInIntervalYieldsNilGPUMsPerFrame() {
        let start = PerformanceMonitor.Reading(
            cpuSeconds: 0, energyJoules: 0, footprintBytes: 0,
            frames: 5, gpuSeconds: 0, uptime: 0
        )
        let end = PerformanceMonitor.Reading(
            cpuSeconds: 0.02, energyJoules: 0.01, footprintBytes: 60_000_000,
            frames: 5, gpuSeconds: 0, uptime: 1
        )

        let rates = PerformanceMonitor.rates(from: start, to: end)

        XCTAssertNil(rates.gpuMsPerFrame)
        XCTAssertEqual(rates.fps, 0)
    }

    func testFormatCurrentMatchesDocumentedString() {
        let rates = PerformanceMonitor.Rates(
            cpuPercent: 2.1, watts: 0.14, fps: 60, gpuMsPerFrame: 0.4, footprintMB: 58
        )

        XCTAssertEqual(
            PerformanceMonitor.formatCurrent(rates),
            "2.1% CPU · 0.14 W · 60 fps · 0.4 ms GPU"
        )
    }

    func testFormatCurrentOmitsGPUWhenNil() {
        let rates = PerformanceMonitor.Rates(
            cpuPercent: 2.1, watts: 0.14, fps: 60, gpuMsPerFrame: nil, footprintMB: 58
        )

        XCTAssertEqual(
            PerformanceMonitor.formatCurrent(rates),
            "2.1% CPU · 0.14 W · 60 fps"
        )
    }

    func testFormatCurrentShowsIdleBelowHalfFPS() {
        let rates = PerformanceMonitor.Rates(
            cpuPercent: 0.1, watts: 0.01, fps: 0.2, gpuMsPerFrame: nil, footprintMB: 58
        )

        XCTAssertEqual(
            PerformanceMonitor.formatCurrent(rates),
            "0.1% CPU · 0.01 W · idle"
        )
    }

    func testFormatSinceLaunchMatchesDocumentedString() {
        let rates = PerformanceMonitor.Rates(
            cpuPercent: 1.8, watts: 0.12, fps: 58, gpuMsPerFrame: nil, footprintMB: 58
        )

        XCTAssertEqual(
            PerformanceMonitor.formatSinceLaunch(rates),
            "Since launch: 1.8% CPU · 0.12 W avg · 58 MB"
        )
    }
}
