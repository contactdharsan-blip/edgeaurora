import AppKit

struct GlowPalette {
    var primary: NSColor
    var secondary: NSColor
    var accent: NSColor
    var background: NSColor
    /// Three to five colours: the one the artwork holds most of first, then
    /// the rest walking round the hue circle from it, so the gradient sweeps
    /// instead of jumping.
    /// `primary`, `secondary` and `accent` are `colors[0]`, `[1]` and `[2]`.
    var colors: [NSColor]

    init(primary: NSColor, secondary: NSColor, accent: NSColor, background: NSColor,
         colors: [NSColor]? = nil) {
        self.primary = primary
        self.secondary = secondary
        self.accent = accent
        self.background = background
        self.colors = colors ?? [primary, secondary, accent]
    }

    static let `default` = GlowPalette(
        primary: NSColor(calibratedRed: 0.35, green: 0.65, blue: 1, alpha: 1),
        secondary: NSColor(calibratedRed: 0.75, green: 0.45, blue: 1, alpha: 1),
        accent: NSColor(calibratedRed: 1, green: 0.45, blue: 0.75, alpha: 1),
        background: NSColor(calibratedWhite: 0.02, alpha: 1)
    )
}

enum PaletteExtractor {
    /// Hues the glow falls back to when the artwork has no colour of its own.
    /// Green, teal and violet: an aurora, rather than the grey that a
    /// near-greyscale cover would otherwise hand the renderer.
    private static let auroraHues: [CGFloat] = [150.0 / 360, 185.0 / 360, 265.0 / 360]
    private static let auroraSaturation: CGFloat = 0.7
    private static let auroraBrightness: CGFloat = 0.92

    /// A colour counts as chromatic here if the renderer would see it as a
    /// colour at all; below this it draws grey on purpose.
    private static let chromaticSaturation: CGFloat = 0.2

    private static func auroraColors() -> [NSColor] {
        auroraHues.map {
            NSColor(calibratedHue: $0, saturation: auroraSaturation,
                    brightness: auroraBrightness, alpha: 1)
        }
    }

    /// Used when there are no pixels to read a background from, so it keeps
    /// the one the shipped palette uses rather than inventing another.
    private static func auroraPalette(background: NSColor = GlowPalette.default.background) -> GlowPalette {
        let colors = auroraColors()
        return GlowPalette(primary: colors[0], secondary: colors[1], accent: colors[2],
                           background: background, colors: colors)
    }

    static func extract(from image: NSImage?) -> GlowPalette {
        // No artwork at all is not a colour problem, so it keeps the palette
        // the app ships with.
        guard let image else { return .default }
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return auroraPalette()
        }

        let size = 64
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        guard let context = CGContext(
            data: &pixels,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return auroraPalette() }
        context.interpolationQuality = .low
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))

        var buckets = Array(repeating: (weight: 0.0, r: 0.0, g: 0.0, b: 0.0), count: 24)
        // A second, plainer tally: how many pixels are unmistakably coloured,
        // by hue. It is only read when the ordinary selection comes out grey,
        // and it counts pixels rather than weighting them, so a small patch of
        // real colour can be found under a cover that is otherwise grey.
        var vividBuckets = Array(repeating: (count: 0.0, hue: 0.0), count: 24)
        var sampled = 0.0
        var averageR = 0.0, averageG = 0.0, averageB = 0.0, averageWeight = 0.0
        var darkR = 0.0, darkG = 0.0, darkB = 0.0, darkCount = 0.0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let r = Double(pixels[index]) / 255
            let g = Double(pixels[index + 1]) / 255
            let b = Double(pixels[index + 2]) / 255
            let maxValue = max(r, g, b)
            let minValue = min(r, g, b)
            let brightness = maxValue
            let saturation = maxValue == 0 ? 0 : (maxValue - minValue) / maxValue
            sampled += 1
            if saturation > 0.25, brightness > 0.15 {
                let vividHue = hsvHue(red: r, green: g, blue: b, max: maxValue, min: minValue)
                let vividBucket = min(23, max(0, Int(vividHue * 24)))
                vividBuckets[vividBucket].count += 1
                vividBuckets[vividBucket].hue += vividHue
            }
            if brightness < 0.22 {
                darkR += r; darkG += g; darkB += b; darkCount += 1
            }
            let averageContribution = max(0.08, brightness) * (0.35 + 0.65 * min(1, saturation))
            averageR += r * averageContribution
            averageG += g * averageContribution
            averageB += b * averageContribution
            averageWeight += averageContribution
            guard saturation > 0.16, brightness > 0.12 else { continue }
            let hue = hsvHue(red: r, green: g, blue: b, max: maxValue, min: minValue)
            let bucket = min(23, max(0, Int(hue * 24)))
            let weight = saturation * (0.35 + 0.65 * min(1, brightness))
            buckets[bucket].weight += weight
            buckets[bucket].r += r * weight
            buckets[bucket].g += g * weight
            buckets[bucket].b += b * weight
        }

        let ranked = buckets.indices
            .filter { buckets[$0].weight > 0 }
            .sorted { buckets[$0].weight > buckets[$1].weight }
        let topWeight = ranked.first.map { buckets[$0].weight } ?? 0
        var selected: [Int] = []
        for index in ranked {
            guard selected.count < 5 else { break }
            // A hue one bucket away from one already taken is the same colour
            // with a different name, and the glow needs colours that read apart.
            let isNeighbour = selected.contains { chosen in
                let distance = abs(chosen - index)
                return min(distance, buckets.count - distance) <= 1
            }
            guard !isNeighbour else { continue }
            // The fourth and fifth only earn a place if the artwork really
            // holds them, rather than a stray highlight.
            if selected.count >= 3, buckets[index].weight < topWeight * 0.08 { break }
            selected.append(index)
        }
        let rawSelected = selected.map { index -> NSColor in
            let bucket = buckets[index]
            return NSColor(calibratedRed: bucket.r / bucket.weight,
                           green: bucket.g / bucket.weight,
                           blue: bucket.b / bucket.weight, alpha: 1)
        }
        let extracted = rawSelected.map { glowColor(from: $0) }
        let rawAverage = averageWeight > 0
            ? NSColor(calibratedRed: averageR / averageWeight,
                      green: averageG / averageWeight,
                      blue: averageB / averageWeight, alpha: 1)
            : NSColor.white
        let averageColor = averageWeight > 0 ? glowColor(from: rawAverage) : .white
        let seed = extracted.first ?? averageColor
        let chosen = pad(extracted, using: seed)
        let background = darkCount > 0
            ? NSColor(calibratedRed: darkR / darkCount, green: darkG / darkCount, blue: darkB / darkCount, alpha: 1)
            : .black

        // The aurora is meant to be colourful. If the ordinary selection found
        // nothing that is actually a colour, look again for the strongest
        // patch of real colour on the cover and build around it; failing that,
        // use the aurora hues rather than ship a grey glow.
        //
        // This asks the colours as they came off the artwork, not the ones
        // `glowColor` has already lifted to saturation 0.42: after that lift
        // every selected colour looks chromatic and a grey cover could never
        // be recognised as one.
        let judged = rawSelected.isEmpty ? [rawAverage] : rawSelected
        let colors: [NSColor]
        if judged.allSatisfy({ (rgbComponents(of: $0)?.saturation ?? 0) < chromaticSaturation }) {
            if let hue = dominantVividHue(in: vividBuckets, sampled: sampled) {
                colors = palette(around: hue)
            } else {
                colors = auroraColors()
            }
        } else {
            colors = orderedByHue(chosen)
        }
        return GlowPalette(primary: colors[0], secondary: colors[1], accent: colors[2],
                           background: background, colors: colors)
    }

    /// The hue of the biggest unmistakably coloured cluster, if one holds at
    /// least 0.3% of the sampled pixels. Below that it is a stray pixel or a
    /// compression artefact, not a colour the cover has.
    private static func dominantVividHue(in buckets: [(count: Double, hue: Double)],
                                         sampled: Double) -> CGFloat? {
        guard sampled > 0 else { return nil }
        let minimum = sampled * 0.003
        guard let best = buckets.indices
            .filter({ buckets[$0].count >= minimum })
            .max(by: { buckets[$0].count < buckets[$1].count }) else { return nil }
        return CGFloat(buckets[best].hue / buckets[best].count)
    }

    /// Three colours around one hue: the seed and a neighbour either side,
    /// saturated and bright enough to read as an aurora, in increasing hue
    /// from the seed.
    private static func palette(around hue: CGFloat) -> [NSColor] {
        let spread: CGFloat = 30.0 / 360
        return [hue, hue + spread, hue - spread].map { candidate in
            var wrapped = candidate.truncatingRemainder(dividingBy: 1)
            if wrapped < 0 { wrapped += 1 }
            return NSColor(calibratedHue: wrapped, saturation: 0.6, brightness: 0.82, alpha: 1)
        }
    }

    /// Keeps the heaviest colour first and walks the rest round the hue circle
    /// from it, so neighbouring entries are neighbours in hue and the gradient
    /// sweeps instead of jumping.
    private static func orderedByHue(_ colors: [NSColor]) -> [NSColor] {
        guard colors.count > 2, let primary = colors.first,
              let base = rgbComponents(of: primary)?.hue else { return colors }
        func offset(_ color: NSColor) -> CGFloat {
            guard let hue = rgbComponents(of: color)?.hue else { return 0 }
            var distance = (hue - base).truncatingRemainder(dividingBy: 1)
            if distance < 0 { distance += 1 }
            return distance
        }
        return [primary] + colors.dropFirst().sorted { offset($0) < offset($1) }
    }

    /// Keeps whatever was extracted, in weight order, and invents only what is
    /// missing from the first three.
    private static func pad(_ colors: [NSColor], using seed: NSColor) -> [NSColor] {
        var result = Array(colors.prefix(5))
        guard let seedRGB = rgbComponents(of: seed) else {
            while result.count < 3 { result.append(seed) }
            return result
        }

        let adjustments: [(hue: CGFloat, saturation: CGFloat, brightness: CGFloat)] = [
            (0, 0.08, 1.12),
            (0.08, 0, 0.92),
        ]
        for adjustment in adjustments where result.count < 3 {
            let hue = (seedRGB.hue + adjustment.hue).truncatingRemainder(dividingBy: 1)
            let saturationAdjustment = seedRGB.saturation < 0.08 ? 0 : adjustment.saturation
            let saturation = min(1, max(0, seedRGB.saturation + saturationAdjustment))
            let brightness = min(1, max(0, seedRGB.brightness * adjustment.brightness))
            result.append(NSColor(calibratedHue: hue, saturation: saturation,
                                  brightness: brightness, alpha: 1))
        }
        while result.count < 3 { result.append(seed) }
        return result
    }

    private static func glowColor(from color: NSColor) -> NSColor {
        guard let components = rgbComponents(of: color) else { return color }
        let isChromatic = components.saturation >= 0.08
        let saturation = isChromatic ? max(0.42, components.saturation) : components.saturation
        let brightness = max(isChromatic ? 0.62 : 0.48, components.brightness)
        return NSColor(calibratedHue: components.hue, saturation: saturation,
                       brightness: brightness, alpha: 1)
    }

    private static func rgbComponents(of color: NSColor) ->
        (hue: CGFloat, saturation: CGFloat, brightness: CGFloat)? {
        guard let rgb = color.usingColorSpace(.deviceRGB) else { return nil }
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        rgb.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return (hue, saturation, brightness)
    }

    private static func hsvHue(red: Double, green: Double, blue: Double, max: Double, min: Double) -> Double {
        let delta = max - min
        guard delta > 0 else { return 0 }
        let value: Double
        if max == red { value = ((green - blue) / delta).truncatingRemainder(dividingBy: 6) }
        else if max == green { value = (blue - red) / delta + 2 }
        else { value = (red - green) / delta + 4 }
        return (value / 6).rounded(.down) < 0 ? (value + 6) / 6 : value / 6
    }
}
