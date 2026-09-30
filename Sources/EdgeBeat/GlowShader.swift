import simd

/// Per-frame inputs to the glow shader. Every member is a float4 so the Swift
/// and Metal layouts agree without padding rules; `GlowShader.source` declares
/// the same struct in the same order.
struct GlowUniforms {
    /// width, height (points), corner radius, time (seconds)
    var screen = SIMD4<Float>.zero
    /// origin x, origin y, width, height of the strip being drawn (points, y down)
    var strip = SIMD4<Float>.zero
    /// notch minX, maxX, depth, corner radius; depth 0 means no notch
    var notch = SIMD4<Float>.zero
    /// base reach (points), fade-out distance (points), intensity, presence
    var shape = SIMD4<Float>.zero
    /// level, kick envelope, snare envelope, treble
    var energy = SIMD4<Float>.zero
    /// color phase, color count, mode (0 glow, 1 wave flow), flow head
    var color = SIMD4<Float>.zero
    /// flow length, flow direction (+1/-1), drop flash, unused
    var flow = SIMD4<Float>.zero
    /// age (seconds), strength; strength 0 marks an empty slot
    var shocks: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) = (.zero, .zero, .zero, .zero)
    var colors: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)
        = (.zero, .zero, .zero, .zero, .zero)
    /// 32 band values, four per element
    var bands: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>,
                SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)
        = (.zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero)

    static let maximumShocks = 4
    static let maximumColors = 5

    mutating func setShock(_ index: Int, age: Float, strength: Float) {
        let value = SIMD4<Float>(age, strength, 0, 0)
        switch index {
        case 0: shocks.0 = value
        case 1: shocks.1 = value
        case 2: shocks.2 = value
        case 3: shocks.3 = value
        default: break
        }
    }

    mutating func setColor(_ index: Int, _ value: SIMD4<Float>) {
        switch index {
        case 0: colors.0 = value
        case 1: colors.1 = value
        case 2: colors.2 = value
        case 3: colors.3 = value
        case 4: colors.4 = value
        default: break
        }
    }

    mutating func setBands(_ values: [Float]) {
        func group(_ start: Int) -> SIMD4<Float> {
            SIMD4<Float>((0..<4).map { start + $0 < values.count ? values[start + $0] : 0 })
        }
        bands = (group(0), group(4), group(8), group(12), group(16), group(20), group(24), group(28))
    }
}

enum GlowShader {
    static let vertexFunction = "glow_vertex"
    static let fragmentFunction = "glow_fragment"

    /// Compiled at launch with `makeLibrary(source:)`: SwiftPM command-line
    /// builds do not compile .metal files, and one small shader compiles in a
    /// few milliseconds.
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct GlowUniforms {
        float4 screen;
        float4 strip;
        float4 notch;
        float4 shape;
        float4 energy;
        float4 color;
        float4 flow;
        float4 shocks[4];
        float4 colors[5];
        float4 bands[8];
    };

    struct VertexOut {
        float4 position [[position]];
        float2 point;
    };

    vertex VertexOut glow_vertex(uint vid [[vertex_id]],
                                 constant GlowUniforms &u [[buffer(0)]]) {
        float2 corner = float2(float(vid & 1), float(vid >> 1));
        VertexOut out;
        out.position = float4(corner.x * 2.0 - 1.0, 1.0 - corner.y * 2.0, 0.0, 1.0);
        out.point = u.strip.xy + corner * u.strip.zw;
        return out;
    }

    static float band_value(constant GlowUniforms &u, int index) {
        int i = clamp(index, 0, 31);
        return u.bands[i / 4][i % 4];
    }

    // Catmull-Rom across bands so the edge has no kinks where one band hands
    // over to the next.
    static float band_at(constant GlowUniforms &u, float s) {
        float x = clamp(s, 0.0, 1.0) * 31.0;
        int i = int(floor(x));
        float t = x - float(i);
        float p0 = band_value(u, i - 1);
        float p1 = band_value(u, i);
        float p2 = band_value(u, i + 1);
        float p3 = band_value(u, i + 2);
        float t2 = t * t;
        float t3 = t2 * t;
        float v = 0.5 * ((2.0 * p1) + (-p0 + p2) * t
                         + (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2
                         + (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t3);
        return clamp(v, 0.0, 1.0);
    }

    static float sd_round_box(float2 p, float2 half_size, float radius) {
        float2 q = abs(p) - half_size + radius;
        return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
    }

    // Distance from the pixel to the nearest visible boundary: the screen's
    // rounded outline or the notch. Negative inside the notch.
    static float boundary_distance(float2 p, constant GlowUniforms &u) {
        float2 size = u.screen.xy;
        float d = -sd_round_box(p - size * 0.5, size * 0.5, u.screen.z);
        if (u.notch.z > 0.0) {
            float2 centre = float2((u.notch.x + u.notch.y) * 0.5, 0.0);
            float2 half_size = float2((u.notch.y - u.notch.x) * 0.5, u.notch.z);
            d = min(d, sd_round_box(p - centre, half_size, u.notch.w));
        }
        return d;
    }

    // Two perimeter coordinates, blended between edges near the corners so
    // neither has a seam along the diagonal:
    //   s — mirrored: 0 at bottom centre, up both sides, 1 at top centre.
    //       Bass sits along the bottom, mids climb the sides, treble on top.
    //   c — clockwise from bottom centre, 0...1, for the travelling comet.
    static void perimeter(float2 p, float2 size, thread float &s, thread float &c) {
        float w = size.x;
        float h = size.y;
        float half_perimeter = w + h;
        float2 q = clamp(p, float2(0.0), size);
        float dl = q.x, dr = w - q.x, dt = q.y, db = h - q.y;
        float nearest = min(min(dl, dr), min(dt, db));
        const float softness = 28.0;
        float wl = exp(-(dl - nearest) / softness);
        float wr = exp(-(dr - nearest) / softness);
        float wt = exp(-(dt - nearest) / softness);
        float wb = exp(-(db - nearest) / softness);
        float total = wl + wr + wt + wb;

        float from_centre = abs(q.x - w * 0.5);
        float s_bottom = from_centre;
        float s_side = w * 0.5 + (h - q.y);
        float s_top = w * 0.5 + h + (w * 0.5 - from_centre);
        s = (wb * s_bottom + (wl + wr) * s_side + wt * s_top) / (total * half_perimeter);

        float c_bottom = q.x < w * 0.5 ? (w * 0.5 - q.x) : (1.5 * w + 2.0 * h + (w - q.x));
        float c_left = w * 0.5 + (h - q.y);
        float c_top = w * 0.5 + h + q.x;
        float c_right = 1.5 * w + h + q.y;
        c = (wb * c_bottom + wl * c_left + wt * c_top + wr * c_right) / (total * 2.0 * half_perimeter);
    }

    static float3 palette(constant GlowUniforms &u, float t) {
        int count = max(1, int(u.color.y));
        float x = fract(t) * float(count);
        int i = int(floor(x)) % count;
        int j = (i + 1) % count;
        float f = smoothstep(0.0, 1.0, x - floor(x));
        return mix(u.colors[i].rgb, u.colors[j].rgb, f);
    }

    static float hash(float n) {
        return fract(sin(n * 12.9898) * 43758.5453);
    }

    // Distance used for the soft halo: a smooth minimum of the four edge
    // distances (and the notch), so the glow rounds off in the corners instead
    // of creasing along the diagonal the way a plain min() does.
    static float halo_distance(float2 p, constant GlowUniforms &u, float k) {
        float2 size = u.screen.xy;
        float sum = exp(-p.x / k) + exp(-(size.x - p.x) / k)
                  + exp(-p.y / k) + exp(-(size.y - p.y) / k);
        if (u.notch.z > 0.0) {
            float2 centre = float2((u.notch.x + u.notch.y) * 0.5, 0.0);
            float2 half_size = float2((u.notch.y - u.notch.x) * 0.5, u.notch.z);
            float notch = max(sd_round_box(p - centre, half_size, u.notch.w), 0.0);
            sum += exp(-notch / k);
        }
        return max(-k * log(sum), 0.0);
    }

    // Compactly supported bell (Wendland): 1 at the edge, exactly 0 with zero
    // slope at x = 1, so the glow ends without a visible boundary.
    static float bell(float x) {
        x = clamp(x, 0.0, 1.0);
        float a = 1.0 - x;
        return a * a * a * (1.0 + 3.0 * x);
    }

    fragment float4 glow_fragment(VertexOut in [[stage_in]],
                                  constant GlowUniforms &u [[buffer(0)]]) {
        float presence = u.shape.w;
        if (presence <= 0.001) { return float4(0.0); }
        float2 p = in.point;
        float edge = boundary_distance(p, u);
        if (edge < 0.0) { return float4(0.0); }

        float s, c;
        perimeter(p, u.screen.xy, s, c);
        float band = band_at(u, s);

        float level = u.energy.x;
        float kick = u.energy.y;
        float snare = u.energy.z;
        float treble = u.energy.w;
        float base = u.shape.x;
        float strip_depth = u.shape.y;
        float time = u.screen.w;

        // Each kick launches a shockwave from bottom centre that climbs both
        // sides and meets at the top.
        float shock = 0.0;
        for (int i = 0; i < 4; i++) {
            float strength = u.shocks[i].y;
            if (strength <= 0.0) { continue; }
            float front = u.shocks[i].x / 0.6;
            float x = (s - front) / 0.045;
            shock += strength * (1.0 - clamp(front, 0.0, 1.0)) * exp(-x * x);
        }

        const float support = 1.6;
        float reach = base * (0.16 + 0.84 * band) * (1.0 + 0.7 * kick) + base * 0.75 * shock;
        reach = clamp(reach, 2.0, strip_depth / support);

        float d = halo_distance(p, u, max(6.0, reach * 0.35));
        float halo = bell(d / (reach * support));
        float core = exp(-edge / (1.2 + 0.03 * reach));
        float brightness = halo * (0.5 + 0.5 * band) + 0.85 * core * (0.35 + 0.65 * band);
        brightness += 0.45 * shock * halo;
        brightness *= 1.0 + 0.5 * kick + 0.35 * snare + 0.3 * u.flow.z;
        brightness *= 0.8 + 0.2 * level;

        float mask = 1.0;
        if (u.color.z > 0.5) {
            float head = u.color.w;
            float span = max(u.flow.x, 0.02);
            float behind = fract((head - c) * u.flow.y + 1.0);
            mask = behind < span
                ? smoothstep(0.0, 0.015, behind) * smoothstep(span, span * 0.35, behind)
                : 0.0;
            mask = max(mask, 0.08 * band);
        }

        float3 color = palette(u, s * 0.85 + u.color.x);
        float luma = dot(color, float3(0.2126, 0.7152, 0.0722));
        color = clamp(mix(float3(luma), color, 1.3), 0.0, 1.0);
        color = mix(color, float3(1.0), clamp(core * (0.12 * band + 0.35 * kick + 0.25 * u.flow.z), 0.0, 1.0));

        // Treble sparkle: short-lived glints along the rim where the highs are.
        float perimeter_points = 2.0 * (u.screen.x + u.screen.y);
        float cell = floor(c * perimeter_points / 6.0);
        float tick = floor(time * 12.0);
        float glint = step(1.0 - 0.1 * treble * band, hash(cell * 1.37 + tick * 7.13));
        float sparkle = glint * treble * exp(-edge / 3.0);

        float gain = u.shape.z * presence;
        float alpha = clamp(brightness * mask * gain, 0.0, 1.0);
        float glints = sparkle * gain;
        float3 rgb = color * alpha + float3(glints);
        alpha = clamp(alpha + glints, 0.0, 1.0);
        return float4(min(rgb, float3(alpha)), alpha);
    }
    """
}
