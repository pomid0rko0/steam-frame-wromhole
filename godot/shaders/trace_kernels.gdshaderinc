// The ray tracer's compute kernels (ray_pass.gd compiles them, with one of the KERNEL_* defines and
// the variant's WH_* defines in front). Plain GLSL: the frame's values come in one uniform block
// whose members carry the names wormhole_core.gdshaderinc reads, so the core is the same code
// that ref/ compiles as a fragment shader.
//
// The frame (ray_pass.gd, _pack and _render_callback, writes it in this order):

layout(set = 0, binding = 0, std140) uniform Frame {
    float wh_rho0; float wh_h; float wh_fillet; float wh_pix;
    vec4 wh_tabLo; vec4 wh_tabInv; vec4 wh_tabReg;
    vec4 grav_cyl; vec4 grav_g[2]; vec4 grav_d[2];
    vec4 wh_sph[6]; vec4 wh_pil[4]; vec4 wh_box[4];
    vec4 wh_ball[12]; vec4 wh_ballCol[12]; vec4 wh_fball[12];
    vec4 wh_cube[6]; vec4 wh_cubeE[30]; vec4 wh_cubeCol[6];
    vec4 wh_bound[4];
    ivec4 wh_bIdx; ivec4 wh_cIdx;
    int wh_nBall; int wh_nCube; int fr_views; int fr_flags;
    vec4 head_f[3];
    vec3 head_n; float head_l;
    vec3 head_pos; float fr_pad0;
    // per view: the camera in play space, the eye's offset in it (EYE_OFFSET), and the inverse of
    // its projection with Vulkan's correction (INV_PROJECTION_MATRIX)
    mat4 fr_cam;
    vec4 fr_eyeOff[2];
    mat4 fr_invProj[2];
    ivec4 fr_size;           // the picture's width and height, per view
};

layout(set = 0, binding = 1) uniform sampler2D wh_tab;
layout(rgba16f, set = 0, binding = 2) uniform restrict image2DArray fr_out;
// per view: (l, n), the play axes f0, f1, f2 at the eye, (wh_eye(l), 0, 0)
layout(set = 0, binding = 3, std430) restrict buffer Eyes { vec4 fr_eye[]; };

#include_core

#ifdef KERNEL_EYES
// One invocation per view: the head's point moved along the geodesic of the eye's offset from it,
// as wormhole_view.gdshaderinc's vertex shader does for a fragment ray tracer.
layout(local_size_x = 2, local_size_y = 1, local_size_z = 1) in;
void main() {
    int v = int(gl_GlobalInvocationID.x);
    if (v >= fr_views) return;
    float l = head_l;
    vec3 n = head_n;
    vec4 f0 = head_f[0];
    vec4 f1 = head_f[1];
    vec4 f2 = head_f[2];
    vec3 eye = (fr_cam * vec4(fr_eyeOff[v].xyz, 1.0)).xyz;
    vec3 off = eye - head_pos;                         // this eye relative to the head, play space
    float len = length(off);
    if (len > 1e-6) {
        vec4 dir = (off.x * f0 + off.y * f1 + off.z * f2) / len;
        wh_geodesic(l, n, dir, len, f0, f1, f2);
    }
    fr_eye[5 * v] = vec4(l, n);
    fr_eye[5 * v + 1] = f0;
    fr_eye[5 * v + 2] = f1;
    fr_eye[5 * v + 3] = f2;
    fr_eye[5 * v + 4] = vec4(wh_eye(l), 0.0, 0.0);
}
#endif

#ifdef KERNEL_WORLD
// A pixel per invocation, 16 x 8 of them a group (one wave of 128 on the Frame's GPU), in quads of
// 2 x 2 as a fragment shader's: the grid's screen derivatives are the quad's differences, through
// shared memory.
layout(local_size_x = 16, local_size_y = 8, local_size_z = 1) in;
shared vec2 sh_g[128];

void main() {
    int v = int(gl_GlobalInvocationID.z);
    ivec2 px = ivec2(gl_GlobalInvocationID.xy);
    ivec2 sz = fr_size.xy;
    ivec2 pc = min(px, sz - 1);
    vec4 E0 = fr_eye[5 * v];
    vec4 f0 = fr_eye[5 * v + 1];
    vec4 f1 = fr_eye[5 * v + 2];
    vec4 f2 = fr_eye[5 * v + 3];
    vec2 eyeE = fr_eye[5 * v + 4].xy;
    // this pixel's ray: the line from the eye through its centre unprojected onto the near plane
    // (depth 0: fr_invProj maps depths 0..1, near to far), turned into play space and onto the
    // eye's axes
    vec2 ndc = (vec2(pc) + 0.5) / vec2(sz) * 2.0 - 1.0;
    vec4 pa = fr_invProj[v] * vec4(ndc, 0.0, 1.0);
    vec3 pd = mat3(fr_cam) * (pa.xyz / pa.w - fr_eyeOff[v].xyz);
    vec4 V = normalize(pd.x * f0 + pd.y * f1 + pd.z * f2);
    vec4 dbg;
    WhEnd e = wh_trace(E0.x, E0.yzw, V.x, V.yzw, eyeE, dbg);
    vec2 g = wh_gridAt(e);
    uint li = gl_LocalInvocationIndex;
    sh_g[li] = g;
    barrier();
    // the quad's differences, right minus left and lower minus upper, as a fine derivative
    uint lx = gl_LocalInvocationID.x;
    uint ly = gl_LocalInvocationID.y;
    vec2 gdx = sh_g[(ly << 4) | (lx | 1u)] - sh_g[(ly << 4) | (lx & ~1u)];
    vec2 gdy = sh_g[((ly | 1u) << 4) | lx] - sh_g[((ly & ~1u) << 4) | lx];
    vec3 c = wh_shadeEnd(e, g, gdx, gdy);
    if (all(lessThan(px, sz))) imageStore(fr_out, ivec3(px, v), vec4(c, 1.0));
}
#endif
