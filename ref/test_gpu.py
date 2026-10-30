"""The shaders' geometry (godot/shaders/geo.gdshaderinc) on a GPU, float32, against float64:
headless (EGL), as a compute shader, with the table and series built as WormholeSpace.sweep_table
builds them (ref/geo.py), on three throats: the app's, h = R, a crease (h < R).
  sweep and length from a ray's origin: against quadrature of the integrals (ref/geo.py, exact);
  where the sweep reaches a value (the floor's hit): the sweep at the GPU's l against the value;
  which way the eye sees a point (geo_see, the bodies' vertices): rays shot by RK4 from an eye to a
    point, the GPU given the point must find that ray (angle) and its length;
  the eye (geo_eye): against the head moved along its geodesic by RK4, the frame carried along;
  a ball's surface (geo_onto, the chord): every vertex at chord distance radius, on the space.
Exit status 1 on any failure.
   python3 ref/test_gpu.py"""
import os
import sys
import in_box  # noqa: F401 (first: on the Frame, into tools/box.sh's container)
import numpy as np
import moderngl
from geo import Space, shoot, app_profile

HERE = os.path.dirname(os.path.abspath(__file__))
INC = open(os.path.join(HERE, '..', 'godot', 'shaders', 'geo.gdshaderinc')).read()
NB, NV = 256, 64            # WormholeSpace.SWEEP_NB, SWEEP_NV
PROFILES = {'the app': app_profile(), 'h = R': (3.0, 1.0, 1.0), 'crease, h < R': (3.0, 0.4, 1.0)}
# the limits: radians of sweep (with a share of the sweep for long rays round the photon sphere),
# radians of direction (the headset's pixel is about 1e-3: half a pixel 5e-4), metres; a ray's length
# only orders bodies in depth, and next to the photon sphere it is ill-posed (not checked there)
SWEEP_ABS, SWEEP_REL = 5e-5, 1e-5
INVERSE = 5e-4
DIRECTION = 5e-4
LENGTH_REL = 2e-3
EYE_POS, EYE_AXES = 2e-5, 3e-4
CHORD = 5e-5

SRC = '''#version 430
layout(local_size_x=64) in;
uniform vec4 g_prof; uniform vec4 g_prof2; uniform vec4 g_tabx; uniform sampler2D g_tab; uniform vec4 g_poly[9];
uniform float head_l; uniform vec3 head_n; uniform vec4 head_f[3]; uniform vec3 head_pos;
uniform vec3 vb0; uniform vec3 vb1; uniform vec3 vb2;
layout(std430, binding=0) buffer In { vec4 inp[]; };
layout(std430, binding=1) buffer Out { vec4 outp[]; };
uniform int mode;
''' + INC + '''
void main() {
	uint i = gl_GlobalInvocationID.x;
	vec4 a = inp[2 * i], c = inp[2 * i + 1];
	if (mode == 0) {            // a = (b, |l|): (psi, len) from the origin
		float sig = geo_sigma(a.x - g_prof.x);
		outp[i] = vec4(geo_from_origin(a.x, sig, a.y, geo_r(a.y) - a.x), 0.0, 0.0);
	} else if (mode == 1) {     // a = (b, psi): |l|
		outp[i] = vec4(geo_l_at(a.x, geo_sigma(a.x - g_prof.x), a.y), 0.0, 0.0, 0.0);
	} else if (mode == 2) {     // a = (eye l, n), c = (point l, n): (direction's radial, tangential, len)
		float len; vec4 arr;
		vec4 d = geo_see(a.x, a.yzw, c.x, c.yzw, len, arr);
		outp[i] = vec4(d.x, length(d.yzw), len, 0.0);
	} else if (mode == 3) {     // a = the eye's place in the room: (l, n), then ex, ey, ez
		mat4 iv = mat4(vec4(vb0, 0.0), vec4(vb1, 0.0), vec4(vb2, 0.0), vec4(a.xyz, 1.0));
		float el; vec3 en; vec4 ex, ey, ez;
		geo_eye(iv, vec3(0.0), el, en, ex, ey, ez);
		outp[4 * i] = vec4(el, en); outp[4 * i + 1] = ex; outp[4 * i + 2] = ey; outp[4 * i + 3] = ez;
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
		outp[i] = vec4(length(P - a), geo_sdf(length(P.xyz), P.w).x, 0.0, 0.0);
	}
}'''


class Gpu:
    def __init__(self, ctx, S):
        self.ctx = ctx
        self.prog = ctx.compute_shader(SRC)
        tab = S.build_table(NB, NV, 4)
        poly = S.build_poly()
        self.tex = ctx.texture((NB, NV), 2, dtype='f4', data=np.ascontiguousarray(tab.transpose(1, 0, 2)).astype('f4').tobytes())
        self.tex.filter = (moderngl.LINEAR, moderngl.LINEAR)
        self.tex.repeat_x = self.tex.repeat_y = False
        self.tex.use(0)
        p = self.prog
        p['g_tab'] = 0
        p['g_prof'] = (S.rho0, S.R, S.Lc, S.L)
        p['g_prof2'] = (S.Rout, S.u0, S.rmin, S.th0)
        p['g_tabx'] = (S.t0, 1 / (S.t1 - S.t0), NB, NV)
        p['g_poly'].write(poly.astype('f4').tobytes())

    def run(self, mode, rows, out_per=1):
        rows = np.asarray(rows, 'f4').reshape(-1, 8)
        n = len(rows)
        rows = np.vstack([rows, np.zeros(((-n) % 64, 8), 'f4')])
        bi = self.ctx.buffer(rows.tobytes())
        bo = self.ctx.buffer(reserve=len(rows) * 16 * out_per)
        bi.bind_to_storage_buffer(0)
        bo.bind_to_storage_buffer(1)
        self.prog['mode'] = mode
        self.prog.run(len(rows) // 64)
        return np.frombuffer(bo.read(), 'f4').reshape(-1, 4)[:n * out_per]


def unit(v):
    return v / np.linalg.norm(v)


def check(name, ok, detail):
    print(('PASS ' if ok else 'FAIL ') + name + '  ' + detail)
    return ok


def profile_checks(name, S, gpu, rng):
    fails = 0
    # sweep and length from the origin
    rows, ref = [], []
    while len(rows) < 1500:
        b = rng.uniform(0, S.Rout * 1.3)
        lo = 0.0 if b < S.rmin else S.l_turn(b)
        l = lo + rng.uniform(0, 1) ** 2 * 12
        e = S.sweep(b, l)
        if not np.all(np.isfinite(e)) or e[0] > 2 * np.pi:      # past half a turn the floor stops any ray
            continue
        rows.append([b, l, 0, 0, 0, 0, 0, 0]); ref.append(e)
    o = gpu.run(0, rows)[:, :2]; ref = np.array(ref)
    err = np.abs(o[:, 0] - ref[:, 0]) / (SWEEP_ABS + SWEEP_REL * np.abs(ref[:, 0]))
    lerr = np.abs(o[:, 1] - ref[:, 1]) / (1e-3 + LENGTH_REL * ref[:, 1])
    fails += not check(f'{name}: sweep from the origin', err.max() <= 1, f'worst {err.max():.2f} of the limit, length {lerr.max():.2f} (1500 rays)')
    # where the sweep reaches a value
    rows, want = [], []
    while len(rows) < 1000:
        b = rng.uniform(0, S.Rout * 1.2); psi = rng.uniform(0, 2.5)
        L = S.l_at(b, psi)
        if not np.isfinite(L):
            continue
        rows.append([b, psi, 0, 0, 0, 0, 0, 0]); want.append(psi)
    o = gpu.run(1, rows)[:, 0]
    err = [abs(S.sweep(r[0], max(l, S.l_turn(r[0]) if r[0] >= S.rmin else l))[0] - w) for r, l, w in zip(rows, o, want)]
    fails += not check(f'{name}: where the sweep reaches a value', max(err) <= INVERSE, f'sweep at the GPU l off by {max(err):.1e} rad at most (1000 rays)')
    # which way the eye sees a point
    rows, cases = [], []
    # where the eye stands: on a cylinder if there is one; without one, off l = 0, the photon sphere's
    # point or the crease (no eye stands within a hair of either: see docs/geometry.md, «Точность»)
    places = [0.0, 0.5, S.Lc - 0.1] if S.Lc > 0 else [0.3, -0.4]
    places += [0.5 * (S.Lc + S.L), S.L - 0.05, S.L + 0.5, S.L + 5, -0.5 * (S.Lc + S.L), -(S.L + 1), 25.0]
    while len(rows) < 1200:
        el = rng.choice(places) + rng.uniform(-0.1, 0.1)
        alpha = rng.uniform(0, np.pi)
        s = rng.choice([rng.uniform(0.05, 0.6), rng.uniform(0.6, 4), rng.uniform(4, 30)])
        sol = shoot(S, el, alpha, smax=s)
        lp, vl, phi = sol.y[:, -1]
        if phi > 0.93 * np.pi:
            continue
        en = unit(rng.normal(size=3)); t = rng.normal(size=3); t = unit(t - np.dot(t, en) * en)
        rows.append([el, *en, lp, *(np.cos(phi) * en + np.sin(phi) * t)]); cases.append((el, alpha, s, phi))
    o = gpu.run(2, rows)
    derr, lerr = [], []
    for (el, alpha, s, phi), g in zip(cases, o):
        derr.append(abs(np.arctan2(g[1], g[0] * (1 if el >= 0 else -1)) - alpha))
        b = float(S.r(el)) * np.sin(alpha)
        if abs(b - S.rmin) > 5e-2:          # not round the photon sphere, where length is ill-posed
            lerr.append(abs(g[2] - s) / (1e-3 + LENGTH_REL * s))
    fails += not check(f'{name}: which way the eye sees a point', max(derr) <= DIRECTION and max(lerr) <= 1,
                       f'direction off by {max(derr):.1e} rad at most (median {np.median(derr):.0e}), length {max(lerr):.2f} of the limit (1200 points)')
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


ctx = moderngl.create_standalone_context(backend='egl', require=430)
rng = np.random.default_rng(1)
fails = 0
for name, prof in PROFILES.items():
    S = Space(*prof)
    S.t0, S.t1 = S.t_of_b(0.0), S.t_of_b(S.Rout)
    gpu = Gpu(ctx, S)
    fails += profile_checks(name, S, gpu, rng)
    if name == 'the app':
        fails += eye_checks(S, gpu, rng)
print(f'FAILURES: {fails}')
sys.exit(1 if fails else 0)
