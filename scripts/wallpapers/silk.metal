// Silk — wide satin ribbons sweeping through a dark studio. Each ribbon is a thin, softly folded band that follows
// a slow logarithmic spiral and twists along its length, so it turns from a broad face to a glowing edge and back.
// A big soft key light from the upper left, a warm rim light from behind and a cool kicker from below; the ribbons
// shade each other and deepen in colour where they fold. The clock floats in the calm space the sweep leaves.

struct Rib {
    float3x3 M;      // world → ribbon space
    float3 O;
    // Centre line over x: y = a0 + a1·x + a2·e^(a3·(x − a4)) + a5·sin(a6·x + a7);  z = b0·x + b1·sin(b2·x + b3)
    float4 ya, yb, zb;
    float4 tw;       // twist θ = tw.x + tw.y·sin(tw.z·x + 0.7) + tw.w·smoothstep(tx.x, tx.y, x)
    float2 tx;
    float W, T;      // half width, half thickness
    float fold;      // soft lengthwise folds
    float curl;      // the band cups across its width
    float roll;      // its hems roll over slightly and catch the light
    float lip;       // Lipschitz correction
    float hue;       // palette offset
};

constant int NR = 2;
struct Scene { Rib r[3]; };

inline float3x3 rotX(float a) { float c = cos(a), s = sin(a); return float3x3(float3(1, 0, 0), float3(0, c, s), float3(0, -s, c)); }
inline float3x3 rotY(float a) { float c = cos(a), s = sin(a); return float3x3(float3(c, 0, -s), float3(0, 1, 0), float3(s, 0, c)); }
inline float3x3 rotZ(float a) { float c = cos(a), s = sin(a); return float3x3(float3(c, s, 0), float3(-s, c, 0), float3(0, 0, 1)); }

inline Scene makeScene() {
    Scene S;
    // Hero: enters low on the left, runs under the clock and climbs the right edge.
    Rib a;
    a.M = rotX(radians(-18.0));
    a.O = float3(0.30, -0.36, 0.0);
    a.ya = float4(-1.18, 0.0, 0.33, 1.15);
    a.yb = float4(1.0, -0.13, 0.85, 0.3);
    a.zb = float4(0.18, 0.5, 0.65, 0.4);
    a.tw = float4(1.45, 0.48, 0.8, 0.0); a.tx = float2(1.3, 2.9);
    a.W = 0.62; a.T = 0.006; a.fold = 0.03; a.curl = 0.12; a.roll = 0.05; a.lip = 0.65; a.hue = 0.0;
    S.r[0] = a;
    // Behind it, a layer that shows above its upper edge on the left and climbs the right side further in.
    Rib b = a;
    b.M = rotX(radians(-12.0));
    b.O = float3(0.42, -0.02, -1.1);
    b.ya = float4(-0.80, 0.03, 0.30, 0.95);
    b.yb = float4(1.55, -0.10, 1.05, 1.6);
    b.zb = float4(0.15, 0.35, 0.8, 2.0);
    b.tw = float4(1.75, 0.25, 0.7, 0.0); b.tx = float2(0.9, 2.6);
    b.W = 0.50; b.fold = 0.03; b.curl = 0.12; b.hue = 0.22;
    S.r[1] = b;
    // Close to the lens and far out of focus, a band crossing the lower left corner.
    Rib c = a;
    c.M = rotZ(radians(-35.0));
    c.O = float3(-1.55, -1.25, 2.6);
    c.ya = float4(0.0, 0.0, 0.0, 0.0);
    c.yb = float4(0.0, 0.08, 1.2, 0.0);
    c.zb = float4(0.0, 0.10, 0.9, 0.0);
    c.tw = float4(1.2, 0.0, 0.5, 0.0); c.tx = float2(0.0, 1.0);
    c.W = 0.22; c.fold = 0.0; c.hue = -0.3;
    S.r[2] = c;
    return S;
}

inline float3 centre(thread const Rib& r, float x, thread float3& d1, thread float3& d2) {
    float e = r.ya.z * exp(r.ya.w * (x - r.yb.x));
    float sa = sin(r.yb.z * x + r.yb.w), ca = cos(r.yb.z * x + r.yb.w);
    float sz = sin(r.zb.z * x + r.zb.w), cz = cos(r.zb.z * x + r.zb.w);
    float y = r.ya.x + r.ya.y * x + e + r.yb.y * sa;
    float z = r.zb.x * x + r.zb.y * sz;
    d1 = float3(1.0, r.ya.y + r.ya.w * e + r.yb.y * r.yb.z * ca, r.zb.x + r.zb.y * r.zb.z * cz);
    d2 = float3(0.0, r.ya.w * r.ya.w * e - r.yb.y * r.yb.z * r.yb.z * sa, -r.zb.y * r.zb.z * r.zb.z * sz);
    return float3(x, y, z);
}

/// Distance to one ribbon. Finds the closest point on the centre line by Newton's method, then measures in its
/// normal plane: `xc` is the curve parameter there, `bw` the across-width coordinate (−1…1), `T` the fibre direction.
inline float ribbon(float3 pw, thread const Rib& r, thread float& xc, thread float& bw, thread float3& T, thread float& qt) {
    float3 p = r.M * (pw - r.O);
    // Start from the nearest of a few candidates, so Newton settles on the right stretch of a tight bend.
    float x = p.x;
    float3 c, d1, d2;
    {
        float best = 1e9;
        for (int k = -2; k <= 2; k++) {
            float xi = p.x + 0.45 * float(k);
            float3 ci = centre(r, xi, d1, d2);
            float di = length_squared(ci - p);
            if (di < best) { best = di; x = xi; }
        }
    }
    for (int i = 0; i < 5; i++) {
        c = centre(r, x, d1, d2);
        float3 q = c - p;
        float g = dot(q, d1), h = dot(d1, d1) + dot(q, d2);
        x -= clamp(g / max(h, 0.3 * dot(d1, d1)), -0.8, 0.8);
    }
    c = centre(r, x, d1, d2);
    T = normalize(d1);
    float3 B = normalize(cross(T, float3(0.0, 0.0, 1.0)));
    float3 N = cross(B, T);
    float3 q = p - c;
    float u = dot(q, B), v = dot(q, N);
    qt = abs(dot(q, T)) * r.lip;
    float th = r.tw.x + r.tw.y * sin(r.tw.z * x + 0.7) + r.tw.w * smoothstep(r.tx.x, r.tx.y, x);
    float cs = cos(th), sn = sin(th);
    float a = cs * u - sn * v;
    float b = sn * u + cs * v;
    float xx = b / r.W;
    a -= r.fold * sin(xx * 3.6 + 1.1 * sin(x * 0.8 + r.zb.w) + r.zb.w) * (1.0 - xx * xx * 0.6);
    a -= r.curl * r.W * (xx * xx - 0.33) * sin(x * 0.9 + r.zb.w);
    float hem = smoothstep(0.72, 1.0, abs(xx));
    a -= r.roll * r.W * hem * hem;
    xc = x;
    bw = xx;
    // Back to world for the fibre direction.
    T = transpose(r.M) * T;
    float d = length(float2(a, max(abs(b) - r.W, 0.0))) - r.T;
    return d * r.lip;
}

inline float map(float3 p, thread const Scene& S) {
    float s, b, q; float3 T;
    float d = 1e9;
    for (int i = 0; i < NR; i++) d = min(d, ribbon(p, S.r[i], s, b, T, q));
    return d;
}

/// Everything but ribbon `skip`: shadows come from the other bands (a thin sheet grazing itself only makes acne).
inline float mapOthers(float3 p, thread const Scene& S, int skip) {
    float s, b, q; float3 T;
    float d = 1e9;
    // Where Newton hasn't settled (far from the band) the tangential residual keeps the estimate honest.
    for (int i = 0; i < NR; i++) if (i != skip) { float di = ribbon(p, S.r[i], s, b, T, q); d = min(d, max(di, q)); }
    return d;
}

inline float mapId(float3 p, thread const Scene& S, thread int& id, thread float& s, thread float& b, thread float3& T) {
    float best = 1e9;
    for (int i = 0; i < NR; i++) {
        float si, bi, qi; float3 Ti;
        float d = ribbon(p, S.r[i], si, bi, Ti, qi);
        if (d < best) { best = d; id = i; s = si; b = bi; T = Ti; }
    }
    return best;
}

inline float3 normalAt(float3 p, thread const Scene& S) {
    const float e = 0.0008;
    const float2 k = float2(1, -1);
    return normalize(k.xyy * map(p + k.xyy * e, S) + k.yyx * map(p + k.yyx * e, S) +
                     k.yxy * map(p + k.yxy * e, S) + k.xxx * map(p + k.xxx * e, S));
}

inline float trace(Ray r, thread const Scene& S, float tMax) {
    float t = 0.0;
    for (int i = 0; i < 260; i++) {
        float d = map(r.o + r.d * t, S);
        if (d < 0.00035 * t) return t;
        t += d * 0.8;
        if (t > tMax) break;
    }
    return -1.0;
}

/// Soft shadow toward a light of angular half-size `k` (IQ's penumbra estimate, improved).
inline float softShadow(float3 o, float3 l, thread const Scene& S, float k, int skip) {
    float res = 1.0, t = 0.02, ph = 1e10;
    for (int i = 0; i < 72; i++) {
        float h = mapOthers(o + l * t, S, skip);
        float y = h * h / (2.0 * ph);
        float d = sqrt(max(0.0, h * h - y * y));
        res = min(res, d / (k * max(0.0, t - y)));
        ph = h;
        t += clamp(h, 0.01, 0.4);
        if (res < 0.002 || t > 12.0) break;
    }
    res = clamp(res, 0.0, 1.0);
    return res * res * (3.0 - 2.0 * res);
}

inline float ambientOcclusion(float3 p, float3 n, thread const Scene& S) {
    float occ = 0.0, w = 1.0;
    for (int i = 1; i <= 5; i++) {
        float h = 0.03 + 0.09 * float(i);
        occ += (h - map(p + n * h, S)) * w;
        w *= 0.7;
    }
    return clamp(1.0 - 1.6 * occ, 0.0, 1.0);
}

// MARK: - Satin

inline float3 palette(float x) {
    // Deep blue → violet → magenta → rose, linear.
    const float3 c0 = float3(0.020, 0.060, 0.62);
    const float3 c1 = float3(0.20, 0.050, 0.66);
    const float3 c2 = float3(0.62, 0.035, 0.44);
    const float3 c3 = float3(0.95, 0.20, 0.36);
    x = clamp(x, 0.0, 1.0) * 3.0;
    if (x < 1.0) return mix(c0, c1, smoothstep(0.0, 1.0, x));
    if (x < 2.0) return mix(c1, c2, smoothstep(0.0, 1.0, x - 1.0));
    return mix(c2, c3, smoothstep(0.0, 1.0, x - 2.0));
}

/// Anisotropic GGX: `ax` along the fibres (t), `ay` across them (b).
inline float ggxAniso(float3 h, float3 n, float3 t, float3 b, float ax, float ay) {
    float th = dot(t, h) / ax, bh = dot(b, h) / ay, nh = dot(n, h);
    float d = th * th + bh * bh + nh * nh;
    return 1.0 / (PI * ax * ay * d * d);
}

/// Charlie sheen distribution (Estevez & Kulla): the soft glow of fibres at grazing angles.
inline float charlie(float nh, float r) {
    float inv = 1.0 / r;
    float sin2 = max(1.0 - nh * nh, 1e-4);
    return (2.0 + inv) * pow(sin2, inv * 0.5) / (2.0 * PI);
}

struct Light { float3 pos; float radius; float3 col; };

/// Satin over a thin, translucent sheet. `shadowF` is the light reaching the front face, `shadowB` the back face.
inline float3 satin(float3 p, float3 n, float3 v, float3 t, float3 albedo, float3 sheenCol, Light L, float shadowF, float shadowB) {
    float3 toL = L.pos - p;
    float dist = length(toL);
    float3 l = toL / dist;
    float ndl = dot(n, l), ndv = max(dot(n, v), 1e-3);
    float3 E = L.col / (dist * dist);
    float a0 = L.radius / (2.0 * dist);   // a sphere light widens the lobe (Karis)
    float3 b = normalize(cross(n, t));
    float3 tt = cross(b, n);
    float3 h = normalize(l + v);
    float ndlc = max(ndl, 0.0);
    float ax = clamp(0.16 + a0, 0.0, 1.0), ay = clamp(0.42 + a0, 0.0, 1.0);
    float D = ggxAniso(h, n, tt, b, ax, ay);
    float F = 0.04 + 0.96 * pow(1.0 - max(dot(h, v), 0.0), 5.0);
    float G = 1.0 / (ndv + ndlc + 0.15);
    float3 spec = mix(float3(1.0), sheenCol, 0.6) * D * F * G * ndlc * 1.0;
    float S = charlie(max(dot(n, h), 0.0), 0.4);
    float3 sheen = sheenCol * S * ndlc / (4.0 * (ndlc + ndv - ndlc * ndv) + 1e-3);
    // Light that wraps past the terminator returns deeper in colour.
    float wrap = max(0.0, (ndl + 0.3) / 1.3);
    float3 diff = albedo * (ndlc + (wrap - ndlc) * albedo * 1.3) / PI;
    // Thin silk glows when lit from behind: transmitted light, filtered twice by the dye.
    float3 trans = albedo * albedo * 1.6 * max(-ndl, 0.0) * (0.35 + 0.65 * pow(max(dot(-l, v), 0.0), 3.0)) / PI;
    return E * (shadowF * (diff + spec + sheen) + shadowB * trans);
}

// MARK: - Render

inline float3 backdrop(float3 d, float2 uv) {
    // A dark studio: indigo near the centre, falling to black, with a faint warm bloom low on the right.
    float3 c = float3(0.0022, 0.0024, 0.0068);
    float2 q = uv - float2(0.56, 0.60);
    c += float3(0.0090, 0.0075, 0.026) * exp(-2.6 * dot(q, q * float2(0.8, 1.6)));
    c += float3(0.026, 0.005, 0.018) * exp(-5.0 * length((uv - float2(0.92, 0.88)) * float2(1.0, 1.3)));
    c += float3(0.003, 0.008, 0.032) * exp(-5.0 * length((uv - float2(0.04, 0.84)) * float2(1.0, 1.3)));
    return c;
}

/// A lens sample for sub-sample `k` of this pass: a low-discrepancy sequence (the 4-D golden ratios, so it doesn't
/// line up with the pixel jitter's R2), rotated per pixel. Out-of-focus edges come out smooth instead of speckled.
inline float2 lensSample(float2 px, uint pass, int k, int sub) {
    float i = float(pass * uint(sub) + uint(k));
    return fract(float2(0.5) + i * float2(0.6287047, 0.5385888) + hash22(floor(px) * 0.7131 + 19.0));
}

constant int SUB = 3;

float3 shade(Ray ray, thread const Scene& S, float2 uv);

Sample render(float2 px, thread Ctx& ctx) {
    Scene S = makeScene();
    float3 eye = float3(0.0, 0.0, 7.0);
    float2 uv = px / ctx.res;
    float3 sum = float3(0.0);
    for (int k = 0; k < SUB; k++) {
        Ray ray = camera(eye, float3(0.0, 0.0, 0.0), 28.0, px, ctx.res, 0.14, 7.0, lensSample(px, ctx.pass, k, SUB));
        sum += shade(ray, S, uv);
    }
    Sample smp;
    smp.fg = 0.0;
    smp.color = sum / float(SUB);
    return smp;
}

float3 shade(Ray ray, thread const Scene& S, float2 uv) {
    float t = trace(ray, S, 30.0);
    if (t < 0.0) return backdrop(ray.d, uv);

    float3 p = ray.o + ray.d * t;
    int id = 0; float s = 0.0, bw = 0.0; float3 tw;
    mapId(p, S, id, s, bw, tw);
    float3 n = normalAt(p, S);
    float3 v = -ray.d;
    if (dot(n, v) < 0.0) n = -n;
    tw = normalize(tw - n * dot(tw, n));
    Rib r = S.r[id];

    // Colour runs along each ribbon and shifts a little across it.
    float x = 0.42 + 0.16 * s + r.hue - 0.06 * bw;
    float3 albedo = palette(x);
    float3 sheenCol = mix(albedo, float3(1.0, 0.82, 0.92), 0.45);

    float ao = ambientOcclusion(p, n, S);
    float3 pf = p + n * 0.012, pb = p - n * 0.012;

    Light lights[3] = {
        { float3(3.0, 7.0, 5.0), 3.4, float3(330.0, 318.0, 326.0) },    // key: big and soft, above and to the right
        { float3(5.5, 4.0, -6.5), 2.2, float3(840.0, 500.0, 600.0) },   // rim: warm, behind on the right
        { float3(-3.0, -6.0, 2.0), 2.5, float3(30.0, 55.0, 150.0) },     // kicker: cool, from below
    };
    float3 col = float3(0.0);
    for (int i = 0; i < 3; i++) {
        float3 l = normalize(lights[i].pos - p);
        float k = i == 0 ? 0.35 : 0.5;
        float sh = softShadow(dot(n, l) > 0.0 ? pf : pb, l, S, k, id);
        col += satin(p, n, v, tw, albedo, sheenCol, lights[i], sh, sh);
    }
    // Studio fill: a dim dome, and colour that deepens in folds (light bouncing between the ribbon and itself).
    float3 dome = mix(float3(0.004, 0.005, 0.014), float3(0.022, 0.022, 0.05), 0.5 + 0.5 * n.y);
    col += albedo * dome * mix(albedo * 0.5, float3(1.0), ao) * ao;

    // Gently fade the far ribbon into the dark (it sits back in the studio).
    float fog = exp(-max(0.0, t - 8.0) * 0.12);
    return mix(backdrop(ray.d, uv), col, fog);
}

float3 post(float3 hdr, float2 uv, float2 px) {
    float3 c = hdr * 1.0;
    c *= vignette(uv, 0.30);
    c = agx(c, 0.6);
    c = saturation(c, 1.04);
    return grain(c, px, 0.010);
}
