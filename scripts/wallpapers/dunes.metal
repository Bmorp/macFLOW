// Dunes — one great dune at the end of the afternoon, the way Mojave's picture works. Its long windward face rises
// toward a knife-edge crest that curves across the frame; the sun is low behind the camera's right shoulder, so the
// face glows warm and every ripple and smaller dune on it carries a shadow, while the sky ahead deepens to blue.
// Lower, hazier dunes show past the crest where it dips. The great dune is the depth layer.

// Low sun from behind the left shoulder (elevation 11°, 118° left of the view). Precomputed: Metal allows no global
// constructors.
constant float3 SUN_DIR = float3(-0.86673, 0.19081, 0.46085);
constant float3 SUN_I = float3(24.0);
constant float HAZE = 0.7;
constant float PITCH = 0.20164;   // tan(11.4°): the summit sits at the frame's middle
constant float FOV = 34.0;
constant float WAVE = 140.0;      // metres between the lower dunes' crests
constant float AMP = 20.0;

inline Atmos desertAir() { Atmos a = earth(); a.haze = HAZE; a.hM = 1600.0; return a; }


/// Transverse dune profile over one wavelength: a long convex windward rise to a knife-edge crest, then a steep
/// concave slip face down to the trough.
inline float profile(float f) {
    const float c = 0.74;
    return f < c ? pow(f / c, 1.55) : pow((1.0 - f) / (1.0 - c), 1.9);
}

inline float duneField(float2 p) {
    // Crest lines meander: warp the across-wind coordinate.
    float2 q = p;
    q.x += 34.0 * sin(p.y * 0.0105 + 1.3) + 22.0 * fbm(p * 0.0042, 3) * 2.0;
    float s = q.x / WAVE;
    float big = profile(fract(s)) * AMP * (0.72 + 0.28 * noise(p * 0.0031 + float2(floor(s) * 7.1, 0)));
    // Smaller dunes riding the windward slopes, at an angle.
    float2 r = ROT2 * p;
    float s2 = (r.x + 9.0 * noise(p * 0.02)) / 33.0;
    float small = profile(fract(s2)) * 2.4 * smoothstep(0.1, 0.6, fract(s)) * smoothstep(0.74, 0.6, fract(s));
    // Broad swells.
    float swell = 9.0 * fbm(p * 0.0016 + 3.0, 3);
    return big + small + swell;
}

/// The great dune's crest: straight up and away from the camera, round a wide bend to the right, then across the view
/// — a line, an arc and a line meeting with matching tangents, so the dune has no creases.
constant float2 CA = float2(4.0, 30.0);           // start (x, z)
constant float2 CH1 = float2(-0.0797, -0.99682);  // first heading, normalize(-0.08, -1)
constant float CL1 = 245.0;                       // first leg
constant float CR = 120.0;                        // bend radius (a right turn of 90°)

/// One stretch of dune: knife-edge crest, long windward face on the left (negative `across`), steep concave slip face
/// on the right.
inline float duneShape(float across, float hc) {
    float h = across < 0.0 ? hc * pow(saturate(1.0 + across / (2.4 * hc + 60.0)), 1.55)
                           : hc * pow(saturate(1.0 - across / (1.45 * hc + 12.0)), 1.45);
    // A slightly rounded crest, as wind leaves it.
    return h - 0.35 * exp(-abs(across) * 1.2) * smoothstep(5.0, 20.0, hc);
}

inline float crestHeight(float along);

/// The great dune as the union of its three stretches (each continuous, so the whole has no cliffs).
inline float hero(float2 p) {
    float2 right1 = float2(-CH1.y, CH1.x);
    float2 B = CA + CH1 * CL1;
    float2 C = B + right1 * CR;
    float2 E = C + CH1 * CR;
    float2 h2 = right1, right2 = float2(-h2.y, h2.x);
    // First leg, up to the radius through B, where the bend takes over with exactly the same height.
    float t1 = dot(p - CA, CH1);
    float h = t1 <= CL1 ? duneShape(dot(p - CA, right1), crestHeight(max(t1, 0.0))) : 0.0;
    // The bend, within its angle.
    float2 v = p - C, vb = B - C, ve = E - C;
    float turn = vb.x * ve.y - vb.y * ve.x;
    if ((vb.x * v.y - vb.y * v.x) * turn >= 0.0 && (v.x * ve.y - v.y * ve.x) * turn >= 0.0) {
        float r = length(v);
        float along = CL1 + CR * acos(clamp(dot(v / max(r, 1e-3), vb / CR), -1.0, 1.0));
        h = max(h, duneShape(CR - r, crestHeight(along)));
    }
    // Last leg, from the radius through E on to the right.
    float t2 = dot(p - E, h2);
    if (t2 >= 0.0) h = max(h, duneShape(dot(p - E, right2), crestHeight(CL1 + CR * 1.5707963 + t2)));
    return h;
}

inline float crestHeight(float along) {
    return 3.0 + 59.0 * smoothstep(0.0, 335.0, along) - 15.0 * smoothstep(335.0, 760.0, along) + 2.0 * sin(along * 0.021);
}

/// Lower dunes everywhere else, their crests also running across the view.
inline float field(float2 p) {
    // Turned 35° so no crest runs parallel to the frame, and kept low: the great dune is the subject.
    float2 q = float2(0.81915 * p.x - 0.57358 * p.y, 0.57358 * p.x + 0.81915 * p.y);
    return 0.32 * duneField(q + float2(400.0, 0.0)) + 3.0 * fbm(p * 0.004, 3) - 5.0;
}

inline float terrain(float2 p) {
    float h = max(hero(p), field(p));
    // Smaller dunes riding the great one's face, and broad undulation.
    float2 r = ROT2 * p;
    float s2 = (r.x + 9.0 * noise(p * 0.02)) / 38.0;
    return h + 0.8 * fbm(p * 0.008, 3);
}

/// Wind ripples: only for shading, fading with distance (they'd alias long before they'd be seen).
inline float ripples(float2 p, float t) {
    float fade = 1.0 - smoothstep(60.0, 320.0, t);
    if (fade <= 0.0) return 0.0;
    float2 d = normalize(float2(0.25, 1.0));
    float w = dot(p, d) * (2.0 * PI / 2.6) + 3.0 * noise(p * 0.08) + 1.2 * noise(p * 0.4);
    float fine = 1.0 - smoothstep(25.0, 110.0, t);
    float w2 = dot(p, d) * (2.0 * PI / 0.45) + 4.0 * noise(p * 0.5);
    float patchy = smoothstep(-0.3, 0.45, noise(p * 0.02));
    return ((0.5 + 0.5 * sin(w)) * 0.05 + (0.5 + 0.5 * sin(w2)) * 0.01 * fine) * fade * patchy;
}

inline float3 normalAt(float2 p, float t) {
    float e = 0.02 + t * 0.0012;
    float hx = terrain(p + float2(e, 0)) - terrain(p - float2(e, 0)) + ripples(p + float2(e, 0), t) - ripples(p - float2(e, 0), t);
    float hz = terrain(p + float2(0, e)) - terrain(p - float2(0, e)) + ripples(p + float2(0, e), t) - ripples(p - float2(0, e), t);
    return normalize(float3(-hx, 2.0 * e, -hz));
}

inline float march(Ray r, float tMax, thread bool& hit) {
    float t = 0.2, last = 0.2, h = 1.0;
    hit = false;
    for (int i = 0; i < 2000 && t < tMax; i++) {
        float3 p = r.o + r.d * t;
        h = p.y - terrain(p.xz);
        if (h < 0.0008 * t) { hit = true; break; }
        last = t;
        t += max(0.4 * h, 0.02 + t * 0.0015);
    }
    // Ran out of steps skimming a slope: that's ground, not sky.
    if (!hit && t < tMax && h < 0.01 * t) hit = true;
    if (!hit) return tMax;
    // Bisect onto the surface.
    float a = last, b = t;
    for (int i = 0; i < 10; i++) {
        float m = 0.5 * (a + b);
        float3 p = r.o + r.d * m;
        if (p.y - terrain(p.xz) > 0.0) a = m; else b = m;
    }
    return b;
}

inline float shadow(float3 p, float3 l) {
    float t = 0.15;
    for (int i = 0; i < 160; i++) {
        float3 q = p + l * t;
        float h = q.y - terrain(q.xz);
        if (h < 0.0) return 0.0;
        t += clamp(0.5 * h, 0.08, 18.0);
        if (t > 2500.0 || q.y > 120.0) break;
    }
    return 1.0;
}

Sample render(float2 px, thread Ctx& ctx) {
    Atmos A = desertAir();
    float2 camXZ = float2(0.0, 0.0);
    float3 eye = float3(camXZ.x, terrain(camXZ) + 1.7, camXZ.y);
    Ray ray = camera(eye, eye + float3(0.0, PITCH, -1.0), FOV, px, ctx.res, 0.0, 1.0, float2(0.0));

    float3 planetEye = float3(0.0, A.rPlanet + 2.0, 0.0);
    float3 trans;
    Sample s;
    s.fg = 0.0;

    bool hit;
    float t = march(ray, 12000.0, hit);
    if (!hit) {
        float3 sky = scatter(planetEye, ray.d, 1e9, SUN_DIR, SUN_I, A, 24, 8, trans);
        // The sun's disc, limb-darkened, through the air in front of it.
        float cosA = dot(ray.d, SUN_DIR);
        float disc = smoothstep(cos(radians(0.30)), cos(radians(0.26)), cosA);
        sky += disc * trans * float3(9000.0) * (0.6 + 0.4 * smoothstep(cos(radians(0.27)), 1.0, cosA));
        s.color = sky;
        return s;
    }

    float3 p = ray.o + ray.d * t;
    float3 n = normalAt(p.xz, t);
    float3 sunCol = sunlight(p.y + 20.0, SUN_DIR, SUN_I, A, 12);
    // A sun a little larger than life softens the shadow edges across the samples.
    float3 l = coneSample(SUN_DIR, cos(radians(0.9)), ctx.rng.next2());
    float sh = shadow(p + n * 0.06, l);
    float ndl = max(0.0, dot(n, l));

    // Sky light: the dome above, warmer toward the sun's side of the horizon.
    float3 tz, tx;
    float3 zenith = scatter(planetEye, normalize(float3(0.0, 1.0, 0.0)), 1e9, SUN_DIR, SUN_I, A, 12, 6, tz);
    float3 horizonSun = scatter(planetEye, normalize(float3(SUN_DIR.x, 0.08, SUN_DIR.z)), 1e9, SUN_DIR, SUN_I, A, 12, 6, tx);
    float3 skyLight = zenith * (0.55 + 0.45 * n.y) * 3.2 + horizonSun * max(0.0, dot(n, normalize(float3(SUN_DIR.x, 0.3, SUN_DIR.z)))) * 0.35;

    // Occlusion in the troughs: how far the ground around rises above this point.
    float occ = 0.0;
    for (int k = 0; k < 4; k++) {
        float a = float(k) * 1.5708 + 0.4;
        float2 o = float2(cos(a), sin(a)) * 6.0;
        occ += max(0.0, terrain(p.xz + o) - p.y) / 6.0;
    }
    float ao = clamp(1.0 - 0.5 * occ, 0.35, 1.0);

    float3 sand = float3(0.62, 0.34, 0.17);
    // Fine grain: the sand isn't one colour.
    sand *= 0.97 + 0.06 * noise(p.xz * 0.012);
    float3 bounce = sand * sunCol * 0.012 * (0.5 - 0.5 * n.y + 0.3);
    // Lambert, with the backscatter that makes sand glow when lit from behind the eye's line.
    float back = pow(max(0.0, dot(-ray.d, l)), 6.0) * 0.25;
    float3 col = sand * (sunCol * ndl * sh * (1.0 / PI) * (1.0 + back) + skyLight * ao * (1.0 / PI) + bounce);
    // A whisper of sheen on grazing, sunlit sand.
    float fres = pow(1.0 - max(0.0, dot(n, -ray.d)), 5.0);
    col += sunCol * sh * fres * 0.004 * ndl;

    // Aerial perspective.
    float3 inscatter = scatter(planetEye, ray.d, t, SUN_DIR, SUN_I, A, 10, 6, trans);
    s.color = col * trans + inscatter;
    // The great dune and everything in front of its crest.
    s.fg = (hero(p.xz) > field(p.xz) + 0.2 || t < 300.0) ? 1.0 : 0.0;
    return s;
}

float3 post(float3 hdr, float2 uv, float2 px) {
    float3 c = hdr * 0.62 * float3(1.0, 0.955, 1.05);
    c *= vignette(uv, 0.28);
    c = agx(c, 0.55);
    // A touch of warmth in the shadows' cool.
    c = saturation(c, 1.06);
    return grain(c, px, 0.005);
}
