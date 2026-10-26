// Shared by every wallpaper scene. A scene defines:
//   Sample render(float2 px, thread Ctx& ctx)      — one jittered sample at canvas pixel `px` (y down), linear HDR
//   float3 post(float3 hdr, float2 uv, float2 px)  — its grade: HDR → display-linear [0, 1] (sRGB is applied after)
// and may set Sample.fg = 1 for samples whose first hit is the foreground (the depth layer).
#include <metal_stdlib>
using namespace metal;

constant float PI = 3.14159265358979;
inline float radians(float deg) { return deg * (PI / 180.0); }

// MARK: - Random

inline uint pcg(uint v) {
    uint s = v * 747796405u + 2891336453u;
    uint w = ((s >> ((s >> 28u) + 4u)) ^ s) * 277803737u;
    return (w >> 22u) ^ w;
}

struct Rng {
    uint s;
    Rng() : s(0u) {}
    Rng(uint2 p, uint pass) { s = pcg(p.x ^ pcg(p.y ^ pcg(pass * 9781u + 0x9E3779B9u))); }
    float next() { s = pcg(s); return float(s) * (1.0 / 4294967296.0); }
    float2 next2() { return float2(next(), next()); }
};

struct Ctx {
    float2 res;
    uint pass;
    uint passes;
    Rng rng;
};

struct Sample {
    float3 color;
    float fg;
};

// Dave Hoskins' sine-free hashes.
inline float hash12(float2 p) { float3 p3 = fract(float3(p.xyx) * 0.1031); p3 += dot(p3, p3.yzx + 33.33); return fract((p3.x + p3.y) * p3.z); }
inline float2 hash22(float2 p) { float3 p3 = fract(float3(p.xyx) * float3(0.1031, 0.1030, 0.0973)); p3 += dot(p3, p3.yzx + 33.33); return fract((p3.xx + p3.yz) * p3.zy); }
inline float hash13(float3 p3) { p3 = fract(p3 * 0.1031); p3 += dot(p3, p3.zyx + 31.32); return fract((p3.x + p3.y) * p3.z); }
inline float3 hash33(float3 p3) { p3 = fract(p3 * float3(0.1031, 0.1030, 0.0973)); p3 += dot(p3, p3.yxz + 33.33); return fract((p3.xxy + p3.yxx) * p3.zyx); }

// MARK: - Noise

/// Value noise with analytic derivatives: (value in -1…1, d/dx, d/dy).
inline float3 noised(float2 x) {
    float2 i = floor(x), f = fract(x);
    float2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    float2 du = 30.0 * f * f * (f * (f - 2.0) + 1.0);
    float a = hash12(i), b = hash12(i + float2(1, 0)), c = hash12(i + float2(0, 1)), d = hash12(i + float2(1, 1));
    float k1 = b - a, k2 = c - a, k4 = a - b - c + d;
    return float3(-1.0 + 2.0 * (a + k1 * u.x + k2 * u.y + k4 * u.x * u.y), 2.0 * du * float2(k1 + k4 * u.y, k2 + k4 * u.x));
}
inline float noise(float2 x) { return noised(x).x; }

/// 3D value noise, -1…1.
inline float noise3(float3 x) {
    float3 i = floor(x), f = fract(x);
    float3 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    float n000 = hash13(i), n100 = hash13(i + float3(1, 0, 0)), n010 = hash13(i + float3(0, 1, 0)), n110 = hash13(i + float3(1, 1, 0));
    float n001 = hash13(i + float3(0, 0, 1)), n101 = hash13(i + float3(1, 0, 1)), n011 = hash13(i + float3(0, 1, 1)), n111 = hash13(i + float3(1, 1, 1));
    float v = mix(mix(mix(n000, n100, u.x), mix(n010, n110, u.x), u.y), mix(mix(n001, n101, u.x), mix(n011, n111, u.x), u.y), u.z);
    return v * 2.0 - 1.0;
}

constant float2x2 ROT2 = float2x2(float2(0.80, 0.60), float2(-0.60, 0.80));
constant float3x3 ROT3 = float3x3(float3(0.00, 0.80, 0.60), float3(-0.80, 0.36, -0.48), float3(-0.60, -0.48, 0.64));

inline float fbm(float2 p, int octaves) {
    float s = 0.0, a = 0.5;
    for (int i = 0; i < octaves; i++) { s += a * noise(p); p = ROT2 * p * 2.03; a *= 0.5; }
    return s;
}

inline float fbm3(float3 p, int octaves) {
    float s = 0.0, a = 0.5;
    for (int i = 0; i < octaves; i++) { s += a * noise3(p); p = ROT3 * p * 2.02; a *= 0.5; }
    return s;
}

/// Terrain fbm that smooths detail on steep ground (Inigo Quilez's "erosion" trick).
inline float fbmEroded(float2 p, int octaves) {
    float s = 0.0, a = 0.5;
    float2 d = float2(0);
    for (int i = 0; i < octaves; i++) {
        float3 n = noised(p);
        d += n.yz;
        s += a * n.x / (1.0 + dot(d, d));
        p = ROT2 * p * 2.0;
        a *= 0.5;
    }
    return s;
}

// MARK: - Sampling

inline void basis(float3 n, thread float3& t, thread float3& b) {
    float s = n.z >= 0.0 ? 1.0 : -1.0;
    float a = -1.0 / (s + n.z);
    float bb = n.x * n.y * a;
    t = float3(1.0 + s * n.x * n.x * a, s * bb, -s * n.x);
    b = float3(bb, s + n.y * n.y * a, -n.y);
}

inline float2 diskSample(float2 u) { float r = sqrt(u.x), a = 2.0 * PI * u.y; return r * float2(cos(a), sin(a)); }

/// A direction within `cosMax` of `dir` (an area light such as the sun).
inline float3 coneSample(float3 dir, float cosMax, float2 u) {
    float c = mix(1.0, cosMax, u.x), s = sqrt(max(0.0, 1.0 - c * c)), phi = 2.0 * PI * u.y;
    float3 t, b; basis(dir, t, b);
    return normalize(t * cos(phi) * s + b * sin(phi) * s + dir * c);
}

inline float3 cosineHemisphere(float3 n, float2 u) {
    float2 d = diskSample(u);
    float3 t, b; basis(n, t, b);
    return normalize(t * d.x + b * d.y + n * sqrt(max(0.0, 1.0 - dot(d, d))));
}

// MARK: - Camera

struct Ray { float3 o; float3 d; };

/// A thin-lens camera. `px` in canvas pixels (y down), `vfov` in degrees; aperture 0 is a pinhole.
inline Ray camera(float3 eye, float3 target, float vfov, float2 px, float2 res, float aperture, float focus, float2 lensU, float roll = 0.0) {
    float3 f = normalize(target - eye);
    float3 up = float3(sin(roll), cos(roll), 0.0);
    float3 r = normalize(cross(f, up));
    float3 u = cross(r, f);
    float2 ndc = (2.0 * px - res) / res.y;
    ndc.y = -ndc.y;
    float th = tan(radians(vfov) * 0.5);
    Ray ray;
    ray.o = eye;
    ray.d = normalize(f + (ndc.x * r + ndc.y * u) * th);
    if (aperture > 0.0) {
        float3 fp = eye + ray.d * (focus / dot(ray.d, f));
        float2 l = diskSample(lensU) * aperture;
        ray.o = eye + r * l.x + u * l.y;
        ray.d = normalize(fp - ray.o);
    }
    return ray;
}

// MARK: - Atmosphere (single scattering, Rayleigh + Mie)

struct Atmos {
    float rPlanet;
    float rAtmos;
    float3 betaR;
    float betaM;
    float hR;
    float hM;
    float g;
    /// Multiplies aerosol density: dust, haze, humidity.
    float haze;
};

inline Atmos earth() {
    Atmos a;
    a.rPlanet = 6371e3; a.rAtmos = 6471e3;
    a.betaR = float3(5.8e-6, 13.5e-6, 33.1e-6);
    a.betaM = 21e-6; a.hR = 8000.0; a.hM = 1200.0; a.g = 0.76; a.haze = 1.0;
    return a;
}

inline float2 raySphere(float3 ro, float3 rd, float r) {
    float b = dot(ro, rd), c = dot(ro, ro) - r * r, d = b * b - c;
    if (d < 0.0) return float2(1e30, -1e30);
    d = sqrt(d);
    return float2(-b - d, -b + d);
}

/// Light scattered toward the eye along `rd` from `ro` (metres, relative to the planet's centre) over at most `tMax`;
/// `trans` receives the transmittance over the same stretch (for aerial perspective, multiply the surface by it).
inline float3 scatter(float3 ro, float3 rd, float tMax, float3 sunDir, float3 sunI, Atmos A, int steps, int lightSteps, thread float3& trans) {
    trans = float3(1.0);
    float2 pa = raySphere(ro, rd, A.rAtmos);
    float t0 = max(pa.x, 0.0), t1 = min(pa.y, tMax);
    float2 pg = raySphere(ro, rd, A.rPlanet);
    if (pg.x > 0.0) t1 = min(t1, pg.x);
    if (t1 <= t0) return float3(0.0);
    float ds = (t1 - t0) / float(steps);
    float mu = dot(rd, sunDir), g = A.g;
    float pR = 3.0 / (16.0 * PI) * (1.0 + mu * mu);
    float pM = 3.0 / (8.0 * PI) * ((1.0 - g * g) * (1.0 + mu * mu)) / ((2.0 + g * g) * pow(max(1e-4, 1.0 + g * g - 2.0 * g * mu), 1.5));
    float2 od = float2(0.0);
    float3 sumR = float3(0.0), sumM = float3(0.0);
    for (int i = 0; i < steps; i++) {
        float3 x = ro + rd * (t0 + (float(i) + 0.5) * ds);
        float h = length(x) - A.rPlanet;
        float dR = exp(-h / A.hR) * ds, dM = exp(-h / A.hM) * ds * A.haze;
        od += float2(dR, dM);
        float2 ls = raySphere(x, sunDir, A.rAtmos);
        float lds = ls.y / float(lightSteps);
        float2 lod = float2(0.0);
        bool shadow = false;
        for (int j = 0; j < lightSteps; j++) {
            float3 y = x + sunDir * ((float(j) + 0.5) * lds);
            float lh = length(y) - A.rPlanet;
            if (lh < 0.0) { shadow = true; break; }
            lod += float2(exp(-lh / A.hR), exp(-lh / A.hM) * A.haze) * lds;
        }
        if (!shadow) {
            float3 att = exp(-(A.betaR * (od.x + lod.x) + A.betaM * 1.1 * (od.y + lod.y)));
            sumR += dR * att;
            sumM += dM * att;
        }
    }
    trans = exp(-(A.betaR * od.x + A.betaM * 1.1 * od.y));
    return sunI * (sumR * A.betaR * pR + sumM * A.betaM * pM);
}

/// Sunlight reaching a point at `altitude` metres (the sky's own colour filter on it: amber when low).
inline float3 sunlight(float altitude, float3 sunDir, float3 sunI, Atmos A, int steps) {
    float3 x = float3(0.0, A.rPlanet + altitude, 0.0);
    float2 ls = raySphere(x, sunDir, A.rAtmos);
    float lds = ls.y / float(steps);
    float2 lod = float2(0.0);
    for (int j = 0; j < steps; j++) {
        float lh = length(x + sunDir * ((float(j) + 0.5) * lds)) - A.rPlanet;
        if (lh < 0.0) return float3(0.0);
        lod += float2(exp(-lh / A.hR), exp(-lh / A.hM) * A.haze) * lds;
    }
    return sunI * exp(-(A.betaR * lod.x + A.betaM * 1.1 * lod.y));
}

// MARK: - Colour

inline float luma(float3 c) { return dot(c, float3(0.2126, 0.7152, 0.0722)); }

inline float3 srgb(float3 c) {
    return select(1.055 * pow(c, float3(1.0 / 2.4)) - 0.055, 12.92 * c, c <= 0.0031308);
}

inline float3 saturation(float3 c, float s) { float l = luma(c); return max(float3(0.0), l + (c - l) * s); }

/// AgX (Troy Sobotka), Benjamin Wrensch's fit: filmic, with highlights that desaturate gracefully instead of
/// skewing hue. `punch` 0 is the base look; 1 is "punchy" (more contrast and colour).
inline float3 agx(float3 c, float punch) {
    const float3x3 inMat = float3x3(float3(0.842479062253094, 0.0423282422610123, 0.0423756549057051),
                                    float3(0.0784335999999992, 0.878468636469772, 0.0784336),
                                    float3(0.0792237451477643, 0.0791661274605434, 0.879142973793104));
    const float3x3 outMat = float3x3(float3(1.19687900512017, -0.0528968517574562, -0.0529716355144438),
                                     float3(-0.0980208811401368, 1.15190312990417, -0.0980434501171241),
                                     float3(-0.0990297440797205, -0.0989611768448433, 1.15107367264116));
    const float minEv = -12.47393, maxEv = 4.026069;
    float3 v = inMat * max(c, float3(1e-10));
    v = (clamp(log2(v), minEv, maxEv) - minEv) / (maxEv - minEv);
    float3 v2 = v * v, v4 = v2 * v2;
    v = 15.5 * v4 * v2 - 40.14 * v4 * v + 31.96 * v4 - 6.868 * v2 * v + 0.4298 * v2 + 0.1191 * v - 0.00232;
    // Look (in display space).
    float l = luma(v);
    v = pow(max(v, float3(0.0)), float3(mix(1.0, 1.35, punch)));
    v = l + (v - l) * mix(1.0, 1.4, punch);
    v = outMat * v;
    return pow(max(v, float3(0.0)), float3(2.2));
}

/// Fine luminance grain, about one percent: photographic, and it hides any banding the eye could find.
inline float3 grain(float3 c, float2 px, float amount) {
    float n = hash12(px * 0.913 + 41.0) + hash12(px * 1.371 + 7.0) - 1.0;
    return max(float3(0.0), c * (1.0 + n * amount));
}

inline float vignette(float2 uv, float strength) {
    float2 d = (uv - 0.5) * float2(1.0, 0.8);
    return 1.0 - strength * smoothstep(0.25, 0.85, length(d) * 1.3);
}
