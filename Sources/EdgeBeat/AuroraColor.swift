import AppKit
import simd

/// Colour math for the aurora, done once per palette change rather than per
/// pixel: palette colours go to the shader as OKLCH (lightness, chroma, hue),
/// where blending along the hue angle keeps midpoints vivid. A straight RGB or
/// Oklab mix sends complementary pairs such as blue and yellow through grey.
enum AuroraColor {
    /// Chroma is pushed past what sRGB can show; the shader converts to Display
    /// P3 and clips there, so the wider panel gamut is actually used.
    static let chromaBoost: Float = 1.25

    /// The shader-ready form of a palette colour: (L, C, h radians, 1).
    static func auroraLCH(_ color: NSColor) -> SIMD4<Float> {
        let lch = oklch(fromSRGB: vivid(srgbComponents(color)))
        return SIMD4(lch.x, lch.y * chromaBoost, lch.z, 1)
    }

    /// Luminous version of a colour: hue kept at full value and strong
    /// saturation, lifted toward white so it glows rather than sits dark.
    /// Near-greys stay grey (a custom grey is a deliberate choice).
    static func vivid(_ c: SIMD3<Float>) -> SIMD3<Float> {
        let high = max(c.x, max(c.y, c.z))
        let low = min(c.x, min(c.y, c.z))
        guard high - low >= 0.05 else { return SIMD3(repeating: min(1, high * 1.25)) }
        let shape = (c - low) / (high - low)
        return simd_mix(SIMD3(repeating: 1), shape, SIMD3(repeating: 0.72))
    }

    static func srgbComponents(_ color: NSColor) -> SIMD3<Float> {
        guard let rgb = color.usingColorSpace(.sRGB) else { return SIMD3(repeating: 1) }
        return SIMD3(Float(rgb.redComponent), Float(rgb.greenComponent), Float(rgb.blueComponent))
    }

    // MARK: - sRGB <-> Oklab <-> OKLCH (Björn Ottosson's reference matrices)

    static func linear(fromSRGB c: SIMD3<Float>) -> SIMD3<Float> {
        func channel(_ v: Float) -> Float {
            v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return SIMD3(channel(c.x), channel(c.y), channel(c.z))
    }

    static func srgb(fromLinear c: SIMD3<Float>) -> SIMD3<Float> {
        func channel(_ v: Float) -> Float {
            let v = max(0, v)
            return v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055
        }
        return SIMD3(channel(c.x), channel(c.y), channel(c.z))
    }

    static func oklab(fromLinear c: SIMD3<Float>) -> SIMD3<Float> {
        let l = 0.4122214708 * c.x + 0.5363325363 * c.y + 0.0514459929 * c.z
        let m = 0.2119034982 * c.x + 0.6806995451 * c.y + 0.1073969566 * c.z
        let s = 0.0883024619 * c.x + 0.2817188376 * c.y + 0.6299787005 * c.z
        let l_ = cbrt(l), m_ = cbrt(m), s_ = cbrt(s)
        return SIMD3(0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_,
                     1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_,
                     0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_)
    }

    static func linear(fromOklab lab: SIMD3<Float>) -> SIMD3<Float> {
        let l_ = lab.x + 0.3963377774 * lab.y + 0.2158037573 * lab.z
        let m_ = lab.x - 0.1055613458 * lab.y - 0.0638541728 * lab.z
        let s_ = lab.x - 0.0894841775 * lab.y - 1.2914855480 * lab.z
        let l = l_ * l_ * l_, m = m_ * m_ * m_, s = s_ * s_ * s_
        return SIMD3(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
                     -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
                     -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s)
    }

    /// (L, C, h) with h in radians.
    static func oklch(fromSRGB c: SIMD3<Float>) -> SIMD3<Float> {
        let lab = oklab(fromLinear: linear(fromSRGB: c))
        return SIMD3(lab.x, hypot(lab.y, lab.z), atan2(lab.z, lab.y))
    }

    static func srgb(fromOKLCH lch: SIMD3<Float>) -> SIMD3<Float> {
        let lab = SIMD3(lch.x, lch.y * cos(lch.z), lch.y * sin(lch.z))
        return srgb(fromLinear: linear(fromOklab: lab))
    }

    /// Blend along the shorter hue arc, chroma and lightness linearly. A grey
    /// endpoint has no hue of its own, so it borrows the other's.
    static func mixOKLCH(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ t: Float) -> SIMD3<Float> {
        var ha = a.z, hb = b.z
        if a.y < 0.02 { ha = hb }
        if b.y < 0.02 { hb = ha }
        var dh = hb - ha
        dh -= 2 * .pi * (dh / (2 * .pi)).rounded()
        return SIMD3(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, ha + dh * t)
    }
}
