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
    /// flow length, flow direction (+1/-1), drop flash, aurora drift
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
        const float softness = 60.0;
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
        return mix(u.colors[i].rgb, u.colors[j].rgb, x - floor(x));
    }

    // Luminous version of a colour: the hue is kept at full value and strong
    // saturation, lifted toward white so it glows rather than sits dark.
    // Near-greys stay grey.
    static float3 vivid(float3 c) {
        float high = max(c.r, max(c.g, c.b));
        float low = min(c.r, min(c.g, c.b));
        if (high - low < 0.05) { return float3(min(1.0, high * 1.25)); }
        float3 shape = (c - low) / (high - low);
        return mix(float3(1.0), shape, 0.72);
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

    // Integer cell modulo the period. Fast-math division can return
    // 0.99999994 for 21.0 / 21.0, which floors to the wrong cell exactly at
    // the wrap and put a visible seam at bottom centre; the half-cell offset
    // keeps the quotient away from every integer.
    static float wrap_cell(float cell, float period) {
        return cell - period * floor((cell + 0.5) / period);
    }

    // Smooth value noise that repeats every `period` cells, so a pattern laid
    // around the whole perimeter meets itself without a seam.
    static float loop_noise(float x, float period) {
        float i = floor(x);
        float f = x - i;
        float a = hash(wrap_cell(i, period));
        float b = hash(wrap_cell(i + 1.0, period));
        return mix(a, b, f * f * (3.0 - 2.0 * f));
    }


    static float cells(float perimeter_points, float spacing) {
        return max(1.0, round(perimeter_points / spacing));
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
        float drift = u.flow.w;
        float perimeter_points = 2.0 * (u.screen.x + u.screen.y);

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

        // The ribbon is bounded by two crisp lines. The start line hugs the
        // screen edge and breathes a few points; the end line rides the music
        // (its reach follows the band under it) and undulates like the lower
        // edge of an aurora curtain, drifting along the rim faster as the song
        // gets louder.
        float n1 = cells(perimeter_points, 230.0);
        float n2 = cells(perimeter_points, 90.0);
        float n3 = cells(perimeter_points, 36.0);
        float swell = 0.55 * loop_noise(c * n1 - drift * 0.9, n1)
                    + 0.30 * loop_noise(c * n2 + drift * 1.5, n2)
                    + 0.15 * loop_noise(c * n3 - drift * 2.6, n3);
        float reach = base * (0.4 + 0.6 * band) * (1.0 + 0.22 * kick) + base * 0.3 * shock;
        float end_line = clamp(reach * (0.55 + 0.65 * swell), 3.0, strip_depth * 0.68);
        float start_line = 1.0 + 3.5 * loop_noise(c * n2 - drift * 0.6, n2);
        end_line = max(end_line, start_line + 2.0);

        float d = halo_distance(p, u, 14.0);
        // A little softer than a pixel: the lines read as light, not ink.
        float aa = max(fwidth(d), 2.5);
        float inside = smoothstep(start_line - aa, start_line + aa, d)
                     * smoothstep(end_line + aa, end_line - aa, d);
        float depth = clamp((d - start_line) / (end_line - start_line), 0.0, 1.0);

        // Curtain rays: streaks across the ribbon that drift along it. The
        // strongest shoot past the end line and fade out, the way aurora rays
        // spill over the curtain's lower edge.
        float n4 = cells(perimeter_points, 10.0);
        float n5 = cells(perimeter_points, 4.5);
        float ray_field = loop_noise(c * n4 + drift * 2.0, n4);
        float hair = 0.88 + 0.12 * loop_noise(c * n5 - drift * 3.4, n5);
        float rays = (0.72 + 0.28 * ray_field) * hair;
        float ray = smoothstep(0.5, 0.95, ray_field) * hair;
        float ray_soft = smoothstep(0.3, 0.95, ray_field);

        float end_offset = (d - end_line) / 3.6;
        float start_offset = (d - start_line) / 4.0;
        float end_glow = exp(-end_offset * end_offset);
        float start_glow = exp(-start_offset * start_offset);
        float past = d - end_line;
        float room = max(strip_depth - end_line - 4.0, 0.0);
        float ray_length = min((10.0 + 42.0 * ray) * (0.75 + 0.35 * band) * (1.0 + 0.25 * kick), room);
        float streak = past > 0.0 && ray_length > 0.0
            ? ray * pow(clamp(1.0 - past / ray_length, 0.0, 1.0), 1.6)
            : 0.0;
        // Opacity falls steeply across the band: strong at the screen edge,
        // nearly clear by the inner edge, which then barely needs a line.
        float fill = inside * mix(0.9, 0.06, pow(depth, 0.75)) * rays;

        // Neon halos: every crisp line and ray carries a soft glow around its
        // sharp core, wider than the core and fainter.
        float end_halo_offset = (d - end_line) / 18.0;
        float start_halo_offset = (d - start_line) / 16.0;
        float end_halo = exp(-end_halo_offset * end_halo_offset);
        float start_halo = exp(-start_halo_offset * start_halo_offset);
        float ray_halo_length = min(ray_length * 1.6 + 12.0, room);
        float ray_halo = past > 0.0 && ray_halo_length > 0.0
            ? ray_soft * pow(clamp(1.0 - past / ray_halo_length, 0.0, 1.0), 2.0)
            : 0.0;
        // Bloom: the whole ribbon breathes light a little way past its end line.
        float bloom = past > 0.0 ? exp(-past / 16.0) : 0.0;
        // Rays and their halos past the inner edge continue the fade across
        // the band instead of starting brighter than the fill beside them.
        float halos = 0.35 * end_halo + 0.7 * start_halo + 0.3 * ray_halo + 0.2 * bloom;

        float energy = (0.7 + 0.3 * band) * (1.0 + 0.2 * kick + 0.1 * snare + 0.15 * u.flow.z)
                     * (0.9 + 0.1 * level);
        // The body keeps its colour in quiet passages; the lines, rays and
        // their halos carry the (deliberately gentle) swings.
        float body_energy = (0.85 + 0.15 * band) * (1.0 + 0.1 * kick + 0.1 * u.flow.z);
        float brightness = fill * body_energy
                         + (0.3 * end_glow + 0.6 * start_glow + 0.35 * streak + halos) * energy
                         + 0.15 * shock * end_glow;

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

        // Colour runs across the ribbon from one palette entry at the edge to
        // the next at the end line, the way an aurora shifts hue with height.
        // Only about a third of the palette spans the rim at once, so colours
        // change in long, gradual sweeps rather than bands.
        float hue = s * 0.32 + u.color.x;
        float3 color = mix(vivid(palette(u, hue)), vivid(palette(u, hue + 0.08)), depth);
        // The ribbon's body sits a little deeper than its lines; rays past the
        // end line keep the end line's colour.
        // Neon: white-hot cores on every line and ray inside their coloured
        // glow, and the whole ribbon lifted toward white.
        // The inner (end) line stays a gentle edge; the outer line and rays
        // carry the white-hot cores.
        float core = max(max(end_glow * 0.3, start_glow * 0.85), streak * 0.8);
        color = mix(color, float3(1.0),
                    clamp(0.14 + core * (0.55 + 0.1 * kick + 0.08 * u.flow.z), 0.0, 1.0));

        // Treble shimmer: soft, tinted glints on the start line where the highs
        // are, each cell on its own random phase so they never flicker in step.
        float along = c * perimeter_points / 22.0;
        float cell = floor(along);
        float cycle = time * 3.0 + hash(cell * 1.37) * 10.0;
        float life = fract(cycle);
        float chance = hash(cell * 3.11 + floor(cycle) * 7.13);
        float lit = step(1.0 - 0.45 * treble * band, chance);
        float offset = (fract(along) - 0.5) * 3.2;
        float sparkle = lit * sin(life * 3.14159) * exp(-offset * offset)
                      * treble * start_glow;

        float gain = u.shape.z * presence;
        // Never fully opaque: the screen always shows through the aurora.
        float alpha = clamp(brightness * mask * gain, 0.0, 1.0) * 0.82;
        float glints = clamp(0.8 * sparkle * gain, 0.0, 1.0);
        float3 glint_color = mix(color, float3(1.0), 0.4);
        float3 rgb = color * alpha * (1.0 - glints) + glint_color * glints;
        alpha = alpha + glints * (1.0 - alpha);
        return float4(min(rgb, float3(alpha)), alpha);
    }
    """
}
