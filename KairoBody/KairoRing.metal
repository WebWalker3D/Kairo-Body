#include <metal_stdlib>
using namespace metal;
#define TAU 6.28318530718

// This ABI is shared with KairoRingUniformsStorage: seven float4s + 12 emitters.
struct KairoRingUniforms {
    float4 viewport, mood, accent, core, paramsA, paramsB, paramsC;
    float4 emitters[12];
};
struct FieldVertex { float4 position [[position]]; float2 uv; };
vertex FieldVertex kairoRingVertex(uint id [[vertex_id]]) {
    const float2 p[3] = {float2(-1,-3), float2(3,1), float2(-1,1)};
    return {float4(p[id],0,1), p[id]*.5+.5};
}
fragment float4 kairoRingFragment(FieldVertex in [[stage_in]], constant KairoRingUniforms &u [[buffer(0)]]) {
    float2 p = (in.uv-.5)*2;
    float r = length(p * float2(1,1.16));
    float a = atan2(p.y,p.x);
    float halo = exp(-pow((r-.54)/.20,2.0));
    float light = halo * (.035 + .025*sin(a*2+u.paramsA.x*.08));
    float sleep = u.paramsB.w > .5 ? .14 : 1;
    float3 c = u.mood.rgb * light * u.paramsA.w * u.paramsB.z * sleep;
    return float4(c, max(c.r,max(c.g,c.b)));
}
static float hash(float p) { return fract(sin(p*127.1+311.7)*43758.5453); }
struct ParticleVertex {
    float4 position [[position]];
    float size [[point_size]];
    float3 colour;
    float light;
};
vertex ParticleVertex kairoParticleVertex(uint id [[vertex_id]],
    constant KairoRingUniforms &u [[buffer(0)]], constant float4 &contact [[buffer(1)]]) {
    float t = u.paramsA.x;
    float energy = clamp(u.paramsA.z,0.0,1.0);
    float activity = u.paramsC.x;
    float live = clamp(u.paramsC.y,0.0,1.0);
    float seed = hash(float(id)+11);
    // 32 flowing filaments, 640 particles apiece. A dispersed outer field
    // occupies the remaining points. No per-frame allocations or CPU loops.
    float strand = floor(float(id)/640);
    float along = float(id%640)/640;
    float arousal = clamp(u.paramsC.w,0.0,1.0);
    // A shared integrated phase closes seamlessly at TAU. State-dependent
    // speed changes never multiply elapsed uptime or teleport the filaments.
    float a = along*TAU + u.paramsB.x;
    float v = strand*2.399963 + a*3 + t*.13;
    uint emitter = uint(floor(fract((-a/TAU)-.5)*12)) % 12;
    float signal = clamp(u.emitters[emitter].x,0.0,1.0);
    float pulse = 0;
    if (u.paramsC.z > 2.5) pulse = pow(max(0.0,sin(t*2.6+a*3)),12.0)*.025;
    else if (u.paramsC.z > 1.5) pulse = pow(max(0.0,sin(t*3.3)),6.0)*.025;
    float breath = sin(u.paramsB.y)*u.paramsA.y*.018;
    float wave = sin(a*5-t*.23+strand*.2) * (.85+arousal*.3);
    float tube = .125 + energy*.025 + signal*.035;
    if (activity > 1.5 && activity < 2.5) tube += sin(a*9+t*8)*live*.016;
    float r = .53 + tube*sin(v) + .027*wave + breath + pulse;
    float3 p = float3(r*cos(a),r*sin(a),tube*cos(v)+.065*sin(a*3+t*.14));
    // Dust follows neighbouring streamlines, with broad depth and sparse stars.
    bool dust = id >= 20480;
    if (dust) {
        r = .36+hash(float(id)*.7)*.47;
        a = seed*TAU+t*(.012+hash(float(id)*.31)*.025);
        p = float3(r*cos(a),r*sin(a), (hash(float(id)*.9)-.5)*.55);
    }
    // Camera tilt and slow precession reveal near and far surfaces.
    float tilt = .48 + sin(t*.09)*.10;
    p.yz = float2(p.y*cos(tilt)-p.z*sin(tilt),p.y*sin(tilt)+p.z*cos(tilt));
    float yaw = .16*sin(t*.07+.8);
    p.xz = float2(p.x*cos(yaw)+p.z*sin(yaw),-p.x*sin(yaw)+p.z*cos(yaw));
    float perspective = 2.5/(2.5-p.z);
    float2 screen = p.xy*perspective;
    // Contact is local geometry feedback, not an invented server response.
    float2 delta = contact.xy-screen;
    float influence = exp(-dot(delta,delta)*16)*contact.z;
    screen += delta*influence*.23;
    screen += float2(-delta.y,delta.x)*influence*.18;
    float depth = clamp((p.z+.4)/.8,0.0,1.0);
    float sheen = pow(.5+.5*sin(a-t*.12),6.0);
    float3 chroma = mix(u.mood.rgb*.72,u.accent.rgb,depth*.32);
    // Spectral scattering on the shadow edge; the committed palette remains
    // the source of the hue, including warm/concerned/reflective expressions.
    float3 scatter = float3(u.mood.b*.95,u.mood.r*.45,u.mood.g*1.2);
    chroma = mix(chroma,scatter,(1-depth)*.60);
    float lum = (.48+depth*.65+sheen*.55+signal*.7)*u.paramsA.w;
    if (activity > .5 && activity < 1.5) lum *= 1+live*.3*(.5+.5*sin(t*2.4));
    lum *= u.paramsB.z * (u.paramsB.w > .5 ? .14 : 1);
    ParticleVertex out;
    out.position = float4(screen,0,1);
    // Point sizes are drawable pixels; viewport.z stores the actual scale.
    float pixelScale = max(u.viewport.z,1.0);
    out.size = (dust ? 1.3+pow(seed,12.0)*6 : 2.0+depth*2.1+sheen*1.6)*pixelScale;
    out.colour = chroma;
    out.light = lum * (dust ? .23+pow(seed,16.0) : .62);
    return out;
}
fragment float4 kairoParticleFragment(ParticleVertex in [[stage_in]], float2 point [[point_coord]]) {
    float r2 = dot(point-.5,point-.5)*4;
    float glow = exp(-r2*4.5)*.55 + exp(-r2*26)*1.15;
    float3 colour = in.colour * glow * in.light * (1.0-smoothstep(.55,1.0,r2));
    return float4(colour, clamp(max(colour.r,max(colour.g,colour.b)),0.0,1.0));
}
