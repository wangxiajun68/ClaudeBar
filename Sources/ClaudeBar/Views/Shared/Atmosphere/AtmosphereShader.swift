/// Metal source for the atmosphere pass, compiled at runtime with
/// `MTLDevice.makeLibrary(source:options:)`. The build uses bare `swiftc`, which
/// has no offline Metal compiler, and the runtime compiler ships with the OS.
///
/// One full-screen triangle, one fragment function, layered far → near:
/// sky gradient + horizon scattering → stars / moon / sun → cirrus → volumetric
/// cloud deck (perspective plane, light-marched toward the sun or moon) → fog →
/// far rain / snow → rainbow / meteor / lightning → the greeting (glass, rim-lit,
/// under the cloud shadow) → near rain / snow → refraction through drops on the
/// card's own glass. `Uniforms` must match `AtmosphereUniforms` field for field.
enum AtmosphereShader {
    static let source = #"""
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float2 resolution;
    float time;
    float scale;
    float4 zenith;      // rgb, a: sky band height (pt)
    float4 mid;         // rgb, a: exposure
    float4 horizon;     // rgb, a: nightness
    float4 glow;        // rgb, a: strength
    float4 sun;         // uv, radius pt, visibility
    float4 sunColor;    // rgb, altitude deg
    float4 moon;        // uv, radius pt, visibility
    float4 sky;         // moon phase, star visibility, star drift, star count
    float4 cloud;       // cover, darkness, wind pt/s, rain slant rad
    float4 precip;      // rain, snow, fog, thunder
    float4 effects;     // glass drops, hail, rainbow, entrance
    float4 textRect;    // pt: x, y, w, h
    float4 textStyle;   // pen reveal 0…1, rim, glow, dark ink
    float4 pointer;     // pt xy, active, unused
    float4 parallax;    // pt xy, dark appearance, unused
    float4 ripple;      // pt xy, age s, kind
    float4 flash;       // sky illumination, strike x (uv), channel seed, channel brightness
    float4 meteor;      // start uv, end uv
    float4 meteorInfo;  // progress, brightness, unused, unused
};

struct VOut { float4 position [[position]]; };

vertex VOut atmosphere_vertex(uint vid [[vertex_id]]) {
    float2 p = float2(float((vid << 1) & 2), float(vid & 2));
    VOut o;
    o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    return o;
}

constexpr sampler noiseSampler(filter::linear, mip_filter::linear, address::repeat);
constexpr sampler textSampler(filter::linear, mip_filter::linear, address::clamp_to_zero);

constant float HORIZON = 0.80;

static float hash11(float p) { p = fract(p * 0.1031); p *= p + 33.33; p *= p + p; return fract(p); }
static float hash21(float2 p) {
    float3 p3 = fract(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}
static float2 hash22(float2 p) {
    float3 p3 = fract(float3(p.xyx) * float3(0.1031, 0.1030, 0.0973));
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.xx + p3.yz) * p3.zy);
}

static float fbm(texture2d<float> nt, float2 p, int octaves) {
    float v = 0.0, a = 0.5;
    const float2x2 m = float2x2(float2(1.6, 1.2), float2(-1.2, 1.6));
    for (int i = 0; i < octaves; i++) {
        v += a * nt.sample(noiseSampler, p / 64.0).r;
        p = m * p + 7.31;
        a *= 0.5;
    }
    return v;
}

static float3 skyGradient(constant Uniforms &u, float y) {
    float t = clamp(y / (HORIZON + 0.06), 0.0, 1.0);
    float3 c = t < 0.55 ? mix(u.zenith.rgb, u.mid.rgb, t / 0.55)
                        : mix(u.mid.rgb, u.horizon.rgb, (t - 0.55) / 0.45);
    return c;
}

static float luminance(float3 c) { return dot(c, float3(0.2126, 0.7152, 0.0722)); }

// Moonlit cloud tops: a cool grey a little above the night zenith.
static float3 nightBellyTop(constant Uniforms &u) { return u.zenith.rgb * 1.8 + float3(0.06, 0.07, 0.09); }

// Cloud density on a perspective ceiling: rows near the horizon are farther
// away, so the same noise is compressed and drifts slower on screen.
static float cloudField(texture2d<float> nt, float2 uv, float aspect, float t, float wind, float cover, int octaves) {
    // Below the deck's far edge the result is masked to zero; skip the noise.
    float fade = smoothstep(HORIZON + 0.05, HORIZON - 0.08, uv.y);
    if (fade <= 0.0) return 0.0;
    float h = max(0.035, (HORIZON + 0.10) - uv.y);
    float depth = 1.0 / h;
    float2 p = float2((uv.x - 0.5) * aspect * depth, depth * 1.35) * 2.4;
    p.x += t * wind * 0.010;
    p.y += t * 0.004;
    float n = fbm(nt, p, octaves);
    float threshold = mix(0.64, 0.20, cover);
    float d = smoothstep(threshold, threshold + 0.20, n);
    // A closed deck: past ~75 % cover the gaps fill with thinner cloud rather
    // than showing blue sky through a rain sky.
    d = max(d, smoothstep(0.72, 0.97, cover) * (0.62 + 0.38 * smoothstep(0.25, 0.7, n)));
    return d * fade;
}

static float rainLayer(float2 pt, float t, float angle, float cellW, float cellH, float speed,
                       float len, float width, float density, float seed) {
    float cs = cos(angle), sn = sin(angle);
    float2 p = float2(cs * pt.x - sn * pt.y, sn * pt.x + cs * pt.y);
    float col = floor(p.x / cellW);
    float colH = hash11(col * 13.17 + seed);
    p.y -= t * speed * (0.85 + 0.3 * colH);
    p.y += colH * 731.0;
    float2 cell = float2(col, floor(p.y / cellH));
    float h = hash21(cell + seed);
    if (h > density) return 0.0;
    float2 f = float2(p.x / cellW - col, fract(p.y / cellH));
    float x = 0.15 + 0.7 * hash21(cell + seed + 3.7);
    float dx = abs(f.x - x) * cellW;
    float yLen = min(0.95, len / cellH);
    float y0 = hash21(cell + 9.1) * (1.0 - yLen);
    float a = (f.y - y0) / yLen;
    if (a < 0.0 || a > 1.0) return 0.0;
    return smoothstep(width, 0.0, dx) * pow(sin(a * 3.14159), 0.8) * (0.55 + 0.45 * hash21(cell + 2.3));
}

static float snowLayer(float2 pt, float t, float cell, float speed, float size, float blur,
                       float density, float seed, float windX) {
    float2 p = pt;
    p.y -= t * speed;
    p.x -= t * windX;
    float2 id = floor(p / cell);
    float h = hash21(id + seed);
    if (h > density) return 0.0;
    float2 f = fract(p / cell) * cell;
    float2 c = (0.22 + 0.56 * hash22(id + seed)) * cell;
    c.x += sin(t * (0.5 + h) + h * 40.0) * cell * 0.16;
    float r = size * (0.55 + 0.9 * hash21(id + 4.2));
    return smoothstep(r + blur, r * 0.25, length(f - c));
}

// A lightning channel's lateral offset (pt) at height y (pt) and its slope
// dx/dy: straight runs between random kinks, at three scales, which is what
// makes a bolt read as tortuous rather than as a wobbling line.
static float2 zigzag(float y, float seed, float3 period, float3 amp) {
    float2 r = float2(0.0);
    for (int k = 0; k < 3; k++) {
        float s = y / period[k];
        float i = floor(s);
        float a = hash11(i * 7.13 + seed + float(k) * 19.7) - 0.5;
        float b = hash11((i + 1.0) * 7.13 + seed + float(k) * 19.7) - 0.5;
        r.x += mix(a, b, s - i) * amp[k];
        r.y += (b - a) * amp[k] / period[k];
    }
    return r;
}

// Brightness of one channel at `dist` pt (already corrected for its slope):
// a white-hot core of `core` pt, a tight halo, and a wide scattered glow.
static float2 channelLight(float dist, float core) {
    float hot = smoothstep(core, 0.0, dist);
    float halo = exp(-dist / (core * 3.2)) * 0.55 + exp(-dist / 28.0) * 0.16;
    return float2(hot, halo);
}

// x: coverage, y: write time, zw: coverage gradient (points into the glyph).
static float4 greeting(texture2d<float> tt, float2 tuv, float px) {
    float2 base = tt.sample(textSampler, tuv, level(0.0)).rg;
    float a0 = base.x;
    float e = 1.6 * px;
    float l = tt.sample(textSampler, tuv - float2(e, 0), level(1.2)).r;
    float r = tt.sample(textSampler, tuv + float2(e, 0), level(1.2)).r;
    float d = tt.sample(textSampler, tuv - float2(0, e), level(1.2)).r;
    float b = tt.sample(textSampler, tuv + float2(0, e), level(1.2)).r;
    return float4(a0, base.y, r - l, b - d);
}

struct SceneOut { float3 color; float cloud; };

static SceneOut scene(constant Uniforms &u, constant float4 *stars,
                      texture2d<float> nt, texture2d<float> tt, float2 pt) {
    float W = u.resolution.x / u.scale;
    float skyH = u.zenith.a;
    float aspect = W / skyH;
    float t = u.time;
    float night = u.horizon.a;
    float2 par = u.parallax.xy;

    // --- far: sky ---------------------------------------------------------
    float2 uv = float2(pt.x / W, pt.y / skyH);
    float3 c = skyGradient(u, uv.y);

    float2 sunPt = u.sun.xy * float2(W, skyH) + par * 0.05;
    float2 moonPt = u.moon.xy * float2(W, skyH) + par * 0.05;
    bool sunLight = u.sunColor.a > -3.0;
    float2 lightPt = sunLight ? sunPt : moonPt;
    float3 lightCol = sunLight ? u.sunColor.rgb : float3(0.78, 0.84, 1.0) * 0.55;
    float lightVis = sunLight ? u.sun.w : u.moon.w * 0.6;

    // Horizon scattering under the sun (or moon), strongest in twilight.
    float2 gc = float2(u.sun.x, HORIZON + 0.02);
    float2 gd = (uv - gc) * float2(aspect * 0.42, 2.1);
    c += u.glow.rgb * u.glow.a * exp(-dot(gd, gd) * 1.6);
    // Sky brightens gently toward the light source (Mie forward lobe).
    float ld = length(pt - lightPt);
    c += lightCol * lightVis * (0.18 * exp(-ld / 140.0) + 0.08 * exp(-ld / 420.0));

    // --- stars --------------------------------------------------------------
    float3 bodies = float3(0);
    float starVis = u.sky.y * smoothstep(HORIZON, HORIZON - 0.25, uv.y);
    if (starVis > 0.001) {
        float2 sp = pt + par * 0.05;
        int count = int(u.sky.w);
        for (int i = 0; i < count; i++) {
            float4 s = stars[i];
            float2 d = sp - s.xy * float2(W, skyH);
            // Past 24 pt both the core and the spikes are under 1/255: every
            // pixel visits every star, so the far ones must cost a compare.
            if (abs(d.x) > 24.0 || abs(d.y) > 24.0) continue;
            float r = s.z * 0.8;
            float tw = fract(s.w * 7.13) > 0.86 ? (0.72 + 0.28 * sin(t * (0.8 + fract(s.w) * 1.6) + s.w * 20.0)) : 1.0;
            float core = exp(-dot(d, d) / (r * r * 0.6));
            float spike = (exp(-abs(d.x) * 1.4) * exp(-abs(d.y) * 0.22) + exp(-abs(d.y) * 1.4) * exp(-abs(d.x) * 0.22)) * step(1.3, s.z) * 0.16;
            bodies += float3(0.92, 0.95, 1.0) * (core + spike) * tw;
        }
        float2 fp = (sp + float2(u.sky.z * W * 1.4, 0)) / 11.0;
        float2 id = floor(fp);
        float h = hash21(id);
        if (h > 0.84) {
            float2 o = hash22(id + 3.1) * 0.8 + 0.1;
            float dd = length(fract(fp) - o) * 11.0;
            float rr = 0.35 + 0.55 * hash21(id + 8.0);
            float tw = 0.65 + 0.35 * sin(t * (0.6 + h * 2.0) + h * 50.0);
            bodies += float3(0.85, 0.9, 1.0) * smoothstep(rr + 0.6, 0.0, dd) * (h - 0.84) * 4.0 * mix(1.0, tw, step(0.97, h));
        }
        bodies *= starVis;
    }

    // --- moon ----------------------------------------------------------------
    if (u.moon.w > 0.001) {
        float2 mp = (pt - moonPt) / u.moon.z;
        float r2 = dot(mp, mp);
        float ang = u.sky.x * 6.28318;
        float3 L = float3(sin(ang), 0.0, -cos(ang));
        float illum = 0.5 - 0.5 * cos(ang);
        float3 mcol = mix(float3(1.0, 0.91, 0.76), float3(0.96, 0.97, 1.0), smoothstep(HORIZON - 0.05, HORIZON - 0.3, u.moon.y));
        if (r2 < 1.0) {
            float3 n = float3(mp.x, -mp.y, sqrt(1.0 - r2));
            float lit = smoothstep(-0.06, 0.1, dot(n, L));
            float maria = 0.78 + 0.22 * fbm(nt, mp * 3.0 + 17.0, 3) * 1.4;
            float edge = smoothstep(1.0, 0.93, r2);
            float3 disc = mcol * (0.05 + lit * maria * (0.75 + 0.25 * n.z));
            c = mix(c, c * 0.35 + disc, edge * u.moon.w * mix(0.55, 1.0, night));
            bodies *= 1.0 - edge;
        }
        float halo = exp(-max(0.0, sqrt(r2) - 1.0) * 1.3) * (0.1 + 0.25 * illum);
        c += mcol * halo * u.moon.w * 0.5 * step(1.0, r2);
    }

    // --- sun -------------------------------------------------------------------
    if (u.sun.w > 0.001) {
        float d = length(pt - sunPt);
        float r = u.sun.z;
        float disc = smoothstep(r, r * 0.86, d);
        float3 core = mix(u.sunColor.rgb, float3(1.0, 0.99, 0.95), 0.45);
        float limb = 1.0 - 0.25 * pow(clamp(d / r, 0.0, 1.0), 3.0);
        bodies += core * disc * 1.15 * limb + u.sunColor.rgb * (0.42 * exp(-d / (r * 1.5)) + 0.18 * exp(-d / (r * 7.0)));
        bodies *= u.sun.w;
    }
    c += bodies;

    // --- cirrus ----------------------------------------------------------------
    float2 cp = pt + par * 0.12;
    float2 cuv = float2(cp.x / W, cp.y / skyH);
    float cirrusBand = smoothstep(HORIZON, 0.2, cuv.y);
    float cir = cirrusBand > 0.0 ? fbm(nt, float2(cuv.x * aspect * 3.2 + t * u.cloud.z * 0.0015, cuv.y * 11.0), 4) : 0.0;
    float wisp = smoothstep(0.52, 0.78, cir) * (1.0 - u.cloud.x * 0.7) * cirrusBand;
    float3 wispCol = mix(skyGradient(u, cuv.y) * 1.25 + 0.08, lightCol, 0.25 * lightVis);
    c = mix(c, wispCol, wisp * 0.42 * (1.0 - night * 0.6));

    // --- volumetric cloud deck -----------------------------------------------
    float2 kp = pt + par * 0.25;
    float2 kuv = float2(kp.x / W, kp.y / skyH);
    float wind = u.cloud.z;
    float dens = cloudField(nt, kuv, aspect, t, wind, u.cloud.x, 5);
    float alpha = 0.0;
    if (dens > 0.002) {
        float2 dir = normalize(lightPt - kp + float2(0.001, 0.001));
        float tau = 0.0;
        for (int i = 1; i <= 4; i++) {
            float2 q = kp + dir * float(i * i) * 7.0;
            tau += cloudField(nt, float2(q.x / W, q.y / skyH), aspect, t, wind, u.cloud.x, 3);
        }
        float T = exp(-tau * 0.42);
        float powder = 1.0 - exp(-dens * 2.5);
        float bright = mix(1.0, 0.2, night);
        float storm = u.cloud.y;
        // Sunlit crown and a sky-lit, bluish shadow side; storm decks lose both.
        float3 crown = mix(mix(float3(1.0, 0.99, 0.97), lightCol, 0.3) * bright, nightBellyTop(u), night * 0.6) * (1.0 - storm * 0.55);
        float3 dayBelly = mix(skyGradient(u, kuv.y) * 0.9, float3(0.58, 0.63, 0.72), 0.45);
        float3 nightBelly = skyGradient(u, kuv.y) * 1.3 + float3(0.02, 0.025, 0.035);
        float3 belly = mix(dayBelly, nightBelly, night) * (1.0 - storm * 0.6);
        float shadeT = clamp(T * 0.85 + (1.0 - dens) * 0.35, 0.0, 1.0);
        float3 cc = mix(belly, crown, shadeT * mix(1.0, 0.55, storm));
        cc += lightCol * lightVis * T * powder * 0.25 * (1.0 - night * 0.6);
        float prox = exp(-length(kp - lightPt) / 170.0);
        float silver = prox * smoothstep(0.0, 0.35, dens) * (1.0 - dens) * 3.2 * lightVis;
        cc += lightCol * silver;
        float haze = smoothstep(HORIZON - 0.25, HORIZON, kuv.y);
        cc = mix(cc, skyGradient(u, kuv.y) * 1.02, haze * 0.65);
        alpha = dens * mix(0.9, 1.0, u.cloud.x);
        c = mix(c, cc, alpha);
    }

    // Lightning lights the deck from inside, brightest around the strike and
    // most where the cloud is thick; the open sky only brightens a little.
    if (u.flash.x > 0.001) {
        float cy = 0.14 + fract(u.flash.z * 0.371) * 0.16;
        float2 off = float2((uv.x - u.flash.y) * aspect, (uv.y - cy) * 1.6);
        float near = exp(-length(off) * 1.9);
        float lit = 0.08 + alpha * (0.2 + 1.1 * near) * (0.6 + 0.4 * dens);
        c += float3(0.70, 0.74, 1.0) * u.flash.x * lit;
    }

    // --- fog -----------------------------------------------------------------
    if (u.precip.z > 0.001) {
        float2 fp = float2(uv.x * aspect * 1.4 + t * 0.012, uv.y * 3.2);
        float n = fbm(nt, fp * 2.0, 3);
        float depthFog = smoothstep(0.05, HORIZON + 0.05, uv.y);
        float fogD = u.precip.z * (0.25 + 0.75 * depthFog) * (0.7 + 0.6 * n);
        float3 fogCol = mix(u.horizon.rgb, float3(0.86, 0.88, 0.9) * mix(1.0, 0.3, night), 0.35);
        c = mix(c, fogCol, clamp(fogD * 0.72, 0.0, 0.92));
    }

    // --- far precipitation ---------------------------------------------------
    float slant = u.cloud.w;
    float3 dropCol = mix(float3(0.80, 0.86, 0.94), float3(0.55, 0.62, 0.75), night);
    if (u.precip.x > 0.001) {
        float2 rp = pt + par * 0.35;
        float r = rainLayer(rp, t, slant, 7.0, 90.0, 520.0, 16.0, 0.55, u.precip.x * 0.55, 1.0)
                + rainLayer(rp, t, slant, 11.0, 130.0, 700.0, 24.0, 0.7, u.precip.x * 0.45, 7.0);
        c += dropCol * r * 0.26;
        c = mix(c, c * 0.9 + skyGradient(u, HORIZON) * 0.1, u.precip.x * 0.4);
    }
    if (u.precip.y > 0.001) {
        float2 sp = pt + par * 0.3;
        float s = snowLayer(sp, t, 22.0, 16.0, 0.9, 0.6, u.precip.y * 0.55, 3.0, 4.0)
                + snowLayer(sp, t, 34.0, 28.0, 1.5, 0.8, u.precip.y * 0.5, 9.0, 7.0);
        c = mix(c, float3(0.97, 0.98, 1.0) * mix(1.0, 0.7, night), clamp(s, 0.0, 1.0) * 0.75);
    }

    // --- lightning bolt --------------------------------------------------------
    // Cloud base to ground: a main channel of straight runs between kinks at
    // three scales, a few tapering branches forking down and out from it, a
    // white-hot core inside a violet halo, and a glow where it meets the
    // ground. Only pixels in the strike's column do the work.
    if (u.flash.w > 0.01) {
        float seed = u.flash.z;
        float top = (0.10 + fract(seed * 0.371) * 0.08) * skyH;
        float ground = (HORIZON + 0.03) * skyH;
        float x0 = u.flash.y * W;
        float lean = (hash11(seed * 3.1) - 0.5) * 0.5;
        if (abs(pt.x - x0) < 0.45 * skyH + 60.0 && pt.y > top - 4.0 && pt.y < ground + 24.0) {
            float3 period = float3(46.0, 15.0, 4.5);
            float3 amp = float3(58.0, 16.0, 4.0);
            float hot = 0.0, halo = 0.0;
            float y = clamp(pt.y, top, ground);
            float2 z = zigzag(y - top, seed, period, amp);
            float mainX = x0 + (y - top) * lean + z.x;
            float slopeMain = lean + z.y;
            float d = length(float2(pt.x - mainX, pt.y - y)) / sqrt(1.0 + slopeMain * slopeMain);
            float2 l = channelLight(d, 1.5);
            float taper = smoothstep(top - 2.0, top + 26.0, pt.y);
            hot += l.x * taper;
            halo += l.y * taper;

            int branches = 3 + int(hash11(seed * 5.3) * 3.0);
            for (int b = 0; b < 5; b++) {
                if (b >= branches) break;
                float hb = float(b) + seed * 1.7;
                float span = ground - top;
                float y0 = top + (0.12 + 0.62 * hash11(hb * 2.3)) * span;
                float len = (0.12 + 0.26 * hash11(hb * 4.1)) * span;
                if (pt.y < y0 - 3.0 || pt.y > y0 + len + 3.0) continue;
                float side = hash11(hb * 6.7) > 0.5 ? 1.0 : -1.0;
                float blean = side * (0.35 + 0.9 * hash11(hb * 8.9));
                float2 zb0 = zigzag(y0 - top, seed, period, amp);
                float bx0 = x0 + (y0 - top) * lean + zb0.x;
                float yy = clamp(pt.y, y0, y0 + len);
                float2 zb = zigzag(yy - y0, seed + hb * 13.0, float3(22.0, 7.0, 2.6), float3(20.0, 6.0, 2.0));
                float bx = bx0 + (yy - y0) * blean + zb.x;
                float slope = blean + zb.y;
                float bd = length(float2(pt.x - bx, pt.y - yy)) / sqrt(1.0 + slope * slope);
                // Clamped: at the tip rounding can put `along` a hair past 1,
                // and pow() of a negative base is NaN (a black scanline).
                float along = saturate((yy - y0) / len);
                float fadeB = pow(1.0 - along, 1.6) * (0.4 + 0.35 * hash11(hb * 3.3));
                float2 lb = channelLight(bd, 0.9);
                hot += lb.x * fadeB;
                halo += lb.y * fadeB * 0.8;
            }

            float groundGlow = exp(-length(float2(pt.x - mainX, (pt.y - ground) * 2.2)) / 22.0)
                             * smoothstep(ground - 60.0, ground, pt.y);
            float3 core = float3(1.0, 0.98, 1.0);
            float3 violet = float3(0.66, 0.66, 1.0);
            float below = smoothstep(ground + 24.0, ground, pt.y);
            c += (core * min(1.0, hot) * 1.6 + violet * halo * 0.9 + violet * groundGlow * 0.5) * u.flash.w * below;
        }
    }

    // --- rainbow -----------------------------------------------------------------
    if (u.effects.z > 0.001) {
        float2 anti = float2(1.0 - u.sun.x, HORIZON + u.sunColor.a / 90.0 * 0.72);
        float2 dd = float2((uv.x - anti.x) * 220.0, (uv.y - anti.y) / 0.72 * 90.0);
        float rr = length(dd);
        float band = (rr - 40.3) / 2.4;
        if (band > 0.0 && band < 1.0 && uv.y < HORIZON) {
            float3 rb = clamp(abs(fmod(band * 6.0 * 0.83 + float3(0.0, 4.0, 2.0), 6.0) - 3.0) - 1.0, 0.0, 1.0);
            float env = sin(band * 3.14159) * smoothstep(HORIZON, HORIZON - 0.2, uv.y);
            c += rb * env * 0.22 * u.effects.z;
        }
    }

    // --- meteor -------------------------------------------------------------------
    if (u.meteorInfo.x >= 0.0 && u.meteorInfo.x <= 1.0) {
        float2 a = u.meteor.xy * float2(W, skyH), b = u.meteor.zw * float2(W, skyH);
        float2 head = mix(a, b, u.meteorInfo.x);
        float2 dir = normalize(b - a);
        float2 tail = head - dir * 90.0;
        float2 pa = pt - tail, ba = head - tail;
        float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
        float d = length(pa - ba * h);
        float env = sin(u.meteorInfo.x * 3.14159) * u.meteorInfo.y;
        c += float3(0.9, 0.95, 1.0) * smoothstep(1.2, 0.0, d) * h * h * env;
    }

    // --- greeting ------------------------------------------------------------------
    float4 tr = u.textRect;
    float2 tp = pt - par * 0.4;
    float2 tuv = (tp - tr.xy) / tr.zw;
    if (tr.z > 1.0 && tuv.x > -0.02 && tuv.x < 1.02 && tuv.y > -0.02 && tuv.y < 1.02) {
        float pxu = 1.0 / (tr.z * u.scale);
        float4 g = greeting(tt, tuv, pxu);
        // The pen: ink whose write time is behind the reveal is on the page.
        // Ink just behind the nib is still wet — brighter, fading as it dries.
        // The edge is soft (about 2 % of the line) and the reveal overshoots it
        // at both ends, so the first letter starts from nothing and the last
        // settles fully.
        float reveal = u.textStyle.x;
        float front = reveal * 1.04 - 0.02;
        float written = reveal >= 1.0 ? 1.0 : smoothstep(front + 0.02, front - 0.02, g.y);
        float wet = reveal >= 1.0 ? 0.0 : exp(-max(0.0, front - g.y) * 30.0) * written;
        // The pool of shade and the glow build with the line, not ahead of it.
        float wipe = smoothstep(0.0, 0.7, reveal);
        float aGlow = tt.sample(textSampler, tuv, level(5.0)).r;
        float aShadow = tt.sample(textSampler, tuv - float2(0.0, 9.0 / tr.w), level(4.0)).r;
        float a = g.x * written;
        float darkInk = u.textStyle.w;
        float lum = luminance(c);
        // Against the sun disc or its bloom the white glass has nothing to read against.
        float glare = u.sun.w * smoothstep(u.sun.z * 6.0, u.sun.z * 1.2, length(tp - sunPt))
                    * smoothstep(0.45, 0.85, lum) * (1.0 - darkInk);
        // Legibility: a soft pool of shade behind the glyphs, deeper on bright skies.
        float shadeAmt = mix(0.18 + 0.35 * smoothstep(0.25, 0.6, lum) + 0.2 * glare, 0.0, darkInk);
        c *= 1.0 - (aShadow * 0.55 + aGlow * 0.45) * shadeAmt * wipe;
        c += u.glow.rgb * aGlow * u.textStyle.z * (1.0 - darkInk) * wipe;

        float2 grad = g.zw;
        float gl = length(grad);
        float2 nrm = gl > 1e-4 ? -grad / gl : float2(0);
        float2 toLight = normalize(lightPt - tp + float2(0.001, 0.0));
        float edge = clamp(gl * 2.2, 0.0, 1.0);
        float3 refr = skyGradient(u, clamp(uv.y + nrm.y * 0.08, 0.0, 1.0));
        float3 inkLight = mix(float3(1.0, 0.985, 0.96), float3(0.93, 0.95, 1.0), night);
        // A monoline stroke is only a few pixels across, so it is ink with a
        // breath of the sky in it, not glass: at the old 36 % refraction the
        // rim covered the whole stroke and the line read as a hollow tube.
        float3 glass = mix(refr * 1.15 + 0.1, inkLight, 0.9);
        glass *= mix(1.0, 0.94, clamp(tuv.y * 1.3 - 0.2, 0.0, 1.0));
        glass *= 1.0 - alpha * 0.10;
        float3 inkDark = mix(float3(0.08, 0.12, 0.2), refr * 0.35, 0.25);
        glass = mix(glass, glass * float3(0.74, 0.79, 0.88), glare);
        float3 fill = mix(glass, inkDark, darkInk);
        c = mix(c, fill, a);
        c *= 1.0 - edge * a * (1.0 - a) * 4.0 * glare * 0.45;
        float rim = clamp(dot(nrm, toLight), 0.0, 1.0) * edge * a;
        float3 rimCol = sunLight ? mix(u.sunColor.rgb, float3(1.0), 0.35) : float3(0.8, 0.86, 1.0);
        c += rimCol * rim * u.textStyle.y * mix(0.3, 0.15, darkInk);
        float3 nib = mix(mix(u.sunColor.rgb, float3(1.0), 0.55), float3(0.86, 0.92, 1.0), night);
        c += nib * wet * a * mix(0.55, 0.2, darkInk);
    }

    // --- near precipitation (in front of the greeting) ----------------------------
    if (u.precip.x > 0.001) {
        float2 rp = pt + par * 0.7;
        float r = rainLayer(rp, t, slant * 1.15, 26.0, 260.0, 1100.0, 46.0, 1.6, u.precip.x * 0.32, 13.0);
        c += dropCol * r * 0.20;
    }
    if (u.precip.y > 0.001) {
        float2 sp = pt + par * 0.75;
        float s = snowLayer(sp, t, 70.0, 46.0, 3.2, 2.6, u.precip.y * 0.3, 21.0, 11.0);
        c = mix(c, float3(1.0), clamp(s, 0.0, 1.0) * 0.6 * mix(1.0, 0.7, night));
    }
    if (u.effects.y > 0.5) {
        float2 hp = pt + par * 0.6;
        float hl = snowLayer(hp, t * 5.0, 40.0, 150.0, 1.2, 0.4, 0.35, 31.0, 20.0);
        c = mix(c, float3(0.95), clamp(hl, 0.0, 1.0) * 0.7);
    }

    SceneOut o;
    o.color = c;
    o.cloud = alpha;
    return o;
}

// A bead of water seen against light: a dark meniscus at the rim (heavier on
// top, where it faces away from the light), a bright caustic crescent low
// inside, and a pin highlight up and to the left.
static float dropShade(float2 n, float m) {
    float l = length(n);
    float rim = smoothstep(0.62, 1.0, l) * (0.55 + 0.45 * smoothstep(0.4, -0.8, n.y));
    float caustic = smoothstep(0.35, 0.85, l) * smoothstep(0.2, 0.85, n.y) * smoothstep(1.0, 0.85, l);
    float2 hs = n - float2(-0.32, -0.4);
    float spec = exp(-dot(hs, hs) * 26.0);
    return (spec * 0.65 + caustic * 0.16 - rim * 0.3) * m;
}

// Drops on the card's glass. Returns (offset pt, mask, shading).
static float4 glassDrops(float2 pt, float t, float amount, float H, float4 pointer) {
    float4 res = float4(0);
    if (amount <= 0.001) return res;
    float wipe = 1.0;
    if (pointer.z > 0.5) wipe = smoothstep(36.0, 80.0, length(pt - pointer.xy));

    // Static drops that bead, sit, and evaporate.
    float cell = 34.0;
    float2 id = floor(pt / cell);
    float h = hash21(id * 1.7 + 0.3);
    if (h < amount * 0.62) {
        float life = fract(t * (0.035 + 0.03 * h) + h * 11.0);
        float grow = smoothstep(0.0, 0.04, life) * smoothstep(1.0, 0.75, life);
        float2 ctr = (id + 0.2 + 0.6 * hash22(id + 5.0)) * cell;
        float r = (1.6 + 4.4 * pow(hash21(id + 2.0), 2.0)) * grow;
        float2 n = (pt - ctr) / max(r, 0.01);
        float l = length(n);
        if (l < 1.0 && r > 0.3) {
            float m = smoothstep(1.0, 0.82, l) * wipe;
            res.xy = -n * r * 2.6 * m;
            res.z = m;
            res.w = dropShade(n, m);
        }
    }
    // Sliding drops, one per lane, each with a thin wet trail.
    float lane = 64.0;
    float col = floor(pt.x / lane);
    float lh = hash11(col * 3.3 + 1.7);
    if (lh < amount * 0.4) {
        float speed = 18.0 + 30.0 * lh;
        float cycle = H + 160.0;
        float y = fmod(t * speed + lh * 997.0, cycle) - 60.0;
        float x = (col + 0.5) * lane + sin(y * 0.045 + lh * 9.0) * 7.0;
        float r = 4.2 + 2.2 * lh;
        float2 n = (pt - float2(x, y)) / r;
        n.y *= 0.85;
        float l = length(n);
        if (l < 1.0) {
            float m = smoothstep(1.0, 0.8, l) * wipe;
            res.xy = -n * r * 2.8 * m;
            res.z = max(res.z, m);
            res.w = dropShade(n, m);
        } else {
            float above = y - pt.y;
            float tx = abs(pt.x - (col + 0.5) * lane - sin(pt.y * 0.045 + lh * 9.0) * 7.0);
            if (above > 0.0 && above < 120.0 && tx < r * 0.45) {
                float m = (1.0 - above / 120.0) * smoothstep(r * 0.45, 0.0, tx) * 0.5 * wipe;
                res.x += (pt.x > x ? -1.0 : 1.0) * m * 1.5;
                res.z = max(res.z, m * 0.3);
            }
        }
    }
    return res;
}

fragment float4 atmosphere_fragment(VOut in [[stage_in]],
                                    constant Uniforms &u [[buffer(0)]],
                                    constant float4 *stars [[buffer(1)]],
                                    texture2d<float> noiseTex [[texture(0)]],
                                    texture2d<float> textTex [[texture(1)]]) {
    float2 pt = in.position.xy / u.scale;
    float W = u.resolution.x / u.scale;
    float Hc = u.resolution.y / u.scale;

    float2 offset = float2(0);
    float3 extra = float3(0);

    // Click ripple: a ring of light that bends what is behind it.
    if (u.ripple.z >= 0.0 && u.ripple.z < 1.1) {
        float age = u.ripple.z;
        float2 d = pt - u.ripple.xy;
        float dist = length(d);
        float R = age * 300.0;
        float ring = exp(-pow((dist - R) / 16.0, 2.0)) * pow(1.0 - age / 1.1, 2.0);
        offset += (dist > 0.001 ? d / dist : float2(0)) * ring * 7.0;
        float3 rc = u.ripple.w < 0.5 ? mix(u.sunColor.rgb, float3(1.0), 0.4) : float3(0.8, 0.88, 1.0);
        extra += rc * ring * 0.16;
    }

    float4 drop = glassDrops(pt, u.time, u.effects.x, Hc, u.pointer);
    offset += drop.xy;

    SceneOut s = scene(u, stars, noiseTex, textTex, pt + offset);
    float3 c = s.color;
    if (drop.z > 0.001) {
        c = mix(c, c * 1.1 + 0.025, drop.z * 0.6);
        c += drop.w;
    }
    c += extra;

    // Soft vignette, a deeper floor under the glass sill, appearance and entrance.
    float2 v = (pt / float2(W, Hc) - 0.5) * float2(1.0, 1.25);
    c *= 1.0 - 0.14 * pow(length(v) * 1.2, 2.4);
    c *= mix(1.0, 0.8, smoothstep(u.zenith.a * 0.9, Hc, pt.y));
    c *= u.mid.a * mix(1.0, 0.88, u.parallax.z);
    c *= mix(0.3, 1.0, u.effects.w);

    // Keep highlights from clipping, then dither to hide gradient banding.
    c = select(c, 0.82 + (1.0 - exp(-(c - 0.82) * 5.5)) * 0.18, c > 0.82);
    c += (hash21(in.position.xy + fract(u.time) * 17.0) - 0.5) / 255.0;
    return float4(clamp(c, 0.0, 1.0), 1.0);
}
"""#
}
