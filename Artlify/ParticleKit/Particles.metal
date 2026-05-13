//
//  Particles.metal
//  Artlify / ParticleKit
//
//  GPU compute + render for the silhouette-as-force-field particle
//  installation.
//
//    update_particles  — compute shader, advances each particle one
//                        timestep. Uses the person-segmentation mask
//                        as a scalar field; particles are pushed by
//                        the mask's spatial gradient (i.e. pushed
//                        away from / toward the silhouette edge).
//
//    particle_vertex   — emits one point sprite per particle, sized
//                        in pixels via [[point_size]].
//
//    particle_fragment — soft circular dot, additive-blended over
//                        the camera image.
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
    float2 home;
    float  seed;        // 0..1, used for hue + jitter
    float  life;        // 0..1, fades on respawn
};

struct ParticleUniforms {
    float dt;            // seconds since last update
    float time;          // wall-clock seconds (for noise drift)
    float repulsion;     // magnitude of mask-gradient push
    float damping;       // 0..1, multiplied into velocity each step
    float returnSpring;  // pull toward home position
    float noise;         // random jitter magnitude
    float maskWeight;    // 0 = ignore mask, 1 = full repulsion
    float pointSize;     // sprite size in pixels
    float2 viewport;     // drawable size in pixels (for point_size)
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

    // Sample mask + 4-tap gradient. 1.5px epsilon at a 256² mask is
    // about right; smaller starves the gradient of signal, larger
    // smears the silhouette into a halo.
    const float2 eps = float2(1.5 / 256.0, 1.5 / 256.0);
    float m   = mask.sample(s, p.position).r;
    float mxp = mask.sample(s, p.position + float2(eps.x, 0)).r;
    float mxn = mask.sample(s, p.position - float2(eps.x, 0)).r;
    float myp = mask.sample(s, p.position + float2(0, eps.y)).r;
    float myn = mask.sample(s, p.position - float2(0, eps.y)).r;
    float2 grad = float2(mxp - mxn, myp - myn);

    // Repulsion force pushes particles AWAY from higher mask values
    // (i.e. away from the body). Scaled by maskWeight so the user can
    // dial it from "ignore person" to "violent shove".
    float2 fRepel = -grad * u.repulsion * u.maskWeight;

    // Particles unlucky enough to be inside the body get an extra
    // shove proportional to how deep they are.
    fRepel += -grad * (m * u.repulsion * 0.6 * u.maskWeight);

    // Soft spring back to home so the field stays a *field*, not a
    // permanent dispersal. Without this, one big motion clears the
    // canvas forever.
    float2 fHome = (p.home - p.position) * u.returnSpring;

    // Curl-noise-ish wandering (cheap, not actual curl). Drifts the
    // wave-of-dots feel even when nobody is in frame.
    float2 nseed = p.position * 4.0 + float2(u.time * 0.15, -u.time * 0.11);
    float2 fNoise = float2(vnoise(nseed), vnoise(nseed + 17.3)) * u.noise;

    float2 acc = fRepel + fHome + fNoise;
    p.velocity = p.velocity * u.damping + acc * u.dt;

    // Cap speed so a violent shove doesn't fling particles to infinity.
    float speed = length(p.velocity);
    const float vmax = 0.8;
    if (speed > vmax) p.velocity *= (vmax / speed);

    p.position += p.velocity * u.dt;

    // Wrap-around so the field stays full. The home stays put, so the
    // spring still pulls a wrapped particle back across the seam — that
    // creates a nice "comet" trail when something blasts a particle
    // across the canvas.
    p.position = fract(p.position);

    // Slow life decay → respawn. Keeps the field from looking static.
    p.life -= u.dt * 0.05;
    if (p.life <= 0.0) {
        // Respawn at home with fresh seed.
        p.position = p.home;
        p.velocity = float2(0.0);
        p.life = 1.0;
    }

    particles[gid] = p;
}

// ---------------------------------------------------------------------
// Render
// ---------------------------------------------------------------------

struct ParticleVSOut {
    float4 position [[position]];
    float  point_size [[point_size]];
    float  seed;
    float  speed;
    float  life;
};

vertex ParticleVSOut particle_vertex(
    uint                       vid       [[vertex_id]],
    const device GPUParticle*  particles [[buffer(0)]],
    constant ParticleUniforms& u         [[buffer(1)]]
) {
    GPUParticle p = particles[vid];

    // UV (top-left origin) → clip space. Flip y so up-on-screen = uv.y=0.
    float2 clip = float2(p.position.x * 2.0 - 1.0,
                         1.0 - p.position.y * 2.0);

    ParticleVSOut o;
    o.position   = float4(clip, 0.0, 1.0);
    o.point_size = u.pointSize;
    o.seed       = p.seed;
    o.speed      = length(p.velocity);
    o.life       = p.life;
    return o;
}

// HSV → RGB (h in 0..1).
static inline float3 hsv2rgb(float h, float s, float v) {
    float3 k = float3(1.0, 2.0/3.0, 1.0/3.0);
    float3 p = abs(fract(float3(h) + k) * 6.0 - 3.0);
    return v * mix(float3(1.0), clamp(p - 1.0, 0.0, 1.0), s);
}

fragment float4 particle_fragment(
    ParticleVSOut         in   [[stage_in]],
    float2                pc   [[point_coord]]
) {
    // Soft circular dot. point_coord is 0..1 across the sprite.
    float d = distance(pc, float2(0.5));
    float a = 1.0 - smoothstep(0.30, 0.50, d);
    if (a <= 0.001) discard_fragment();

    // Hue drifts with seed; saturation rises with speed. So a still
    // field looks calm/cool, a kicked-up swarm flares warm/bright.
    float hue = fract(in.seed + in.speed * 0.6);
    float3 rgb = hsv2rgb(hue, 0.85, 1.0);

    // Premultiply alpha for additive-friendly blending; caller chooses
    // the actual blend factors.
    return float4(rgb * a * in.life, a * in.life);
}
