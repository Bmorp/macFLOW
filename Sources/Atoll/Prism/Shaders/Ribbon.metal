// Ribbon numerals: the time as about a thousand vertical glass strips, one column per pitch, each column cut into at
// most four runs where the glyphs cover it (PrismStage.swift). When a digit changes every run springs from where it
// was to where it goes — evaluated here in closed form, so the CPU uploads once per change and then only a clock.
#include <metal_stdlib>
#include "PrismOptics.h"

using namespace metal;

/// Matches `RibbonUniforms` in PrismStage.swift (all 4-byte fields, then a float4 pair; 16-byte aligned).
struct RibbonUniforms {
    float2 viewport;     // points
    float scale;         // device pixels per point
    float time;          // seconds since the change began
    float pitch;
    float lens;
    float depth;         // how far the backdrop shifts through a strip's tilt, points
    float disperse;
    float spec;
    float sparks;
    float seed;
    float omega;         // spring: natural frequency (rad/s)
    float zeta;          // spring: damping ratio
    float lag;           // the foot of each run follows its top by this much (s)
    float curl;          // the rolled end's length, points
    float fade;          // Reduce Motion: cross-fade progress 0…1
    float top;           // the numerals' top and foot, for the light's ramp
    float foot;
    uint flags;
    float sparkMotion;   // 0 at rest; >0 while a change is in flight (sparks run along their strip)
    float4 tint;         // light tint (white: none), alpha = strength
    float4 backdrop;     // where the backdrop texture lies on the canvas: origin and size, points
};

constant uint SAMPLE_BACKDROP = 1u;
constant uint DISPERSE = 2u;
constant uint NIGHT = 4u;
constant uint CONTRAST = 8u;

/// One run of one column: where it was (a) and where it's going (b). The top and foot are where the outline crosses
/// the middle of the column; each end is a straight cut through that point, `t0`/`t1` points higher at the right edge
/// than at the left, and `l`…`r` (0…1 across the column) is the stretch the glyph covers. Matches `RibbonStrip`.
struct Strip {
    float x;
    float y0a, y1a;
    float y0b, y1b;
    float t0a, t1a;
    float t0b, t1b;
    float la, ra;
    float lb, rb;
    float delay;
    float phase;         // cross-fade: 0 the old run, 1 the new one; 2 a spring morph
    float index;         // the column, for its hash
};

struct RibbonOut {
    float4 position [[position]];
    float2 pos;          // canvas point
    float s;             // −1…1 across the strip (a little beyond, for antialiasing)
    float y0 [[flat]];
    float y1 [[flat]];
    float t0 [[flat]];
    float t1 [[flat]];
    float l [[flat]];
    float r [[flat]];
    float tail [[flat]];
    float index [[flat]];
    float alpha [[flat]];
};

/// A unit spring released from 1 toward 0 at t = 0, as progress 0 → 1 (it overshoots a little when underdamped).
/// Within 0.2 % of rest it is at rest, exactly (RibbonSpring.progress does the same).
static inline float springProgress(float t, float omega, float zeta) {
    if (t <= 0.0) return 0.0;
    float z = min(zeta, 0.999);
    if (t >= -log(0.002 * sqrt(1.0 - z * z)) / (z * omega)) return 1.0;
    float x;
    if (zeta < 1.0) {
        float wd = omega * sqrt(1.0 - zeta * zeta);
        x = exp(-zeta * omega * t) * (cos(wd * t) + (zeta * omega / wd) * sin(wd * t));
    } else {
        x = (1.0 + omega * t) * exp(-omega * t);
    }
    return 1.0 - x;
}

vertex RibbonOut ribbonVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                              constant RibbonUniforms& U [[buffer(0)]],
                              const device Strip* strips [[buffer(1)]]) {
    Strip st = strips[iid];
    float y0, y1, t0, t1, l, r, alpha = 1.0;
    if (st.phase < 1.5) {
        bool fresh = st.phase > 0.5;
        y0 = fresh ? st.y0b : st.y0a;
        y1 = fresh ? st.y1b : st.y1a;
        t0 = fresh ? st.t0b : st.t0a;
        t1 = fresh ? st.t1b : st.t1a;
        l = fresh ? st.lb : st.la;
        r = fresh ? st.rb : st.ra;
        alpha = fresh ? U.fade : 1.0 - U.fade;
    } else {
        float p0 = springProgress(U.time - st.delay, U.omega, U.zeta);
        float p1 = springProgress(U.time - st.delay - U.lag, U.omega, U.zeta);
        y0 = mix(st.y0a, st.y0b, p0);
        y1 = mix(st.y1a, st.y1b, p1);
        t0 = mix(st.t0a, st.t0b, p0);
        t1 = mix(st.t1a, st.t1b, p1);
        l = mix(st.la, st.lb, p0);
        r = mix(st.ra, st.rb, p0);
    }
    // Rare strips trail a hairline below their foot while a change is in flight, as ribbons do when they unroll; at
    // rest the figures keep a clean silhouette.
    float h = prism::stripHash(st.index, U.seed + 31.0);
    float tail = h > 0.975 ? U.sparkMotion * U.pitch * (1.5 + 4.0 * (h - 0.975) / 0.025) : 0.0;
    // Length of the strip at each side of what it covers; nothing to draw when neither has any.
    float lenL = (y1 - y0) + (t1 - t0) * (l - 0.5), lenR = (y1 - y0) + (t1 - t0) * (r - 0.5);
    bool drawn = max(lenL, lenR) >= 0.01 && r - l >= 0.01;
    float pad = 1.5 / U.scale;
    float2 corner = float2(vid & 1u, vid >> 1u);
    float x = st.x + (corner.x - 0.5) * (U.pitch + 2.0 * pad);
    // The quad holds both slanted ends, and a little more where a steep cut needs a wider band to antialias in.
    float ua = max(l - 0.02, 0.0) - 0.5, ub = min(r + 0.02, 1.0) - 0.5;
    float top = min(y0 + t0 * ua, y0 + t0 * ub);
    float foot = max(y1 + t1 * ua, y1 + t1 * ub);
    float yTop = top - pad * sqrt(1.0 + (t0 / U.pitch) * (t0 / U.pitch));
    float yFoot = foot + tail + pad * sqrt(1.0 + (t1 / U.pitch) * (t1 / U.pitch));
    float y = mix(yTop, yFoot, corner.y);
    if (!drawn) { x = st.x; y = y0; }   // nothing to draw: a zero-area quad
    RibbonOut o;
    o.position = float4(x / U.viewport.x * 2.0 - 1.0, 1.0 - y / U.viewport.y * 2.0, 0.0, 1.0);
    o.pos = float2(x, y);
    o.s = (x - st.x) / (0.5 * U.pitch);
    o.y0 = y0;
    o.y1 = y1;
    o.t0 = t0;
    o.t1 = t1;
    o.l = l;
    o.r = r;
    o.tail = tail;
    o.index = st.index;
    o.alpha = alpha;
    return o;
}

fragment float4 ribbonFragment(RibbonOut in [[stage_in]],
                               constant RibbonUniforms& U [[buffer(0)]],
                               texture2d<float> backdrop [[texture(0)]]) {
    float px = 1.0 / U.scale;
    float y = in.pos.y;
    float len = (in.y1 - in.y0) + (in.t1 - in.t0) * (0.5 * (in.l + in.r) - 0.5);   // what the glyph covers, mid-way
    float s = clamp(in.s, -1.0, 1.0);
    // Where across the column this pixel is (0 left edge, 1 right) and where the two cut ends run through it: straight
    // lines, so the silhouette follows the outline's own slope instead of stepping.
    float u = 0.5 + 0.5 * in.s;
    float yTop = in.y0 + in.t0 * (u - 0.5), yFoot = in.y1 + in.t1 * (u - 0.5);
    // Distance from each cut, perpendicular to it (a steep cut would otherwise antialias over many rows).
    float dTop = (y - yTop) * rsqrt(1.0 + (in.t0 / U.pitch) * (in.t0 / U.pitch));
    float dFoot = (yFoot - y) * rsqrt(1.0 + (in.t1 / U.pitch) * (in.t1 / U.pitch));
    // Coverage is the area the strip fills of this pixel: both cuts at once (the sum, less one, so a run shorter
    // than a pixel is a faint line and a run of no length is nothing), then the strip's own sides, and the stretch
    // the glyph covers where it ends inside the column.
    float vertical = saturate(saturate(dTop / px + 0.5) + saturate(dFoot / px + 0.5) - 1.0);
    float across = saturate((1.0 - abs(in.s)) * 0.5 * U.pitch / px + 0.5);
    float reach = (in.l > 0.001 ? saturate((u - in.l) * U.pitch / px + 0.5) : 1.0) * (in.r < 0.999 ? saturate((in.r - u) * U.pitch / px + 0.5) : 1.0);
    float cover = vertical * across * reach;

    float3 col;
    float alpha;
    if (y > yFoot && in.tail > 0.0) {
        // The hairline tail: one device pixel wide, fading over its length.
        float d = (s - 0.35) * 0.5 * U.pitch / px;
        float fadeOut = 1.0 - saturate((y - yFoot) / in.tail);
        alpha = exp(-0.5 * d * d) * fadeOut * fadeOut * 0.85 * in.alpha;
        col = mix(prism::STEEL, prism::WHITE, 0.35);
    } else {
        prism::Flute f = prism::flute((s + 1.0) * 0.5 * U.pitch, U.pitch, U.lens);
        // The rolled ends, faked over `curl`: the surface turns toward the light at the top (a highlight band, then
        // the darker underside as it rolls over) and away from it at the foot.
        float c = max(min(U.curl, 0.5 * len), 1e-3);
        float uTop = saturate(1.0 - dTop / c);
        float uFoot = saturate(1.0 - dFoot / c);
        float th = 2.0 * (uTop * uTop) - 1.6 * (uFoot * uFoot);
        float3 n = normalize(float3(f.n.x, -sin(th), f.n.z * cos(th)));
        float t = (y - U.top) / max(U.foot - U.top, 1.0);
        float3 light = prism::ramp(t) * mix(float3(1.0), U.tint.rgb, U.tint.a);
        // Each strip catches its own share of the light, as cut glass does; its body is brightest where it faces
        // the light and falls off into a groove at each edge.
        float own = 0.86 + 0.2 * prism::stripHash(in.index, U.seed + 11.0);
        float body = prism::diffuse(n) / 0.82;
        float groove = 1.0 - 0.5 * pow(abs(s), 5.0);
        col = light * body * groove * own * 0.92;
        if ((U.flags & SAMPLE_BACKDROP) != 0u) {
            // What's behind the glass, bent by the strip's tilt; red and blue split apart toward the edges. The glass
            // adds its colour to the light it catches, so the figures stay legible on any picture.
            float2 off = float2(U.depth * n.x, U.depth * n.y * 0.5);
            float2 uv = (in.pos - U.backdrop.xy) / U.backdrop.zw;
            float2 du = off / U.backdrop.zw;
            constexpr sampler lin(filter::linear, address::clamp_to_edge);
            float3 b;
            if ((U.flags & DISPERSE) != 0u) {
                float d = 1.0 + U.disperse * prism::DISPERSION * 6.0 * abs(s);
                b = float3(backdrop.sample(lin, uv + du * (2.0 - d)).r, backdrop.sample(lin, uv + du).g, backdrop.sample(lin, uv + du * d).b);
            } else {
                b = backdrop.sample(lin, uv + du).rgb;
            }
            float through = (U.flags & CONTRAST) != 0u ? 0.2 : 0.42;
            col = col * (1.0 - 0.3 * through) + b * through * groove;
        }
        // The underside of the roll is steel, deeper than the face.
        float under = saturate(-cos(th));
        col = mix(col, prism::STEEL_DEEP, under * 0.85);
        col += 1.6 * U.spec * prism::ridge(n) * (1.0 - under);
        // The top of the roll catches the light as a band.
        col += 0.45 * U.spec * smoothstep(0.5, 0.8, uTop) * (1.0 - smoothstep(0.88, 1.0, uTop));
        if (prism::hasSpark(in.index, U.seed, U.sparks)) {
            float run = 1.0;
            if (U.sparkMotion > 0.0) run = mix(1.0, 0.45 + 0.55 * sin(y * 0.045 - U.time * 7.0), U.sparkMotion);
            col += prism::sparkTint(in.index, U.seed) * prism::sparkLine(s, 2.0 * px / U.pitch) * 1.3 * run;
        }
        if ((U.flags & CONTRAST) != 0u) col = mix(col, col * 1.15, 0.6);
        alpha = cover * in.alpha;
    }
    if ((U.flags & NIGHT) != 0u) {
        float l = prism::luma(col);
        col = float3(0.6, 0.07, 0.05) * l * 0.9;
    }
    col = clamp(col, 0.0, 1.0);
    return float4(col * alpha, alpha);
}
