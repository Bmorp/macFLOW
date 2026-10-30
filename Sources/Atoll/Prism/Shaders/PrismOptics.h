// Prism's optics, shared by the app's shaders (Prism.metallib) and the offline wallpaper tracer
// (scripts/wallpapers/optics.metal includes this file), so the glass in a wallpaper and the glass on screen bend and
// colour light the same way. Everything lives in `prism::` so it never collides with a scene's own helpers.
#ifndef PRISM_OPTICS_H
#define PRISM_OPTICS_H

#include <metal_stdlib>

namespace prism {
using namespace metal;

// MARK: - Spectral glass

/// Wavelength (nm) → linear-sRGB weight whose average over 400–700 nm is white (Wyman's CIE fit, clipped).
inline float3 spectrum(float l) {
    float t1 = (l - 599.8) / (l < 599.8 ? 37.9 : 31.0), t2 = (l - 442.0) / (l < 442.0 ? 16.0 : 26.7), t3 = (l - 501.1) / (l < 501.1 ? 20.4 : 26.2);
    float x = 1.056 * exp(-0.5 * t1 * t1) + 0.362 * exp(-0.5 * t2 * t2) - 0.065 * exp(-0.5 * t3 * t3);
    float t4 = (l - 568.8) / (l < 568.8 ? 46.9 : 40.5), t5 = (l - 530.9) / (l < 530.9 ? 16.3 : 31.1);
    float y = 0.821 * exp(-0.5 * t4 * t4) + 0.286 * exp(-0.5 * t5 * t5);
    float t6 = (l - 437.0) / (l < 437.0 ? 11.8 : 36.0), t7 = (l - 459.0) / (l < 459.0 ? 26.0 : 13.8);
    float z = 1.217 * exp(-0.5 * t6 * t6) + 0.681 * exp(-0.5 * t7 * t7);
    float3 rgb = float3(3.2406 * x - 1.5372 * y - 0.4986 * z, -0.9689 * x + 1.8758 * y + 0.0415 * z, 0.0557 * x - 0.2040 * y + 1.0570 * z);
    return max(rgb, float3(0.0)) / float3(0.586964, 0.384455, 0.362577);
}

/// Cauchy dispersion around n = 1.50 at 550 nm (stronger than crown glass, for visible fire at the rims).
inline float iorAt(float l) { float u = l * 0.001; return 1.50 + 0.011 * (1.0 / (u * u) - 1.0 / (0.55 * 0.55)); }

/// Unpolarised Fresnel reflectance for a ray meeting a surface at `cosi`, `eta` = n_from / n_to.
inline float fresnel(float cosi, float eta) {
    float s2 = eta * eta * (1.0 - cosi * cosi);
    if (s2 >= 1.0) return 1.0;
    float cost = sqrt(1.0 - s2);
    float rs = (eta * cosi - cost) / (eta * cosi + cost);
    float rp = (cosi - eta * cost) / (cosi + eta * cost);
    return 0.5 * (rs * rs + rp * rp);
}

/// How far apart the red and blue images of one strip sit, relative to green: the spread of `iorAt` over 450–650 nm,
/// normalised so the flute shaders can scale it by `disperse`.
constant float DISPERSION = 0.055;

// MARK: - Light

/// Light comes from above and a little in front (screen space: x right, y down, z toward the viewer).
constant float3 LIGHT = float3(0.0, -0.8, 0.6);
/// The half vector the ridge highlight is aimed at: a long softbox above and a little to the left, mirrored to a viewer
/// in front, normalize(0.22, −0.12, 1). A strip's normal only turns across it, so the highlight lands as one hairline
/// just left of each ridge.
constant float3 HALFWAY = float3(0.2147, -0.1171, 0.9696);

/// The ramp the light runs through from the top of a surface to its foot: white where it's lit, steel blue below
/// (#5E7FA6), display-encoded sRGB like everything SwiftUI draws.
constant float3 WHITE = float3(1.0, 1.0, 1.0);
constant float3 STEEL = float3(0.3686, 0.4980, 0.6510);
constant float3 STEEL_DEEP = float3(0.105, 0.150, 0.215);

inline float3 ramp(float t) { return mix(WHITE, STEEL, smoothstep(0.0, 1.0, clamp(t, 0.0, 1.0))); }

/// Lambert with a lifted floor: a strip facing away from the light is dimmer, never black.
inline float diffuse(float3 n) { return 0.55 + 0.45 * dot(n, LIGHT); }

/// The narrow highlight along each strip's ridge.
inline float ridge(float3 n) { return pow(max(dot(n, HALFWAY), 0.0), 60.0); }

// MARK: - Flutes

/// One glass strip under a point: which strip (`index`), where across it (`s`, −1 at its left edge to 1 at its right)
/// and its surface normal. Each strip is a cylindrical lens: the normal tilts toward the edges by `lens`.
struct Flute {
    float index;
    float s;
    float3 n;
};

inline Flute flute(float x, float pitch, float lens) {
    float u = x / pitch;
    Flute f;
    f.index = floor(u);
    f.s = 2.0 * (u - f.index) - 1.0;
    f.n = normalize(float3(-lens * f.s / max(sqrt(max(1.0 - f.s * f.s, 0.0)), 0.2), 0.0, 1.0));
    return f;
}

// MARK: - Sparks

inline uint pcg(uint v) {
    uint s = v * 747796405u + 2891336453u;
    uint w = ((s >> ((s >> 28u) + 4u)) ^ s) * 277803737u;
    return (w >> 22u) ^ w;
}

/// A stable 0…1 value for strip `index` under `seed`.
inline float stripHash(float index, float seed) {
    return float(pcg(uint(int(index) + 65536) ^ pcg(uint(seed) + 0x9E3779B9u))) * (1.0 / 4294967296.0);
}

/// Whether a strip carries a spark: `share` of them do (0.012 is about one in eighty).
inline bool hasSpark(float index, float seed, float share) { return share > 0.0 && stripHash(index, seed) > 1.0 - share; }

/// The spark's colour: orange #FF8A3D, red #FF453A or blue #64D2FF, chosen per strip.
inline float3 sparkTint(float index, float seed) {
    float h = stripHash(index + 7919.0, seed);
    return h < 0.45 ? float3(1.0, 0.541, 0.239) : h < 0.7 ? float3(1.0, 0.271, 0.227) : float3(0.392, 0.824, 1.0);
}

/// A hairline at s ≈ 0.85, `px` wide in strip units (one device pixel, so it stays a hairline at any size).
inline float sparkLine(float s, float px) {
    float d = (s - 0.85) / max(px, 1e-3);
    return exp(-0.5 * d * d);
}

inline float luma(float3 c) { return dot(c, float3(0.2126, 0.7152, 0.0722)); }

} // namespace prism

#endif // PRISM_OPTICS_H
