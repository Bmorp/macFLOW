// Alpine — a high range at the first light of dawn. The sun is still below the horizon for the valley: only the
// upper faces stand high enough to catch it, and its light, having grazed the lower atmosphere (and the ozone
// layer) on the way, arrives rose-gold. Everything lower lies in shadow under a deep twilight sky; a sea of fog
// fills the valley. Behind the range, opposite the sun, the sky shows the Earth's shadow and the Belt of Venus.
// The camera stands on a snow col; its smooth, shadowed brow is the depth layer.

#define DEBUG_SHAPE 0
#define SWATCH 1

constant float CAM_H = 3200.0;
constant float FG_DIST = 4200.0;   // samples hitting closer than this belong to the near ridge
constant float3 SUN_I = float3(22.0);

// The sky's sun, 1.6° below the horizon (the twilight sky and the colour of the light), and the shading sun a little
// higher (so lit faces take the light at a usable angle and cast long shadows). Azimuth 40° left of behind.
inline float3 skySun() { return float3(-0.64254, -0.02792, 0.76575); }
inline float3 shadeSun() { return float3(-0.64269, 0.01745, 0.76593); }

inline Atmos alpineAir() { Atmos a = earth(); a.haze = 0.7; a.hM = 1400.0; return a; }

// MARK: - Atmosphere with ozone (the Chappuis band keeps a twilight sky blue instead of olive) and a multiple-
// scattering glow (what keeps the Earth's shadow blue rather than black).

constant float3 BETA_O3 = float3(0.650e-6, 1.881e-6, 0.085e-6);
constant float3 MS_GLOW = float3(0.012, 0.030, 0.085);
inline float ozoneD(float h) { return max(0.0, 1.0 - abs(h - 25000.0) / 15000.0); }

inline float3 scatterO(float3 ro, float3 rd, float tMax, float3 sunDir, float3 sunI, Atmos A, int steps, int lightSteps,
                       float jitter, thread float3& trans) {
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
    float3 od = float3(0.0);
    float3 sumR = float3(0.0), sumM = float3(0.0), sumMS = float3(0.0);
    for (int i = 0; i < steps; i++) {
        float3 x = ro + rd * (t0 + (float(i) + jitter) * ds);
        float h = length(x) - A.rPlanet;
        float3 d = float3(exp(-h / A.hR), exp(-h / A.hM) * A.haze, ozoneD(h)) * ds;
        od += d;
        float3 tv = exp(-(A.betaR * od.x + A.betaM * 1.1 * od.y + BETA_O3 * od.z));
        sumMS += (d.x * A.betaR + d.y * A.betaM) * tv;
        float2 ls = raySphere(x, sunDir, A.rAtmos);
        float lds = ls.y / float(lightSteps);
        float3 lod = float3(0.0);
        bool shadow = false;
        for (int j = 0; j < lightSteps; j++) {
            float3 y = x + sunDir * ((float(j) + 0.5) * lds);
            float lh = length(y) - A.rPlanet;
            if (lh < 0.0) { shadow = true; break; }
            lod += float3(exp(-lh / A.hR), exp(-lh / A.hM) * A.haze, ozoneD(lh)) * lds;
        }
        if (!shadow) {
            float3 tau = A.betaR * (od.x + lod.x) + A.betaM * 1.1 * (od.y + lod.y) + BETA_O3 * (od.z + lod.z);
            float3 att = exp(-tau);
            sumR += d.x * att;
            sumM += d.y * att;
        }
    }
    trans = exp(-(A.betaR * od.x + A.betaM * 1.1 * od.y + BETA_O3 * od.z));
    return sunI * (sumR * A.betaR * pR + sumM * A.betaM * pM + sumMS * MS_GLOW * (1.0 / (4.0 * PI)));
}

inline float3 sunlightO(float altitude, float3 sunDir, float3 sunI, Atmos A, int steps) {
    float3 x = float3(0.0, A.rPlanet + altitude, 0.0);
    float2 ls = raySphere(x, sunDir, A.rAtmos);
    float lds = ls.y / float(steps);
    float3 lod = float3(0.0);
    for (int j = 0; j < steps; j++) {
        float lh = length(x + sunDir * ((float(j) + 0.5) * lds)) - A.rPlanet;
        if (lh < 0.0) return float3(0.0);
        lod += float3(exp(-lh / A.hR), exp(-lh / A.hM) * A.haze, ozoneD(lh)) * lds;
    }
    return sunI * exp(-(A.betaR * lod.x + A.betaM * 1.1 * lod.y + BETA_O3 * lod.z));
}

// MARK: - Terrain

inline float bump(float x, float c, float r) { float d = (x - c) / r; return exp(-d * d); }

/// Ridged multifractal with Quilez-style erosion: sharp arêtes, smooth couloirs. ~0…1. `oct` is fractional.
inline float ridged(float2 p, float oct) {
    float s = 0.0, a = 0.5, w = 1.0;
    float2 d = float2(0.0);
    for (int i = 0; i < 13; i++) {
        float k = clamp(oct - float(i), 0.0, 1.0);
        if (k <= 0.0) break;
        float3 n = noised(p);
        float r = 1.0 - abs(n.x);
        d += -sign(n.x) * n.yz * w;
        float v = r * r;
        s += a * v * w * k / (1.0 + 0.35 * dot(d, d));
        w = clamp(v * 1.3, 0.2, 1.0);
        p = ROT2 * p * 2.03;
        a *= 0.47;
    }
    return s;
}

/// Gully erosion (after Clay John's "Eroded Terrain Noise"): cosine ridges that run along `dir` — downhill — blended
/// over jittered cells, so drainage lines form and branch. Returns (height, d/dx, d/dy).
inline float3 erosionCell(float2 p, float2 dir) {
    float2 ip = floor(p), fp = fract(p);
    float3 va = float3(0.0);
    float wt = 0.0;
    for (int i = -2; i <= 1; i++) {
        for (int j = -2; j <= 1; j++) {
            float2 o = float2(i, j);
            float2 h = hash22(ip - o) * 0.5;
            float2 pp = fp + o - h;
            float w = exp(-dot(pp, pp) * 2.0);
            wt += w;
            float mag = dot(pp, dir) * (2.0 * PI);
            va += float3(cos(mag), -sin(mag) * dir) * w;
        }
    }
    return va / wt;
}

/// The macro landform. From near to far: the camera's own summit (falling away out of frame), a near ridge 2.5 km
/// ahead whose crest rises to either side (the depth layer), a valley of fog with a few lower ridges breaking it, and
/// the high range 25–40 km off (higher toward the sides, lower in the centre). Behind the camera, out of frame, the
/// mountains that keep the near ridge in shadow. Cheap; the erosion is layered on top.
constant float2 SEED = float2(0.4, 6.6);
inline float baseH(float2 p, float oct) {
    float x = p.x, d = -p.y;
    float2 w = p + 1800.0 * float2(fbm(p * 0.00007 + 3.1, 3), fbm(p * 0.00007 + 7.7, 3));
    float floorH = 1500.0 + 150.0 * fbm(p * 0.0004, 3);

    // The high range.
    float band = smoothstep(-19000.0, -27000.0, w.y) * smoothstep(-48000.0, -36000.0, w.y);
    float lat = 0.62 + 0.38 * smoothstep(2000.0, 12000.0, abs(x + 600.0));
    float r = ridged(w * 0.00011 + SEED, clamp(oct, 1.0, 5.0));
    float range = 7600.0 * band * lat * pow(max(r, 0.0), 1.2);

    // Lower ridges in the middle distance, just breaking the fog.
    float mid = 1500.0 * smoothstep(-8000.0, -12000.0, w.y) * smoothstep(-22000.0, -16000.0, w.y)
              * ridged(w * 0.00025 + SEED + 3.0, clamp(oct - 0.5, 1.0, 5.0));

    // The near ridge.
    float crestD = 2500.0 + 220.0 * sin(x * 0.0011 + 0.5);
    float crestH = 2950.0 + 1.0e-4 * x * x + 40.0 * fbm(float2(x * 0.004, 1.7), 3);
    float u = d - crestD;
    float su = sqrt(u * u + 900.0);                                  // a rounded crest
    float nearR = crestH + 30.0 - (u < 0.0 ? 0.62 : 0.85) * su;

    // The camera's own summit.
    float own = 3195.0 - 0.55 * max(0.0, length(p) - 25.0);

    float2 bq = (p - float2(-5600.0, 7200.0)) / float2(5000.0, 3500.0);
    float behind = 1300.0 + 3000.0 * exp(-dot(bq, bq));

    return max(max(floorH + max(range, mid), max(nearR, own)), behind);
}

constant float ERO_AMP = 260.0;     // metres of gully relief at most

inline float erode(float2 p, float2 g, float oct) {
    // Flats (valley floors, snowfields) erode less than steep faces.
    float steep = smoothstep(0.15, 0.7, length(g));
    float2 q = p * (1.0 / 800.0);
    float2 dir = float2(g.y, -g.x) * 2.2;
    float3 h = float3(0.0);
    float a = 0.5, f = 1.0;
    int n = int(clamp(oct - 2.0, 0.0, 5.0));
    for (int i = 0; i < 5; i++) {
        if (i >= n) break;
        h += erosionCell(q * f, dir + h.zy * float2(1.0, -1.0) * 2.6) * a * float3(1.0, f, f);
        a *= 0.5;
        f *= 2.0;
    }
    return (h.x - 0.5) * ERO_AMP * steep;
}

/// The snow col the camera stands on: a smooth, wind-shaped brow ahead whose shoulders rise to either side.
inline float snowH(float2 p, float oct) {
    float x = p.x, d = -p.y;
    float browD = 150.0 - 0.0012 * x * x;
    float browH = CAM_H - 17.0 + 0.0011 * x * x;
    float h = browH - 0.075 * max(0.0, browD - d);
    float over = max(0.0, d - browD);
    h -= 0.012 * over * over;                                  // the drop beyond the brow
    // Broad wind-shaped undulation, then sastrugi along the wind (fading where they'd be sub-pixel anyway).
    h += 1.6 * fbm(p * float2(0.012, 0.02) + 4.0, 4);
    float2 q = float2(0.8 * p.x + 0.6 * p.y, -0.6 * p.x + 0.8 * p.y);
    h += 0.12 * fbm(q * float2(0.35, 1.4), int(clamp(oct - 6.0, 0.0, 5.0)));
    return h;
}

/// Height in metres at (x, z). `oct` controls detail (fewer octaves far away).
inline float terrain(float2 p, float oct) {
    float b = baseH(p, oct);
    float e = 30.0;
    float2 g = float2(baseH(p + float2(e, 0), 3.0) - baseH(p - float2(e, 0), 3.0),
                      baseH(p + float2(0, e), 3.0) - baseH(p - float2(0, e), 3.0)) / (2.0 * e);
    float h = b + erode(p, g, oct);
    h += 14.0 * fbm(p * 0.012, int(clamp(oct - 6.0, 0.0, 6.0)));
    return h;
}

inline float detailFor(float t, float pixAngle) {
    float fp = max(t * pixAngle, 0.002);
    return clamp(log2(2200.0 / (2.0 * fp)) + 1.0, 3.0, 13.0);
}

inline float3 normalAt(float2 p, float t, float oct, float pixAngle) {
    float e = max(0.004, t * pixAngle * 0.7);
    float hx = terrain(p + float2(e, 0), oct) - terrain(p - float2(e, 0), oct);
    float hz = terrain(p + float2(0, e), oct) - terrain(p - float2(0, e), oct);
    return normalize(float3(-hx, 2.0 * e, -hz));
}

inline float march(Ray r, float tMax, float pixAngle, thread bool& hit) {
    float t = 1.0, last = 1.0;
    hit = false;
    for (int i = 0; i < 800 && t < tMax; i++) {
        float3 p = r.o + r.d * t;
        float oct = detailFor(t, pixAngle);
        float h = p.y - terrain(p.xz, oct);
        if (h < 0.0003 * t) { hit = true; break; }
        if (p.y > 6500.0 && r.d.y > 0.0) break;
        last = t;
        t += max(0.3 * h, 0.01 + t * 0.0005);
    }
    if (!hit) return tMax;
    float a = last, b = t;
    for (int i = 0; i < 14; i++) {
        float m = 0.5 * (a + b);
        float3 p = r.o + r.d * m;
        if (p.y - terrain(p.xz, detailFor(m, pixAngle)) > 0.0) a = m; else b = m;
    }
    return b;
}

inline float shadow(float3 p, float3 l) {
    float t = 1.0;
    for (int i = 0; i < 220; i++) {
        float3 q = p + l * t;
        float h = q.y - terrain(q.xz, 7.0);
        if (h < 0.0) return 0.0;
        t += clamp(0.35 * h, 1.0 + t * 0.002, 800.0);
        if (t > 60000.0 || q.y > 6500.0) break;
    }
    return 1.0;
}

// MARK: - Valley fog

inline float fogTop(float2 p) { return 2450.0 + 110.0 * fbm(p * 0.00030 + 2.0, 3) + 45.0 * fbm(p * 0.0014, 3); }

inline float fogDensity(float3 p) {
    float top = fogTop(p.xz);
    float k = clamp((top - p.y) / 70.0, 0.0, 1.0);
    if (k <= 0.0) return 0.0;
    float wisp = 0.65 + 0.7 * fbm3(p * float3(0.004, 0.008, 0.004), 3);
    return 0.02 * k * k * max(wisp, 0.0);
}

// MARK: - Render

Sample render(float2 px, thread Ctx& ctx) {
    Atmos A = alpineAir();
    float3 sunS = skySun(), sunL = shadeSun();
    float vfov = 34.0;
    float pixAngle = 2.0 * tan(radians(vfov) * 0.5) / ctx.res.y;
    float3 eye = float3(0.0, CAM_H, 0.0);
    float3 target = eye + float3(0.03, -0.072, -1.0);
    // A real lens: focused far, a little depth of field on the nearest snow.
    Ray ray = camera(eye, target, vfov, px, ctx.res, 0.0, 9000.0, ctx.rng.next2());

    float3 planetEye = float3(0.0, A.rPlanet + CAM_H, 0.0);
    float3 trans;
    Sample s;
    s.fg = 0.0;
    float jit = ctx.rng.next();

    bool hit;
    float t = march(ray, 90000.0, pixAngle, hit);

    float3 tz, th, ta;
    float3 zenith = scatterO(planetEye, float3(0.0, 1.0, 0.0), 1e9, sunS, SUN_I, A, 16, 8, 0.5, tz);
    float3 horizSun = scatterO(planetEye, normalize(float3(sunS.x, 0.06, sunS.z)), 1e9, sunS, SUN_I, A, 16, 8, 0.5, th);
    float3 horizAnti = scatterO(planetEye, normalize(float3(-sunS.x, 0.08, -sunS.z)), 1e9, sunS, SUN_I, A, 16, 8, 0.5, ta);

    float3 col = float3(0.0);
#if SWATCH
    if (px.y < ctx.res.y * 0.08) {
        float u = px.x / ctx.res.x;
        s.color = u < 0.33 ? zenith : (u < 0.66 ? horizSun : horizAnti);
        return s;
    }
#endif
    if (!hit) {
        col = scatterO(planetEye, ray.d, 1e9, sunS, SUN_I, A, 32, 10, jit, trans);
    } else {
        float3 p = ray.o + ray.d * t;
        float oct = detailFor(t, pixAngle) + 0.5;
        float3 n = normalAt(p.xz, t, oct, pixAngle);
#if DEBUG_SHAPE
        float3 L = normalize(float3(-0.5, 0.5, 0.7));
        s.color = float3(0.05 + 0.6 * max(0.0, dot(n, L))) * exp(-t / 40000.0);
        s.fg = t < FG_DIST ? 1.0 : 0.0;
        return s;
#endif
        float3 sunCol = sunlightO(p.y, sunS, SUN_I, A, 16) * 1.8;
        float3 l = coneSample(sunL, cos(radians(0.45)), ctx.rng.next2());
        float ndl = max(0.0, dot(n, l));
        float sh = (ndl > 0.0 && luma(sunCol) > 1e-5) ? shadow(p + n * 0.5, l) : 0.0;

        // Snow on gentle ground and in the gullies, rock on the steepest faces.
        float sn = smoothstep(0.48, 0.66, n.y + 0.12 * fbm(p.xz * 0.003, 4) + 0.00008 * (p.y - 2600.0));
        float3 rock = float3(0.12, 0.105, 0.095) * (0.7 + 0.6 * (0.5 + 0.5 * fbm(p.xz * 0.02, 3)));
        float3 alb = mix(rock, float3(0.86, 0.90, 0.95), sn);

        // Sky light: the dome above, the bright horizon toward the sun, the cooler one opposite.
        float3 skyLight = zenith * (0.5 + 0.5 * n.y) * 2.6
                        + horizSun * max(0.0, dot(n, normalize(float3(sunS.x, 0.3, sunS.z)))) * 0.25
                        + horizAnti * max(0.0, dot(n, normalize(float3(-sunS.x, 0.3, -sunS.z)))) * 0.5;
        float occ = 0.0;
        float r0 = max(3.0, t * 0.004);
        for (int k = 0; k < 4; k++) {
            float a = float(k) * 1.5708 + 0.6;
            float2 o = float2(cos(a), sin(a)) * r0;
            occ += max(0.0, terrain(p.xz + o, 6.0) - p.y) / r0;
        }
        float ao = clamp(1.0 - 0.35 * occ, 0.3, 1.0);
        col = alb * (sunCol * ndl * sh + skyLight * ao) * (1.0 / PI);
        // Snow's soft sheen at grazing angles.
        float fres = pow(1.0 - max(0.0, dot(n, -ray.d)), 5.0);
        col += sn * fres * 0.12 * horizAnti;
        s.fg = t < FG_DIST ? 1.0 : 0.0;
    }

    // Valley fog between the eye and the hit: a slab, marched with jitter.
    const float fogHi = 2620.0, fogLo = 2000.0;
    float accT = 1.0, tFog = 0.0, wFog = 0.0;
    float3 fogL = float3(0.0);
    if (ray.d.y < 0.0) {
        float tEnd = hit ? t : 90000.0;
        float ta0 = (CAM_H - fogHi) / -ray.d.y, ta1 = min(tEnd, (CAM_H - fogLo) / -ray.d.y);
        ta1 = min(ta1, ta0 + 40000.0);
        if (ta1 > ta0) {
            const int N = 40;
            float dt = (ta1 - ta0) / float(N);
            for (int i = 0; i < N; i++) {
                float tt = ta0 + (float(i) + jit) * dt;
                float3 q = ray.o + ray.d * tt;
                float sig = fogDensity(q);
                if (sig <= 0.0) continue;
                float depth = clamp((fogTop(q.xz) - q.y) / 90.0, 0.0, 1.0);
                // Lit by the twilight dome: the top brightest, deeper fog greyer.
                float3 Lf = (zenith * 2.4 + horizSun * 0.35 + horizAnti * 0.25) * (1.0 - 0.45 * depth) * (0.9 / PI);
                float a = 1.0 - exp(-sig * dt);
                fogL += accT * a * Lf;
                tFog += accT * a * tt;
                wFog += accT * a;
                accT *= 1.0 - a;
                if (accT < 0.01) break;
            }
        }
    }

    if (hit) {
        // Aerial perspective at the depth the pixel's light mostly comes from (fog or ground).
        float tEff = (tFog + accT * t) / (wFog + accT);
        float3 ins = scatterO(planetEye, ray.d, tEff, sunS, SUN_I, A, 12, 6, jit, trans);
        col = (fogL + col * accT) * trans + ins + (1.0 - trans) * zenith * 0.6;
    } else if (wFog > 0.0) {
        float3 ins = scatterO(planetEye, ray.d, tFog / wFog, sunS, SUN_I, A, 12, 6, jit, trans);
        col = col * accT + fogL * trans + ins * (1.0 - accT);
    }

    s.color = col;
    return s;
}

float3 post(float3 hdr, float2 uv, float2 px) {
#if DEBUG_SHAPE
    return hdr;
#endif
    float3 c = hdr * 5.0;
    c *= vignette(uv, 0.25);
    c = agx(c, 0.5);
    return grain(c, px, 0.010);
}
