// Horizon — the open sea a minute before sunset. A low camera looks out over a calm swell toward a sun that is
// about to touch the horizon off to the right. The sky is single-scattered air with ozone (which is what turns the
// twilight zenith deep blue); the sea is a raymarched sum of directional waves whose detail is filtered by each
// sample's footprint: waves too small to resolve stop being geometry and become roughness, so the glitter path
// widens toward the horizon the way a real one does, and nothing shimmers.

constant float3 SUN_I = float3(24.0);
constant float EYE_H = 3.2;          // metres above mean sea level
constant float VFOV = 34.0;
constant int NWAVES = 56;
constant int NGEO = 24;              // the longest waves also displace the surface
constant float AMP_BOUND = 0.9;      // more than the geometric waves can ever add up to
constant float MS_LIFT = 22000.0;
constant float MS_GAIN = 1.1;

inline float3 sunDirection() {
    float el = radians(0.08), az = radians(20.0);
    return float3(cos(el) * sin(az), sin(el), -cos(el) * cos(az));
}

inline Atmos seaAir() { Atmos a = earth(); a.haze = 1.5; a.hM = 1100.0; a.g = 0.84; return a; }

// MARK: - Sky (single scattering with ozone, importance-spaced and jittered steps)

inline float ozone(float h) { return max(0.0, 1.0 - abs(h - 25e3) / 15e3); }

inline float3 sky(float3 ro, float3 rd, float tMax, float3 sunDir, Atmos A, int steps, int lsteps, float jit, thread float3& trans) {
    const float3 betaO = float3(0.650e-6, 1.881e-6, 0.085e-6);
    trans = float3(1.0);
    float2 pa = raySphere(ro, rd, A.rAtmos);
    float t0 = max(pa.x, 0.0), t1 = min(pa.y, tMax);
    float2 pg = raySphere(ro, rd, A.rPlanet);
    if (pg.x > 0.0) t1 = min(t1, pg.x);
    if (t1 <= t0) return float3(0.0);
    float mu = dot(rd, sunDir), g = A.g;
    float pR = 3.0 / (16.0 * PI) * (1.0 + mu * mu);
    float pM = 3.0 / (8.0 * PI) * ((1.0 - g * g) * (1.0 + mu * mu)) / ((2.0 + g * g) * pow(max(1e-4, 1.0 + g * g - 2.0 * g * mu), 1.5));
    float3 od = float3(0.0);
    float3 sumR = float3(0.0), sumM = float3(0.0), sumMS = float3(0.0);
    for (int i = 0; i < steps; i++) {
        float u0 = float(i) / float(steps), u1 = float(i + 1) / float(steps);
        float ta = t0 + (t1 - t0) * u0 * u0, tb = t0 + (t1 - t0) * u1 * u1;
        float ds = tb - ta;
        float3 x = ro + rd * (ta + ds * jit);
        float h = length(x) - A.rPlanet;
        float3 d = float3(exp(-h / A.hR), exp(-h / A.hM) * A.haze, ozone(h)) * ds;
        float3 odHere = od + d * 0.5;
        od += d;
        // Toward the sun, also with steps crowded near the point (where the air is densest).
        float2 ls = raySphere(x, sunDir, A.rAtmos);
        float3 lod = float3(0.0);
        bool shadow = false;
        float prev = 0.0;
        for (int j = 0; j < lsteps; j++) {
            float v = (float(j) + 1.0) / float(lsteps);
            float tl = ls.y * v * v;
            float dl = tl - prev;
            float3 y = x + sunDir * (tl - 0.5 * dl);
            prev = tl;
            float lh = length(y) - A.rPlanet;
            if (lh < 0.0) { shadow = true; break; }
            lod += float3(exp(-lh / A.hR), exp(-lh / A.hM) * A.haze, ozone(lh)) * dl;
        }
        float3 viewAtt = exp(-(A.betaR * odHere.x + A.betaM * 1.1 * odHere.y + betaO * odHere.z));
        if (!shadow) {
            float3 att = viewAtt * exp(-(A.betaR * lod.x + A.betaM * 1.1 * lod.y + betaO * lod.z));
            sumR += d.x * att;
            sumM += d.y * att;
        }
        // Second order, approximately: the air above this point, lit by cleaner sunlight higher up, sheds a blue
        // light on it. (Single scattering alone leaves the twilight sky grey-violet; this is most of its blue.)
        float hu = h + MS_LIFT;
        float3 xu = normalize(x) * (A.rPlanet + hu);
        float2 lu = raySphere(xu, sunDir, A.rAtmos);
        float3 lodU = float3(0.0);
        bool shadowU = false;
        prev = 0.0;
        for (int j = 0; j < lsteps; j++) {
            float v = (float(j) + 1.0) / float(lsteps);
            float tl = lu.y * v * v;
            float dl = tl - prev;
            float3 y = xu + sunDir * (tl - 0.5 * dl);
            prev = tl;
            float lh = length(y) - A.rPlanet;
            if (lh < 0.0) { shadowU = true; break; }
            lodU += float3(exp(-lh / A.hR), exp(-lh / A.hM) * A.haze, ozone(lh)) * dl;
        }
        if (!shadowU) {
            float3 tu = exp(-(A.betaR * lodU.x + A.betaM * 1.1 * lodU.y + betaO * lodU.z));
            float3 above = A.betaR * A.hR * exp(-h / A.hR) + A.betaM * A.hM * A.haze * exp(-h / A.hM);
            sumMS += (d.x * A.betaR + d.y * A.betaM) * viewAtt * tu * above;
        }
    }
    trans = exp(-(A.betaR * od.x + A.betaM * 1.1 * od.y + betaO * od.z));
    return SUN_I * (sumR * A.betaR * pR + sumM * A.betaM * pM + sumMS * (MS_GAIN / (4.0 * PI)));
}

inline float3 sunAt(float altitude, float3 sunDir, Atmos A) {
    const float3 betaO = float3(0.650e-6, 1.881e-6, 0.085e-6);
    float3 x = float3(0.0, A.rPlanet + altitude, 0.0);
    float2 ls = raySphere(x, sunDir, A.rAtmos);
    float3 lod = float3(0.0);
    float prev = 0.0;
    const int n = 24;
    for (int j = 0; j < n; j++) {
        float v = (float(j) + 1.0) / float(n);
        float tl = ls.y * v * v;
        float dl = tl - prev;
        float lh = length(x + sunDir * (tl - 0.5 * dl)) - A.rPlanet;
        prev = tl;
        if (lh < 0.0) return float3(0.0);
        lod += float3(exp(-lh / A.hR), exp(-lh / A.hM) * A.haze, ozone(lh)) * dl;
    }
    return SUN_I * exp(-(A.betaR * lod.x + A.betaM * 1.1 * lod.y + betaO * lod.z));
}

// MARK: - Clouds: a thin, distant deck of stratus streaks lying along the horizon

constant float CLOUD_H = 1900.0;
constant float CLOUD_TAU = 2.5;
constant float CLOUD_BIAS = 0.0;

/// fbm whose octaves fade as they shrink below the footprint `fp` (in noise units, per axis): no octave can alias.
inline float fbmAniso(float2 p, float2 fp, int octaves) {
    float s = 0.0, a = 0.5;
    for (int i = 0; i < octaves; i++) {
        float w = 1.0 - smoothstep(0.25, 0.8, max(fp.x, fp.y));
        s += a * w * noise(p);
        p = p * 2.07 + float2(17.1, 3.7);
        fp *= 2.07;
        a *= 0.5;
    }
    return s;
}

/// Adds the cloud deck to `skyL` (the clear sky along `rd`). `ro` is relative to the planet's centre.
inline float3 withClouds(float3 skyL, float3 ro, float3 rd, float3 sunDir, Atmos A, float pixA, float jit, thread float& alphaOut) {
    alphaOut = 0.0;
    float2 hit = raySphere(ro, rd, A.rPlanet + CLOUD_H);
    float t = hit.y;
    if (t <= 0.0 || t > 400e3) return skyL;
    float band = smoothstep(62e3, 85e3, t) * (1.0 - smoothstep(230e3, 330e3, t));
    if (band <= 0.0) return skyL;
    float3 x = ro + rd * t;
    float3 up = normalize(x);
    float mul = max(dot(rd, up), 0.004);
    // Layer coordinates: across the view (x) and along it (z), metres.
    float2 q = x.xz;
    float fs = t * pixA, fl = fs / mul;
    const float2 scale = float2(1.0 / 9000.0, 1.0 / 9000.0);
    float2 fp = float2(fs, fl) * scale;
    float2 uq = q * scale;
    float warp = fbmAniso(uq * 0.35 + 4.0, fp * 0.35, 3);
    float n = fbmAniso(uq + float2(warp * 1.6, warp * 0.4), fp, 6);
    // Fibres along each streak: fine across the view, long along it, so they survive the grazing footprint.
    n += 0.16 * fbmAniso(q * float2(1.0 / 1400.0, 1.0 / 40000.0) + 5.0, float2(fs / 1400.0, fl / 40000.0), 3);
    float cover = fbmAniso(q * float2(1.0 / 60000.0, 1.0 / 30000.0) + 11.0, float2(fs / 60000.0, fl / 30000.0), 2);
    float dens = smoothstep(0.02, 0.42, n + 0.30 * cover - 0.06 + CLOUD_BIAS) * band;
    if (dens <= 0.0) return skyL;
    float tau = dens * CLOUD_TAU / mul;
    float alpha = 1.0 - exp(-tau);
    alphaOut = alpha;
    // Light: the sun (low, gold, through the deck's own body), forward-scattered; plus the sky dome.
    float3 sunC = sunAt(CLOUD_H, sunDir, A);
    float mu = dot(rd, sunDir);
    float g1 = 0.72, g2 = -0.2;
    float hg1 = (1.0 - g1 * g1) / (4.0 * PI * pow(1.0 + g1 * g1 - 2.0 * g1 * mu, 1.5));
    float hg2 = (1.0 - g2 * g2) / (4.0 * PI * pow(1.0 + g2 * g2 - 2.0 * g2 * mu, 1.5));
    float phase = mix(hg2, hg1, 0.6);
    float self = exp(-dens * 1.6);
    float3 tz;
    float3 zen = sky(float3(0.0, A.rPlanet + CLOUD_H, 0.0), float3(0.0, 1.0, 0.0), 1e9, sunDir, A, 8, 5, jit, tz);
    float3 Lc = sunC * phase * 4.0 * PI * 0.11 * (0.35 + 0.65 * self) + zen * 1.2;
    // The air between the eye and the deck.
    float3 trD;
    float3 inD = sky(ro, rd, t, sunDir, A, 12, 6, jit, trD);
    float3 behind = skyL - inD;
    return inD + trD * Lc * alpha + behind * (1.0 - alpha);
}

// MARK: - Waves

struct Wave { float2 d; float k; float a; float s; float ph; };

/// The sea's spectrum: a long swell running at the camera (its crests lie across the frame), a weaker cross swell,
/// and wind waves that spread wider and shorten down to capillaries.
inline Wave wave(int i) {
    float fi = float(i);
    float t = fi / float(NWAVES - 1);
    float lambda = 64.0 * pow(0.852, fi);
    float h1 = hash12(float2(fi, 17.3)), h2 = hash12(float2(fi, 3.1)), h3 = hash12(float2(fi, 91.7));
    int fam = i % 3;
    float base = fam == 0 ? 0.0 : (fam == 1 ? 0.62 : -0.38);
    float spread = mix(fam == 0 ? 0.30 : 0.45, 1.3, smoothstep(0.15, 0.85, t));
    float ang = base + (h1 - 0.5) * 2.0 * spread;
    Wave w;
    w.d = float2(sin(ang), cos(ang));
    w.k = 2.0 * PI / lambda;
    float steep = lambda > 12.0 ? 0.022 : mix(0.032, 0.022, smoothstep(0.3, 1.0, t));
    if (fam == 1 && lambda > 6.0) steep *= 0.6;
    w.s = steep * (0.7 + 0.6 * h2);
    w.a = w.s / w.k;
    w.ph = h3 * 2.0 * PI;
    return w;
}

/// How much of a wave survives a footprint of `fl` metres along the view and `fs` across it (`v` = view, horizontal).
inline float keep(Wave w, float2 v, float fl, float fs) {
    float a = dot(w.d, v), b = w.d.x * v.y - w.d.y * v.x;
    float r = sqrt(a * a * fl * fl + b * b * fs * fs) * w.k * (0.5 / PI);
    return 1.0 - smoothstep(0.2, 0.85, r);
}

/// Wind lanes: patches where the ripples are stronger or weaker (this is what makes a calm sea's sheen patchy).
inline float wind(float2 p, float fl) {
    float2 q = float2(p.x * 0.0045 + 0.0018 * p.y, p.y * 0.011);
    float n = fbm(q + 7.3, 3) * (1.0 - smoothstep(0.08, 0.5, fl * 0.011));
    return 0.62 + 0.76 * smoothstep(-0.32, 0.32, n);
}

// MARK: - Scene

constant float R_EARTH = 6371e3;
constant float T_FAR = 3000.0;

inline float footprintAngle(float2 res) { return 2.0 * tan(radians(VFOV) * 0.5) / res.y; }
inline float curveDrop(float2 p) { return dot(p, p) / (2.0 * R_EARTH); }
/// Sine of the angle between the ray and the (curved) sea at distance t.
inline float grazing(float3 d, float t) { return max(-d.y - t / R_EARTH, 1e-4); }
/// Smaller root of t²/2R + d.y t + c = 0 (the ray's height above the curved sea equals EYE_H − c… i.e. a level).
inline float levelHit(float dy, float c) {
    float a = 0.5 / R_EARTH, disc = dy * dy - 4.0 * a * c;
    if (disc < 0.0) return -1.0;
    return (-dy - sqrt(disc)) / (2.0 * a);
}

inline float geoHeight(float2 p, float2 v, float fl, float fs, thread const Wave* W) {
    float h = 0.0;
    for (int i = 0; i < NGEO; i++) {
        float k = keep(W[i], v, fl, fs);
        h += k * W[i].a * sin(W[i].k * dot(W[i].d, p) + W[i].ph);
    }
    return h;
}

inline bool marchSea(Ray r, float pixA, thread const Wave* W, thread float& tHit) {
    if (r.d.y >= 0.0) return false;
    float2 v = normalize(r.d.xz);
    float tSea = levelHit(r.d.y, EYE_H);
    if (tSea < 0.0) return false;
    if (tSea > T_FAR) { tHit = tSea; return true; }
    float t = max(0.0, levelHit(r.d.y, EYE_H - AMP_BOUND));
    float tLow = levelHit(r.d.y, EYE_H + AMP_BOUND);
    float tEnd = tLow > 0.0 ? tLow : tSea * 1.5;
    float last = t;
    bool hit = false;
    for (int i = 0; i < 320; i++) {
        float3 p = r.o + r.d * t;
        float g = grazing(r.d, t);
        float fs = t * pixA, fl = fs / g;
        float h = p.y + curveDrop(p.xz) - geoHeight(p.xz, v, fl, fs, W);
        if (h < 0.0) { hit = true; break; }
        if (t >= tEnd) { hit = true; break; }
        last = t;
        t = min(t + clamp(h / (g + 0.2), 0.004 + t * 0.0012, 60.0), tEnd);
    }
    if (!hit) { tHit = tSea; return true; }
    float a = last, b = t;
    for (int i = 0; i < 14; i++) {
        float m = 0.5 * (a + b);
        float3 p = r.o + r.d * m;
        float g = grazing(r.d, m);
        float fs = m * pixA, fl = fs / g;
        if (p.y + curveDrop(p.xz) - geoHeight(p.xz, v, fl, fs, W) > 0.0) a = m; else b = m;
    }
    tHit = b;
    return true;
}

inline float gaussian(float2 m, float a, float b, float c) {
    float det = max(a * c - b * b, 1e-12);
    float q = (c * m.x * m.x - 2.0 * b * m.x * m.y + a * m.y * m.y) / det;
    return exp(-0.5 * q) / (2.0 * PI * sqrt(det));
}

inline float smithG1(float cosT, float sigma) {
    float c = clamp(cosT, 1e-4, 0.9999);
    float a = c / (sqrt(1.0 - c * c) * 1.41421356 * max(sigma, 1e-4));
    return a < 1.6 ? (3.535 * a + 2.181 * a * a) / (1.0 + 2.276 * a + 2.577 * a * a) : 1.0;
}

inline float fresnel(float c) { float m = 1.0 - clamp(c, 0.0, 1.0); return 0.0204 + 0.9796 * m * m * m * m * m; }

Sample render(float2 px, thread Ctx& ctx) {
    Atmos A = seaAir();
    float3 sunDir = sunDirection();
    float pitch = radians(5.0);
    float3 eye = float3(0.0, EYE_H, 0.0);
    Ray ray = camera(eye, eye + float3(0.0, sin(pitch), -cos(pitch)), VFOV, px, ctx.res, 0.0, 1.0, float2(0.0));
    float pixA = footprintAngle(ctx.res);
    float3 planetEye = float3(0.0, A.rPlanet + EYE_H, 0.0);
    // Stratified across passes: a per-pixel rotation of the R2 sequence.
    float2 rot = hash22(floor(px) * 0.7123 + 3.1);
    float jit = fract(rot.x + float(ctx.pass) * 0.6180339887);

    Sample s;
    s.fg = 0.0;
    float3 trans;

    Wave W[NWAVES];
    for (int i = 0; i < NWAVES; i++) W[i] = wave(i);

    float tHit;
    if (!marchSea(ray, pixA, W, tHit)) {
        float3 col = sky(planetEye, ray.d, 1e9, sunDir, A, 32, 10, jit, trans);
        float cloudA;
        col = withClouds(col, planetEye, ray.d, sunDir, A, pixA, jit, cloudA);
        float occl = 1.0 - cloudA;
        // The sun's disc, flattened a little by refraction, limb-darkened.
        float3 sd = ray.d - sunDir;
        float3 rt = normalize(cross(sunDir, float3(0.0, 1.0, 0.0)));
        float3 u2 = cross(rt, sunDir);
        float2 o = float2(dot(sd, rt), dot(sd, u2) / 0.86);
        float rr = length(o) / radians(0.27);
        float disc = 1.0 - smoothstep(0.96, 1.02, rr);
        float limb = 0.55 + 0.45 * sqrt(max(0.0, 1.0 - rr * rr));
        col += disc * limb * trans * SUN_I * 160.0 * occl;
        s.color = col;
        return s;
    }

    float3 p = ray.o + ray.d * tHit;
    float2 v = normalize(ray.d.xz);
    float g = grazing(ray.d, tHit);
    float fs = tHit * pixA, fl = fs / g;
    float wl = wind(p.xz, fl);

    // Resolved slope from every wave the footprint keeps; the rest becomes roughness (a slope covariance).
    float2 slope = float2(0.0);
    float cap = 1.4e-3 * wl * wl;
    float ca = cap, cb = 0.0, cc = cap;
    float crest = 0.0;
    for (int i = 0; i < NWAVES; i++) {
        Wave w = W[i];
        float k = keep(w, v, fl, fs);
        float sc = w.k > 2.0 ? wl : 1.0;   // wind lanes ruffle only the short waves
        float th = w.k * dot(w.d, p.xz) + w.ph;
        slope += k * sc * w.s * cos(th) * w.d;
        if (i < NGEO) crest += k * w.a * sin(th);
        float lost = (1.0 - k * k) * 0.5 * w.s * w.s * sc * sc;
        ca += lost * w.d.x * w.d.x;
        cb += lost * w.d.x * w.d.y;
        cc += lost * w.d.y * w.d.y;
    }
    ca += 3e-6; cc += 3e-6;   // the sun's own size
    // The curved sea tilts away with distance.
    float3 up = normalize(float3(p.x / R_EARTH, 1.0, p.z / R_EARTH));
    float3 n = normalize(float3(-slope.x, 1.0, -slope.y) + (up - float3(0, 1, 0)));
    float3 V = -ray.d;
    float nv = max(dot(n, V), 1e-4);

    // Sky reflection: facets drawn from the unresolved slopes (stratified across passes), weighted by how much of
    // each the eye can see.
    float l11 = sqrt(ca), l21 = cb / l11, l22 = sqrt(max(cc - l21 * l21, 1e-9));
    float3 refl = float3(0.0);
    float wsum = 0.0;
    float3 rOrigin = float3(0.0, A.rPlanet + 1.0, 0.0);
    const int NR = 3;
    for (int j = 0; j < NR; j++) {
        float idx = float(ctx.pass * NR + j);
        float2 u = fract(rot + idx * float2(0.7548776662, 0.5698402910));
        float rG = sqrt(-2.0 * log(max(u.x, 1e-6)));
        float2 z = rG * float2(cos(2.0 * PI * u.y), sin(2.0 * PI * u.y));
        float2 m = float2(l11 * z.x, l21 * z.x + l22 * z.y);
        float3 nf = normalize(float3(-(slope.x + m.x), 1.0, -(slope.y + m.y)) + (up - float3(0, 1, 0)));
        float vn = dot(V, nf);
        if (vn <= 0.0) continue;
        float w = vn / nv;
        float3 rd = reflect(ray.d, nf);
        float fr = fresnel(vn);
        // Express the reflected ray in the local frame of the far point (the sea curves away).
        float ry = dot(rd, up);
        float3 rl = normalize(float3(rd.x, ry, rd.z));
        if (rl.y < 0.0) { rl.y = -rl.y; fr *= fresnel(rl.y + 0.2); }   // into the next wave: a second bounce
        rl.y = max(rl.y, 0.0015);
        rl = normalize(rl);
        float3 tr2;
        float3 rs = sky(rOrigin, rl, 1e9, sunDir, A, 16, 6, fract(jit + 0.37 * float(j)), tr2);
        float ca2;
        refl += w * fr * withClouds(rs, rOrigin, rl, sunDir, A, pixA * 4.0, jit, ca2);
        wsum += w;
    }
    refl /= max(wsum, 1e-4);

    // The sun's glitter, analytic (Cox–Munk): the share of facets that turn the sun toward the eye.
    float3 L = sunDir;
    float3 hv = normalize(L + V);
    float hy = dot(hv, up);
    float2 sh = float2(-hv.x / hy, -hv.z / hy);
    float3 nh = normalize(float3(-sh.x, 1.0, -sh.y));
    float cth = max(dot(nh, n), 1e-3);
    float pdf = gaussian(sh - slope, ca, cb, cc);
    float sigV = sqrt(ca * v.x * v.x + 2.0 * cb * v.x * v.y + cc * v.y * v.y);
    float2 lh = normalize(L.xz);
    float sigL = sqrt(ca * lh.x * lh.x + 2.0 * cb * lh.x * lh.y + cc * lh.y * lh.y);
    float G = smithG1(nv, sigV) * smithG1(max(dot(n, L), 1e-4), sigL);
    float3 sunCol = sunAt(2.0, sunDir, A);
    float3 glint = sunCol * fresnel(dot(V, hv)) * pdf * G / (4.0 * nv * cth * cth * cth * cth);

    // Light that enters the water and comes back out: the deep sea's own colour, and a hint of it glowing through
    // the crests that stand between the eye and the sun.
    float3 tz;
    float3 zen = sky(planetEye, float3(0.0, 1.0, 0.0), 1e9, sunDir, A, 12, 6, jit, tz);
    float3 skyE = zen * PI * 0.9 + sunCol * max(sunDir.y, 0.0);
    float fr0 = fresnel(nv);
    float3 body = skyE * float3(0.0016, 0.0062, 0.0090);
    float back = pow(max(0.0, dot(v, normalize(L.xz))), 3.0);
    float lift = smoothstep(0.05, 0.4, crest);
    float3 sss = sunCol * float3(0.004, 0.022, 0.020) * lift * back * (1.0 - smoothstep(60.0, 400.0, tHit));

    float3 col = refl + glint + (body + sss) * (1.0 - fr0);

    float3 inscatter = sky(planetEye, ray.d, tHit, sunDir, A, 10, 6, jit, trans);
    s.color = col * trans + inscatter;
    return s;
}

float3 post(float3 hdr, float2 uv, float2 px) {
    float3 c = hdr * 0.38 * float3(0.87, 0.955, 1.16);
    c *= vignette(uv, 0.22);
    c = agx(c, 0.6);
    c = saturation(c, 1.04);
    return grain(c, px, 0.010);
}
