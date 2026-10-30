// Prism's material for SwiftUI: a view seen through vertical fluted glass (View.prism, DesignSystem/Prism.swift).
// Both effects are static: they render when the view changes, never per frame.
#include <metal_stdlib>
#if __has_include(<SwiftUI/SwiftUI_Metal.h>)
#include <SwiftUI/SwiftUI_Metal.h>
#else
// Compiled at run time (tests, benchmarks) the SDK's header isn't on the include path; this is the same layout.
namespace SwiftUI {
struct Layer {
    metal::texture2d<half> tex;
    float2 info[5];
    half4 sample(float2 p) const {
        p = metal::fma(p.x, info[0], metal::fma(p.y, info[1], info[2]));
        p = metal::clamp(p, info[3], info[4]);
        return tex.sample(metal::sampler(metal::filter::linear), p);
    }
};
}
#endif
#include "PrismOptics.h"

using namespace metal;

/// The light a strip catches at `p`: the top-down ramp (tinted), shaded by the strip's normal.
static inline float3 stripLight(float3 n, float2 p, float4 box, half4 tint) {
    float t = (p.y - box.y) / max(box.w, 1.0);
    float3 light = mix(float3(1.0), prism::ramp(t), 0.32) * mix(float3(1.0), float3(tint.rgb), 0.5 * float(tint.a));
    return light * prism::diffuse(n) / 0.82;
}

/// Content behind fluted glass. Each strip of `pitch` points is a cylindrical lens: it magnifies (or, with a negative
/// `magnify`, mirrors) the slice behind it and shifts it by `depth` along its tilted normal. Red and blue land a little
/// apart from green toward the strip edges (`disperse`), the ridge carries a highlight (`spec`), and a rationed share of
/// strips (`sparks`) carries a coloured hairline.
[[stitchable]] half4 prismFlutes(float2 p, SwiftUI::Layer layer, float4 box,
                                 float pitch, float lens, float magnify, float depth,
                                 float disperse, float spec, float sparks, float seed, half4 tint) {
    prism::Flute f = prism::flute(p.x - box.x, pitch, lens);
    float centre = box.x + (f.index + 0.5) * pitch;
    float offset = f.s * pitch * magnify * 0.5 + depth * f.n.x;
    half4 g = layer.sample(float2(centre + offset, p.y));
    half4 c = g;
    if (disperse > 0.0) {
        float d = disperse * prism::DISPERSION * 4.0 * abs(f.s);
        half4 r = layer.sample(float2(centre + offset * (1.0 - d), p.y));
        half4 b = layer.sample(float2(centre + offset * (1.0 + d), p.y));
        half a = (r.a + g.a + b.a) / 3.0h;
        c = half4(min(r.r, a), min(g.g, a), min(b.b, a), a);
    }
    float3 rgb = float3(c.rgb) * stripLight(f.n, p, box, tint);
    rgb += float(c.a) * spec * 0.9 * prism::ridge(f.n) * mix(float3(1.0), prism::ramp((p.y - box.y) / max(box.w, 1.0)), 0.4);
    if (prism::hasSpark(f.index, seed, sparks)) {
        rgb += float(c.a) * prism::sparkTint(f.index, seed) * prism::sparkLine(f.s, 2.0 / max(pitch, 0.5)) * 0.9;
    }
    return half4(half3(min(rgb, float3(c.a))), c.a);
}

/// Reduce Transparency: the same strips shaded over the view's own colour, without looking through to anything else.
[[stitchable]] half4 prismSolid(float2 p, half4 color, float4 box, float pitch, float lens, float spec, half4 tint) {
    prism::Flute f = prism::flute(p.x - box.x, pitch, lens);
    float3 rgb = float3(color.rgb) * stripLight(f.n, p, box, tint);
    rgb += float(color.a) * spec * 0.6 * prism::ridge(f.n);
    return half4(half3(min(rgb, float3(color.a))), color.a);
}
