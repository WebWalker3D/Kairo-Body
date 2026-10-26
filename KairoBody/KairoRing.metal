#include <metal_stdlib>
using namespace metal;

#define TAU 6.283185307179586
#define PI  3.141592653589793

// The iPad's living ring: twelve emitters around a core, in the same physical
// arrangement measured on the Dot. Every motion here answers a real signal:
// fresh Dot output levels, the composed phase (speaking / thinking /
// listening), and the committed mood's own motion mode - pulse, orbit, spark
// or breathe - exactly the vocabulary the 1.0.x body and the Dot animate with.
// While Kairo speaks through this iPad the Dot's stream may be stale, and the
// beat is synthesized from the observed fact of speech itself, as 1.0.x did.

struct KairoRingUniforms {
    float4 viewport;        // width, height, centre x, centre y
    float4 mood;            // committed affect primary (rgb)
    float4 accent;          // mood accent (rgb)
    float4 core;            // core colour (rgb)
    float4 paramsA;         // time, idle breath amplitude, phase energy, overall intensity
    float4 paramsB;         // ring radius, emitter width, screensaver fade, sleeping (1) flag
    float4 paramsC;         // activity (0 idle, 1 listening, 2 speaking, 3 thinking), live level, motion mode (0 breathe, 1 orbit, 2 pulse, 3 spark), reserved
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

// Triangular keyframe like the 1.0.x motion curves: a flare centred at
// `centre` within the cycle, half-width `width`, eased.
static float flare(float cycle, float centre, float width) {
    const float c = cycle - floor(cycle);
    const float env = clamp(1.0 - abs(c - centre) / max(width, 0.001), 0.0, 1.0);
    return env * env * (3.0 - 2.0 * env);
}

static float wrapAngle(float a) {
    return a - TAU * floor((a + PI) / TAU);
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
    const float baseRadius = u.paramsB.x;
    const float emitterWidth = u.paramsB.y;
    const float fade = clamp(u.paramsB.z, 0.0, 1.0);
    const float sleeping = u.paramsB.w;
    const float activity = u.paramsC.x;
    const float live = clamp(u.paramsC.y, 0.0, 1.0);
    const float mode = u.paramsC.z;

    // A slow breath only when the posture is resting; focused light stays steady.
    const float idleBreath = 1.0 + breath * sin(time * 0.9) * (1.0 - energy * 0.8);

    // --- the mood's own motion, as the 1.0.x keyframe curves animated it ---
    const float amp = 0.35 + 0.65 * energy;
    float scaleKick = 0.0;
    float glowBoost = 0.0;
    float widthBoost = 0.0;
    if (mode > 2.5) {            // spark: three quick flares per 2.4 s
        const float e = max(flare(time / 2.4, 0.06, 0.10),
                            max(flare(time / 2.4, 0.36, 0.10) * 0.95,
                                flare(time / 2.4, 0.68, 0.09) * 0.85));
        scaleKick += 0.05 * e * amp;
        glowBoost += 0.55 * e * amp;
    } else if (mode > 1.5) {     // pulse: one heartbeat every 1.9 s
        const float e = flare(time / 1.9, 0.10, 0.32);
        scaleKick += 0.07 * e * amp;
        glowBoost += 0.50 * e * amp;
    } else if (mode > 0.5) {     // orbit: brightness travels the ring once per 6.5 s
        scaleKick += 0.015 * sin(TAU * time / 6.5);
        glowBoost += 0.10 * (0.5 + 0.5 * sin(TAU * time / 6.5));
    } else {                     // breathe: one long swell every 4.6 s
        scaleKick += 0.05 * sin(TAU * time / 4.6) * amp;
        glowBoost += 0.12 * (0.5 + 0.5 * sin(TAU * time / 4.6)) * amp;
    }

    // --- what Kairo is doing right now, as 1.0.x animated it ---
    float scanPhase = 0.0;
    if (activity > 0.5 && activity < 1.5) {          // listening: a slow attentive swell
        const float wave = 0.5 + 0.5 * sin(time * TAU * 0.7);
        glowBoost += (0.06 * wave + 0.24 * live);
        scaleKick += 0.012 * wave + 0.030 * live;
        widthBoost += 0.05 * wave + 0.14 * live;
    } else if (activity > 1.5 && activity < 2.5) {   // speaking: the beat itself
        const float wave = 0.5 + 0.5 * sin(time * TAU * 2.2);
        glowBoost += 0.13 * wave + 0.24 * live;
        scaleKick += 0.025 * wave + 0.025 * live;
        widthBoost += 0.08 * wave + 0.13 * live;
    } else if (activity > 2.5) {                     // thinking: a pulse travels around the ring
        const float wave = 0.5 + 0.5 * sin(time * TAU * 0.42);
        glowBoost += 0.13 * wave * live;
        scaleKick += -0.008 + 0.025 * wave * live;
        scanPhase = TAU * fract(time * 0.42);
    }
    const float radius = baseRadius * clamp(1.0 + scaleKick, 0.82, 1.22);

    // Core: soft radial glow - brighter with presence, flaring with mood
    // motion and with whatever Kairo is doing.
    const float coreDistance = length(p) / radius;
    float coreGlow = exp(-coreDistance * coreDistance * 6.0)
        * (0.22 + energy * 0.5 + glowBoost * 0.55) * idleBreath;

    // Guide ring: a faint annulus marking where the emitters live; a thinking
    // scan brightens the arc the pulse is crossing.
    const float annulus = abs(coreDistance - 1.0);
    const float theta = atan2(p.y, p.x);
    float guide = exp(-annulus * annulus * 900.0) * (0.10 + energy * 0.16 + glowBoost * 0.10);
    if (scanPhase != 0.0) {
        const float d = wrapAngle(theta - scanPhase);
        guide += exp(-d * d * 5.0) * (0.12 + 0.28 * live);
    }

    // Twelve measured emitters.
    float emitterGlow = 0.0;
    float3 emitterMix = float3(0.0);
    for (uint i = 0u; i < 12u; i++) {
        float level = clamp(u.emitters[i].x, 0.0, 1.0);
        const float seed = u.emitters[i].y;
        // Emitter 11 faces the person; ids increase clockwise from above,
        // matching Blaine's physical calibration on the Dot.
        const float angle = (-0.5 * TAU - float(i) * (TAU / 12.0)) + seed * 0.02;

        // When a fresh Dot waveform is quiet or absent, the phase itself
        // drives the emitters so speech, thought and attention stay visible
        // on this body - the same rule 1.0.x used for the Dot's own pulse.
        if (activity > 0.5) {
            float synth = 0.0;
            if (activity < 1.5) {                    // listening swell, breathing apart per emitter
                const float wave = 0.5 + 0.5 * sin(time * TAU * 0.7 + seed * 3.1);
                synth = live * (0.10 + 0.22 * wave);
            } else if (activity < 2.5) {             // speaking: 2.2 Hz beat, each emitter bobbing
                const float w = abs(sin(time * PI * 2.2 + float(i) * 0.55 + seed * 1.7));
                synth = live * (0.18 + 0.60 * w);
            } else {                                 // thinking: one light circling the ring
                const float d = wrapAngle(angle - scanPhase);
                synth = live * 0.85 * exp(-d * d * 5.0);
            }
            level = max(level, synth);
        }
        if (level <= 0.002) { continue; }

        const float2 centre = float2(cos(angle), sin(angle)) * radius;
        const float sparkle = 1.0 + 0.08 * sin(time * 2.2 + seed * 6.28);
        // Orbit moods travel brightness around the ring like the Dot's tilt.
        const float orbitGain = mode > 0.5 && mode < 1.5
            ? 1.0 + 0.16 * amp * sin(angle - TAU * time / 6.5) : 1.0;
        const float contribution = mote(p, centre,
                radius * emitterWidth * (0.55 + 0.45 * level) * (1.0 + widthBoost))
            * level * level * sparkle * orbitGain;
        emitterGlow += contribution;
        emitterMix += mix(u.mood.rgb, u.accent.rgb, level) * contribution;
    }

    // Coherent orbital filaments make a spatial presence from the same
    // measured phase/affect. These are expressive light, never telemetry.
    const float r = length(p);
    float silk = 0.0;
    float corona = 0.0;
    for (uint strand = 0; strand < 5; strand++) {
        const float k = float(strand);
        const float drift = time * (0.10 + k * 0.015);
        const float wave = sin(theta * (3.0 + k) + drift) * 0.018
                         + sin(theta * 7.0 - drift * 1.7 + k) * 0.009;
        const float orbit = radius * (1.12 + k * 0.10) + wave * (0.4 + energy);
        const float d = abs(r - orbit);
        const float arc = 0.35 + 0.65 * pow(0.5 + 0.5 * cos(theta - drift - k * 1.8), 3.0);
        silk += exp(-d * d * 180000.0) * arc * (0.18 + energy * 0.13);
        corona += exp(-d * d * 1400.0) * arc * 0.035;
    }
    // A soft atmosphere with a dark centre gives the ring depth without
    // covering the twelve original directional emitters.
    const float atmosphere = exp(-pow((r - radius * 0.94) / 0.13, 2.0));
    const float innerEdge = exp(-pow((r - radius * 0.72) / 0.006, 2.0));
    const float contour = 0.5 + 0.5 * sin(theta * 2.0 + time * 0.12);

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
    colour += mix(u.mood.rgb, u.accent.rgb, contour) * (silk + corona) * intensity;
    colour += u.mood.rgb * atmosphere * 0.07 * intensity;
    colour += u.accent.rgb * innerEdge * 0.035 * intensity;
    colour *= fade;
    colour = 1.0 - exp(-colour * 1.25);

    const float alpha = clamp(
        length(colour) * 1.35 + (1.0 - sleeping) * guide * 0.15,
        0.0, 1.0) * fade;
    return float4(colour, alpha);
}
