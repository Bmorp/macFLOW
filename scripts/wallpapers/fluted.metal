// Fluted — the Prism pictures. A slab of a few hundred vertical glass strips stands in a dark studio; each strip is a
// cylindrical lens (an elliptical cross-section, edge to edge with its neighbours, silk's ribbon section made thick).
// The strips rise to one long, uneven, continuous crest and fold over it toward the viewer, as a wide flat ribbon
// folds: a tight rolled edge that catches the softbox as a single clean line, then a flap hanging down in front of
// the strip, ending in a hairline on a few. Behind them, a field of light: brightest just under the crest, falling
// through the variant's colours to black, and every strip takes its own share of it, bent and magnified. A spark or
// two (a thin coloured light behind one strip) and no more. Each sample traces one wavelength, so strip edges split
// into spectra.
// The crest rises under the right of the clock (the slab is the depth layer and tucks over the lower minutes).
//
// Variants (render.swift --define VARIANT=n): 0 Steel (white to steel blue), 1 Ember (gold to deep red),
// 2 Polar (mint to teal to violet).

#ifndef VARIANT
#define VARIANT 0
#endif

constant float P = 0.034;            // strip pitch, world units (about two hundred strips across the frame)
constant float HALF_W = 0.5 * P;     // lens half width: neighbours meet at their thin edges
constant float HALF_T = 0.34 * P;    // lens half thickness at the ridge
#ifndef FLATT
#define FLATT 0.07
#endif
constant float HALF_T_FLAT = FLATT * P;   // …and in the fold and the flap, where the ribbon is flat
constant float HALF_H = 2.244;       // half the frame's height at z = 0 (camera at z = 9, 28°)
constant float HALF_X = 3.59;        // half its width (16:10)
constant float ZB = -1.3;            // the light field's plane
constant float FOLD = PI;            // a strip folds right over at its top: 180°, back down in front of itself
constant int SUB = 3;
constant float BEHIND = (9.0 - ZB) / 9.0;   // a strip at x on the slab is in front of x · BEHIND on the field

// MARK: - The slab

/// The crest, as a fraction of the frame from the top, across the frame (xn from −1 to 1).
/// A smooth bump: 1 at `x` = 0, falling off over `w`.
inline float bump(float x, float w) { float u = x / w; return exp(-u * u); }

inline float crestV(float xn) {
#if VARIANT == 1
    return 0.70 - 0.19 * bump(xn - 0.58, 0.24) - 0.07 * bump(xn + 0.55, 0.3) + 0.015 * sin(xn * 7.0 + 1.0);
#elif VARIANT == 2
    return 0.69 - 0.15 * bump(xn - 0.48, 0.32) - 0.12 * bump(xn + 0.82, 0.2) + 0.02 * sin(xn * 5.0 - 0.6);
#else
    return 0.68 - 0.18 * bump(xn - 0.52, 0.26) - 0.10 * bump(xn + 0.78, 0.22) + 0.02 * sin(xn * 9.0);
#endif
}

inline float crestY(float x) { return (0.5 - crestV(x / HALF_X)) * 2.0 * HALF_H; }

struct Strip {
    float x;       // centre
    float h;       // where it starts to fold, at the centre…
    float dh;      // …and how that rises across the strip (the crest's slope: the fold follows the crest, not a step)
    float z;       // its plane
    float R;       // the fold's radius
    float e;       // where the flap ends, at the centre…
    float de;      // …and its slope across the strip
    float tail;    // hairline length below the flap (0: none)
    float hash;
};

/// The flap's length along the crest: a long, slow drift.
inline float flapLength(float x) { return 0.15 + 0.2 * noise(float2(x * 0.8, 17.0)); }

/// Everything varies smoothly along the crest (the fold's depth, radius and the flap's length drift with x, so
/// neighbours always agree), and each strip adds only a hair of its own: no bundles, no steps. A strip's fold and
/// the end of its flap are cut along the crest's own slope, so the edges are continuous curves.
inline Strip stripAt(int i) {
    float fi = float(i);
    Strip s;
    s.x = (fi + 0.5) * P;
    s.hash = hash12(float2(fi, 3.7));
    float l = s.x - 0.5 * P, r = s.x + 0.5 * P;
    float drift = noise(float2(s.x * 1.1, 4.0)), slow = noise(float2(s.x * 0.45, 9.0));
    s.h = crestY(s.x) + (s.hash - 0.5) * 0.003;
    s.dh = (crestY(r) - crestY(l)) / P;
    s.z = (drift - 0.5) * 0.03;
    s.R = 0.030 + 0.012 * slow;
    float jitter = (hash12(float2(fi, 8.1)) - 0.5) * 0.012;
    s.e = crestY(s.x) - flapLength(s.x) + jitter;
    s.de = ((crestY(r) - flapLength(r)) - (crestY(l) - flapLength(l))) / P;
    s.tail = s.hash > 0.972 ? 0.16 + 0.5 * (s.hash - 0.972) / 0.028 : 0.0;
    return s;
}

/// IQ's ellipse bound (good near the surface).
inline float sdEllipse(float2 p, float2 r) {
    float k0 = length(p / r), k1 = length(p / (r * r));
    return k0 * (k0 - 1.0) / max(k1, 1e-6);
}

/// A strip's glass in the (y, z) plane: straight up to `h` at its full thickness, then a half-turn of radius `R` toward
/// the viewer during which it flattens, then straight back down in front to `e` as a thin, flat ribbon. `end`
/// receives the flap's last point (y, z).
inline float stripSDF(float3 p, thread const Strip& s, thread float2& end) {
    float x = p.x - s.x;
    float h = s.h + s.dh * x;
    float2 q = float2(p.y, p.z), base = float2(h, s.z);
    float2 c = float2(h, s.z + s.R);
    float2 turn = float2(h, s.z + 2.0 * s.R);
    end = float2(min(s.e + s.de * x, h - 0.01), turn.y);
    // The body.
    float dBody = q.x <= h ? abs(q.y - s.z) : length(q - base);
    float d = sdEllipse(float2(x, dBody), float2(HALF_W, HALF_T)) * 0.8;
    // The fold, thinning to a flat ribbon over its first part.
    float2 v = q - c;
    float a = atan2(v.x, -v.y);
    if (a < 0.0) a += 2.0 * PI;
    float dArc = a <= FOLD ? abs(length(v) - s.R) : min(length(q - base), length(q - turn));
    float thin = smoothstep(0.0, 0.45, saturate(min(a, FOLD) / FOLD));
    d = min(d, sdEllipse(float2(x, dArc), float2(HALF_W, mix(HALF_T, HALF_T_FLAT, thin))) * 0.8);
    // The flap.
    float dFlap = length(q - float2(clamp(q.x, end.x, turn.x), turn.y));
    d = min(d, sdEllipse(float2(x, dFlap), float2(HALF_W, HALF_T_FLAT)) * 0.8);
    if (s.tail > 0.0) {
        // A hairline of glass hanging from the end of the flap.
        float y = clamp(p.y, end.x - s.tail, end.x);
        d = min(d, length(float3(x, p.y - y, p.z - end.y)) - 0.0016);
    }
    return d;
}

inline float map(float3 p) {
    int i = int(floor(p.x / P));
    float d = 1e9;
    for (int k = -1; k <= 1; k++) { Strip s = stripAt(i + k); float2 end; d = min(d, stripSDF(p, s, end)); }
    return d;
}

inline float3 normalAt(float3 p) {
    const float e = 0.00015;
    const float2 k = float2(1, -1);
    return normalize(k.xyy * map(p + k.xyy * e) + k.yyx * map(p + k.yyx * e) + k.yxy * map(p + k.yxy * e) + k.xxx * map(p + k.xxx * e));
}

/// March from outside (sign 1) or inside (sign −1) to the next surface, within the slab's depth.
inline float march(float3 o, float3 d, float sgn, float tMax) {
    float t = 0.0;
    for (int i = 0; i < 160; i++) {
        float3 p = o + d * t;
        if (p.z < -0.12 && d.z < 0.0) break;
        if (p.z > 0.36 && d.z > 0.0) break;
        float h = sgn * map(p);
        if (h < 0.00012) return t;
        t += max(h * 0.9, 0.00008);
        if (t > tMax) break;
    }
    return -1.0;
}

// MARK: - Light

inline float3 rampColour(float k, float xn) {
#if VARIANT == 1
    float3 top = float3(1.0, 0.74, 0.44), mid = float3(1.0, 0.30, 0.05), low = float3(0.50, 0.035, 0.02);
#elif VARIANT == 2
    float3 top = float3(0.80, 1.0, 0.94), mid = mix(float3(0.05, 0.85, 0.62), float3(0.10, 0.55, 1.0), 0.5 + 0.5 * xn), low = float3(0.36, 0.10, 0.85);
#else
    float3 top = float3(1.0, 1.0, 1.0), mid = float3(0.30, 0.52, 0.92), low = float3(0.05, 0.10, 0.30);
#endif
    return k < 0.5 ? mix(top, mid, smoothstep(0.0, 0.5, k)) : mix(mid, low, smoothstep(0.5, 1.0, k));
}

inline float3 sparkColour(float h) {
#if VARIANT == 1
    return h < 0.6 ? float3(0.39, 0.82, 1.0) : float3(0.45, 0.55, 1.0);
#elif VARIANT == 2
    return h < 0.5 ? float3(1.0, 0.27, 0.62) : float3(1.0, 0.54, 0.24);
#else
    return h < 0.45 ? float3(1.0, 0.54, 0.24) : h < 0.7 ? float3(1.0, 0.27, 0.23) : float3(0.39, 0.82, 1.0);
#endif
}

/// The strips that carry a spark: one or two a picture, never more (strip indices; the clock sits above them).
inline bool sparkAt(int i) {
#if VARIANT == 1
    return i == 47 || i == -29;
#elif VARIANT == 2
    return i == 21;
#else
    return i == 52 || i == -68;
#endif
}

/// The field of light behind the slab: brightest just under the crest (light from above, caught by the glass), white
/// there and the variant's colours further down, and gone to black before the foot. Every strip takes its own share:
/// its own brightness and its own height for the glow, so neighbours never show the same light.
inline float3 field(float2 q, bool direct) {
    float3 c = float3(0.0010, 0.0011, 0.0018);
    float xn = q.x / HALF_X;
    float cy = crestY(q.x / BEHIND) * BEHIND;   // the crest as seen on the field's plane, from the camera
    float i = floor(q.x / BEHIND / P);
    float own = 0.34 + 0.96 * pow(hash12(float2(i, 5.3)), 1.5);
    float lift = (hash12(float2(i, 12.9)) - 0.5) * 0.3;
    float dy = q.y - cy;
    float below = max(-dy - lift * 0.5, 0.0);
    float k = saturate(below / 1.7);
    // A tight band of light under the crest, a long dimmer fall below it, nothing above, and black by the foot.
    // Light spills a little above the crest, for the glass that bends the view up there; seen straight on (past the
    // glass, not through it) it isn't there, so nothing glows outside the silhouette.
    float spill = direct ? 0.0 : 0.85 * exp(-dy / 0.12);
    float crest = dy > 0.0 ? spill : exp(-below * below / (2.0 * 0.30 * 0.30));
    float body = 0.30 * exp(-below / 0.5);
    float fall = 1.0 - smoothstep(0.5, 1.75, below);
    float band = 0.6 + 0.4 * (0.5 + 0.5 * fbm(float2(q.x * 0.8, q.y * 0.3) + 3.0, 3));
    c += rampColour(k, xn) * (crest * 1.55 + (dy > 0.0 ? 0.0 : body)) * fall * band * own;
    // A spark: a thin coloured light behind one strip.
    if (sparkAt(int(i))) {
        float sx = (i + 0.5) * P * BEHIND;
        float w = P * 0.2;
        float line = bump(q.x - sx, w) * smoothstep(-0.02, -0.3, dy) * smoothstep(-1.9, -0.5, dy);
        c += sparkColour(hash12(float2(i, 17.0))) * line * 5.0;
    }
    return c;
}

inline float box(float2 q, float2 h, float soft) {
    float2 d = abs(q) - h;
    return 1.0 - smoothstep(-soft, soft, max(d.x, d.y));
}

/// What a ray sees once it leaves the glass: the field behind, a long softbox overhead, a dark studio.
inline float3 env(float3 o, float3 d, bool direct) {
    float3 c = float3(0.0008, 0.0009, 0.0016);
    if (d.z < 0.0) {
        float t = (ZB - o.z) / d.z;
        c = field(o.xy + d.xy * t, direct);
    }
    if (d.y > 0.0) {
        float t = (6.0 - o.y) / d.y;
        float2 q = o.xz + d.xz * t;
        c += float3(16.0, 16.4, 17.2) * box(q - float2(0.0, 1.4), float2(9.0, 2.2), 0.8);
    }
    return c;
}

// MARK: - Glass

inline float3 path(float3 o, float3 d, bool inside, float ior, thread Rng& rng, int maxDepth) {
    float3 thr = float3(1.0);
    for (int depth = 0; depth < maxDepth; depth++) {
        float t = march(o, d, inside ? -1.0 : 1.0, 4.0);
        if (t < 0.0) return thr * env(o, d, false);
        float3 p = o + d * t;
        float3 n = normalAt(p);
        if (inside) thr *= exp(-float3(5.0, 2.5, 1.2) * t);   // a touch of steel in thick glass
        float3 nf = inside ? -n : n;
        float eta = inside ? ior : 1.0 / ior;
        float cosi = clamp(-dot(d, nf), 0.0, 1.0);
        float F = fresnel(cosi, eta);
        if (rng.next() < F) {
            d = reflect(d, nf);
            o = p + nf * 0.0004;
        } else {
            d = refract(d, nf, eta);
            o = p - nf * 0.0004;
            inside = !inside;
        }
    }
    return thr * env(o, d, false) * 0.5;
}

inline float2 r4(uint i, float2 rot) { return fract(float2(0.5) + float(i) * float2(0.6287047, 0.5385888) + rot); }

Sample render(float2 px, thread Ctx& ctx) {
    float3 eye = float3(0.0, 0.0, 9.0);
    float2 rot = hash22(floor(px) * 0.7131 + 19.0);
    float rotL = hash12(floor(px) * 0.391 + 5.0);
    float3 sum = float3(0.0);
    float fg = 0.0;
    for (int k = 0; k < SUB; k++) {
        uint i = ctx.pass * uint(SUB) + uint(k);
        Ray ray = camera(eye, float3(0.0), 28.0, px, ctx.res, 0.0, 9.0, r4(i, rot));
        // Start at the slab's front: nothing stands between it and the camera.
        float t0 = (0.36 - ray.o.z) / ray.d.z;
        float3 o = ray.o + ray.d * t0;
        float t = march(o, ray.d, 1.0, 2.0);
        if (t < 0.0) { sum += env(o, ray.d, true); continue; }
        fg += 1.0;
        float lam = 400.0 + 300.0 * fract(0.5 + float(i) * 0.6180339887 + rotL);
        float ior = iorAt(lam);
        float3 w = spectrum(lam);
        float3 p = o + ray.d * t;
        float3 n = normalAt(p);
        float cosi = clamp(-dot(ray.d, n), 0.0, 1.0);
        float F = fresnel(cosi, 1.0 / ior);
        float3 refl = path(p + n * 0.0004, reflect(ray.d, n), false, ior, ctx.rng, 3);
        float3 refr = path(p - n * 0.0004, refract(ray.d, n, 1.0 / ior), true, ior, ctx.rng, 7);
        sum += w * (F * refl + (1.0 - F) * refr);
    }
    Sample s;
    s.fg = fg / float(SUB);
    s.color = sum / float(SUB);
    return s;
}

float3 post(float3 hdr, float2 uv, float2 px) {
    float3 c = hdr * 1.1;
    c *= vignette(uv, 0.28);
    c = agx(c, 0.55);
    return grain(c, px, 0.004);
}
