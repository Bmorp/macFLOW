// Glass — Liquid Glass. Two thick, flawless glass forms float in front of a soft field of coloured light: a fat ring
// low on the right and a smooth pebble on the left. Rays are traced through the glass (reflection and refraction
// chosen by Fresnel, up to a handful of crossings), each sample at its own wavelength so the edges split into
// spectra. Long studio softboxes above and to the side give the crisp white edge light; the field behind supplies
// the colour that the glass bends, magnifies and inverts.

constant float ZB = -6.0;          // the light field's plane
constant int SUB = 3;              // sub-samples per pass (lens + wavelength)

// MARK: - Shapes

inline float3x3 rotX(float a) { float c = cos(a), s = sin(a); return float3x3(float3(1, 0, 0), float3(0, c, s), float3(0, -s, c)); }
inline float3x3 rotY(float a) { float c = cos(a), s = sin(a); return float3x3(float3(c, 0, -s), float3(0, 1, 0), float3(s, 0, c)); }
inline float3x3 rotZ(float a) { float c = cos(a), s = sin(a); return float3x3(float3(c, s, 0), float3(-s, c, 0), float3(0, 0, 1)); }

struct Scene {
    float3x3 ringM; float3 ringO; float ringR, ringr;
    float3 sphO; float sphR;
    float3 farO; float farR;
};

inline Scene makeScene() {
    Scene S;
    // A great arc of glass sweeping under the clock and rising on both sides.
    S.ringM = rotX(radians(90.0 - 22.0)) * rotY(radians(-14.0));
    S.ringO = float3(0.3, 2.25, -1.0);
    S.ringR = 4.0; S.ringr = 0.40;
    S.sphO = float3(-2.55, -1.35, 0.9);
    S.sphR = 0.52;
    S.farO = float3(-3.6, 1.9, -4.5);
    S.farR = 0.42;
    return S;
}

inline float sdTorus(float3 p, float R, float r) { float2 q = float2(length(p.xz) - R, p.y); return length(q) - r; }

/// IQ's ellipsoid bound (good near the surface).
inline float sdEllipsoid(float3 p, float3 r) {
    float k0 = length(p / r), k1 = length(p / (r * r));
    return k0 * (k0 - 1.0) / k1;
}

constant int SPHERES = 0;

inline float map(float3 p, thread const Scene& S) {
    // The tube swells a little toward the bottom of the arc and slims as it rises.
    float r = S.ringr * (1.0 + 0.22 * smoothstep(1.2, -1.6, p.y));
    float a = sdTorus(S.ringM * (p - S.ringO), S.ringR, r) * 0.95;
    if (SPHERES >= 1) a = min(a, length(p - S.sphO) - S.sphR);
    if (SPHERES >= 2) a = min(a, length(p - S.farO) - S.farR);
    return a;
}

inline float3 normalAt(float3 p, thread const Scene& S) {
    const float e = 0.0005;
    const float2 k = float2(1, -1);
    return normalize(k.xyy * map(p + k.xyy * e, S) + k.yyx * map(p + k.yyx * e, S) +
                     k.yxy * map(p + k.yxy * e, S) + k.xxx * map(p + k.xxx * e, S));
}

/// March from outside (sign 1) or inside (sign −1) to the next surface.
inline float march(float3 o, float3 d, thread const Scene& S, float sgn, float tMax) {
    float t = 0.0;
    for (int i = 0; i < 200; i++) {
        float h = sgn * map(o + d * t, S);
        if (h < 0.00025) return t;
        t += max(h, 0.0004);
        if (t > tMax) break;
    }
    return -1.0;
}

// MARK: - Light

/// The coloured light field behind the glass: large soft pools of light on a deep ground, darker behind the clock.
inline float3 hueRamp(float x) {
    // Coral → magenta → violet → cyan, linear and saturated.
    const float3 c0 = float3(1.00, 0.30, 0.12);
    const float3 c1 = float3(0.95, 0.06, 0.42);
    const float3 c2 = float3(0.42, 0.10, 1.00);
    const float3 c3 = float3(0.05, 0.62, 1.00);
    x = clamp(x, 0.0, 1.0) * 3.0;
    if (x < 1.0) return mix(c0, c1, smoothstep(0.0, 1.0, x));
    if (x < 2.0) return mix(c1, c2, smoothstep(0.0, 1.0, x - 1.0));
    return mix(c2, c3, smoothstep(0.0, 1.0, x - 2.0));
}

inline float3 field(float2 q) {
    float3 c = float3(0.0022, 0.0022, 0.0065);
    // A luminous band low in the field, rising gently to the right; its colour runs through the spectrum.
    float y0 = -3.1 + 0.14 * q.x + 0.25 * sin(q.x * 0.45 + 0.6);
    float dy = q.y - y0;
    float band = exp(-dy * dy / (2.0 * 0.45 * 0.45)) + 0.22 * exp(-dy * dy / (2.0 * 1.4 * 1.4));
    c += hueRamp(0.5 + q.x / 12.0) * band * 1.2 * smoothstep(-9.0, -4.0, q.x) * smoothstep(9.0, 5.0, q.x);
    // A broad, faint violet haze over the lower half, so the dark never goes dead.
    c += float3(0.020, 0.010, 0.060) * smoothstep(2.0, -4.5, q.y);
    return c;
}

/// Soft-edged rectangle mask.
inline float box(float2 q, float2 h, float soft) {
    float2 d = abs(q) - h;
    return 1.0 - smoothstep(-soft, soft, max(d.x, d.y));
}

/// Everything a ray sees once it leaves the glass: the field ahead, softboxes above and to the left, a dark studio.
inline float3 env(float3 o, float3 d) {
    float3 c = float3(0.004, 0.004, 0.010) * (0.6 + 0.4 * d.y);
    if (d.z < 0.0) {
        float t = (ZB - o.z) / d.z;
        c = field(o.xy + d.xy * t);
    }
    // Long strip softbox overhead, slightly in front.
    if (d.y > 0.0) {
        float t = (7.0 - o.y) / d.y;
        float2 q = o.xz + d.xz * t;
        c += float3(9.0, 9.0, 9.4) * box(q - float2(-0.5, 2.0), float2(6.0, 1.1), 0.5);
    }
    // Tall softbox on the left.
    if (d.x < 0.0) {
        float t = (-8.0 - o.x) / d.x;
        float2 q = o.yz + d.yz * t;
        c += float3(5.0, 5.2, 6.0) * box(q - float2(1.0, 3.0), float2(2.5, 1.0), 0.6);
    }
    // A warm kicker low on the right.
    if (d.x > 0.0) {
        float t = (8.0 - o.x) / d.x;
        float2 q = o.yz + d.yz * t;
        c += float3(4.0, 2.2, 1.6) * box(q - float2(-2.0, 1.0), float2(1.2, 1.6), 0.8);
    }
    return c;
}

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

inline float fresnel(float cosi, float eta) {
    float s2 = eta * eta * (1.0 - cosi * cosi);
    if (s2 >= 1.0) return 1.0;
    float cost = sqrt(1.0 - s2);
    float rs = (eta * cosi - cost) / (eta * cosi + cost);
    float rp = (cosi - eta * cost) / (cosi + eta * cost);
    return 0.5 * (rs * rs + rp * rp);
}

/// Follows a ray through the scene, choosing reflection or refraction by Fresnel at each crossing.
inline float3 path(float3 o, float3 d, bool inside, float ior, thread const Scene& S, thread Rng& rng, int maxDepth) {
    float3 thr = float3(1.0);
    for (int depth = 0; depth < maxDepth; depth++) {
        float t = march(o, d, S, inside ? -1.0 : 1.0, 40.0);
        if (t < 0.0) return thr * env(o, d);
        float3 p = o + d * t;
        float3 n = normalAt(p, S);
        // Faint absorption: thick glass is a touch cool.
        if (inside) thr *= exp(-float3(0.10, 0.05, 0.02) * t);
        float3 nf = inside ? -n : n;
        float eta = inside ? ior : 1.0 / ior;
        float cosi = clamp(-dot(d, nf), 0.0, 1.0);
        float F = fresnel(cosi, eta);
        if (rng.next() < F) {
            d = reflect(d, nf);
            o = p + nf * 0.0012;
        } else {
            d = refract(d, nf, eta);
            o = p - nf * 0.0012;
            inside = !inside;
        }
    }
    return thr * env(o, d) * 0.5;
}

// MARK: - Render

inline float2 r4(uint i, float2 rot, int which) {
    // Golden-ratio sequences that don't line up with the pixel jitter.
    float2 a = which == 0 ? float2(0.6287047, 0.5385888) : float2(0.8566749, 0.7338919);
    return fract(float2(0.5) + float(i) * a + rot);
}

Sample render(float2 px, thread Ctx& ctx) {
    Scene S = makeScene();
    float3 eye = float3(0.0, 0.25, 8.0);
    float3 target = float3(0.0, -0.1, 0.0);
    float2 rot = hash22(floor(px) * 0.7131 + 19.0);
    float rotL = hash12(floor(px) * 0.391 + 5.0);
    float3 sum = float3(0.0);
    for (int k = 0; k < SUB; k++) {
        uint i = ctx.pass * uint(SUB) + uint(k);
        Ray ray = camera(eye, target, 30.0, px, ctx.res, 0.10, 8.1, r4(i, rot, 0));
        float t = march(ray.o, ray.d, S, 1.0, 30.0);
        if (t < 0.0) { sum += env(ray.o, ray.d); continue; }
        // Hit glass: this sample carries one wavelength (stratified across the passes).
        float lam = 400.0 + 300.0 * fract(0.5 + float(i) * 0.6180339887 + rotL);
        float ior = iorAt(lam);
        float3 w = spectrum(lam);
        float3 p = ray.o + ray.d * t;
        float3 n = normalAt(p, S);
        float cosi = clamp(-dot(ray.d, n), 0.0, 1.0);
        float F = fresnel(cosi, 1.0 / ior);
        // Split the first crossing: both the reflection and the refraction, weighted (far less noise).
        float3 refl = path(p + n * 0.0012, reflect(ray.d, n), false, ior, S, ctx.rng, 3);
        float3 refr = path(p - n * 0.0012, refract(ray.d, n, 1.0 / ior), true, ior, S, ctx.rng, 7);
        sum += w * (F * refl + (1.0 - F) * refr);
    }
    Sample s;
    s.fg = 0.0;
    s.color = sum / float(SUB);
    return s;
}

float3 post(float3 hdr, float2 uv, float2 px) {
    float3 c = hdr * 1.0;
    c *= vignette(uv, 0.25);
    c = agx(c, 0.45);
    return grain(c, px, 0.010);
}
