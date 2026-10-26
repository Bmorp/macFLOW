// Host-side kernels: one jittered sample per pixel per pass, then the scene's grade, sRGB and dither.

struct Params { uint2 origin; uint2 res; uint pass; uint passes; uint2 offset; };

kernel void accumulate(texture2d<float, access::read_write> acc [[texture(0)]],
                       texture2d<float, access::read_write> fga [[texture(1)]],
                       constant Params& P [[buffer(0)]],
                       uint2 gid [[thread_position_in_grid]]) {
    uint2 pix = gid + P.origin;
    if (pix.x >= acc.get_width() || pix.y >= acc.get_height()) return;
    uint2 canvas = pix + P.offset;
    // R2 low-discrepancy sequence, rotated per pixel so neighbours don't share a pattern.
    float2 j = fract(float2(0.5) + float(P.pass) * float2(0.7548776662, 0.5698402910) + hash22(float2(canvas) * 0.6180339));
    Ctx ctx;
    ctx.res = float2(P.res);
    ctx.pass = P.pass;
    ctx.passes = P.passes;
    ctx.rng = Rng(canvas, P.pass);
    Sample s = render(float2(canvas) + j, ctx);
    s.color = max(s.color, float3(0));
    // A firefly guard: one sample can't outshine the rest by more than this.
    float l = luma(s.color);
    if (l > 64.0) s.color *= 64.0 / l;
    acc.write(acc.read(pix) + float4(s.color, s.fg), pix);
    fga.write(fga.read(pix) + float4(s.color * s.fg, s.fg), pix);
}

kernel void finish(texture2d<float, access::read> acc [[texture(0)]],
                   texture2d<float, access::read> fga [[texture(1)]],
                   device ushort4* full [[buffer(0)]],
                   device ushort4* front [[buffer(1)]],
                   constant Params& P [[buffer(2)]],
                   constant uint2& size [[buffer(3)]],
                   uint2 pix [[thread_position_in_grid]]) {
    if (pix.x >= size.x || pix.y >= size.y) return;
    uint i = pix.y * size.x + pix.x;
    float2 canvas = float2(pix + P.offset) + 0.5;
    float2 uv = canvas / float2(P.res);
    float n = float(P.passes);
    // Triangular dither of one 8-bit step: wide gradients never band, whatever the encoder keeps.
    float2 d = hash22(canvas * 1.37 + 17.0) + hash22(canvas * 0.73 + 3.0) - 1.0;
    float4 a = acc.read(pix) / n;
    float3 c = saturate(srgb(saturate(post(a.rgb, uv, canvas))) + d.x / 255.0);
    full[i] = ushort4(ushort3(round(c * 65535.0)), 65535);
    float4 b = fga.read(pix);
    float cover = b.a / n;
    float3 f = b.a > 0 ? saturate(srgb(saturate(post(b.rgb / b.a, uv, canvas))) + d.y / 255.0) : float3(0);
    front[i] = ushort4(ushort3(round(f * cover * 65535.0)), ushort(round(cover * 65535.0)));
}
