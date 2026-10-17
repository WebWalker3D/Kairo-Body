#include <metal_stdlib>
using namespace metal;

struct KairoFormUniforms {
    float4 viewport;
    float4 proportions;
    float4 pose;
    float4 primary;
    float4 accent;
    float4 core;
};

struct KairoFormVertexOutput {
    float4 position [[position]];
    float2 uv;
};

vertex KairoFormVertexOutput kairoFormVertex(uint index [[vertex_id]]) {
    const float2 positions[3] = {
        float2(-1.0, -3.0),
        float2(3.0, 1.0),
        float2(-1.0, 1.0),
    };
    KairoFormVertexOutput output;
    output.position = float4(positions[index], 0.0, 1.0);
    output.uv = positions[index] * 0.5 + float2(0.5);
    return output;
}

static float kairoMote(float2 p, float2 centre, float radius) {
    const float distance = length((p - centre) / max(radius, 0.001));
    return exp(-distance * distance * 5.5);
}

fragment float4 kairoFormFragment(
    KairoFormVertexOutput input [[stage_in]],
    constant KairoFormUniforms &form [[buffer(0)]]
) {
    const float2 viewport = max(form.viewport.xy, float2(1.0));
    const float aspect = viewport.x / viewport.y;
    const float presentationScale = clamp(form.viewport.z, 0.7, 1.3);
    float2 p = (input.uv - float2(0.5)) * float2(aspect, 1.0);
    const float width = form.proportions.x;
    const float height = form.proportions.y;
    const float asymmetry = form.proportions.z;
    const float openness = form.proportions.w;
    const float scale = form.pose.x;
    const float glow = form.pose.y;
    const float tilt = form.pose.z;
    const float drift = form.pose.w;
    p.y -= drift * 0.05;

    const float postureAngle = tilt * 0.98;
    const float cosine = cos(postureAngle);
    const float sine = sin(postureAngle);
    p = float2(p.x * cosine + p.y * sine, -p.x * sine + p.y * cosine);

    const float authoredSpan = (width + height) * 0.5;
    const float presentedWidth = mix(authoredSpan, width, 0.08);
    const float presentedHeight = mix(authoredSpan, height, 0.08);
    const float openWidth = 0.97 + openness * 0.07;
    const float2 radii = float2(
        0.322 * presentedWidth * openWidth * scale,
        0.322 * presentedHeight * scale
    ) * presentationScale;
    p.x -= asymmetry * 0.045;
    p.x += asymmetry * p.y * p.y * 0.30;
    const float2 q = p / radii;
    const float polarAngle = atan2(q.y, q.x);
    const float contour = 1.0
        + sin(polarAngle * 3.0 + asymmetry * 5.0 + drift * 0.18)
            * (0.018 + openness * 0.026)
        + cos(polarAngle * 5.0 - tilt * 8.0)
            * (0.010 + glow * 0.014)
        + sin(polarAngle * 2.0 - q.y * 1.8) * asymmetry * 0.070;
    const float radial = length(q) / contour;
    const float depth = sqrt(max(0.0, 1.0 - radial * radial));
    const float body = 1.0 - smoothstep(0.80, 1.015, radial);
    const float skin = 1.0 - smoothstep(0.014, 0.055, abs(radial - 0.955));
    const float aura = radial < 1.78
        ? exp(-max(radial - 1.0, 0.0) * 5.1) * (0.11 + glow * 0.18)
        : 0.0;

    const float3 normal = normalize(float3(q.x, q.y, max(depth, 0.001)));
    const float3 lightVector = normalize(float3(-0.46, -0.58, 0.68));
    const float diffuse = max(dot(normal, lightVector), 0.0);
    const float fresnel = pow(1.0 - depth, 2.4);
    const float3 deepPrimary = pow(clamp(form.primary.rgb, float3(0.0), float3(1.0)), float3(1.82));
    const float3 deepAccent = pow(clamp(form.accent.rgb, float3(0.0), float3(1.0)), float3(1.82));
    const float3 glassBase = mix(
        deepPrimary * (0.64 + glow * 0.22),
        deepAccent * (0.60 + glow * 0.20),
        clamp(diffuse * 0.46 + depth * 0.20, 0.0, 0.86)
    );
    const float spectralPhase = 0.5 + 0.5 * sin(
        polarAngle * 2.6 + q.y * 2.1 - q.x * 1.4 + drift * 0.42
    );
    const float3 spectralGlass = mix(deepPrimary, deepAccent, spectralPhase);

    const float currentAY = sin(q.x * 3.8 + drift * 1.4 + tilt * 5.0) * 0.19
        + asymmetry * 0.09;
    const float currentA = exp(-abs(q.y - currentAY) * 17.0)
        * body * (1.0 - smoothstep(0.58, 0.98, abs(q.x)));
    const float currentBY = -0.22
        + cos(q.x * 4.7 - drift * 1.1) * (0.12 + openness * 0.05);
    const float currentB = exp(-abs(q.y - currentBY) * 24.0)
        * body * (1.0 - smoothstep(0.42, 0.96, abs(q.x)));
    const float currentCX = 0.17 + sin(q.y * 4.2 + tilt * 8.0) * 0.13
        + asymmetry * 0.08;
    const float currentC = exp(-abs(q.x - currentCX) * 20.0)
        * body * (1.0 - smoothstep(0.48, 0.95, abs(q.y)));

    const float2 coreOffset = float2(
        0.08 + asymmetry * 0.16 + sin(drift * 0.8) * 0.025,
        0.035 - openness * 0.045
    );
    const float coreDistance = length(
        (q - coreOffset) / float2(0.47 + openness * 0.08, 0.43)
    );
    const float coreVoid = exp(-coreDistance * coreDistance * 1.92);
    const float coreBloom = exp(-coreDistance * coreDistance * 1.15) * body;
    const float coreCaustic = exp(-abs(coreDistance - 0.72) * 15.0) * body;
    const float orbitalDistance = length(
        (q - coreOffset) / float2(0.72, 0.43 + openness * 0.06)
    );
    const float orbital = exp(-abs(orbitalDistance - 0.72) * 18.0)
        * body * (0.55 + 0.45 * sin(polarAngle * 3.0 + drift));

    const float broadGlint = kairoMote(q, float2(-0.34, -0.35), 0.24);
    const float sharpGlint = kairoMote(q, float2(-0.43, -0.42), 0.065);
    const float motes =
        kairoMote(q, float2(-0.26 - openness * 0.05, -0.08), 0.040)
        + kairoMote(q, float2(0.34 + asymmetry * 0.10, 0.18), 0.035)
        + kairoMote(q, float2(-0.08 + asymmetry * 0.12, 0.38), 0.030);

    float3 radiance = glassBase * (0.23 + depth * 0.29);
    radiance += spectralGlass * body * (0.08 + fresnel * 0.14 + glow * 0.05);
    radiance += mix(form.primary.rgb, form.accent.rgb, 0.62)
        * coreBloom * (0.15 + glow * 0.10);
    radiance += deepPrimary * currentA * (0.52 + glow * 0.25);
    radiance += deepAccent * currentB * (0.46 + glow * 0.22);
    radiance += mix(deepPrimary, deepAccent, 0.45)
        * currentC * (0.33 + openness * 0.15);
    radiance += deepPrimary * orbital * (0.30 + glow * 0.17);
    radiance += mix(deepPrimary, deepAccent, 0.62)
        * coreCaustic * (0.28 + glow * 0.23);
    radiance += mix(deepPrimary, float3(1.0), 0.52)
        * broadGlint * (0.25 + glow * 0.12);
    radiance += float3(1.0) * sharpGlint * (0.58 + glow * 0.23);
    radiance += mix(deepPrimary, deepAccent, 0.58)
        * motes * (0.24 + glow * 0.22);
    radiance += spectralGlass * fresnel * body * (0.29 + glow * 0.13);
    radiance += mix(form.accent.rgb, float3(1.0), 0.20)
        * skin * (0.30 + glow * 0.15);
    radiance += form.primary.rgb * aura * 0.42;
    radiance *= 1.0 - coreVoid * (0.998 - openness * 0.012);
    radiance += deepPrimary * coreCaustic * coreVoid * 0.16;

    const float coverage = clamp(
        body * (0.68 + depth * 0.20)
            + skin * 0.14
            + aura * 0.44
            + broadGlint * body * 0.05
            + motes * body * 0.035,
        0.0,
        0.98
    );
    const float3 tonemapped = radiance / (radiance + float3(0.62));
    const float3 graded = pow(clamp(tonemapped, float3(0.0), float3(1.0)), float3(0.88));
    const float luminance = dot(graded, float3(0.2126, 0.7152, 0.0722));
    const float3 chromatic = clamp(mix(float3(luminance), graded, 1.34), float3(0.0), float3(1.0));
    const float dimensionalShade = clamp(
        0.54 + fresnel * 0.38 + diffuse * 0.14 + sharpGlint * 0.26,
        0.0,
        1.0
    );
    const float3 lit = chromatic * dimensionalShade;
    return float4(lit * coverage, coverage);
}

struct KairoPlasmaUniforms {
    float4 viewport;
    float4 primary;
    float4 accent;
    float4 motion;
};

fragment float4 kairoPlasmaFragment(
    KairoFormVertexOutput input [[stage_in]],
    constant KairoPlasmaUniforms &plasma [[buffer(0)]]
) {
    const float aspect = plasma.viewport.x / max(plasma.viewport.y, 1.0);
    const float2 p = (input.uv - 0.5) * float2(aspect, 1.0);
    const float time = plasma.motion.x;
    const float bend = sin(p.x * 5.2 + time * 0.72) * 0.12
        + sin(p.x * 9.1 - time * 0.43) * 0.035;
    const float upperDistance = p.y + 0.18 - bend;
    const float lowerDistance = p.y - 0.22 + sin(p.x * 4.1 - time * 0.54) * 0.14;
    const float upper = exp(-abs(upperDistance) * 7.0);
    const float lower = exp(-abs(lowerDistance) * 8.5);
    const float turbulence = 0.5 + 0.5 * sin(p.x * 8.0 + p.y * 5.0 + time * 0.48)
        * sin(p.y * 11.0 - p.x * 3.2 - time * 0.63);
    const float edge = smoothstep(0.05, 0.38, abs(p.x));
    const float veil = (upper * 0.58 + lower * 0.44) * (0.62 + turbulence * 0.38);
    const float filaments = exp(-abs(upperDistance) * 34.0)
        + exp(-abs(lowerDistance) * 39.0) * 0.85;
    const float alpha = clamp((veil * 0.20 + filaments * 0.13 + turbulence * 0.025) *
                              (0.32 + edge * 0.68) * plasma.motion.y, 0.0, 0.34);
    const float hue = clamp(0.5 + 0.5 * sin(p.x * 3.0 - time * 0.24), 0.0, 1.0);
    const float3 color = mix(plasma.primary.rgb, plasma.accent.rgb, hue);
    return float4(color * alpha, alpha);
}
