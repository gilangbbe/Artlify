//
//  Particles.metal
//  Artlify / ParticleKit
//
//  GPU compute + render for the "silhouette as particle swarm"
//  installation. The person-segmentation mask is treated as a soft
//  containment field: particles flow with curl noise (fluid-looking
//  swirl), are pulled toward the mask interior, and only become
//  visible inside the silhouette. The visual goal is a body-shaped
//  cloud of glowing dots — a gamma-ray-through-a-galaxy aesthetic
//  on a dark background.
//
//    update_particles  — compute shader, advances each particle one
//                        timestep. Adds (a) curl noise drift, (b) a
//                        gentle attractive force toward the mask
//                        gradient, (c) a slow life decay; particles
//                        that drift far from any silhouette respawn
//                        at a fresh random location.
//
//    particle_vertex   — emits one point sprite per particle. Samples
//                        the mask at the particle's position so the
//                        fragment shader can gate alpha by mask
//                        coverage.
//
//    particle_fragment — soft circular dot, additive-blended over
//                        the dark background. Color = warm hue around
//                        the user-selected base.
//
//  All particle coordinates live in normalised [0..1] UV space with
//  origin at TOP-LEFT (matches the camera passthrough's UV).
//

#include <metal_stdlib>
using namespace metal;

// Must match the layout of `ParticleField.GPUParticle` exactly.
struct GPUParticle {
    float2 position;
    float2 velocity;
    float2 home;        // unused by the swarm model; kept for layout parity
    float  seed;        // 0..1, used for hue + jitter
    float  life;        // 0..1, fades on respawn
};

struct ParticleUniforms {
    float dt;            // seconds since last update
    float time;          // wall-clock seconds (for noise drift)
    float attraction;    // pull toward mask gradient (into the body)
    float damping;       // 0..1, multiplied into velocity each step
    float flow;          // curl-noise magnitude
    float flowScale;     // spatial frequency of the curl noise
    float maskGate;      // 0 = always visible, 1 = strict mask alpha
    float pointSize;     // sprite size in pixels
    float glow;          // overall intensity multiplier
    float hueShift;      // 0..1, base hue offset
    float2 viewport;     // drawable size in pixels
};

// Cheap deterministic noise — one float in, two floats out, in -1..1.
static inline float2 hash22(float2 p) {
    p = float2(dot(p, float2(127.1, 311.7)),
               dot(p, float2(269.5, 183.3)));
    return -1.0 + 2.0 * fract(sin(p) * 43758.5453123);
}

// Cheap value-noise scalar in -1..1 from a 2D coord.
static inline float vnoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    float a = dot(hash22(i + float2(0,0)), f - float2(0,0));
    float b = dot(hash22(i + float2(1,0)), f - float2(1,0));
    float c = dot(hash22(i + float2(0,1)), f - float2(0,1));
    float d = dot(hash22(i + float2(1,1)), f - float2(1,1));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

// 2D curl of a scalar potential P:  curl = (∂P/∂y, -∂P/∂x).
// Approximated with finite differences. The result is divergence-free,
// which is what makes the motion look like a fluid rather than a
// gradient flow.
static inline float2 curlNoise(float2 p) {
    const float eps = 0.07;
    float n_xp = vnoise(p + float2( eps, 0));
    float n_xn = vnoise(p + float2(-eps, 0));
    float n_yp = vnoise(p + float2(0,  eps));
    float n_yn = vnoise(p + float2(0, -eps));
    return float2(n_yp - n_yn, -(n_xp - n_xn)) / (2.0 * eps);
}

// Stable per-particle pseudo-random respawn point in [0,1]² that
// changes as `seed` ticks forward.
static inline float2 respawnPoint(float baseSeed, float t) {
    float2 r = hash22(float2(baseSeed * 71.3 + t * 0.13,
                             baseSeed * 197.7 - t * 0.07));
    return clamp(0.5 + 0.5 * r, float2(0.001), float2(0.999));
}

kernel void update_particles(
    device GPUParticle*           particles [[buffer(0)]],
    constant ParticleUniforms&    u         [[buffer(1)]],
    texture2d<float, access::sample> mask   [[texture(0)]],
    uint                          gid       [[thread_position_in_grid]],
    uint                          gcount    [[threads_per_grid]]
) {
    if (gid >= gcount) return;

    GPUParticle p = particles[gid];

    constexpr sampler s(mag_filter::linear, min_filter::linear,
                        address::clamp_to_edge);

    // ---- Mask sample + gradient.
    // Gradient points from low → high mask, i.e. INTO the silhouette,
    // so using +grad as the force pulls outside-particles back in.
    const float2 eps = float2(2.0 / 256.0, 2.0 / 256.0);
    float m   = mask.sample(s, p.position).r;
    float mxp = mask.sample(s, p.position + float2(eps.x, 0)).r;
    float mxn = mask.sample(s, p.position - float2(eps.x, 0)).r;
    float myp = mask.sample(s, p.position + float2(0, eps.y)).r;
    float myn = mask.sample(s, p.position - float2(0, eps.y)).r;
    float2 grad = float2(mxp - mxn, myp - myn);

    // Attractive force: stronger when we are OUTSIDE the silhouette
    // (so particles get sucked in), weakens to ~zero deep inside so
    // particles inside just float around with the curl flow.
    float outside = saturate(1.0 - m * 2.0);
    float2 fAttract = grad * (u.attraction * (0.4 + outside));

    // Curl-noise flow — divergence-free, looks like fluid.
    float2 cseed  = p.position * u.flowScale + float2(u.time * 0.13,
                                                      -u.time * 0.09);
    float2 fFlow  = curlNoise(cseed) * u.flow;

    float2 acc = fAttract + fFlow;
    p.velocity = p.velocity * u.damping + acc * u.dt;

    // Cap speed so a violent gradient doesn't fling particles to infinity.
    float speed = length(p.velocity);
    const float vmax = 0.9;
    if (speed > vmax) p.velocity *= (vmax / speed);

    p.position += p.velocity * u.dt;

    // Wrap-around so the field stays full edge-to-edge.
    p.position = fract(p.position);

    // Life: decays slowly always, faster if the particle is sitting in
    // empty space (so the swarm self-cleans away from the body and the
    // overall density tracks the silhouette). When a particle dies it
    // respawns at a fresh random point — picked with respawnPoint so
    // that, given a few frames, some respawns happen to land inside the
    // silhouette and the cluster keeps replenishing itself there.
    float emptiness = saturate(1.0 - m * 4.0);
    p.life -= u.dt * (0.04 + 0.45 * emptiness);
    if (p.life <= 0.0) {
        p.position = respawnPoint(p.seed, u.time);
        p.velocity = float2(0.0);
        p.life     = 1.0;
        p.seed     = fract(p.seed + 0.61803398875); // golden-ratio spin
    }

    particles[gid] = p;
}

// ---------------------------------------------------------------------
// Render
// ---------------------------------------------------------------------

struct ParticleVSOut {
    float4 position   [[position]];
    float  point_size [[point_size]];
    float  seed;
    float  speed;
    float  life;
    float  mask;       // mask sampled at particle position (gates alpha)
};

vertex ParticleVSOut particle_vertex(
    uint                       vid       [[vertex_id]],
    const device GPUParticle*  particles [[buffer(0)]],
    constant ParticleUniforms& u         [[buffer(1)]],
    texture2d<float, access::sample> mask [[texture(0)]]
) {
    GPUParticle p = particles[vid];

    // UV (top-left origin) → clip space. Flip y so up-on-screen = uv.y=0.
    float2 clip = float2(p.position.x * 2.0 - 1.0,
                         1.0 - p.position.y * 2.0);

    constexpr sampler s(mag_filter::linear, min_filter::linear,
                        address::clamp_to_edge);
    float m = mask.sample(s, p.position).r;

    ParticleVSOut o;
    o.position   = float4(clip, 0.0, 1.0);
    o.point_size = u.pointSize;
    o.seed       = p.seed;
    o.speed      = length(p.velocity);
    o.life       = p.life;
    o.mask       = m;
    return o;
}

// HSV → RGB (h in 0..1).
static inline float3 hsv2rgb(float h, float s, float v) {
    float3 k = float3(1.0, 2.0/3.0, 1.0/3.0);
    float3 p = abs(fract(float3(h) + k) * 6.0 - 3.0);
    return v * mix(float3(1.0), clamp(p - 1.0, 0.0, 1.0), s);
}

fragment float4 particle_fragment(
    ParticleVSOut          in       [[stage_in]],
    constant ParticleUniforms& u    [[buffer(1)]],
    float2                 pc       [[point_coord]]
) {
    // Soft circular dot. point_coord is 0..1 across the sprite; build
    // a tight bright core surrounded by a wide soft halo.
    float d = distance(pc, float2(0.5));
    float core = 1.0 - smoothstep(0.05, 0.22, d);
    float halo = 1.0 - smoothstep(0.20, 0.50, d);
    float a = max(core, halo * 0.55);
    if (a <= 0.001) discard_fragment();

    // Mask gate: at maskGate=0 particles are visible everywhere
    // (faint ambient swarm); at maskGate=1 only inside the silhouette.
    // smoothstep gives a soft edge so the silhouette doesn't cut.
    float gate = mix(1.0, smoothstep(0.05, 0.45, in.mask), u.maskGate);
    a *= gate;

    // Color: hue centered on user-chosen base (hueShift), nudged by
    // per-particle seed for variety and by current speed so faster
    // particles flare slightly warmer.
    float hue = fract(u.hueShift + (in.seed - 0.5) * 0.18 + in.speed * 0.20);
    float3 rgb = hsv2rgb(hue, 0.55, 1.0);

    float intensity = u.glow * in.life;
    // Premultiplied alpha for additive blending.
    return float4(rgb * a * intensity, a * intensity);
}
