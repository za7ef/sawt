#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// الكرة كلها ترسم على كرت الشاشة في تمريرة وحدة، بدون تمويه طبقات كبيرة.
static float wob(float a, float t, float w) {
    return 1.0 + w * (0.55 * sin(3.0 * a + t * 1.7) + 0.30 * sin(5.0 * a - t * 2.3) + 0.15 * sin(7.0 * a + t * 3.1));
}

[[ stitchable ]] half4 orb(float2 pos, half4 color, float2 size, float t, float mic, float outLevel,
                          float think, float baseFrac, half4 c1, half4 c2, half4 c3) {
    float half_ = min(size.x, size.y) * 0.5;
    float2 p = (pos - size * 0.5) / half_;          // -1..1
    float r = length(p);
    float a = atan2(p.y, p.x);
    float energy = max(mic, outLevel);
    float pulse = think > 0.5 ? 0.06 * sin(t * 4.0) : 0.0;
    float base = baseFrac * (0.78 + 0.16 * energy + pulse);

    // هالة خارجية ناعمة
    float dOuter = r / (base * 1.05 * wob(a, t * 0.6, 0.08 + 0.12 * energy));
    float glow = exp(-max(dOuter - 0.55, 0.0) * 3.2) * (0.55 + 0.4 * energy);
    float3 gcol = mix(float3(c1.rgb), float3(c2.rgb), clamp(0.5 + 0.5 * (p.x + p.y) * 0.7, 0.0, 1.0));
    float3 col = gcol * glow;
    float alpha = glow;

    // طبقتين داخليتين
    for (int i = 0; i < 2; i++) {
        float k = float(i);
        float level = i == 0 ? outLevel : mic;
        float w = 0.05 + 0.18 * level + 0.02 * k;
        float rad = base * (0.95 - k * 0.12);
        float d = r / (rad * wob(a, t * (0.9 + k * 0.35) + k * 2.0, w));
        float edge = 0.06 + k * 0.04;
        float m = 1.0 - smoothstep(1.0 - edge, 1.0 + edge, d);
        float2 cc = float2(cos(t + k), sin(t * 1.3 + k)) * baseFrac * 0.25;
        float g = clamp(length(p - cc) / rad, 0.0, 1.0);
        float3 ca = float3((i == 0 ? c2 : c3).rgb), cb = float3((i == 0 ? c1 : c2).rgb);
        float3 lc = mix(ca * 0.95, cb * 0.75, g);
        float op = (0.85 - k * 0.2) * m;
        col = mix(col, lc, op);
        alpha = alpha + op * (1.0 - alpha);
    }

    // لمعة زجاجية
    float2 hp = (p - float2(0.0, -base * 0.47)) / float2(base * 0.45, base * 0.28);
    float hl = exp(-dot(hp, hp) * 1.6) * 0.35;
    col = col + float3(hl);
    alpha = clamp(alpha + hl * (1.0 - alpha), 0.0, 1.0);

    return half4(half3(min(col, float3(1.0)) * alpha), half(alpha));
}
