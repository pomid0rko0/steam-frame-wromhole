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
  both also with a quarter of the search's rays made NaN: every vertex still a number, never the
    stand-in (how far it then goes off is printed, held to no limit: a failure of the GPU's that
    the headset's marking of such vertices, body.gdshaderinc's, has never shown);
  the paths by a body's table (zone_path_see, the zone bodies' vertices): eyes as above, bodies of
    the toys' sizes about the eye, across the cylinder's and the zone's ends and anywhere in the
    zone, the table's nodes worked out as the table's pass does (zone_path_frame, zone_path_at,
    zone_path_node); points along shot rays within the body's l, every image up to the last
    Renderer.ZONE_IMAGES draws: the direction within PATH_DIRECTION, the length as above, the
    direction the light comes in at the point (the lighting's) within PATH_ARRIVE;
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
  the zone bodies' meshes whole (balls zone_ball_vertex, cubes zone_cube.gdshaderinc's passes;
    MESHES), for eyes' axes through and beside the bodies: every vertex on its body; a ball's first
    and last columns' sections at its tips; a cube: every triangle (of area in the picture, not
    dropped) on one face of it (ON_FACE: none across an edge, the face's lighting another's), and
    every face covered (COVER points at random on each, each in a triangle on it in its own
    coordinates, or at a knot's two columns in (theta, alpha) round the axis within DIRECTION of
    one: no gap); and built round an axis no further than ZC_PUSH off the eye's; also for cubes
    the axis passes through or next to a corner, an edge or a face of (within a hundredth of a
    radian, and exactly), and issue #147's four;
  the eye (geo_eye): against the head moved along its geodesic by RK4, the frame carried along;
  a ball's surface (geo_onto, the chord): every vertex at chord distance radius, on the space.
Off on a throat with a crease (h < R) until issue #118 (CREASE_OFF): the cubes' meshes in the zone
and a ball's surface. The zone's steps take the profile smooth, and there cubes across the crease
came out with vertices hundreds of metres off, a ball next to it off its chord by 5.8e-5 m. And
until #145 (CREASE_PATHS_OFF) the paths by a body's table: the rays that turn before the crease turn
by no more than the one that grazes it, beyond that the way hugs the crease, and the table's cubic
smooths the kink between (4e-3 rad off).
Every number of godot/shaders as Godot writes it into the GLSL it compiles (14 decimals): the same
float32; the GPU here is given them so written.
Each throat's checks run in pieces, each in a process of its own (a GPU context and random draws
of its own, seeded by the throat and the piece), as many at once as there are cores, the longest
first; their lines come throat by throat. Exit status 1 on any failure.
   python3 ref/test_gpu.py [numbers profile images paths exit zone eye]     (all, or those checks)"""
import copy
import os
import re
import subprocess
import sys
import tempfile
import time
import in_box  # noqa: F401 (first: on the Frame, into tools/box.sh's container)
import numpy as np
import moderngl
from scipy import optimize
from geo import Space, shoot, plane_rhs, app_profile, app_lift, leave
from scipy import integrate

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


INC = ''.join(open(os.path.join(SHADERS, f)).read() for f in ('geo.gdshaderinc', 'zone.gdshaderinc', 'zone_cube.gdshaderinc', 'zone_tail.gdshaderinc'))
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
PROFILES = {'the app': app_profile(), 'h = R': (3.0, 1.0, 1.0), 'crease, h < R': (3.0, 0.4, 1.0),
            'long, h = 41': (3.0, 41.0, 1.0)}
LIFT = app_lift()           # the floor at z = -LIFT (every profile's zone, radius Rout = 4 m, above it)
# the limits: radians of sweep (with a share of the sweep for long rays round the photon sphere),
# radians of direction (the headset's pixel is about 1e-3: half a pixel 5e-4), metres; a ray's length
# only orders bodies in depth and hazes the floor: a share of it
SWEEP_ABS, SWEEP_REL = 5e-5, 1e-5
DIRECTION = 5e-4
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
PATH_DIRECTION = 1e-4        # radians: a body's table (a tenth of the headset's pixel)
# radians: the direction light comes in at a body's point by its table (the lighting's only: its rim
# goes as (1 - n . ray)^3, 3/4 of a step of the ray at most, 2/255 of the colour at this)
PATH_ARRIVE = 1e-2
# a body's table's nodes (zone.gdshaderinc) and the images drawn of a body in the zone (renderer.gd)
ZONE_PL, ZONE_PQ = (int(re.search(r'const int %s = (\d+);' % k, open(os.path.join(SHADERS, 'zone.gdshaderinc')).read()).group(1))
                    for k in ('ZONE_PL', 'ZONE_PQ'))
ZONE_IMAGES = int(re.search(r'^const ZONE_IMAGES := (\d+)', open(os.path.join(HERE, '..', 'godot', 'renderer.gd')).read(), re.M).group(1))

SRC = '''#version 430
layout(local_size_x=64) in;
uniform vec4 g_prof; uniform vec4 g_prof2; uniform vec4 g_tabx; uniform sampler2D g_tab; uniform float g_lift;
uniform sampler2DArray g_paths;     // a body's table (mode 12), slot 0, one eye
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
		// worked out here as foveation's table pass works them out; and 1 in the floor's point's .w if
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
	} else if (mode == 11) {    // a = (eye l, n), c = a table's frame, (node i, k): the node
		vec2 at = zone_path_at(c, int(inp[I + 2].x), int(inp[I + 2].y));
		outp[O] = zone_path_node(a.x, a.yzw, at.x, at.y);
	} else if (mode == 12) {    // a = (eye l, n), c = (point l, n), (t, alpha), (image): by g_paths, the direction, (len, fell), arrive
		vec4 e = inp[I + 2];
		float len, fell; vec4 arr;
		vec4 d = zone_path_see(g_paths, 0, 0, a.x, a.yzw, c.x, c.yzw, e.xyz, e.w, int(inp[I + 3].x), len, arr, fell);
		outp[O] = d;
		outp[O + 1] = vec4(len, fell, 0.0, 0.0);
		outp[O + 2] = arr;
	} else if (mode == 13) {    // a = a body's centre, c = (reach, psi_max): its table's frame
		outp[O] = zone_path_frame(a, c.x, c.y);
	} else if (mode == 15) {    // a = (eye l, n), c = a ray there, C, E1, E2, (size, 1 a cube, psi_min): the
		// tail's first way into the body (zone_tail.gdshaderinc): (hit, y, psi, len), its point, (its
		// stretch, the band's least and greatest angle off the inward radial, 1 if a tail ray)
		float al = abs(a.x);
		vec3 eye = vec3(geo_r(al), sqrt(geo_u(al)), geo_dr(al));
		vec4 e = inp[I + 5];
		TailRay z;
		TailBody q = tail_body(e.y > 0.5, inp[I + 2], inp[I + 3], inp[I + 4], e.x);
		bool ray = tail_ray(a.x, eye, a.yzw, c, e.z, z);
		float y = 0.0, ang = 0.0, psi = 0.0;
		int on = 0;
		bool hit = ray && tail_meet(z, q, e.z, y, ang, psi, on);
		vec4 P = vec4(0.0), arr = vec4(0.0);
		float len = 0.0;
		if (hit) tail_hit(z, y, ang, on, P, arr, len);
		vec2 band = tail_band(a.x, eye, e.z);
		outp[O] = vec4(hit ? 1.0 : 0.0, y, psi, len);
		outp[O + 1] = P;
		outp[O + 2] = vec4(float(on), band, ray ? 1.0 : 0.0);
	} else if (mode == 9) {     // a = (u, v), c = (en, size), C: a ball's node (l, alpha), t
		vec3 t;
		vec2 p = zone_ball_vertex(a.xy, c.xyz, inp[I + 2], c.w, t);
		outp[O] = vec4(p, 0.0, 0.0);
		outp[O + 1] = vec4(t, 0.0);
	} else if (mode == 14) {    // a = (column, columns, rows), c = (en, size), C, E1, E2, E3: a cube's column,
		// each of its nodes (l, alpha, 1 if killed, 1 if not a number), (t, its span), as zone_sections'
		// cube passes work them out, here all in one invocation; then (the axis it is built round, the
		// column's side of a knot: zc_side)
		vec4 C = inp[I + 2];
		ZCube q = zc_cube(C, inp[I + 3], inp[I + 4], inp[I + 5], geo_normal(C), c.w, c.xyz);
		vec4 near[12];
		vec2 ends[12];
		for (int e = 0; e < 12; e++) near[e] = zc_edge_near(q, e, ends[e]);
		ZAxis ax = zc_axis(q, near, ends);
		bool turned = ax.en != q.en;
		q = zc_cube(C, inp[I + 3], inp[I + 4], inp[I + 5], geo_normal(C), c.w, ax.en);
		ZPieces pcs;
		for (int e = 0; e < 12; e++) {
			vec3 pu[ZC_PIECES], pt[ZC_PIECES];
			vec2 en_;
			if (turned) near[e] = zc_edge_near(q, e, en_);
			pcs.n[e] = zc_pieces(q, e, near[e], pu, pt);
			for (int k = 0; k < ZC_PIECES; k++) {
				pcs.u[e * ZC_PIECES + k] = pu[k];
				pcs.t[e * ZC_PIECES + k] = pt[k];
			}
		}
		float th0 = ax.rnd ? 0.0 : geo_atan2(dot(C.xyz, q.a2), dot(C.xyz, q.a1));
		float kn[ZC_KNOTS];
		int nk = zc_knots(pcs, ax.rnd, th0, kn);
		vec3 col = zc_column(a.x, a.y, kn, nk, ax.rnd, th0);
		ZSeq sq = zc_sequence(q, pcs, ax, col.y);
		vec3 m;
		vec3 t = zc_t(q, col.x, m);
		vec2 pos[ZC_ITEMS];
		int ne = 0;
		for (int j = 0; j < ZC_PARTS; j++) {
			if (j < sq.k) ne += sq.n[j];
		}
		for (int j = 0; j < ZC_ITEMS; j++) pos[j] = j < ne ? zc_item(q, pcs, ax, sq.id[j], col.x, t, m) : vec2(0.0);
		for (int r = 0; r <= int(a.z); r++) {
			bool kill;
			vec2 p = zc_node(q, float(r), a.z, sq, pos, t, m, kill);
			outp[O + 2 * r] = vec4(p, kill ? 1.0 : 0.0, geo_finite(p.x + p.y) ? 0.0 : 1.0);
			outp[O + 2 * r + 1] = vec4(t, col.z);
		}
		float th_prev = a.x > 0.0 ? zc_column(a.x - 1.0, a.y, kn, nk, ax.rnd, th0).x : 0.0;
		float th_next = a.x < a.y ? zc_column(a.x + 1.0, a.y, kn, nk, ax.rnd, th0).x : 0.0;
		outp[O + 2 * int(a.z) + 2] = vec4(ax.en, zc_side(a.x, a.y, ax.rnd, th_prev, col.x, th_next));
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
        p['g_paths'] = 1           # a unit of its own: two samplers of different types on one unit stop the run
        p['g_prof'] = (S.rho0, S.R, S.Lc, S.L)
        p['g_prof2'] = (S.Rout, S.u0, S.rmin, S.th0)
        p['g_tabx'] = (S.t0, 1 / (S.t1 - S.t0), NB, NV)
        p['g_lift'] = LIFT

    def run(self, mode, rows, in_per=2, out_per=1, paths=None):
        """paths: a body's table, (ZONE_PL, ZONE_PQ + 1, 4) float32, as g_paths (mode 12)."""
        if paths is not None:
            self.paths = self.ctx.texture_array((ZONE_PQ + 1, ZONE_PL, 1), 4, dtype='f4', data=np.ascontiguousarray(paths, 'f4').tobytes())
            self.paths.filter = (moderngl.NEAREST, moderngl.NEAREST)
            self.paths.use(1)
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


# The checks off on a throat with a crease (h < R) until the bodies there are drawn right: the issue
CREASE_OFF = 'https://github.com/pomid0rko0/steam-frame-wromhole/issues/118'


# and the paths by a body's table, next to the largest turn the rays that turn before the crease take
CREASE_PATHS_OFF = 'https://github.com/pomid0rko0/steam-frame-wromhole/issues/145'


def crease_off(name, S, what, issue=CREASE_OFF):
    """True (and a SKIP line) where the throat has a crease: the check what is off (until issue)."""
    if S.th0 > 0:
        print(f'SKIP {name}: {what}  off on a throat with a crease until {issue}', flush=True)
    return S.th0 > 0


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
    derr = np.array([abs(np.arctan2(g[1], g[0] * (1 if el >= 0 else -1)) - alpha) for (el, alpha, s, phi), g in zip(cases, o)])
    stand_in = int((o[:, 3] - 2 * np.floor(o[:, 3] / 2) > 0.75).sum())
    nan = int((~np.isfinite(o[:, :3]).all(1)).sum())
    fails += not check(f'{name}: the same, a quarter of the search\'s rays made NaN', nan == 0 and stand_in == 0,
                       f'{nan} not a number, {stand_in} by the stand-in; direction then off by {np.nanmax(derr):.1e} rad at most (median {np.nanmedian(derr):.0e})')
    # a ball's surface
    if crease_off(name, S, 'a ball\'s vertices'):
        return fails
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
    nan = int((~(np.isfinite(o[0::2]).all(1) & np.isfinite(o[1::2, 0]))).sum())
    fails += not check(f'{name}: the same, a quarter of the search\'s rays made NaN', nan == 0 and stand_in == 0,
                       f'{nan} not a number, {stand_in} by the stand-in; direction then off by {np.nanmax(derr):.1e} rad at most (median {np.nanmedian(derr):.0e})')
    return fails


def path_checks(name, S, gpu, rng):
    """A body's table of the ways from an eye (zone_path_see): bodies about eyes as image_checks puts
    them, points along shot rays through each, every image up to the last drawn."""
    if crease_off(name, S, 'the paths by a body\'s table', CREASE_PATHS_OFF):
        return 0
    fails = 0
    places = eye_places(S)
    psi_max = np.pi * ZONE_IMAGES

    def far(s, y):
        return abs(y[0]) - (S.L + 30.0)
    far.terminal, far.direction = True, 1
    rows, cases, kinds = [], [], []
    bodies = 0
    while len(rows) < 1500:
        el = float(np.float32(eye_at(places, rng)))
        side = 1.0 if el >= 0 else -1.0
        # the body: before the eye (held, or at the eyes), across an end of the cylinder or of the
        # zone, anywhere in it or reaching into it; the toys' sizes (a ball's radius, 1.8 a cube's half)
        u = rng.uniform()
        if u < 0.35:
            lc = el + rng.uniform(-1.0, 1.0)
        elif u < 0.6:
            lc = rng.choice([-1, 1]) * rng.choice([S.Lc, S.L]) + rng.uniform(-0.3, 0.3)
        else:
            lc = rng.uniform(-(S.L + 0.6), S.L + 0.6)
        reach = float(rng.choice([0.04, 0.1, 0.2, 0.25, 0.35, 0.4, 1.8 * 0.1, 1.8 * 0.15, 1.8 * 0.3]))
        en, t = frame(rng)
        m = unit(rng.normal(size=3))
        C = np.r_[float(S.r(lc)) * m, float(S.w(lc))]
        f = gpu.run(13, [[*C, reach, psi_max, 0, 0]])[0].astype(float)
        nodes = [[el, *en, *f, i, k, 0, 0] for i in range(ZONE_PL) for k in range(ZONE_PQ)]
        tab = np.zeros((ZONE_PL, ZONE_PQ + 1, 4), 'f4')
        tab[:, :ZONE_PQ] = gpu.run(11, nodes, in_per=3).reshape(ZONE_PL, ZONE_PQ, 4)
        tab[0, ZONE_PQ] = f
        l0, l1 = lc - (1.1 * reach + 0.01), lc + (1.1 * reach + 0.01)     # the l the table holds (zone_path_frame)
        bodies += 1
        # points along rays from the eye that pass through the body's l
        brows, bcases = [], []
        for shot in range(12):
            kind = shot % 3
            alpha = launch_rmin(S, float(S.r(el)), rng) if kind == 2 else launch(rng, kind == 1)
            if alpha is None:
                alpha = launch(rng, False)
            sol = shoot(S, el, alpha, smax=IMAGE_S, events=[far], max_step=0.2)
            s = np.linspace(0.05, sol.t[-1], 6000)      # from 5 cm, as image_checks
            y = sol.sol(s)
            inb = np.nonzero((y[0] >= l0) & (y[0] <= l1) & (y[2] <= psi_max))[0]
            if len(inb) == 0:
                continue
            D = np.r_[side * np.cos(alpha), np.sin(alpha) * t]
            b = float(S.r(el)) * np.sin(alpha)
            for q in rng.choice(inb, min(6, len(inb)), replace=False):
                lp, vl, phi = y[:, q]
                jj, a, sg = image_of(phi)
                ti = sg * t
                brows.append([el, *en, lp, *(np.cos(a) * en + np.sin(a) * ti), *ti, a, jj, 0, 0, 0])
                # the way it comes in: dl/ds along d/dl, b / r toward growing angle (R^4)
                pn = np.cos(phi) * en + np.sin(phi) * t
                tau = np.cos(phi) * t - np.sin(phi) * en
                A = np.r_[vl * float(S.dr(lp)) * pn + b / float(S.r(lp)) * tau, vl * float(S.dw(lp))]
                bcases.append((D, s[q], jj, A))
        if not brows:
            continue
        o = gpu.run(12, brows, in_per=4, out_per=3, paths=tab)
        for r, c, d, g, ar in zip(brows, bcases, o[0::3], o[1::3], o[2::3]):
            rows.append(r)
            cases.append((*c, d, g, reach, lc, ar))
    derr = np.array([angle(d, D) for D, s, j, A, d, g, reach, lc, ar in cases])
    lerr = np.array([abs(g[0] - s) / (1e-3 + LENGTH_REL * s) for D, s, j, A, d, g, reach, lc, ar in cases])
    aerr = np.array([angle(ar, A) for D, s, j, A, d, g, reach, lc, ar in cases])
    js = np.array([c[2] for c in cases])
    near = np.array([c[1] for c in cases]) < 1.0
    fails += not check(f'{name}: the paths by a body\'s table (zone_path_see)', derr.max() <= PATH_DIRECTION and lerr.max() <= 1 and aerr.max() <= PATH_ARRIVE,
                       f'direction off by {derr.max():.1e} rad at most (median {np.median(derr):.0e}; nearer than 1 m '
                       f'{derr[near].max() if near.any() else 0:.1e}), length {lerr.max():.2f} of the limit, the way in off by {aerr.max():.1e} rad '
                       f'({len(rows)} points of {bodies} bodies, {near.sum()} nearer than 1 m, images 0 to {js.max()}: {(js >= 2).sum()} past the first turn)')
    for k in [k for k in np.argsort(-np.maximum(np.maximum(derr / PATH_DIRECTION, lerr), aerr / PATH_ARRIVE))
              if derr[k] > PATH_DIRECTION or lerr[k] > 1 or aerr[k] > PATH_ARRIVE][:8]:
        r, (D, s, j, A, d, g, reach, lc, ar) = rows[k], cases[k]
        print(f'    point {k}: eye l {r[0]!r}; body l {lc:.4f}, reach {reach}; point l {r[4]!r}, alpha {r[11]!r}, image {j}: '
              f'GPU direction {tuple(d)}, length {g[0]!r}; the shot ray\'s {tuple(D)}, {s!r} ({derr[k]:.1e} rad off, length {lerr[k]:.2f} of the limit, '
              f'the way in {aerr[k]:.1e} rad off)')
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
    app's throat, h > R, has none; CREASE_OFF: to go once they are drawn right)."""
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
ON_FACE = 2e-4                  # a share of a cube's half size: a vertex this near a face's plane is on it
ZC_PUSH = float(re.search(r'const float ZC_PUSH = ([\d.e-]+);', open(os.path.join(SHADERS, 'zone_cube.gdshaderinc')).read()).group(1))
COVER = 400                     # points at random on each face of a cube that its mesh must cover
# issue #147's cubes, on the app's throat (docs/issues/147 on the branch docs/issue-media, repro.gd's
# log): the axis 1e-4 rad off a corner, 1e-3 rad off a face's point, 1e-4 rad off a corner, through a
# corner. C, E1, E2, E3, the half size, the eye's direction from the centre
ISSUE_147 = (
    ((2.969605684, 0.238620833, 0.352848709, 1.871206522), (-0.035447560, 0.193725392, 0.167319223, -0.966032267),
     (-0.105392635, 0.931379139, 0.257130325, 0.235178977), (-0.088295490, -0.297786236, 0.944486499, 0.107110150), 0.25,
     (0.999947369, 0.009940772, 0.002540309)),
    ((2.955003500, -0.376517773, 0.355231017, -1.541054130), (0.118200965, 0.947049677, 0.020540997, 0.297831506),
     (-0.063462868, -0.289088637, 0.221506521, 0.929158270), (-0.108506903, 0.061425351, 0.967725158, -0.219000593), 0.3,
     (0.999943316, -0.010646766, 0.000235083)),
    ((2.970422268, 0.376555264, -0.186543465, -0.707098782), (0.125366583, -0.978970706, 0.020129848, 0.159669697),
     (-0.000038873, 0.158904359, 0.320144147, 0.933947086), (-0.062486708, 0.024717567, -0.945111692, 0.319763064), 0.3,
     (0.999962211, 0.008213704, 0.002850926)),
    ((2.980897903, 0.333923757, 0.052381247, 1.610111237), (-0.007974274, 0.001796874, 0.442342788, -0.896808863),
     (-0.104284145, 0.964974403, -0.217015311, -0.104180135), (-0.041899271, 0.237553492, 0.870018721, 0.429977298), 0.25,
     (0.999943137, 0.010663752, -0.000186108)))


def issue_cubes():
    """ISSUE_147 in zone_body's form."""
    return [(np.array(C), [np.array(E1), np.array(E2), np.array(E3)], size, unit(np.array(en)), None, None, True)
            for C, E1, E2, E3, size, en in ISSUE_147]


def mesh_triangles(cols, rws):
    """Renderer._zone_mesh's triangles, each as its three nodes (column, row): [T, 3, 2]."""
    i, j = np.meshgrid(np.arange(cols), np.arange(rws), indexing='ij')
    i, j = i.ravel(), j.ravel()
    a = np.stack([np.stack([i, j], -1), np.stack([i + 1, j], -1), np.stack([i, j + 1], -1)], 1)
    b = np.stack([np.stack([i, j + 1], -1), np.stack([i + 1, j], -1), np.stack([i + 1, j + 1], -1)], 1)
    return np.concatenate([a, b])


def cube_mesh_faults(S, C, E, size, en, x, A, T, kill, rng):
    """A cube's mesh (its nodes' box coordinates x [cols + 1, rows + 1, 3] in half sizes, alpha A,
    their half-surfaces' t, the killed ones; round the axis en) against the cube: the triangles with
    area in the picture (not all on one half-surface, not all killed) not all on one face (ON_FACE);
    and of COVER points at random on each face how many no triangle on that face holds. First in the
    face's own coordinates, exact but for the two columns of a knot: there the section at one azimuth
    twice, as each span's rows have it, two polylines inscribed in one curve, apart in the box but on
    one line in the picture. So a point none holds there is looked for again in (theta, alpha) round
    the axis, where those two columns meet on that line: a fault only if no triangle of its face is
    within DIRECTION of it there (the angle from the axis, and sin alpha times the azimuth): what is
    left between a face's outline and its chords. Returns the triangles across, the points uncovered,
    those found again, and how far at most from a triangle."""
    cols, rws = x.shape[0] - 1, x.shape[1] - 1
    TR = mesh_triangles(cols, rws)
    X = x[TR[..., 0], TR[..., 1]]
    Ts = T[TR[..., 0], TR[..., 1]]
    one = np.abs(Ts - Ts[:, :1]).max((1, 2)) < 1e-6
    fin = np.isfinite(X).all((1, 2))
    area = np.linalg.norm(np.cross(X[:, 1] - X[:, 0], X[:, 2] - X[:, 0]), axis=-1)
    live = ~one & ~kill[TR[..., 0], TR[..., 1]].all(1) & (~fin | (area >= 1e-9))
    on = np.stack([(np.abs(X[:, :, f // 2] - (1 if f % 2 else -1)) < ON_FACE).all(1) for f in range(6)], 1)
    across = int((live & (~fin | ~on.any(1))).sum())
    # (theta, alpha): the columns' azimuths in order, unwrapped
    a1 = unit(np.cross(en, [0, 0, 1.0] if abs(en[2]) < 0.9 else [1.0, 0, 0]))
    a2 = np.cross(en, a1)
    th = np.unwrap(np.arctan2(T[:, 0] @ a2, T[:, 0] @ a1))
    V = np.stack([np.broadcast_to(th[:, None], A.shape), A], -1)[TR[..., 0], TR[..., 1]]
    N = normal4(S, C)
    uncovered, again, far = 0, 0, 0.0
    for f in range(6):
        a = f // 2
        ix = [(a + 1) % 3, (a + 2) % 3]
        sel = live & fin & on[:, f]
        p = rng.uniform(-1, 1, (COVER, 2))
        held = in_triangles(X[sel][:, :, ix], p)
        for q in p[~held]:
            xq = np.zeros(3)
            xq[a] = 1 if f % 2 else -1
            xq[ix] = q
            n = unit(onto(S, C + size * (xq @ np.asarray(E)), N)[:3])
            tq = np.arctan2(n @ a2, n @ a1)
            tq += 2 * np.pi * np.round((th[0] - tq) / (2 * np.pi))
            aq = np.arccos(np.clip(n @ en, -1.0, 1.0))
            # the face's triangles there, the azimuth scaled to an angle at the point; the point the
            # nearest turn of its azimuth to each
            W = V[sel].copy()
            W[..., 0] = W[..., 0] - tq
            W[..., 0] -= 2 * np.pi * np.round(W[..., 0].mean(1, keepdims=True) / (2 * np.pi))
            W[..., 0] *= np.sin(aq)
            W[..., 1] -= aq
            d = triangles_distance(W)
            again += 1
            far = max(far, d)
            uncovered += d > DIRECTION
    return across, uncovered, again, far


def knot_sides(T0):
    """Each column's side of a knot (zc_side) from its half-surface's t [cols + 1, 3]: +1 the first
    of two on one (t the same to the bit), -1 the second; round the axis (the first and last t a
    hair apart) the last +1 and the first -1."""
    cols = len(T0) - 1
    same = np.all(T0[1:] == T0[:-1], -1)
    rnd = np.abs(T0[0] - T0[cols]).max() < 1e-5
    side = np.zeros(cols + 1)
    for c in range(cols + 1):
        if c < cols and same[c]:
            side[c] = 1.0
        elif c > 0 and same[c - 1]:
            side[c] = -1.0
        elif rnd and c in (0, cols):
            side[c] = 1.0 if c == cols else -1.0
    return side


def in_triangles(T2, p):
    """Which of the points p [n, 2] some triangle of T2 [m, 3, 2] holds."""
    v0, v1, v2 = T2[None, :, 1] - T2[None, :, 0], T2[None, :, 2] - T2[None, :, 0], p[:, None, :] - T2[None, :, 0]
    den = v0[..., 0] * v1[..., 1] - v0[..., 1] * v1[..., 0]
    with np.errstate(divide='ignore', invalid='ignore'):
        u = (v2[..., 0] * v1[..., 1] - v2[..., 1] * v1[..., 0]) / den
        w = (v0[..., 0] * v2[..., 1] - v0[..., 1] * v2[..., 0]) / den
        return ((u >= -1e-6) & (w >= -1e-6) & (u + w <= 1 + 1e-6)).any(1)


def triangles_distance(W):
    """The distance from the origin to the nearest of the triangles W [m, 3, 2] (0 inside one)."""
    if len(W) == 0:
        return np.inf
    if in_triangles(W, np.zeros((1, 2)))[0]:
        return 0.0
    P0, P1 = W, np.roll(W, -1, axis=1)
    e = P1 - P0
    s = np.clip(-(P0 * e).sum(-1) / np.maximum((e * e).sum(-1), 1e-300), 0.0, 1.0)
    return float(np.linalg.norm(P0 + s[..., None] * e, axis=-1).min())


def near_axis_cube(S, rng):
    """A cube in the zone and an eye's axis en through or next to its corner, edge or face (to
    within a hundredth of a radian), in zone_body's form."""
    size = rng.choice([0.15, 0.25, 0.3])
    lc = rng.uniform(-S.L - 0.3, S.L + 0.3)
    nc = unit(rng.normal(size=3))
    C = np.r_[float(S.r(lc)) * nc, float(S.w(lc))]
    dr, dw = float(S.dr(lc)), float(S.dw(lc))
    a1 = unit(np.cross(nc, rng.normal(size=3)))
    T = [np.r_[dr * nc, dw], np.r_[a1, 0.0], np.r_[np.cross(nc, a1), 0.0]]
    Q = np.linalg.qr(rng.normal(size=(3, 3)))[0]
    E = [sum(Q[i, j] * T[j] for j in range(3)) for i in range(3)]
    x = rng.uniform(-1, 1, 3)
    kind = rng.integers(3)
    k = rng.integers(3)
    if kind == 0:
        x = np.sign(x)
    elif kind == 1:
        x = np.sign(x)
        x[k] = rng.uniform(-1, 1)
    else:
        x[k] = np.sign(x[k])
    P = onto(S, C + size * (x @ np.array(E)), normal4(S, C))
    n = unit(unit(P[:3]) + rng.choice([0.0, 1e-4, 1e-3, 1e-2]) * rng.normal(size=3))
    en = n if rng.uniform() < 0.5 else -n
    t = rng.normal(size=3)
    t = unit(t - (t @ en) * en)
    return C, E, size, en, t, np.cross(en, t), True


def zone_mesh_checks(name, S, gpu, rng):
    """The zone bodies' meshes whole (balls: zone_ball_vertex; cubes: zone_cube.gdshaderinc's passes,
    mode 14), for eyes' axes through and beside them."""
    fails = 0
    for ball in (True, False):
        if not ball and crease_off(name, S, 'a cube\'s mesh in the zone'):
            continue
        bodies = []
        while len(bodies) < 30:
            b = zone_body(S, rng, ball, axis_share=0.4)
            if b is not None:
                bodies.append(b)
        near = 0 if ball else 30            # bodies[30:]: next to the axis's features
        bodies += [near_axis_cube(S, rng) for _ in range(near)]
        if not ball and name == 'the app':
            bodies += issue_cubes()
        for cols, rws in MESHES:
            if ball:
                rows = [[i / cols, j / rws, 0, 0, *en, size, *C] for C, E, size, en, t, m, axis in bodies
                        for i in range(cols + 1) for j in range(rws + 1)]
                o = gpu.run(9, rows, in_per=3, out_per=2).astype(float).reshape(len(bodies), cols + 1, rws + 1, 2, 4)
                o[..., 0, 2:] = 0.0
            else:
                rows = [[i, cols, rws, 0, *en, size, *C, *E[0], *E[1], *E[2]] for C, E, size, en, t, m, axis in bodies
                        for i in range(cols + 1)]
                o = gpu.run(14, rows, in_per=6, out_per=2 * (rws + 1) + 1).astype(float).reshape(len(bodies), cols + 1, 2 * (rws + 1) + 1, 4)
                axes, sides = o[:, :, -1, :3], o[:, :, -1, 3]
                o = o[:, :, :-1].reshape(len(bodies), cols + 1, rws + 1, 2, 4)
            worst, alpha_out, tip, across, uncovered, nans, faulty, turned, turn, again, far, marks = 0.0, 0, 0.0, 0, 0, 0, [], 0, 0.0, 0, 0.0, 0
            for k, (C, E, size, en, t0, m0, axis) in enumerate(bodies):
                L, A, T = o[k, :, :, 0, 0], o[k, :, :, 0, 1], o[k, :, :, 1, :3]
                if not ball:
                    # the mesh round its own axis (zc_axis: the eye's, or turned off a corner or an edge
                    # near it), the picture the cube turned so about the centre: by ZC_PUSH at most
                    ax = axes[k, 0]
                    a = angle(ax, en) * np.linalg.norm(C[:3])
                    if a > 3e-7:                     # beyond float32's rounding of the axis
                        turned += 1
                        turn = max(turn, a)
                    if a > 1.1 * ZC_PUSH:
                        faulty.append((k, np.inf, 0, 0))
                    en = ax
                kill, nan = o[k, :, :, 0, 2] > 0.5, o[k, :, :, 0, 3] > 0.5
                n = np.cos(A)[..., None] * en + np.sin(A)[..., None] * T
                P = np.concatenate([S.r(L)[..., None] * n, S.w(L)[..., None]], axis=-1)
                q = P - C
                E = np.array(E)
                sl = q @ E.T                                   # [cols + 1, rows + 1, 3]
                off = np.abs(np.linalg.norm(q, axis=-1) - size) if ball else np.abs(np.abs(sl).max(-1) - size)
                off = np.where(np.isfinite(off), off, np.inf)
                off = np.where(kill, 0.0, off)
                worst = max(worst, off.max())
                # a hair across the axis (alpha past 0 or pi): body.gdshaderinc draws on the axis,
                # where its image is on the ring
                alpha_out += int((((A < -1e-6) | (A > np.pi + 1e-6)) & ~kill).sum())
                if ball:
                    # off the axis, the first and last columns' sections are at the ball's tips
                    if np.linalg.norm(q[0, 0]) > 0 and not np.isclose(T[0, 0] @ T[-1, 0], 1.0):
                        for i in (0, cols):
                            tip = max(tip, np.linalg.norm(P[i] - P[i].mean(0), axis=-1).max() / size)
                    continue
                # a cube: every triangle on one face, every face covered
                a, u, ag, fa = cube_mesh_faults(S, C, E, size, en, sl / size, A, T, kill, rng)
                across += a
                uncovered += u
                again += ag
                far = max(far, fa)
                # a knot's two columns (one half-surface, its t to the bit; round the axis the last
                # and the first too) marked as zc_side's, no other
                mk = np.abs(knot_sides(T[:, 0]) - sides[k]).sum() > 0
                marks += mk
                nans += int(nan.sum())
                if a or u or mk or nan.any() or off.max() > CHORD:
                    faulty.append((k, off.max(), a, u))
            body = 'ball' if ball else 'cube'
            ok = worst <= CHORD and alpha_out == 0 and (tip <= 0.02 if ball else not faulty)
            what = (f'vertices off its surface by {worst:.1e} m at most, {alpha_out} out of the half-surface'
                    + (f'; the tips\' sections {tip:.3f} of the radius across at most' if ball else
                       f'; {across} triangles across an edge, of {COVER} points at random on each face {uncovered} on no triangle '
                       f'({again} not in its own coordinates, at a knot, and there in (theta, alpha) {far:.1e} rad from a triangle at most), {nans} nodes not a number, '
                       f'{marks} with a knot\'s columns marked wrong; '
                       f'{turned} built round an axis turned off a corner or an edge near it, the cube moved by up to {turn:.1e} m')
                    + f' ({len(bodies)} {body}s, {sum(1 for b in bodies if b[6])} about the axis'
                    + ('' if ball else f', {near} with the axis next to a corner, an edge or a face'
                       + (f', issue #147\'s {len(ISSUE_147)}' if name == 'the app' else '')) + ')')
            fails += not check(f'{name}: a {body}\'s mesh in the zone, {cols} by {rws} ({"zone_ball_vertex" if ball else "zone_cube.gdshaderinc"})', ok, what)
            for k, d, a, u in faulty[:5]:
                C, E, size, en = bodies[k][:4]
                print(f'    cube {k}: C {tuple(C)}, E {tuple(map(tuple, E))}, size {size!r}, en {tuple(en)}: a vertex {d:.2e} m off its surface, '
                      f'{a} triangles across an edge, {u} points on no triangle')
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


# ---------- the tail of the bodies' images, per pixel (zone_tail.gdshaderinc) ----------
TAIL_CASES = 160
TAIL_STEP = 2e-3             # m: the reference's samples along a ray where it may meet the body
TAIL_GRAZE = 2e-4            # m: a ray this near a body's surface at its deepest grazes it (either answer)
TAIL_POINT = 1e-3            # m: the way in, off the reference's (its length, and its point in R^4)


def tail_reference(S, el, alpha, en, t, out_f, psi_min):
    """The first way into a body (out_f(l, phi) > 0 outside, at arrays of points of the ray's plane)
    at a turn of psi_min or more along the ray from the eye at el launched alpha off the outward
    radial: DOP853 off the throat's cylinder (ref/geo.py's plane equations), on it the closed form
    (uniform in l and in phi), to |l| = L + 12 or out past it. Returns (s, l, phi) of the way in or
    None, and how deep the ray goes into the body there at most (or how near it comes, a miss: the
    least of out_f)."""
    b = float(S.r(abs(el))) * np.sin(alpha)
    side = 1.0 if el >= 0 else -1.0
    pieces = []                 # (s0, s1, f(s) -> (l, phi) arrays)
    y = np.array([el, side * np.cos(alpha), 0.0])
    s0 = 0.0
    for _ in range(3):
        if abs(y[0]) < S.Lc - 1e-12:
            # the cylinder: to its end the ray's l goes toward
            vl = y[1]
            if abs(vl) < 1e-12:
                return None, 1.0
            ln = np.sign(vl) * S.Lc
            s1 = s0 + (ln - y[0]) / vl
            l0, p0, a = y[0], y[2], s0
            pieces.append((s0, s1, lambda s, l0=l0, p0=p0, a=a, vl=vl: (l0 + vl * (s - a), p0 + b / S.rho0 ** 2 * (s - a))))
            y = np.array([ln, vl, p0 + b / S.rho0 ** 2 * (s1 - s0)])
            s0 = s1
            continue
        # off it: to the cylinder (entering it) or out of the zone's neighbourhood
        def into(s, yy):
            return abs(yy[0]) - S.Lc
        into.terminal, into.direction = True, -1
        def out(s, yy):
            return abs(yy[0]) - (S.L + 12)
        out.terminal, out.direction = True, 1
        sol = integrate.solve_ivp(lambda s, yy: plane_rhs(S, s, yy, b), (s0, s0 + 1000), y, method='DOP853',
                                  rtol=1e-11, atol=1e-12, events=[into, out] if S.Lc > 0 else [out],
                                  dense_output=True, max_step=0.05)
        pieces.append((s0, sol.t[-1], lambda s, sol=sol: (sol.sol(s)[0], sol.sol(s)[2])))
        if S.Lc > 0 and len(sol.t_events[0]):
            y = sol.y[:, -1].copy()
            y[0] = np.sign(y[0]) * S.Lc * (1 - 1e-12)
            s0 = sol.t[-1]
            continue
        break
    least = 1.0
    for s0, s1, f in pieces:
        if s1 <= s0:
            continue
        ss = np.linspace(s0, s1, int((s1 - s0) / TAIL_STEP) + 2)
        l, ph = f(ss)
        g = out_f(l, ph)
        ok = ph >= psi_min
        if ok.any():
            least = min(least, g[ok].min())
        ins = g <= 0
        for i in np.nonzero(~ins[:-1] & ins[1:])[0]:
            a, c = ss[i], ss[i + 1]
            for _ in range(50):
                m = 0.5 * (a + c)
                lm, pm = f(np.array([m]))
                if out_f(lm, pm)[0] <= 0:
                    c = m
                else:
                    a = m
            lm, pm = f(np.array([c]))
            if pm[0] >= psi_min:
                j = i + 1
                while j < len(g) and g[j] <= 0:
                    j += 1
                return (c, lm[0], pm[0]), g[i + 1:j].min()
    return None, least


def tail_checks(name, S, gpu, rng):
    """The tail per pixel (zone_tail.gdshaderinc, mode 15): rays from eyes in the cylinder, on the
    fillets and out, through the throat (inward, or from the cylinder either way along it) aimed at
    an image of a ball or a cube past psi_min (the image's ray, by ref/geo.py's sweeps, then moved
    across it by up to three of the body's widths there), the body in the cylinder, on the far fillet
    or across the far zone's edge; psi_min Renderer.ZONE_IMAGES pi, and 2 pi and 6 pi (more of the
    method on shorter rays). Everything as the GPU gets it (float32), and the reference's ray that
    one; a ray float32 can't tell from r_min's left out. Hit or miss as the reference's (where the
    ray goes deeper than TAIL_GRAZE into the body, or stays further off it), and a hit's way in
    within TAIL_POINT of the reference's for a launch within ALPHA_TOL (a hundredth of a pixel: next
    to the limit the turn grows so fast with the launch that float32's last digit of it, a
    sixteen-thousandth of a pixel, moves the way in by millimetres): its point and its length."""
    if S.Lc <= 0:
        print(f'SKIP {name}: tail  no cylinder (h <= R): the tail is no wider than the meshes leave', flush=True)
        return 0
    rows, refs = [], []
    t0 = time.time()
    tries = 0
    while len(rows) < TAIL_CASES and tries < 50 * TAIL_CASES:
        tries += 1
        ball = rng.uniform() < 0.5
        psi_min = rng.choice([2 * np.pi, 6 * np.pi, ZONE_IMAGES * np.pi])
        w = rng.integers(3)
        side = rng.choice([-1.0, 1.0])
        el = side * (rng.uniform(0, S.Lc - 0.05) if w == 0 else (rng.uniform(S.Lc + 0.01, S.L) if w == 1 else rng.uniform(S.L, S.L + 6)))
        le = abs(el)
        outward = le < S.Lc and rng.uniform() < 0.3
        dl = side if outward else -side
        size = rng.uniform(0.08, 0.4) if ball else rng.uniform(0.08, 0.3)
        wb = rng.integers(3)
        if wb == 0:
            far = dl * S.Lc
            lb = rng.uniform(min(el, far), max(el, far)) if le < S.Lc else rng.uniform(-S.Lc, S.Lc)
        elif wb == 1:
            lb = dl * rng.uniform(S.Lc, S.L)
        else:
            lb = dl * (S.L + rng.uniform(-size, size))
        target = psi_min + rng.uniform(0, 4 * np.pi)
        def turn(bb):
            return abs(S.sweep(bb, el)[0] - S.sweep(bb, lb)[0])
        if turn(S.rho0 * (1 - 1e-12)) < target:
            continue
        b0 = optimize.brentq(lambda bb: turn(bb) - target, 1e-9, S.rho0 * (1 - 1e-12), xtol=1e-15, rtol=1e-15)
        en, t = frame(rng)
        m = np.cross(en, t)
        r_c = float(S.r(lb))
        beta = rng.uniform(-1.0, 1.0) * size / r_c
        ac = target % (2 * np.pi)
        nc = np.cos(beta) * (np.cos(ac) * en + np.sin(ac) * t) + np.sin(beta) * m
        C = np.r_[r_c * nc, float(S.w(lb))]
        dr, dw = float(S.dr(lb)), float(S.dw(lb))
        a1 = unit(np.cross(nc, rng.normal(size=3)))
        T = [np.r_[dr * nc, dw], np.r_[a1, 0.0], np.r_[np.cross(nc, a1), 0.0]]
        Q = np.linalg.qr(rng.normal(size=(3, 3)))[0]
        E = [sum(Q[i, j] * T[j] for j in range(3)) for i in range(3)]
        k = np.sqrt(S.rho0 ** 2 - b0 ** 2)
        b = min(b0 + rng.uniform(-1, 1) * 3 * size / max(target, 1) * k * k / S.rho0, S.rho0 * (1 - 1e-9))
        re = float(S.r(le))
        if b >= re:
            continue
        ab = np.arcsin(b / re)
        alpha = ab if outward else np.pi - ab
        f32 = lambda v: np.asarray(v, np.float32).astype(float)
        D = f32(np.r_[side * np.cos(alpha), np.sin(alpha) * t])
        en, el, C, E, size = f32(en), float(np.float32(el)), f32(C), [f32(e) for e in E], float(np.float32(size))
        ca, sa = side * D[0] / np.linalg.norm(D), np.linalg.norm(D[1:]) / np.linalg.norm(D)
        t = D[1:] / np.linalg.norm(D[1:])
        if abs(float(S.r(abs(el))) * sa - S.rho0) < 1e-6 * S.rho0:
            continue
        N = normal4(S, C)
        def out_f(l, ph, C=C, E=E, N=N, size=size, ball=ball, en=en, t=t):
            P = np.c_[S.r(l)[:, None] * (np.cos(ph)[:, None] * en + np.sin(ph)[:, None] * t), S.w(l)] - C
            if ball:
                return (P * P).sum(1) - size * size
            return np.max(np.abs(np.stack([P @ e for e in E + [N]], 1)), 1) - size
        alpha = np.arctan2(sa, ca)
        ref, depth = tail_reference(S, el, alpha, en, t, out_f, psi_min)
        # and the launches ALPHA_TOL either side
        near = [tail_reference(S, el, alpha + d, en, t, out_f, psi_min)[0] for d in (-ALPHA_TOL, ALPHA_TOL)]
        rows.append(np.r_[el, en, D, C, E[0], E[1], size, 0.0 if ball else 1.0, psi_min, 0.0])
        refs.append((ref, abs(depth) / (2 * size) if ball else abs(depth), ball, C, near))
    out = gpu.run(15, np.array(rows), in_per=6, out_per=3).reshape(-1, 3, 4)
    wrong, graze, hits, worst_len, worst_p, onf = [], 0, 0, 0.0, 0.0, 0
    for o, (ref, depth, ball, C, near), row in zip(out, refs, rows):
        hit = o[0, 0] > 0.5
        if hit != (ref is not None):
            if depth < TAIL_GRAZE or any((r is not None) == hit for r in near):
                graze += 1
            else:
                wrong.append(f'{"ball" if ball else "cube"} eye l {row[0]:.3f} body l {l_of(S, C):.3f}: '
                             f'{"met" if hit else "missed"}, the reference\'s ray {"missed" if hit else "met"} it')
            continue
        if not hit:
            continue
        hits += 1
        tt = row[5:8] / np.linalg.norm(row[5:8])
        pts = [(r[0], np.r_[float(S.r(r[1])) * (np.cos(r[2]) * row[1:4] + np.sin(r[2]) * tt), float(S.w(r[1]))])
               for r in (near[0], ref, near[1]) if r is not None]
        # the nearest point of the line through the three ways in (by launch) to the GPU's, and its length
        best = (np.inf, np.inf)
        for (s0, p0), (s1, p1) in zip(pts, pts[1:] or pts):
            d = p1 - p0
            u = float(np.clip((o[1] - p0) @ d / max(d @ d, 1e-30), 0.0, 1.0))
            dp = np.linalg.norm(o[1] - (p0 + u * d))
            if dp < best[0]:
                best = (dp, abs(o[0, 3] - (s0 + u * (s1 - s0))))
        worst_p = max(worst_p, best[0])
        worst_len = max(worst_len, best[1])
        onf += o[2, 0] > 0.5
    fails = 0
    fails += not check(f'{name}: the tail, which rays meet a body past psi_min (zone_tail.gdshaderinc)', not wrong,
                       f'{len(rows)} rays, {hits} meet one ({onf} on the far fillet or out), {graze} grazing or ill-posed; '
                       f'{time.time() - t0:.0f} s' + ''.join('\n    ' + w for w in wrong[:10]))
    fails += not check(f'{name}: the tail, the way in', worst_len <= TAIL_POINT and worst_p <= TAIL_POINT,
                       f'off the reference\'s for a launch within {ALPHA_TOL:.0e} rad: its point by {worst_p:.1e} m, '
                       f'its length by {worst_len:.1e} m at most (limit {TAIL_POINT:.0e})')
    return fails


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


CHECKS = ('numbers', 'profile', 'images', 'paths', 'exit', 'zone', 'tail', 'eye')
# the pieces run apart: (the check that asks for it, its name), the longest first
PIECES = (('zone', 'mesh'), ('zone', 'zone'), ('exit', 'exit'), ('paths', 'paths'), ('tail', 'tail'),
          ('profile', 'profile'), ('images', 'images'), ('eye', 'eye'))


def piece_checks(index, piece):
    """PROFILES' index-th throat's piece of the checks, on a GPU context of its own, with random draws
    of its own (seeded by the throat and the piece)."""
    ctx = moderngl.create_standalone_context(backend='egl', require=430)
    rng = np.random.default_rng([index, [p for _, p in PIECES].index(piece)])
    name, prof = list(PROFILES.items())[index]
    S = Space(*prof)
    S.t0, S.t1 = S.t_of_b(0.0), S.t_of_b(S.Rout)
    gpu = Gpu(ctx, S)
    if piece == 'profile':
        return profile_checks(name, S, gpu, Gpu(ctx, S, NAN_SRC), rng)
    if piece == 'images':
        return image_checks(name, S, gpu, Gpu(ctx, S, NAN_SRC), rng)
    if piece == 'paths':
        return path_checks(name, S, gpu, rng)
    if piece == 'exit':
        # the table's on the same rays
        same = copy.deepcopy(rng)
        return exit_checks(name, S, gpu, rng) + exit_checks(name, S, gpu, same, table=True)
    if piece == 'zone':
        return zone_checks(name, S, gpu, rng)
    if piece == 'mesh':
        return zone_mesh_checks(name, S, gpu, rng)
    if piece == 'tail':
        return tail_checks(name, S, gpu, rng)
    return eye_checks(S, gpu, rng)


def main(checks=CHECKS):
    """The numbers here, then each throat's each piece in a process of its own (this script with
    --piece), as many at once as there are cores, the longest first; their output kept in files and
    printed throat by throat, piece by piece in the checks' order."""
    fails = numbers_check() if 'numbers' in checks else 0
    asked = {piece for check, piece in PIECES if check in checks}
    runs = [(i, piece) for _, piece in PIECES for i, name in enumerate(PROFILES)
            if piece in asked and (piece != 'eye' or name == 'the app')]
    width = max(1, len(os.sched_getaffinity(0)))
    procs, waiting, took = {}, list(runs), {}
    def start():
        i, piece = waiting.pop(0)
        took[i, piece] = time.monotonic()
        out = tempfile.TemporaryFile('w+')
        procs[i, piece] = (subprocess.Popen([sys.executable, __file__, '--piece', str(i), piece],
                                            stdout=out, stderr=subprocess.STDOUT, text=True), out)
    while waiting and len(procs) < width:
        start()
    done = {}
    while len(done) < len(runs):
        for key, (proc, out) in list(procs.items()):
            if key not in done and proc.poll() is not None:
                done[key] = proc
                took[key] = time.monotonic() - took[key]
                if waiting:
                    start()
        if len(done) < len(runs):
            time.sleep(0.2)
    order = ('profile', 'images', 'paths', 'exit', 'zone', 'mesh', 'eye')
    for i, name in enumerate(PROFILES):
        for piece in order:
            if (i, piece) not in procs:
                continue
            proc, out = procs[i, piece]
            out.seek(0)
            text = out.read()
            last = re.findall(r'^FAILURES: (\d+)$', text, re.M)
            print(re.sub(r'^FAILURES: \d+\n?', '', text, flags=re.M), end='', flush=True)
            if proc.returncode not in (0, 1) or not last:
                print(f'FAIL {name}, {piece}: its checks ended with status {proc.returncode}', flush=True)
                fails += 1
            else:
                fails += int(last[-1])
    print(f'pieces on {width} cores, seconds each: ' + ', '.join(
        f'{list(PROFILES)[i]} {piece} {took[i, piece]:.0f}' for i, piece in runs))
    print(f'FAILURES: {fails}')
    return fails


if __name__ == '__main__':
    if sys.argv[1:2] == ['--piece']:
        f = int(piece_checks(int(sys.argv[2]), sys.argv[3]))
        print(f'FAILURES: {f}')
        sys.exit(1 if f else 0)
    sys.exit(1 if main(sys.argv[1:] or CHECKS) else 0)
