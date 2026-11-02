"""The shaders' geometry (godot/shaders/geo.gdshaderinc and zone.gdshaderinc) on a GPU, float32,
against float64: headless (EGL), as a compute shader, with the table and series built as
WormholeSpace.sweep_table builds them (ref/geo.py), on three throats: the app's, h = R, a crease
(h < R). Every sin and cos goes through the headset driver's range reduction (TURNIP below), and the
table is filtered with weights rounded to 1/256 (HW8), as on the headset.
  sweep and length from a ray's origin: against quadrature of the integrals (ref/geo.py, exact);
  which way the eye sees a point, the first image (geo_see): rays shot by DOP853 from an eye to a
    point within its first half turn, the GPU given the point must find that ray (angle) and its
    length, no ray of its search coming out not finite; half of them launched within a hair to a
    third of a radian of the tangent, eyes also at the cylinder's end;
  every image (geo_see_image, the bodies' vertices): points along long rays shot by DOP853, eyes in
    and out of the zone, a third of them launched near the tangent and a third with b next to r_min,
    a tenth radial; a quarter of the points on the line through the eye and the centre (a turn of a
    whole number of pi, alpha 0 or pi exactly: the zone's meshes put vertices there);
    the image a point is of is the ray's turn in its plane up to there (j = 0, 1, 2... as turns
    alpha, 2 pi - alpha, 2 pi + alpha...), and the GPU given that image must find that ray
    (direction as a tangent vector at the eye) and its length; on the app's throat up to j >= 7;
  both also with a quarter of the search's rays made NaN: still near the ray, never the stand-in;
  a ray's way out of the curved zone (geo_exit, each pixel's): rays from eyes in the flat universes
    and in the zone, half near the tangent and a quarter with b next to r_min on either side, against
    ref/geo.py's leave (the sweeps by quadrature; itself checked against DOP853 on some of them):
    whether it enters the zone, the universe it leaves into, where (the exit point's direction from
    the centre), its direction there and its length; then where that line meets the floor (z =
    -lift, as lens.gdshaderinc finds it) within FLOOR_SEEN, beyond which the haze leaves nothing of
    it. Where the exit is ill-posed (the reference's own exit moves by more than half a limit, or
    into the other universe, as the launch turns by ALPHA_TOL: next to b = r_min and the photon
    sphere, a ray grazing the zone's ball), the GPU's exit must be the reference's for a launch
    within ALPHA_TOL (found by bisection on the turn);
  the same by the eye's table (geo_xt, our own foveation's floor), on the same rays: its texels about
    each ray worked out as the table's pass does, the ray by the line between them or by
    geo_exit_way where the cell is not good;
  where a line of a half-surface leaves a body in the zone (zone_edge_ball, zone_edge_cube): lines
    in every direction from inner points of balls and cubes on the cylinder, the fillet, across the
    zone's edge and out of it, half-surfaces in every azimuth: the point on the body's surface
    (chord, a cube's largest slab) and on its line, the line's first way out (as float64 finds it,
    sampled and bisected);
  the zone bodies' meshes whole (zone_vertex, MESHES), for eyes' axes through and beside the
    bodies: every vertex on its body; a ball's first and last columns' sections at its tips; every
    corner of a cube's sections (float64: where the half-surface meets an edge) a vertex of its
    column, and on the same row in the next column (the strips join a corner to itself); a cube an
    edge of which the space's curve takes back round the axis is left out (counted): its sections
    cut that edge twice, which one corner an edge can't be;
  the eye (geo_eye): against the head moved along its geodesic by RK4, the frame carried along;
  a ball's surface (geo_onto, the chord): every vertex at chord distance radius, on the space.
Every number of godot/shaders as Godot writes it into the GLSL it compiles (14 decimals): the same
float32; the GPU here is given them so written.
Exit status 1 on any failure.
   python3 ref/test_gpu.py [numbers profile images exit zone eye]     (all, or those checks)"""
import copy
import os
import re
import sys
import in_box  # noqa: F401 (first: on the Frame, into tools/box.sh's container)
import numpy as np
import moderngl
from scipy import optimize
from geo import Space, shoot, app_profile, app_lift, leave

HERE = os.path.dirname(os.path.abspath(__file__))
SHADERS = os.path.join(HERE, '..', 'godot', 'shaders')
# The headset's driver (Turnip, Mesa's ir3) takes every sin and cos through 2 pi fract(x / 2 pi + 1/2)
# - pi (ir3_nir_trig.py), which puts x on a grid of 4e-7 rad: a small angle keeps none of its digits.
# The PC's drivers don't: here every sin and cos of the shaders does the same.
TURNIP = '''
float turnip_sin(float x) { return sin(fma(6.28318531, fract(fma(x, 0.159154943, 0.5)), -3.14159265)); }
float turnip_cos(float x) { return cos(fma(6.28318531, fract(fma(x, 0.159154943, 0.5)), -3.14159265)); }
'''
# Godot writes a shader's numbers into the GLSL it compiles as String::num does: 14 decimals, fewer
# above 10 (a smaller number comes out 0). Here the shaders' numbers are written so too, and the check
# 'numbers' wants every number of godot/shaders to stay the same float32 so written.
NUMBER = re.compile(r'(?<![\w.])((?:\d+\.\d*|\.\d+)(?:[eE][-+]?\d+)?|\d+[eE][-+]?\d+)(?![\w.])')


def godot_number(text):
    v = float(text)
    t = '%.*f' % (max(14 - (int(np.floor(np.log10(abs(v)))) if abs(v) > 10 else 0), 0), v)
    t = t.rstrip('0') if '.' in t else t + '.'
    return t + '0' if t.endswith('.') else t


INC = open(os.path.join(SHADERS, 'geo.gdshaderinc')).read() + open(os.path.join(SHADERS, 'zone.gdshaderinc')).read()
INC = NUMBER.sub(lambda m: godot_number(m.group(1)), INC)
INC = TURNIP + re.sub(r'(?<![\w.])(sin|cos)\(', r'turnip_\1(', INC)
# A GPU's bilinear filter weighs its four texels by fractions it rounds to 1/256 (as ref/geo.py's
# G_table models it); the PC's driver doesn't: here the table is filtered so.
HW8 = '''
vec4 hw8_tab(vec2 uv) {
	vec2 sz = vec2(textureSize(g_tab, 0));
	vec2 p = uv * sz - 0.5;
	vec2 i = floor(p);
	vec2 f = floor((p - i) * 256.0 + 0.5) / 256.0;
	ivec2 a = clamp(ivec2(i), ivec2(0), ivec2(sz) - 1), b = clamp(ivec2(i) + 1, ivec2(0), ivec2(sz) - 1);
	return mix(mix(texelFetch(g_tab, a, 0), texelFetch(g_tab, ivec2(b.x, a.y), 0), f.x),
			mix(texelFetch(g_tab, ivec2(a.x, b.y), 0), texelFetch(g_tab, b, 0), f.x), f.y);
}
'''
assert INC.count('textureLod(g_tab, uv, 0.0)') == 1
INC = INC.replace('textureLod(g_tab, uv, 0.0)', 'hw8_tab(uv)')
i = INC.index('vec2 geo_G(')
INC = INC[:i] + HW8 + INC[i:]
# the rays geo_see's search tries, counted
INC = INC.replace('const int GEO_ITERS', 'int g_rays = 0;\nconst int GEO_ITERS', 1)
assert INC.count('if (i >= GEO_ITERS + nbad) break;') == 1
INC = INC.replace('if (i >= GEO_ITERS + nbad) break;', 'if (i >= GEO_ITERS + nbad) break;\n\t\t\t\tg_rays = i + 1;')
NB, NV = 256, 64            # WormholeSpace.SWEEP_NB, SWEEP_NV
PROFILES = {'the app': app_profile(), 'h = R': (3.0, 1.0, 1.0), 'crease, h < R': (3.0, 0.4, 1.0)}
LIFT = app_lift()           # the floor at z = -LIFT (every profile's zone, radius Rout = 4 m, above it)
# the limits: radians of sweep (with a share of the sweep for long rays round the photon sphere),
# radians of direction (the headset's pixel is about 1e-3: half a pixel 5e-4), metres; a ray's length
# only orders bodies in depth and hazes the floor: a share of it
SWEEP_ABS, SWEEP_REL = 5e-5, 1e-5
DIRECTION = 5e-4
NAN_DIRECTION = 2e-2         # radians: the search, a quarter of its rays lost, at most this far off
LENGTH_REL = 1e-2
FLOOR_ABS, FLOOR_REL = 1e-3, 2e-3     # metres where a pixel's ray meets the floor, and a share of its way
# metres of way beyond which the floor is its universe's horizon colour to within half a step of 8
# bits (look.gdshaderinc's look_ground: the haze 1 - exp(-way / LOOK_HAZE)), so where a ray meets it
# there doesn't show: a ray grazing it a kilometre off meets it metres further for a direction off
# by a hundredth of a pixel
LOOK_HAZE = float(re.search(r'const float LOOK_HAZE = ([\d.]+);', open(os.path.join(SHADERS, 'look.gdshaderinc')).read()).group(1))
FLOOR_SEEN = LOOK_HAZE * np.log(2 * 255)
ALPHA_TOL = 1e-5             # radians of launch (a hundredth of a pixel): an ill-posed exit is the GPU's
EYE_POS, EYE_AXES = 2e-5, 3e-4
CHORD = 5e-5                 # metres off a body's surface (a ball's chord, a cube's slab)
IMAGE_S = 100.0              # m: the longest ray the images' points are taken along
IMAGE_J = 7                  # the app's throat: images up to at least this one

SRC = '''#version 430
layout(local_size_x=64) in;
uniform vec4 g_prof; uniform vec4 g_prof2; uniform vec4 g_tabx; uniform sampler2D g_tab; uniform float g_lift;
uniform float head_l; uniform vec3 head_n; uniform vec4 head_f[3]; uniform vec3 head_pos;
uniform vec3 vb0; uniform vec3 vb1; uniform vec3 vb2;
layout(std430, binding=0) buffer In { vec4 inp[]; };
layout(std430, binding=1) buffer Out { vec4 outp[]; };
uniform int mode;
uniform int in_per;         // vec4s in and out per case
uniform int out_per;
''' + INC + '''
void main() {
	int i = int(gl_GlobalInvocationID.x);
	int I = in_per * i, O = out_per * i;
	vec4 a = inp[I], c = inp[I + 1];
	if (mode == 0) {            // a = (b, |l|, b - rho0, r - b): (psi, len) from the origin
		outp[O] = vec4(geo_from_origin(a.x, geo_sigma(a.z), a.y, a.w), 0.0, 0.0);
	} else if (mode == 2) {     // a = (eye l, n), c = (point l, n): (direction's radial, tangential, len, fell)
		float len, fell; vec4 arr;
		g_rays = 0;
		vec4 d = geo_see(a.x, a.yzw, c.x, c.yzw, len, arr, fell);
		outp[O] = vec4(d.x, length(d.yzw), len, fell + 2.0 * float(g_rays));
	} else if (mode == 3) {     // a = the eye's place in the room: (l, n), then ex, ey, ez
		mat4 iv = mat4(vec4(vb0, 0.0), vec4(vb1, 0.0), vec4(vb2, 0.0), vec4(a.xyz, 1.0));
		float el; vec3 en; vec4 ex, ey, ez;
		geo_eye(iv, vec3(0.0), el, en, ex, ey, ez);
		outp[O] = vec4(el, en); outp[O + 1] = ex; outp[O + 2] = ey; outp[O + 3] = ez;
	} else if (mode == 5) {     // a = (eye l, n), c = a ray (tangent vector there): (hit, sheet, way,
		// the way to the floor or -1), pos, dir, the floor's point; the eye's numbers as floor.gdshaderinc
		// works them out, the floor along the line out as lens.gdshaderinc finds it
		float al = abs(a.x);
		vec3 pos, dir;
		float sheet, way;
		bool hit = geo_exit(a.x, vec3(geo_r(al), sqrt(geo_u(al)), geo_dr(al)), a.yzw, c, pos, dir, sheet, way);
		float ft = dir.z < 0.0 ? (-g_lift - pos.z) / dir.z : -1.0;
		outp[O] = vec4(hit ? 1.0 : 0.0, sheet, way, ft < 0.0 ? -1.0 : way + ft);
		outp[O + 1] = vec4(pos, 0.0);
		outp[O + 2] = vec4(dir, 0.0);
		outp[O + 3] = vec4(pos.xy + max(ft, 0.0) * dir.xy, 0.0, 0.0);
	} else if (mode == 10) {    // as 5, the way across by the eye's table (geo_xt): its texels k and k + 1
		// worked out here as floor_fov's table pass works them out; and 1 in the floor's point's .w if
		// the ray took the table's line, not geo_exit_way
		float al = abs(a.x);
		vec3 eye = vec3(geo_r(al), sqrt(geo_u(al)), geo_dr(al));
		float ca, sa, b, gap, sigma;
		vec3 t;
		bool hit = geo_exit_ray(a.x, eye, a.yzw, c, ca, sa, t, b, gap, sigma);
		float sheet = a.x < 0.0 ? -1.0 : 1.0, way = 0.0, took = 0.0;
		vec3 pos = eye.x * a.yzw, dir = ca * a.yzw + sa * t;
		if (hit) {
			vec2 xr = geo_xt_range(al, eye);
			bool outw = ca >= 0.0;
			int k;
			float x = geo_xt_place(al, b, gap, sigma, xr, k);
			vec4 ta = geo_xt_texel(al, eye, outw, xr, k), tc = geo_xt_texel(al, eye, outw, xr, k + 1);
			took = ta.w;
			vec3 w = geo_xt_way(ta, tc, x, al, eye, b, sigma, gap, outw);
			if (w.z > 0.5) sheet = -sheet;
			geo_exit_at(a.yzw, t, b, w.x, pos, dir);
			way = w.y;
		}
		float ft = dir.z < 0.0 ? (-g_lift - pos.z) / dir.z : -1.0;
		outp[O] = vec4(hit ? 1.0 : 0.0, sheet, way, ft < 0.0 ? -1.0 : way + ft);
		outp[O + 1] = vec4(pos, 0.0);
		outp[O + 2] = vec4(dir, 0.0);
		outp[O + 3] = vec4(pos.xy + max(ft, 0.0) * dir.xy, 0.0, took);
	} else if (mode == 6) {     // a = (eye l, n), c = (point l, n), (t, alpha), (image): the direction, (len, fell)
		vec4 e = inp[I + 2];
		float len, fell; vec4 arr;
		g_rays = 0;
		vec4 d = geo_see_image(a.x, a.yzw, c.x, c.yzw, e.xyz, e.w, int(inp[I + 3].x), len, arr, fell);
		outp[O] = d;
		outp[O + 1] = vec4(len, fell + 2.0 * float(g_rays), 0.0, 0.0);
	} else if (mode == 9) {     // a = (u, v, columns, rows), c = (en, size), (ball 1 or cube 0), C, E1, E2, E3: (l, alpha), t
		vec4 C = inp[I + 3];
		vec3 t;
		vec2 p = zone_vertex(a.xy, a.z, a.w, inp[I + 2].x > 0.5, c.xyz, C, inp[I + 4], inp[I + 5], inp[I + 6], geo_normal(C), c.w, t);
		outp[O] = vec4(p, 0.0, 0.0);
		outp[O + 1] = vec4(t, 0.0);
	} else if (mode == 7 || mode == 8) {    // a = (l0, al0, dl, dal), c = (en, size), t, C, E1, E2, E3: (l, alpha)
		vec4 e = inp[I + 2], C = inp[I + 3];
		vec2 p = mode == 7 ? zone_edge_ball(a.x, a.y, a.z, a.w, c.xyz, e.xyz, C, c.w)
				: zone_edge_cube(a.x, a.y, a.z, a.w, c.xyz, e.xyz, C, inp[I + 4], inp[I + 5], inp[I + 6], c.w);
		outp[O] = vec4(p, 0.0, 0.0);
	} else {                    // a = a ball's centre, c = (direction in its tangent frame, radius): (chord, sdf)
		vec4 N = geo_normal(a);
		vec4 e1 = vec4(0.0, 0.0, 0.0, 1.0) - N.w * N;
		if (length(e1) < 0.5) e1 = vec4(0.0, 1.0, 0.0, 0.0) - N.y * N;
		e1 = normalize(e1);
		vec4 e2 = vec4(0.0, 1.0, 0.0, 0.0) - N.y * N; e2 -= dot(e2, e1) * e1;
		if (length(e2) < 0.5) { e2 = vec4(1.0, 0.0, 0.0, 0.0) - N.x * N; e2 -= dot(e2, e1) * e1; }
		e2 = normalize(e2);
		vec4 x = c.w * (c.x * e1 + c.y * e2 + c.z * -geo_cross4(e1, e2, N));
		vec4 P = geo_onto(a + x, N);
		for (int k = 0; k < 2; k++) {      // as body.gdshaderinc
			float cc = dot(P - a, N);
			P = geo_onto(a + x * (sqrt(max(c.w * c.w - cc * cc, 0.0)) / c.w), N);
		}
		outp[O] = vec4(length(P - a), geo_sdf(length(P.xyz), P.w).x, 0.0, 0.0);
	}
}'''


# geo_see with a quarter of its search's rays made NaN (as a GPU's arithmetic might at some edge): it
# must still find the ray
NAN_SRC = SRC.replace('uniform int mode;', '''uniform int mode;
uint g_h = 0u;
uint g_hash(uint v) { uint s = v * 747796405u + 2891336453u; uint w = ((s >> ((s >> 28u) + 4u)) ^ s) * 277803737u; return (w >> 22u) ^ w; }''', 1).replace(
    '\t\t\t\tfloat val = s.x - delta;\n',
    '\t\t\t\tif (g_hash(g_h * 16u + uint(i)) % 4u == 0u) s = vec2(uintBitsToFloat(0x7fc00000u));\n'
    '\t\t\t\tfloat val = s.x - delta;\n', 1).replace(
    '\tint i = int(gl_GlobalInvocationID.x);', '\tint i = int(gl_GlobalInvocationID.x);\n\tg_h = uint(i);', 1)
assert NAN_SRC.count('0x7fc00000u') == 1 and NAN_SRC.count('g_h = uint(i);') == 1


class Gpu:
    def __init__(self, ctx, S, src=SRC):
        self.ctx = ctx
        self.prog = ctx.compute_shader(src)
        tab = S.build_table(NB, NV, 4)
        self.tex = ctx.texture((NB, NV), 2, dtype='f4', data=np.ascontiguousarray(tab.transpose(1, 0, 2)).astype('f4').tobytes())
        self.tex.filter = (moderngl.LINEAR, moderngl.LINEAR)
        self.tex.repeat_x = self.tex.repeat_y = False
        p = self.prog
        p['g_tab'] = 0
        p['g_prof'] = (S.rho0, S.R, S.Lc, S.L)
        p['g_prof2'] = (S.Rout, S.u0, S.rmin, S.th0)
        p['g_tabx'] = (S.t0, 1 / (S.t1 - S.t0), NB, NV)
        p['g_lift'] = LIFT

    def run(self, mode, rows, in_per=2, out_per=1):
        rows = np.asarray(rows, 'f4').reshape(-1, 4 * in_per)
        n = len(rows)
        rows = np.vstack([rows, np.zeros(((-n) % 64, 4 * in_per), 'f4')])
        bi = self.ctx.buffer(rows.tobytes())
        bo = self.ctx.buffer(reserve=len(rows) * 16 * out_per)
        bi.bind_to_storage_buffer(0)
        bo.bind_to_storage_buffer(1)
        self.tex.use(0)
        self.prog['mode'] = mode
        self.prog['in_per'] = in_per
        self.prog['out_per'] = out_per
        self.prog.run(len(rows) // 64)
        return np.frombuffer(bo.read(), 'f4').reshape(-1, 4)[:n * out_per]


def unit(v):
    return v / np.linalg.norm(v)


def angle(a, b):
    """The angle between two vectors (any length), exact for small ones."""
    a, b = np.asarray(a, float), np.asarray(b, float)
    c = a @ b
    if len(a) == 3:
        s = np.linalg.norm(np.cross(a, b))
    else:
        s = np.sqrt(max((a @ a) * (b @ b) - c * c, 0.0))
    return float(np.arctan2(s, c))


def frame(rng):
    """A random unit en and a unit t orthogonal to it."""
    en = unit(rng.normal(size=3))
    t = rng.normal(size=3)
    return en, unit(t - np.dot(t, en) * en)


def check(name, ok, detail):
    print(('PASS ' if ok else 'FAIL ') + name + '  ' + detail, flush=True)
    return ok


def profile_checks(name, S, gpu, gpu_nan, rng):
    fails = 0
    # sweep and length from the origin; b as float32 has it, b - rho0 and r - b as the shaders
    # carry them, exact (geo_dr, geo_sigma); any number of turns
    rows, ref = [], []
    while len(rows) < 1500:
        b = float(np.float32(rng.uniform(0, S.Rout * 1.3)))
        lo = 0.0 if b < S.rmin else S.l_turn(b)
        l = lo + rng.uniform(0, 1) ** 2 * 12
        e = S.sweep(b, l)
        if not np.all(np.isfinite(e)):
            continue
        rows.append([b, l, b - S.rho0, float(S.r(l)) - b, 0, 0, 0, 0]); ref.append(e)
    o = gpu.run(0, rows)[:, :2]; ref = np.array(ref)
    err = np.abs(o[:, 0] - ref[:, 0]) / (SWEEP_ABS + SWEEP_REL * np.abs(ref[:, 0]))
    lerr = np.abs(o[:, 1] - ref[:, 1]) / (1e-3 + LENGTH_REL * ref[:, 1])
    fails += not check(f'{name}: sweep from the origin', err.max() <= 1 and lerr.max() <= 1,
                       f'worst {err.max():.2f} of the limit, length {lerr.max():.2f} (1500 rays, turns up to {ref[:, 0].max():.0f} rad)')
    # which way the eye sees a point, the first image
    rows, cases = [], []
    places = eye_places(S)
    while len(rows) < 1200:
        el = eye_at(places, rng)
        alpha = launch(rng, len(rows) % 2)
        s = rng.choice([rng.uniform(0.05, 0.6), rng.uniform(0.6, 4), rng.uniform(4, 30)])
        sol = shoot(S, el, alpha, smax=s)
        lp, vl, phi = sol.y[:, -1]
        if phi > 0.93 * np.pi:
            continue
        en, t = frame(rng)
        rows.append([el, *en, lp, *(np.cos(phi) * en + np.sin(phi) * t)]); cases.append((el, alpha, s, phi))
    o = gpu.run(2, rows)
    derr, lerr = [], []
    for (el, alpha, s, phi), g in zip(cases, o):
        derr.append(abs(np.arctan2(g[1], g[0] * (1 if el >= 0 else -1)) - alpha))
        lerr.append(abs(g[2] - s) / (1e-3 + LENGTH_REL * s))
    rays = np.floor(o[:, 3] / 2)
    fell = int((o[:, 3] - 2 * rays > 0.0).sum())
    searched = rays[rays > 0]
    fails += not check(f'{name}: which way the eye sees a point (geo_see)', max(derr) <= DIRECTION and max(lerr) <= 1 and fell == 0,
                       f'direction off by {max(derr):.1e} rad at most (median {np.median(derr):.0e}), length {max(lerr):.2f} of the limit, {fell} with a ray not finite (1200 points; '
                       f'{len(searched)} searched, in {searched.mean():.1f} rays on average, {int(searched.max())} at most)')
    o = gpu_nan.run(2, rows)
    derr = [abs(np.arctan2(g[1], g[0] * (1 if el >= 0 else -1)) - alpha) for (el, alpha, s, phi), g in zip(cases, o)]
    stand_in = int((o[:, 3] - 2 * np.floor(o[:, 3] / 2) > 0.75).sum())
    fails += not check(f'{name}: the same, a quarter of the search\'s rays made NaN', max(derr) <= NAN_DIRECTION and stand_in == 0,
                       f'direction off by {max(derr):.1e} rad at most (median {np.median(derr):.0e}), {stand_in} by the stand-in')
    # a ball's surface
    rows = []
    for k in range(400):
        l = rng.uniform(-S.L - 2, S.L + 2)
        if S.Lc == 0 and abs(l) < 0.5:     # a ball across the crease of h < R: not this method's
            continue
        n = unit(rng.normal(size=3)); n[2] = abs(n[2])
        C = np.r_[float(S.r(l)) * n, float(S.w(l))]
        m = unit(rng.normal(size=3))
        rows.append([*C, *m, rng.uniform(0.05, 0.4)])
    o = gpu.run(4, rows)
    rad = np.array(rows)[:, 7]
    cerr = np.abs(o[:, 0] - rad).max(); serr = np.abs(o[:, 1]).max()
    fails += not check(f'{name}: a ball\'s vertices', cerr <= CHORD and serr <= CHORD, f'chord off by {cerr:.1e} m, off the space by {serr:.1e} m (400 vertices)')
    return fails


def eye_places(S):
    """Where the eye stands, (l, spread): on the cylinder if there is one, and at its end; without one,
    off l = 0, the photon sphere's point or the crease (an eye a hair from either is not checked);
    the fillet, its end, the flat universes."""
    places = [(0.0, 0.1), (0.5, 0.1), (S.Lc - 0.1, 0.1), (S.Lc, 0.01), (-S.Lc, 0.01)] if S.Lc > 0 else [(0.3, 0.1), (-0.4, 0.1)]
    return places + [(0.5 * (S.Lc + S.L), 0.1), (S.L - 0.05, 0.1), (S.L + 0.5, 0.1), (S.L + 5, 0.1),
                     (-0.5 * (S.Lc + S.L), 0.1), (-(S.L + 1), 0.1), (25.0, 0.1)]


def eye_at(places, rng):
    c, w = places[rng.integers(len(places))]
    return c + rng.uniform(-w, w)


def launch(rng, near_tangent):
    """A launch angle from the outward radial direction: any, or within 1e-6 to 0.3 rad of the tangent."""
    if near_tangent:
        return 0.5 * np.pi + rng.choice([-1, 1]) * 10 ** rng.uniform(-6, -0.5)
    return rng.uniform(0, np.pi)


def launch_rmin(S, re, rng):
    """A launch angle whose b is 1e-7 to 1e-1 of r_min off it, either side, out (a third) or in; None
    from an eye at r_min."""
    b = S.rmin * (1 + rng.choice([-1, 1]) * 10 ** rng.uniform(-7, -1))
    if b >= re:
        return None
    a = np.arcsin(b / re)
    return a if rng.uniform() < 1 / 3 else np.pi - a


def image_of(phi):
    """The image a turn phi >= 0 in the plane reaches: (j, alpha, the plane's side: +1 toward t, -1)."""
    k = np.floor(phi / (2 * np.pi))
    a = phi - 2 * np.pi * k
    return (int(2 * k), a, 1.0) if a <= np.pi else (int(2 * k) + 1, 2 * np.pi - a, -1.0)


def image_checks(name, S, gpu, gpu_nan, rng):
    """Every image: points along long shot rays, each of the image its turn makes it."""
    fails = 0
    places = eye_places(S)

    def far(s, y):
        return abs(y[0]) - (S.L + 30.0)
    far.terminal, far.direction = True, 1
    rows, cases = [], []
    shots = 0
    while len(rows) < 1200:
        el = float(np.float32(eye_at(places, rng)))
        side = 1.0 if el >= 0 else -1.0
        kind = shots % 3
        radial = shots % 10 == 9
        shots += 1
        alpha = launch_rmin(S, float(S.r(el)), rng) if kind == 2 else launch(rng, kind == 1)
        if alpha is None:
            alpha = launch(rng, True)
        if radial:
            alpha = float(rng.choice([0.0, np.pi]))
        sol = shoot(S, el, alpha, smax=IMAGE_S, events=[far], max_step=0.2)
        s_end = sol.t[-1]
        if s_end < 0.2:
            continue
        en, t = frame(rng)
        D = np.r_[side * np.cos(alpha), np.sin(alpha) * t]
        phi0, phi1 = sol.sol(0.05)[2], sol.y[2, -1]
        j0, j1 = image_of(phi0)[0], image_of(phi1)[0]
        for j in rng.permutation(np.arange(j0, j1 + 1))[:6] if not radial else [0] * 4:
            k, odd = divmod(int(j), 2)
            lo, hi = max(2 * np.pi * k + np.pi * odd, phi0), min(2 * np.pi * k + np.pi * (odd + 1), phi1)
            edge = rng.uniform() < 0.25 and lo > phi0     # a point on the axis: a turn of a whole number of pi
            if hi - lo > 1e-9:
                target = lo if edge else rng.uniform(lo, hi)
                s = optimize.brentq(lambda s: sol.sol(s)[2] - target, 0.05, s_end, xtol=1e-13)
            else:
                s = rng.uniform(0.05, s_end)
            lp, vl, phi = sol.sol(s)
            jj, a, sg = image_of(phi)
            if edge or radial:
                a = 0.0 if a < 0.5 * np.pi else np.pi
            ti = sg * t
            rows.append([el, *en, lp, *(np.cos(a) * en + np.sin(a) * ti), *ti, a, jj, 0, 0, 0])
            cases.append((D, s, jj))
    o = gpu.run(6, rows, in_per=4, out_per=2)
    js = np.array([c[2] for c in cases])
    derr = np.array([angle(g, D) for (D, s, j), g in zip(cases, o[0::2])])
    lerr = np.array([abs(g[0] - s) / (1e-3 + LENGTH_REL * s) for (D, s, j), g in zip(cases, o[1::2])])
    f = o[1::2, 1]
    rays = np.floor(f / 2)
    fell = int((f - 2 * rays > 0.0).sum())
    searched = rays[rays > 0]
    enough = name != 'the app' or (js >= IMAGE_J).sum() >= 20
    worst = int(np.argmax(derr))
    fails += not check(f'{name}: every image (geo_see_image)', derr.max() <= DIRECTION and lerr.max() <= 1 and fell == 0 and enough,
                       f'direction off by {derr.max():.1e} rad at most (median {np.median(derr):.0e}; the worst image {js[worst]}), length {lerr.max():.2f} of the limit, '
                       f'{fell} with a ray not finite ({len(rows)} points along {shots} rays, images 0 to {js.max()}: {(js >= 2).sum()} past the first turn, '
                       f'{(js >= IMAGE_J).sum()} from the {IMAGE_J}th; {len(searched)} searched, in {searched.mean():.1f} rays on average, {int(searched.max())} at most)')
    for k in [k for k in np.argsort(-np.maximum(derr / DIRECTION, lerr)) if derr[k] > DIRECTION or lerr[k] > 1][:8]:
        r, (D, s, j), g = rows[k], cases[k], o[2 * k:2 * k + 2]
        print(f'    point {k}: eye l {r[0]!r}, n {tuple(r[1:4])}; point l {r[4]!r}, n {tuple(r[5:8])}; t {tuple(r[8:11])}, alpha {r[11]!r}, image {j}: '
              f'GPU direction {tuple(g[0])}, length {g[1][0]!r}; the shot ray\'s {tuple(D)}, {s!r} ({derr[k]:.1e} rad off, length {lerr[k]:.2f} of the limit)')
    o = gpu_nan.run(6, rows, in_per=4, out_per=2)
    derr = np.array([angle(g, D) for (D, s, j), g in zip(cases, o[0::2])])
    f = o[1::2, 1]
    stand_in = int((f - 2 * np.floor(f / 2) > 0.75).sum())
    fails += not check(f'{name}: the same, a quarter of the search\'s rays made NaN', derr.max() <= NAN_DIRECTION and stand_in == 0,
                       f'direction off by {derr.max():.1e} rad at most (median {np.median(derr):.0e}), {stand_in} by the stand-in')
    return fails


class Exit:
    """A pixel's ray as the GPU got it (float32), and the reference's way out of the zone for it and
    for the launches turned by d in its plane."""

    def __init__(self, S, row):
        self.S = S
        self.el = float(row[0])
        self.side = 1.0 if self.el >= 0 else -1.0
        self.en = unit(row[1:4].astype(float))
        u = row[5:8].astype(float)
        self.t = unit(u - (u @ self.en) * self.en)
        ca, sa = self.side * np.longdouble(row[4]), np.sqrt(np.sum(np.square(row[5:8].astype(np.longdouble))))
        h = np.sqrt(ca * ca + sa * sa)
        self.ca, self.sa = ca / h, sa / h
        self.re = float(S.r(abs(self.el)))

    def at(self, d=0.0):
        """The way out for the launch turned by d: (hit, sheet), psi, way, pos, dir (R^4's xyz). The
        launch in extended precision (leave)."""
        S, en, t = self.S, self.en, self.t
        d = np.longdouble(d)
        c, s = np.cos(d), np.sin(d)
        ca, sa = self.ca * c - self.sa * s, self.sa * c + self.ca * s
        with np.errstate(divide='ignore', invalid='ignore'):    # at b = r_min itself: not finite
            res = leave(S, self.el, ca, sa)
        ca, sa = float(ca), float(sa)
        if res is None:
            return (False, self.side), 0.0, 0.0, self.re * en, ca * en + sa * t
        sheet, psi, way = res
        b = self.re * sa
        nx = np.cos(psi) * en + np.sin(psi) * t
        tx = np.cos(psi) * t - np.sin(psi) * en
        return (True, sheet), psi, way, S.Rout * nx, (np.sqrt(max((S.Rout - b) * (S.Rout + b), 0.0)) * nx + b * tx) / S.Rout


def floor_of(pos, dir_, way):
    """Where the straight line from pos along dir meets the floor: (xy, its way from the eye), or None."""
    if dir_[2] >= 0:
        return None
    t = (-LIFT - pos[2]) / dir_[2]
    return pos[:2] + t * dir_[:2], way + t


def compare(ref, g):
    """The GPU's way out g = (hit, sheet, way, floor's way), pos, dir, floor's xy against the reference's
    ((hit, sheet), psi, way, pos, dir): (same universe, pos's angle, dir's angle, way's share of the
    limit, floor: None if both see the sky or the floor beyond FLOOR_SEEN, its share of the limit if
    both the floor, 'horizon' for floor and sky crossed as near the horizon as the GPU's direction is
    off, else 'flip'))."""
    key, psi, way, pos, dir_ = ref
    same = key == (g[0][0] > 0.5, float(g[0][1]))
    pa, da = angle(g[1][:3], pos), angle(g[2][:3], dir_)
    werr = abs(g[0][2] - way) / (1e-3 + LENGTH_REL * way)
    fr = floor_of(pos, dir_, way)
    if (fr is None) != (g[0][3] < 0):
        fl = 'horizon' if abs(dir_[2]) <= da + 1e-7 else 'flip'
    elif fr is None or (fr[1] > FLOOR_SEEN and g[0][3] > FLOOR_SEEN):
        fl = None
    else:
        fl = float(np.linalg.norm(g[3][:2] - fr[0]) / (FLOOR_ABS + FLOOR_REL * fr[1]))
    return same, pa, da, werr, fl


def exit_ok(c):
    same, pa, da, werr, fl = c
    return same and pa <= DIRECTION and da <= DIRECTION and werr <= 1


def floor_ok(c):
    return c[4] != 'flip' and (not isinstance(c[4], float) or c[4] <= 1)


def passes(c):
    return exit_ok(c) and floor_ok(c)


def backward(X, g):
    """An ill-posed ray: the launch within ALPHA_TOL whose way out is the GPU's (its universe, then
    its turn: the GPU's exit point's angle in the plane plus whole turns, bisected on each stretch of
    launches into that universe, where the turn is monotonic; the whole turns picked by the way when
    there are many). Returns (|d|, the comparison) or None."""
    gkey = (g[0][0] > 0.5, float(g[0][1]))
    grid = np.linspace(-ALPHA_TOL, ALPHA_TOL, 17)
    keys = [X.at(d)[0] for d in grid]
    # the stretches of launches into the GPU's universe, their ends bisected to where it changes
    stretches = []
    k = 0
    while k < len(grid):
        if keys[k] != gkey:
            k += 1
            continue
        m = k
        while m + 1 < len(grid) and keys[m + 1] == gkey:
            m += 1
        ends = []
        for inner, outer in ((k, k - 1), (m, m + 1)):
            a = grid[inner]
            if 0 <= outer < len(grid):
                b = grid[outer]
                for _ in range(60):
                    mid = 0.5 * (a + b)
                    if X.at(mid)[0] == gkey:
                        a = mid
                    else:
                        b = mid
                # where the universe changes the turn has no bound (b = r_min): back to where the
                # reference's numbers are finite
                for f in np.logspace(-15, 0, 46):
                    d = a + (grid[inner] - a) * f
                    if np.isfinite(X.at(d)[1] + X.at(d)[2]):
                        a = d
                        break
            ends.append(a)
        stretches.append(ends)
        k = m + 1
    psig = np.arctan2(g[1][:3] @ X.t, g[1][:3] @ X.en) % (2 * np.pi)
    best = None
    for d0, d1 in stretches:
        p0, p1 = X.at(d0)[1], X.at(d1)[1]
        lo, hi = min(p0, p1), max(p0, p1)
        k0, k1 = int(np.ceil((lo - DIRECTION - psig) / (2 * np.pi))), int(np.floor((hi + DIRECTION - psig) / (2 * np.pi)))
        if k1 < k0:
            continue
        if k1 - k0 > 6:
            # many whole turns: those the way allows
            w0, w1 = X.at(d0)[2], X.at(d1)[2]
            wg = g[0][2]
            if (w0 - wg) * (w1 - wg) < 0:
                dw = optimize.brentq(lambda d: X.at(d)[2] - wg, d0, d1, xtol=1e-18, rtol=1e-15)
            else:
                dw = d0 if abs(w0 - wg) < abs(w1 - wg) else d1
            kw = int(round((X.at(dw)[1] - psig) / (2 * np.pi)))
            k0, k1 = max(k0, kw - 3), min(k1, kw + 3)
        for kk in range(k0, k1 + 1):
            target = psig + 2 * np.pi * kk
            if (p0 - target) * (p1 - target) < 0:
                d = optimize.brentq(lambda d: X.at(d)[1] - target, d0, d1, xtol=1e-18, rtol=1e-15)
            else:
                d = d0 if abs(p0 - target) < abs(p1 - target) else d1
            c = compare(X.at(d), g)
            if passes(c) and (best is None or abs(d) < best[0]):
                best = (abs(d), c)
    return best


def exit_checks(name, S, gpu, rng, table=False):
    """Each pixel's ray out of the curved zone, and the floor along it; table: by the eye's table
    (geo_xt, our own foveation's floor)."""
    places = eye_places(S)
    rows = []
    while len(rows) < 2000:
        el = eye_at(places, rng)
        side = 1.0 if el >= 0 else -1.0
        re = float(S.r(el))
        en, t = frame(rng)
        if re * en[2] < -LIFT + 0.1:         # an eye under the floor: none
            continue
        kind = len(rows) % 4
        alpha = launch_rmin(S, re, rng) if kind == 3 else launch(rng, kind < 2)
        if alpha is None:
            alpha = launch(rng, False)
        rows.append([el, *en, side * np.cos(alpha), *(np.sin(alpha) * t)])
    rows = np.asarray(rows, 'f4')
    o = gpu.run(10 if table else 5, rows, out_per=4)
    gs = [o[4 * k:4 * k + 4] for k in range(len(rows))]
    took = int(sum(g[3][3] > 0.5 for g in gs))
    worst = dict(pa=0.0, da=0.0, werr=0.0, fl=0.0, back=0.0)
    wrong, wrong_floor, ill, enter, other, horizon, floors = [], [], 0, 0, 0, 0, 0
    for k, (row, g) in enumerate(zip(rows, gs)):
        X = Exit(S, row)
        ref = X.at()
        enter += ref[0][0]
        other += ref[0][0] and ref[0][1] != X.side
        # ill-posed: the reference's own way out moves by half a limit within ALPHA_TOL of the launch
        lim_w = 1e-3 + LENGTH_REL * ref[2]
        around = [X.at(d) for d in (-ALPHA_TOL, ALPHA_TOL)]
        if all(a[0] == ref[0] and abs(a[1] - ref[1]) <= 0.5 * DIRECTION and abs(a[2] - ref[2]) <= 0.5 * lim_w for a in around):
            c = compare(ref, g)
            if exit_ok(c):
                worst['pa'] = max(worst['pa'], c[1]); worst['da'] = max(worst['da'], c[2]); worst['werr'] = max(worst['werr'], c[3])
            else:
                wrong.append((k, row, g, ref, c))
        else:
            ill += 1
            bw = backward(X, g)
            if bw is None:
                wrong.append((k, row, g, ref, compare(ref, g)))
                continue
            worst['back'] = max(worst['back'], bw[0])
            c = bw[1]
        if not floor_ok(c):
            wrong_floor.append((k, row, g, ref, c))
        elif isinstance(c[4], float):
            worst['fl'] = max(worst['fl'], c[4]); floors += 1
        horizon += c[4] == 'horizon'
    refdiff = reference_vs_dop853(S, rows[:300])
    what = 'by the eye\'s table (geo_xt)' if table else '(geo_exit)'
    fails = not check(f'{name}: the way out of the zone {what}', not wrong and refdiff <= 1e-6,
                      f'exit point off by {worst["pa"]:.1e} rad, direction by {worst["da"]:.1e} rad, length {worst["werr"]:.2f} of the limit at most; '
                      f'{len(wrong)} wrong ({len(rows)} rays, {enter} into the zone, {other} of them out into the other universe; '
                      f'{ill} ill-posed, each the reference\'s for a launch within {worst["back"]:.0e} rad; the reference off DOP853 by {refdiff:.0e}'
                      + (f'; {took} of those into the zone by the table\'s line, the rest by geo_exit_way)' if table else ')'))
    for k, row, g, ref, c in (wrong + wrong_floor)[:8]:
        print(f'    ray {k}: eye l {row[0]!r}, n {tuple(row[1:4])}, D {tuple(row[4:8])}: GPU (hit, sheet, way, floor way) {tuple(g[0])}, pos {tuple(g[1][:3])}, dir {tuple(g[2][:3])}; '
              f'reference {ref[0]}, psi {ref[1]:.6f}, way {ref[2]:.6f}, pos {tuple(np.round(ref[3], 6))}, dir {tuple(np.round(ref[4], 6))}; '
              f'(same universe, pos, dir, way, floor) {c}')
    fails += not check(f'{name}: where the way out {"by the table " if table else ""}meets the floor', not wrong and not wrong_floor,
                       f'{worst["fl"]:.2f} of the limit at most ({floors} rays onto the floor within {FLOOR_SEEN:.0f} m, where it shows; {len(wrong_floor)} wrong; '
                       f'{horizon} floor for sky or back within the direction\'s error of the horizon)')
    return fails


def reference_vs_dop853(S, rows):
    """The exits by leave (sweeps) against rays integrated by DOP853 to |l| = L going out: the largest
    difference in turn (rad) and length (m), on the reference's well-posed rays into the zone."""
    def edge(s, y):
        return abs(y[0]) - S.L
    edge.terminal, edge.direction = True, 1
    worst, n = 0.0, 0
    for row in rows:
        X = Exit(S, row)
        ref = X.at()
        if not ref[0][0] or ref[2] > 100 or n >= 100:
            continue
        if abs(X.at(ALPHA_TOL)[1] - ref[1]) > 1e-3 or X.at(ALPHA_TOL)[0] != ref[0] or X.at(-ALPHA_TOL)[0] != ref[0]:
            continue
        sol = shoot(S, X.el, float(np.arctan2(X.sa, X.ca)), smax=ref[2] + 5, events=[edge], max_step=0.2)
        if not sol.t_events[0].size:
            return np.inf
        y = sol.y_events[0][0]
        if (1.0 if y[0] > 0 else -1.0) != ref[0][1]:
            return np.inf
        worst = max(worst, abs(y[2] - ref[1]), abs(sol.t_events[0][0] - ref[2]))
        n += 1
    return worst


def zone_point(S, l, a, en, t):
    """The point (l, alpha) of the half-surface toward t, R^4 (zone.gdshaderinc's zone_point)."""
    return np.r_[float(S.r(l)) * (np.cos(a) * en + np.sin(a) * t), float(S.w(l))]


def l_of(S, P):
    """l of the space's point P of R^4 (geo_l_of)."""
    rho, a = np.linalg.norm(P[:3]), abs(P[3])
    sw = 1.0 if P[3] >= 0 else -1.0
    Ka = S.Lc - S.R * np.sin(S.th0)
    if rho >= S.Rout:
        return sw * (S.L + rho - S.Rout)
    if a <= Ka:
        return P[3]
    return sw * (S.Lc + S.R * (np.arctan2(a - Ka, S.Rout - rho) - S.th0))


def zone_body(S, rng, ball, axis_share=0.2):
    """A ball or a cube on the cylinder, the fillet, across the zone's edge or out of it, and an eye's
    axis en through the centre (t, m: a half-surface's direction and its normal, toward the body's
    centre): (C, E, size, en, t, m, axis), axis where the body is about the axis; None for a body
    across the crease of h < R (zone.gdshaderinc's Newton steps take the profile smooth, and the
    app's throat, h > R, has none)."""
    where = rng.integers(4)
    size = rng.uniform(0.05, 0.5) if ball else rng.uniform(0.05, 0.4)
    if where == 0:          # the cylinder (or round the crease, the photon sphere)
        lc = rng.uniform(-1, 1) * max(S.Lc - 0.6, 0.5)
    elif where == 1:        # the fillet
        lc = rng.choice([-1, 1]) * rng.uniform(S.Lc, S.L)
    elif where == 2:        # across the zone's edge
        lc = rng.choice([-1, 1]) * (S.L + rng.uniform(-size, size))
    else:                   # out
        lc = rng.choice([-1, 1]) * rng.uniform(S.L + 1, S.L + 10)
    if S.th0 > 0 and abs(lc) < 2 * size:
        return None
    en, t = frame(rng)
    m = np.cross(en, t)
    r_c = float(S.r(lc))
    axis = rng.uniform() < axis_share       # the eye's axis through the body: the half-surfaces round it
    ac = rng.choice([rng.uniform(0, 0.5), rng.uniform(np.pi - 0.5, np.pi)]) * size / r_c if axis else rng.uniform(0, np.pi)
    beta = rng.uniform(-0.8, 0.8) * size / r_c
    nc = np.cos(beta) * (np.cos(ac) * en + np.sin(ac) * t) + np.sin(beta) * m
    C = np.r_[r_c * nc, float(S.w(lc))]
    # a frame of the space's tangent space at C
    dr, dw = float(S.dr(lc)), float(S.dw(lc))
    a1 = unit(np.cross(nc, rng.normal(size=3)))
    T = [np.r_[dr * nc, dw], np.r_[a1, 0.0], np.r_[np.cross(nc, a1), 0.0]]
    Q = np.linalg.qr(rng.normal(size=(3, 3)))[0]
    E = [sum(Q[i, j] * T[j] for j in range(3)) for i in range(3)]
    return C, E, size, en, t, m, axis


def zone_checks(name, S, gpu, rng):
    """Where a line of a half-surface from an inner point leaves a ball or a cube."""
    fails = 0
    for ball in (True, False):
        rows, cases = [], []
        while len(rows) < 1500:
            body = zone_body(S, rng, ball)
            if body is None:
                continue
            C, E, size, en, t, m, axis = body
            if axis:
                ce = C[:3] @ en
                l0 = l_of(S, np.r_[ce * en, C[3]])
                al0, dsg = (0.0, 1.0) if ce >= 0 else (np.pi, -1.0)
            else:
                cq = C[:3] - (C[:3] @ m) * m
                al0 = np.arctan2(cq @ t, cq @ en)
                l0 = l_of(S, np.r_[cq, C[3]])
                dsg = 0.0
            X0 = zone_point(S, l0, al0, en, t)
            if outside(ball, X0, C, E, size) > -1e-3:
                continue
            r0 = float(S.r(l0))
            for k in range(25):
                phi = rng.uniform(0, np.pi) if axis else rng.uniform(0, 2 * np.pi)
                dl, dal = np.cos(phi), (dsg if axis else 1.0) * np.sin(phi) / r0
                rows.append([l0, al0, dl, dal, *en, size, *t, 0.0, *C, *E[0], *E[1], *E[2]])
        rows = np.asarray(rows, 'f4')
        o = gpu.run(7 if ball else 8, rows, in_per=7)
        on, off = 0.0, 0.0
        bad, later = [], []
        for k, (row, g) in enumerate(zip(rows.astype(float), o)):
            l0, al0, dl, dal = row[0:4]
            en, size, t = row[4:7], row[7], row[8:11]
            C, E = row[12:16], [row[16:20], row[20:24], row[24:28]]
            l, a = float(g[0]), float(g[1])
            r0 = float(S.r(l0))
            # the line's own first way out (float64), and the GPU's point against it in (l, r0 alpha)
            rho1 = first_out(S, ball, row)
            v = np.array([dl, r0 * dal])
            w = np.array([l - l0, r0 * (a - al0)])
            rho = (w @ v) / (v @ v)
            dist = abs(w[0] * v[1] - w[1] * v[0]) / np.linalg.norm(v)
            e = abs(outside(ball, zone_point(S, l, a, en, t), C, E, size))
            on, off = max(on, e), max(off, dist)
            if e > CHORD:
                bad.append((k, row, g, e, rho1))
            elif abs(rho - rho1) > 1e-3:
                later.append((k, row, g, rho, rho1))
        body = 'ball' if ball else 'cube'
        ok = not bad and not later and off <= 1e-4
        fails += not check(f'{name}: where a line leaves a {body} in the zone (zone_edge_{body})', ok,
                           f'off its surface by {on:.1e} m at most, off the line by {off:.1e} m; {len(bad)} off the surface, {len(later)} not the line\'s first way out'
                           + f' ({len(rows)} lines from {len(rows) // 25} inner points)')
        for k, row, g, e, rho1 in bad[:5]:
            print(f'    line {k}: {line_text(row)}: GPU (l, alpha) {tuple(g[:2])}, off the surface by {e:.2e} m (the first way out {rho1:.4f} m along)')
        for k, row, g, rho, rho1 in later[:5]:
            print(f'    line {k}: {line_text(row)}: GPU (l, alpha) {tuple(g[:2])}, {rho:.4f} m along the line, its first way out {rho1:.4f} m')
    return fails


MESHES = ((64, 48), (64, 12))   # the zone bodies' meshes: Renderer's ZONE_AZIMUTHS, ZONE_ROUND, ZONE_ROUND_COARSE
NEAR_END = 5e-4                 # metres: a cube's section corner a vertex within this, next to its edge's end


def zone_mesh_checks(name, S, gpu, rng):
    """The zone bodies' meshes (zone_vertex) whole, for eyes' axes through and beside them."""
    fails = 0
    for ball in (True, False):
        bodies = []
        while len(bodies) < 30:
            b = zone_body(S, rng, ball, axis_share=0.4)
            if b is not None:
                bodies.append(b)
        for cols, rws in MESHES:
            rows = [[i / cols, j / rws, cols, rws, *en, size, 1.0 if ball else 0.0, 0, 0, 0, *C, *E[0], *E[1], *E[2]]
                    for C, E, size, en, t, m, axis in bodies for i in range(cols + 1) for j in range(rws + 1)]
            o = gpu.run(9, rows, in_per=7, out_per=2).astype(float).reshape(len(bodies), cols + 1, rws + 1, 2, 4)
            worst, alpha_out, tip, corners, missed, moved, strips, folded = 0.0, 0, 0.0, 0, [], 0, 0, 0
            for k, (C, E, size, en, t0, m0, axis) in enumerate(bodies):
                L, A, T = o[k, :, :, 0, 0], o[k, :, :, 0, 1], o[k, :, :, 1, :3]
                n = np.cos(A)[..., None] * en + np.sin(A)[..., None] * T
                P = np.concatenate([S.r(L)[..., None] * n, S.w(L)[..., None]], axis=-1)
                q = P - C
                E = np.array(E)
                sl = q @ E.T                                   # [cols + 1, rows + 1, 3]
                if not ball and folds(S, C, E, size, en):
                    folded += 1
                    continue
                off = np.abs(np.linalg.norm(q, axis=-1) - size) if ball else np.abs(np.abs(sl).max(-1) - size)
                worst = max(worst, off.max())
                alpha_out += int(((A < -1e-6) | (A > np.pi + 1e-6)).sum())
                if ball:
                    # off the axis, the first and last columns' sections are at the ball's tips
                    a1 = unit(np.cross(en, [0, 0, 1.0] if abs(en[2]) < 0.9 else [1.0, 0, 0]))
                    ce = C[:3] @ en
                    if np.linalg.norm(q[0, 0]) > 0 and not np.isclose(T[0, 0] @ T[-1, 0], 1.0):
                        for i in (0, cols):
                            tip = max(tip, np.linalg.norm(P[i] - P[i].mean(0), axis=-1).max() / size)
                    continue
                # an edge the space's curve takes back round the axis (the axis next to it): its
                # sections there cut it twice, which a section's corners, one an edge, can't be
                # a cube: each column's section's corners (float64, where the half-surface meets the
                # cube's edges), each a vertex of that column; and each on the same row in the next
                # column (where the columns are apart)
                rows_of = [{} for _ in range(cols + 1)]       # column: edge: the rows at its corner
                for i in range(cols + 1):
                    t = T[i, 0]
                    for e in range(12):
                        for c in cube_corner(S, C, E, size, en, t, e):
                            corners += 1
                            Pc = zone_point(S, c[0], c[1], en, t)
                            d = np.linalg.norm(P[i] - Pc, axis=-1)
                            # within a millimetre of its edge's end (a column on a corner's azimuth,
                            # the shader's own in float32), where the edge meets the half-surface is
                            # ill-posed: a ten-thousandth of a degree moves it by a tenth of a millimetre
                            end = size - abs((Pc - C) @ E[e // 4])
                            tol = max(NEAR_END, end + CHORD) if end < 1e-3 else CHORD
                            if d.min() > tol:
                                missed.append((k, i, e, d.min()))
                            rows_of[i][e] = set(np.nonzero(d <= tol)[0].tolist())
                for i in range(cols):
                    if angle(T[i, 0], T[i + 1, 0]) > 1e-5:
                        strips += 1
                        for e, rs in rows_of[i].items():
                            if rs and rows_of[i + 1].get(e) and not rs & rows_of[i + 1][e]:
                                moved += 1
            body = 'ball' if ball else 'cube'
            ok = worst <= CHORD and alpha_out == 0 and (tip <= 0.02 if ball else not missed and moved == 0)
            fails += not check(f'{name}: a {body}\'s mesh in the zone, {cols} by {rws} (zone_vertex)', ok,
                               f'vertices off its surface by {worst:.1e} m at most, {alpha_out} out of the half-surface'
                               + (f'; the tips\' sections {tip:.3f} of the radius across at most' if ball else
                                  f'; {len(missed)} of {corners} section corners not a vertex, {moved} on another row in the next column ({strips} strips); '
                                  f'{folded} left out, an edge taken back round the axis')
                               + f' ({len(bodies)} {body}s, {sum(1 for b in bodies if b[6])} about the axis)')
            for k, i, e, d in missed[:5]:
                C, E, size, en = bodies[k][:4]
                print(f'    cube C {tuple(C)}, E {tuple(map(tuple, E))}, size {size!r}, en {tuple(en)}: column {i}, edge {e}: the nearest vertex {d:.2e} m from its corner')
    return fails


def normal4(S, C):
    """The space's normal at its point C (geo_normal)."""
    x = C[:3]
    rho, a, sw = np.linalg.norm(x), abs(C[3]), (1.0 if C[3] >= 0 else -1.0)
    Ka = S.Lc - S.R * np.sin(S.th0)
    if rho >= S.Rout:
        return np.array([0, 0, 0, -sw])
    if a <= Ka:
        return np.r_[x / rho, 0.0]
    q = unit(np.array([rho - S.Rout, a - Ka]))
    return np.r_[-q[0] * x / rho, -q[1] * sw]


def onto(S, Q, N):
    """Q taken along N onto the space (geo_onto), float64."""
    c = 0.0
    for _ in range(30):
        P = Q + c * N
        l = l_of(S, P)
        Ps = np.r_[float(S.r(l)) * unit(P[:3]), float(S.w(l))]
        c += (Ps - P) @ N
    return Q + c * N


def folds(S, C, E, size, en):
    """Whether one of a cube's edges goes back round the axis along en (its azimuth turns back:
    the axis within the space's curve of it)."""
    N = normal4(S, C)
    a1 = unit(np.cross(en, [0, 0, 1.0] if abs(en[2]) < 0.9 else [1.0, 0, 0]))
    a2 = np.cross(en, a1)
    for e in range(12):
        a, b, g = e // 4, (e // 4 + 1) % 3, (e // 4 + 2) % 3
        az = []
        for u in np.linspace(-1, 1, 33):
            x = np.zeros(3)
            x[a], x[b], x[g] = u * size, (size if e & 1 else -size), (size if e & 2 else -size)
            P = onto(S, C + x @ E, N)
            az.append(np.arctan2(P[:3] @ a2, P[:3] @ a1))
        d = np.diff(np.unwrap(az))
        if (d > 1e-9).any() and (d < -1e-9).any():
            return True
    return False


def cube_corner(S, C, E, size, en, t, e):
    """Where the half-surface toward t meets the cube's edge e (zone_edge_cut's numbering), float64:
    Newton in (l, alpha) from the first-order cut; [] where it doesn't (or the edge lies along it)."""
    E = np.asarray(E)
    a = e // 4
    b, g = (a + 1) % 3, (a + 2) % 3
    gb, gg = (size if e & 1 else -size), (size if e & 2 else -size)
    m = np.cross(en, t)
    mu = E[:, :3] @ m
    if abs(mu[a]) < 1e-9:
        return []
    x = np.zeros(3)
    x[a], x[b], x[g] = (-C[:3] @ m - mu[b] * gb - mu[g] * gg) / mu[a], gb, gg
    if abs(x[a]) > 1.3 * size:
        return []
    X = C + x @ E
    p = np.array([l_of(S, X), np.arctan2(X[:3] @ t, X[:3] @ en)])

    def f(p):
        q = zone_point(S, p[0], p[1], en, t) - C
        return np.array([q @ E[b] - gb, q @ E[g] - gg])
    for _ in range(40):
        F = f(p)
        h = 1e-7
        J = np.c_[(f(p + [h, 0]) - f(p - [h, 0])) / (2 * h), (f(p + [0, h]) - f(p - [0, h])) / (2 * h)]
        if abs(np.linalg.det(J)) < 1e-8:
            return []
        p = p - np.linalg.solve(J, F)
    q = zone_point(S, p[0], p[1], en, t) - C
    if np.abs(f(p)).max() > 1e-9 or abs(q @ E[a]) > size + 1e-9 or not 0 <= p[1] <= np.pi:
        return []
    return [p]


def line_text(row):
    return (f'(l0, al0, dl, dal) {tuple(float(x) for x in row[0:4])}, en {tuple(float(x) for x in row[4:7])}, size {float(row[7])!r}, '
            f't {tuple(float(x) for x in row[8:11])}, C {tuple(float(x) for x in row[12:16])}, '
            f'E1 {tuple(float(x) for x in row[16:20])}, E2 {tuple(float(x) for x in row[20:24])}, E3 {tuple(float(x) for x in row[24:28])}')


def zone_points(S, ls, als, en, t):
    """zone_point for arrays of (l, alpha): [n, 4]."""
    n = np.cos(als)[:, None] * en + np.sin(als)[:, None] * t
    return np.c_[S.r(ls)[:, None] * n, S.w(ls)]


def first_out(S, ball, row):
    """How far along its line (metres of (l, r0 alpha)) a zone check's line first leaves the body:
    sampled every 1/200 of the body's size, then bisected."""
    l0, al0, dl, dal = row[0:4]
    en, size, t = row[4:7], row[7], row[8:11]
    C, E = row[12:16], np.array([row[16:20], row[20:24], row[24:28]])

    def out(rhos):
        q = zone_points(S, l0 + rhos * dl, al0 + rhos * dal, en, t) - C
        return np.linalg.norm(q, axis=1) - size if ball else np.abs(q @ E.T).max(1) - size
    rhos = np.linspace(0, 8 * size, 1601)
    o = out(rhos)
    i = int(np.argmax(o > 0))
    if o[i] <= 0:
        return np.inf
    lo, hi = rhos[i - 1], rhos[i]
    for _ in range(50):
        mid = 0.5 * (lo + hi)
        if out(np.array([mid]))[0] > 0:
            hi = mid
        else:
            lo = mid
    return 0.5 * (lo + hi)


def outside(ball, X, C, E, size):
    """How far the body's definition puts X outside it, metres (a ball's chord less its radius, a cube's
    largest slab less its half size)."""
    q = X - C
    if ball:
        return np.linalg.norm(q) - size
    return max(abs(q @ E[0]), abs(q @ E[1]), abs(q @ E[2])) - size


def eye_checks(S, gpu, rng):
    """The eye from the head: 300 heads (places, frames, offsets up to 6 cm) against RK4."""
    worst_p = worst_a = 0.0
    for k in range(300):
        l = rng.choice([0.0, S.Lc + 0.3, S.L - 0.2, S.L + 2.0, -(S.Lc + 0.5)]) + rng.uniform(-0.2, 0.2)
        n = unit(rng.normal(size=3)); n[2] = abs(n[2]) + 0.2; n = unit(n)
        # an orthonormal frame of tangent vectors (U_l, u)
        A = []
        for v in rng.normal(size=(3, 4)):
            v[1:] -= np.dot(v[1:], n) * n
            for a in A:
                v -= np.dot(v, a) * a
            A.append(unit(v))
        head_pos = rng.uniform(-1, 1, 3)
        off = unit(rng.normal(size=3)) * rng.uniform(0, 0.06)
        basis = np.linalg.qr(rng.normal(size=(3, 3)))[0]
        p = gpu.prog
        p['head_l'] = l; p['head_n'] = tuple(n); p['head_pos'] = tuple(head_pos)
        p['head_f'].write(np.array(A, 'f4').tobytes())
        p['vb0'] = tuple(basis[:, 0]); p['vb1'] = tuple(basis[:, 1]); p['vb2'] = tuple(basis[:, 2])
        o = gpu.run(3, [[*(head_pos + off), 0, 0, 0, 0, 0]], out_per=4)
        # RK4 along the offset, the frame carried
        T = off[0] * A[0] + off[1] * A[1] + off[2] * A[2]
        dist = np.linalg.norm(T)
        el, en, F = rk4_eye(S, l, n, T, dist, A)
        axes = [basis[0, k2] * F[0] + basis[1, k2] * F[1] + basis[2, k2] * F[2] for k2 in range(3)]
        worst_p = max(worst_p, abs(o[0, 0] - el), np.abs(o[0, 1:] - en).max() * float(S.r(el)))
        worst_a = max(worst_a, max(np.abs(o[1 + k2] - axes[k2]).max() for k2 in range(3)))
    return not check('the eye from the head', worst_p <= EYE_POS + 1e-6 and worst_a <= EYE_AXES,
                     f'place off by {worst_p:.1e} m, axes by {worst_a:.1e} at most (300 heads, offsets to 6 cm)')


def rk4_eye(S, l, n, T, dist, A):
    if dist == 0:
        return l, n, A

    def f(y):
        l, n, vl, v = y[0], y[1:4], y[4], y[5:8]
        r = float(S.r(l)); k = float(S.dr(l)) / r
        vv = v @ v
        out = [vl, *(v / r), k * vv, *(-k * vl * v - vv / r * n)]
        for j in range(3):
            Ul, u = y[8 + 4 * j], y[9 + 4 * j:12 + 4 * j]
            uv = u @ v
            out += [k * uv, *(-k * Ul * v - uv / r * n)]
        return np.array(out)
    y = np.r_[l, n, T[0] / dist, T[1:] / dist, np.concatenate(A)]
    steps = 200
    hs = dist / steps
    for _ in range(steps):
        k1 = f(y); k2 = f(y + hs / 2 * k1); k3 = f(y + hs / 2 * k2); k4 = f(y + hs * k3)
        y = y + hs / 6 * (k1 + 2 * k2 + 2 * k3 + k4)
    return y[0], unit(y[1:4]), [y[8 + 4 * j:12 + 4 * j] for j in range(3)]


def numbers_check():
    """Every number of the shaders the same float32 as Godot writes it into GLSL."""
    changed, count, files = [], 0, 0
    for f in sorted(os.listdir(SHADERS)):
        if not f.endswith(('.gdshader', '.gdshaderinc')):
            continue
        files += 1
        src = open(os.path.join(SHADERS, f)).read()
        src = re.sub(r'/\*.*?\*/', lambda m: '\n' * m.group(0).count('\n'), src, flags=re.S)
        for n, line in enumerate(src.split('\n'), 1):
            for m in NUMBER.finditer(line.split('//')[0]):
                count += 1
                if np.float32(float(m.group(1))) != np.float32(float(godot_number(m.group(1)))):
                    changed.append(f'{f}:{n} {m.group(1)} -> {godot_number(m.group(1))}')
    return int(not check('the shaders\' numbers as Godot writes them', not changed,
                         f'{count} numbers in {files} files, {len(changed)} changed' + ''.join(f'\n    {c}' for c in changed)))


def main(checks=('numbers', 'profile', 'images', 'exit', 'zone', 'eye')):
    ctx = moderngl.create_standalone_context(backend='egl', require=430)
    rng = np.random.default_rng(1)
    fails = numbers_check() if 'numbers' in checks else 0
    for name, prof in PROFILES.items():
        S = Space(*prof)
        S.t0, S.t1 = S.t_of_b(0.0), S.t_of_b(S.Rout)
        gpu = Gpu(ctx, S)
        gpu_nan = Gpu(ctx, S, NAN_SRC)
        if 'profile' in checks:
            fails += profile_checks(name, S, gpu, gpu_nan, rng)
        if 'images' in checks:
            fails += image_checks(name, S, gpu, gpu_nan, rng)
        if 'exit' in checks:
            # the table's on the same rays, and the checks after see the same draws as without it
            same = copy.deepcopy(rng)
            fails += exit_checks(name, S, gpu, rng)
            fails += exit_checks(name, S, gpu, same, table=True)
        if 'zone' in checks:
            fails += zone_checks(name, S, gpu, rng)
            fails += zone_mesh_checks(name, S, gpu, rng)
        if name == 'the app' and 'eye' in checks:
            fails += eye_checks(S, gpu, rng)
    print(f'FAILURES: {fails}')
    return fails


if __name__ == '__main__':
    sys.exit(1 if main(sys.argv[1:] or ('numbers', 'profile', 'images', 'exit', 'zone', 'eye')) else 0)
