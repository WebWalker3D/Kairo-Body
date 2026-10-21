#include <metal_stdlib>
using namespace metal;

#define TAU 6.283185307179586

// The iPad's living ring: twelve emitters around a core, in the same physical
// arrangement measured on the Dot. The Dot's transient output levels, the
// committed mood and the current phase all arrive as bounded uniforms; the
// shader only lights what those signals say. It never invents motion beyond a
// gentle idle breath.

struct KairoRingUniforms {
    float4 viewport;        // width, height, centre x, centre y
    float4 mood;            // committed affect primary (rgb)
    float4 accent;          // mood accent (rgb)
    float4 core;            // core colour (rgb)
    float4 paramsA;         // time, idle breath amplitude, phase energy, overall intensity
    float4 paramsB;         // ring radius, emitter width, screensaver fade, sleeping (1) flag
    float4 emitters[12];    // x: level 0..1, y: phase seed, z: reserved, w: reserved
};

struct KairoRingVertexOutput {
    float4 position [[position]];
    float2 uv;
};

vertex KairoRingVertexOutput kairoRingVertex(uint index [[vertex_id]]) {
    const float2 positions[3] = {
        float2(-1.0, -3.0),
        float2(3.0, 1.0),
        float2(-1.0, 1.0),
    };
    KairoRingVertexOutput output;
    output.position = float4(positions[index], 0.0, 1.0);
    output.uv = positions[index] * 0.5 + float2(0.5);
    return output;
}

static float mote(float2 p, float2 centre, float radius) {
    const float distance = length((p - centre) / max(radius, 0.001));
    return exp(-distance * distance * 5.5);
}

fragment float4 kairoRingFragment(
    KairoRingVertexOutput input [[stage_in]],
    constant KairoRingUniforms &u [[buffer(0)]]
) {
    const float2 viewport = max(u.viewport.xy, float2(1.0));
    const float2 aspect = float2(viewport.x / max(viewport.x, viewport.y),
                                 viewport.y / max(viewport.x, viewport.y));
    // uv is in [0,1]; centre it on the ring.
    const float2 p = (input.uv - 0.5) * 2.0 * aspect;
    const float time = u.paramsA.x;
    const float breath = u.paramsA.y;
    const float energy = u.paramsA.z;
    const float intensity = clamp(u.paramsA.w, 0.0, 1.0);
    const float radius = u.paramsB.x;
    const float emitterWidth = u.paramsB.y;
    const float fade = clamp(u.paramsB.z, 0.0, 1.0);
    const float sleeping = u.paramsB.w;

    // A slow breath only when the posture is resting; focused light stays steady.
    const float idleBreath = 1.0 + breath * sin(time * 0.9) * (1.0 - energy * 0.8);

    // Core: soft radial glow, brighter while Kairo is present in the room.
    const float coreDistance = length(p) / radius;
    float coreGlow = exp(-coreDistance * coreDistance * 6.0) * (0.22 + energy * 0.5) * idleBreath;

    // Guide ring: a faint annulus marking where the emitters live.
    const float annulus = abs(coreDistance - 1.0);
    float guide = exp(-annulus * annulus * 900.0) * (0.10 + energy * 0.16);

    // Twelve measured emitters.
    float emitterGlow = 0.0;
    float3 emitterMix = float3(0.0);
    for (uint i = 0u; i < 12u; i++) {
        const float level = clamp(u.emitters[i].x, 0.0, 1.0);
        if (level <= 0.002) { continue; }
        const float seed = u.emitters[i].y;
        // Emitter 11 faces the person; ids increase clockwise from above,
        // matching Blaine's physical calibration on the Dot.
        // Emitter ids increase clockwise from above, matching Blaine's
        // physical calibration on the Dot (emitter 11 faces the person).
        const float angle = (-0.5 * TAU - float(i) * (TAU / 12.0)) + seed * 0.02;
        const float2 centre = float2(cos(angle), sin(angle)) * radius;
        const float sparkle = 1.0 + 0.08 * sin(time * 2.2 + seed * 6.28);
        const float contribution = mote(p, centre, radius * emitterWidth * (0.55 + 0.45 * level))
            * level * level * sparkle;
        emitterGlow += contribution;
        emitterMix += mix(u.mood.rgb, u.accent.rgb, level) * contribution;
    }

    // Sleeping posture keeps a barely-there ember, like the Dot at timeout.
    const float sleepMix = sleeping * 0.12;

    float3 colour = float3(0.0);
    colour += u.core.rgb * coreGlow * (1.0 - sleepMix) * intensity;
    colour += u.mood.rgb * guide * (0.6 + 0.4 * energy) * intensity;
    if (emitterGlow > 0.0) {
        colour += emitterMix * 1.35 * intensity;
    }
    if (sleeping > 0.5) {
        // Dark clock stage: the ring rests; the timekeeping is drawn elsewhere.
        colour *= 0.14;
    }
    colour *= fade;

    const float alpha = clamp(
        length(colour) * 1.35 + (1.0 - sleeping) * guide * 0.15,
        0.0, 1.0) * fade;
    return float4(colour, alpha);
}
