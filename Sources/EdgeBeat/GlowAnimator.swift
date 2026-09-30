import AppKit
import simd

/// Turns the analyzer's latest reading into the shader's per-frame state:
/// band smoothing, onset envelopes, shockwaves, color drift and the wave-flow
/// head. One animator is shared by every display; `advance(to:)` does nothing
/// when another display has already advanced it for the same frame.
final class GlowAnimator {
    private let preferences: AppPreferences
    private let renderState: RenderState
    private let featureSource: () -> AudioFeatures?

    var isLowPowerModeEnabled = false

    private var lastTime: CFTimeInterval = 0
    private var clock: Double = 0
    private var bands = [Float](repeating: 0, count: AudioFeatures.bandCount)
    private var level: Float = 0
    private var bass: Float = 0
    private var treble: Float = 0
    private var intensity: Float = 0.5
    private var kick: Float = 0
    private var snare: Float = 0
    private var dropFlash: Float = 0
    private var presence: Float = 0
    private var quietness: Float = 0
    private var colorPhase: Double = 0
    private var pendingColorShift: Double = 0
    private var flowHead: Double = 0
    private var auroraDrift: Double = 0
    private var shocks: [(age: Float, strength: Float)] = []
    private var lastKickSerial: UInt64?
    private var lastSnareSerial: UInt64?
    private var lastDropSerial: UInt64?
    private var lastFeatureTimestamp: TimeInterval?
    private var lastFeatureArrival: TimeInterval = 0
    private var frame = GlowUniforms()
    private var paletteSource: [NSColor] = []
    private var palette: [SIMD4<Float>] = []
    private var previousPalette: [SIMD4<Float>] = []
    private var paletteFade: Float = 1

    /// Seconds a track change takes to hand the aurora from one palette to the next.
    static let paletteCrossfadeSeconds: Float = 1.5

    init(preferences: AppPreferences, renderState: RenderState,
         featureSource: @escaping () -> AudioFeatures?) {
        self.preferences = preferences
        self.renderState = renderState
        self.featureSource = featureSource
    }

    /// True while there is anything to draw: music playing, or the glow still
    /// fading out after it stopped. Views pause their display links otherwise.
    var isActive: Bool {
        renderState.isPlaying || presence > 0.002
    }

    /// 0 when nothing is playing, rising to 1 as the glow fades in.
    var visibility: Float { presence }

    /// 0 in loud passages, towards 1 in quiet ones; drives the breathing.
    var quietnessLevel: Float { quietness }

    /// How far the frosted-glass band reaches in from the edge.
    static func frostDepth(thickness: Double) -> CGFloat {
        ceil(baseReach(thickness: thickness) * 1.7)
    }

    /// Points the glow reaches inward from the edge at full band energy.
    static func baseReach(thickness: Double) -> CGFloat {
        CGFloat(14 + 56 * AppPreferences.clampedUnitValue(thickness, fallback: 0.45))
    }

    /// Depth of each edge strip. Kicks and shockwaves push the glow past its
    /// base reach; the shader caps the reach so its falloff reaches exactly
    /// zero inside the strip, and the strip's inner boundary never shows.
    static func stripDepth(thickness: Double) -> CGFloat {
        ceil(baseReach(thickness: thickness) * 2.8)
    }

    static func cornerRadius(for size: CGSize) -> CGFloat {
        min(24, max(12, min(size.width, size.height) * 0.02))
    }

    func advance(to time: CFTimeInterval) {
        guard time - lastTime > 0.002 else { return }
        let dt = Float(lastTime == 0 ? 1.0 / 60.0 : min(0.1, time - lastTime))
        lastTime = time
        clock += Double(dt)

        let playing = renderState.isPlaying
        let features = playing ? freshFeatures() : nil
        presence += ((playing ? 1 : 0) - presence) * coefficient(dt, 0.35)

        let targets = features?.bands ?? []
        for index in bands.indices {
            let target = index < targets.count ? min(1, max(0, targets[index])) : 0
            // Slow on both sides: the owner wanted a calmer, less twitchy glow.
            let tau: Float = target > bands[index] ? 0.12 : 0.5
            bands[index] += (target - bands[index]) * coefficient(dt, tau)
        }
        approach(&level, Float(features?.level ?? 0), dt, attack: 0.04, release: 0.25)
        approach(&bass, Float(features?.bass ?? 0), dt, attack: 0.03, release: 0.2)
        approach(&treble, Float(features?.treble ?? 0), dt, attack: 0.02, release: 0.15)
        approach(&intensity, features?.intensity ?? 0.5, dt, attack: 0.5, release: 0.8)
        // How quiet the passage is, slowly: quiet songs breathe, loud ones don't.
        let quietTarget: Float = playing ? min(1, max(0, (0.5 - level) / 0.35)) : 0
        quietness += (quietTarget - quietness) * coefficient(dt, 2.5)

        kick *= exp(-dt / 0.2)
        snare *= exp(-dt / 0.09)
        dropFlash *= exp(-dt / 0.5)
        shocks = shocks.compactMap { shock in
            let age = shock.age + dt
            return age < 0.6 ? (age, shock.strength) : nil
        }

        if let features {
            if isNewEvent(features.kickSerial, since: &lastKickSerial) {
                let strength = min(1, max(0.3, features.kickStrength))
                kick = max(kick, strength)
                shocks.append((0, strength))
                if shocks.count > GlowUniforms.maximumShocks { shocks.removeFirst() }
            }
            if isNewEvent(features.snareSerial, since: &lastSnareSerial) {
                snare = max(snare, min(1, max(0.3, features.snareStrength)))
            }
            if isNewEvent(features.dropSerial, since: &lastDropSerial) {
                dropFlash = 1
                pendingColorShift += 1 / Double(max(1, palette.count))
            }
        } else if !playing {
            lastKickSerial = nil
            lastSnareSerial = nil
            lastDropSerial = nil
        }

        // Colors drift slowly in quiet passages and a little faster as the song
        // builds; a drop rotates the palette one step over a few seconds.
        colorPhase += Double(dt) * (0.004 + 0.015 * Double(intensity * intensity))
        let shift = pendingColorShift * Double(coefficient(dt, 1.2))
        colorPhase += shift
        pendingColorShift -= shift
        colorPhase = colorPhase.truncatingRemainder(dividingBy: 1)

        // The aurora's end line drifts along the rim; the music sets its pace.
        auroraDrift += Double(dt) * Double(0.3 + 0.35 * level + 0.1 * kick + 0.15 * intensity)
        auroraDrift = auroraDrift.truncatingRemainder(dividingBy: 10_000)

        if preferences.waveFlowEnabled {
            let speed = 0.14 * pow(preferences.waveSpeed, 1.25)
                * Double(1 + level * 0.5 + bass * 0.4 + kick * 0.35)
            flowHead += Double(dt) * speed * preferences.waveFlowDirection.phaseSign
            flowHead -= floor(flowHead)
        }

        updatePalette(dt)
        buildFrame()
    }

    /// The shared frame with the strip-specific fields filled in.
    func uniforms(screenSize: CGSize, strip: CGRect, notch: DisplayNotch?) -> GlowUniforms {
        var uniforms = frame
        uniforms.screen = SIMD4(Float(screenSize.width), Float(screenSize.height),
                                Float(Self.cornerRadius(for: screenSize)), Float(clock))
        uniforms.strip = SIMD4(Float(strip.minX), Float(strip.minY),
                               Float(strip.width), Float(strip.height))
        if let notch {
            uniforms.notch = SIMD4(Float(notch.minX), Float(notch.maxX),
                                   Float(notch.depth), Float(notch.cornerRadius))
        }
        return uniforms
    }

    private func buildFrame() {
        let thickness = preferences.thickness
        var next = GlowUniforms()
        next.shape = SIMD4(Float(Self.baseReach(thickness: thickness)),
                           Float(Self.stripDepth(thickness: thickness)),
                           Float(preferences.waveFlowEnabled ? preferences.waveIntensity
                                                             : preferences.intensity),
                           presence)
        next.energy = SIMD4(level, kick, snare, treble)
        let colors = palette
        next.color = SIMD4(Float(colorPhase), Float(colors.count),
                           preferences.waveFlowEnabled ? 1 : 0, Float(flowHead))
        next.flow = SIMD4(Float(0.08 + preferences.waveLength * 0.44),
                          Float(preferences.waveFlowDirection.phaseSign), dropFlash,
                          Float(auroraDrift))
        next.tuning = SIMD4(Float(AppPreferences.tuningMultiplier(preferences.reactivity)),
                            Float(AppPreferences.tuningMultiplier(preferences.rayLength)),
                            quietness,
                            Float(AppPreferences.clampedUnitValue(preferences.smoke, fallback: 0.3)))
        for (index, shock) in shocks.enumerated() {
            next.setShock(index, age: shock.age, strength: shock.strength)
        }
        next.blend = SIMD4(Float(previousPalette.count), smoothstepFade(paletteFade), 0, 0)
        for (index, color) in previousPalette.enumerated() {
            next.setPreviousColor(index, color)
        }
        for (index, color) in colors.enumerated() {
            next.setColor(index, color)
        }
        next.setBands(bands)
        frame = next
    }

    private func sourceColors() -> [NSColor] {
        let colors: [NSColor]
        switch preferences.colorSource {
        case .album:
            colors = renderState.palette.colors
        case .custom:
            colors = preferences.colorMode == .gradient
                ? [preferences.primaryColor, preferences.secondaryColor]
                : [preferences.primaryColor]
        }
        return Array(colors.prefix(GlowUniforms.maximumColors))
    }

    /// Converts the palette to OKLCH only when it changes, and starts a
    /// crossfade from the old one. The first palette appears without a fade.
    private func updatePalette(_ dt: Float) {
        let source = sourceColors()
        if source != paletteSource {
            let next = source.map(AuroraColor.auroraLCH)
            if palette.isEmpty {
                paletteFade = 1
            } else {
                previousPalette = palette
                paletteFade = 0
            }
            paletteSource = source
            palette = next
        }
        if paletteFade < 1 {
            paletteFade = min(1, paletteFade + dt / Self.paletteCrossfadeSeconds)
            if paletteFade >= 1 { previousPalette = [] }
        }
    }

    private func smoothstepFade(_ t: Float) -> Float {
        t * t * (3 - 2 * t)
    }


    /// A reading that has not changed for half a second belongs to audio that
    /// has stopped. Staleness is judged by when a new reading last arrived, not
    /// by the reading's own timestamp: that is counted in samples, and dropped
    /// buffers or clock drift over a long session would slowly age it out.
    private func freshFeatures() -> AudioFeatures? {
        guard let features = featureSource() else {
            lastFeatureTimestamp = nil
            return nil
        }
        let now = ProcessInfo.processInfo.systemUptime
        if features.timestamp != lastFeatureTimestamp {
            lastFeatureTimestamp = features.timestamp
            lastFeatureArrival = now
        }
        return now - lastFeatureArrival < 0.5 ? features : nil
    }

    /// Serials restart at zero with each audio session, so a smaller value is a
    /// new session rather than an event.
    private func isNewEvent(_ serial: UInt64, since last: inout UInt64?) -> Bool {
        defer { last = serial }
        guard let previous = last else { return false }
        return serial > previous
    }

    private func approach(_ value: inout Float, _ target: Float, _ dt: Float,
                          attack: Float, release: Float) {
        let clamped = min(1, max(0, target))
        value += (clamped - value) * coefficient(dt, clamped > value ? attack : release)
    }

    private func coefficient(_ dt: Float, _ tau: Float) -> Float {
        1 - exp(-dt / tau)
    }
}
