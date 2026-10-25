"""Render the GLSL core headless (EGL/llvmpipe) and compare its per-pixel
geometry against an independent float64 reference that integrates every
curved ray with brute-force RK4 (no symmetry reduction)."""
import sys, os
import numpy as np
import moderngl
from PIL import Image
from wh import Wormhole

HERE = os.path.dirname(os.path.abspath(__file__))
CORE = open(os.path.join(HERE, '..', 'godot', 'shaders', 'wormhole_core.gdshaderinc')).read()
PROF = tuple(float(v) for v in os.environ.get('WH_PROFILE', '3,5,1').split(','))   # rho0, h, fillet in metres
W = Wormhole(*PROF)
import json
SCENE = json.load(open(os.path.join(HERE, '..', 'godot', 'scene.json')))
MAXB = 12


def test_balls():
    """Balls placed in every kind of region: flat A, straddling the shell edge, fillet, throat, flat B.
    Centre as a point of R^4 (r n, w(l)) and radius."""
    def at(l, n):
        n = np.asarray(n, float); n /= np.linalg.norm(n)
        return np.r_[W.r(np.array(l)) * n, W.w(np.array(l))]
    return [
        (at(W.L + 4.6, [1.0, -0.15, 0.06]), 0.35, (0.9, 0.2, 0.2)),            # flat A, in front of the camera
        (at(W.L - 0.1, [1.0, 0.25, 0.08]), 0.40, (0.2, 0.8, 0.3)),             # straddles the shell edge
        (at(0.5 * (W.Lc + W.L), [1.0, -0.35, 0.12]), 0.30, (0.2, 0.4, 0.95)),  # in the fillet
        (at(0.3 * W.Lc if W.Lc > 0 else 0.0, [1.0, 0.3, 0.15]), 0.30, (0.95, 0.85, 0.2)),  # in the throat
        (at(-(W.L + 3.0), [1.0, 0.3, 0.05]), 0.35, (0.8, 0.3, 0.9)),           # flat B
    ]


BALLS = test_balls() if os.environ.get('WH_BALLS', '1') == '1' else []
MAXC = 6


def test_cubes():
    """Cubes (4D boxes cut by the space) in every kind of region, turned against the floor.
    Centre as a point of R^4, four orthonormal axes of R^4 (three tangent at the centre, then the
    normal of the space) and the half size. The tangent frame comes from finite differences of
    the embedding, independent of the shader's formulas."""
    def cube(l, n, half, yaw, tilt, col):
        n = np.asarray(n, float); n /= np.linalg.norm(n)
        el = (W.embed(np.array(l + 1e-6), n) - W.embed(np.array(l - 1e-6), n)); el /= np.linalg.norm(el)
        tz = np.array([0, 0, 1.0]) - n * n[2]; tz /= np.linalg.norm(tz)
        ty = np.cross(tz, n)
        T = np.array([el, np.r_[ty, 0.0], np.r_[tz, 0.0]])          # tangent basis in R^4
        cy, sy, ct, st = np.cos(yaw), np.sin(yaw), np.cos(tilt), np.sin(tilt)
        Rm = np.array([[cy, -sy, 0], [sy, cy, 0], [0, 0, 1]]) @ np.array([[1, 0, 0], [0, ct, -st], [0, st, ct]])
        ax = (Rm.T @ T)                                               # three body axes (rows)
        nrm = np.linalg.svd(ax)[2][-1]                                # orthogonal to all three
        return (W.embed(np.array(l), n), np.vstack([ax, nrm]), half, col)
    return [
        cube(W.L + 3.0, [1.0, 0.35, 0.1], 0.35, 0.4, 0.3, (0.9, 0.9, 0.3)),          # flat A
        cube(W.L - 0.05, [1.0, -0.3, 0.1], 0.40, -0.3, 0.2, (0.3, 0.8, 0.9)),        # straddles the shell edge
        cube(0.5 * (W.Lc + W.L), [1.0, 0.4, 0.15], 0.30, 0.7, -0.4, (0.95, 0.5, 0.2)),  # in the fillet
        cube(0.4 * W.Lc if W.Lc > 0 else 0.0, [1.0, -0.3, 0.1], 0.30, 0.2, 0.5, (0.4, 0.95, 0.4)),  # in the throat
        cube(-(W.L + 3.5), [1.0, -0.35, 0.08], 0.35, -0.5, 0.25, (0.9, 0.4, 0.6)),   # flat B
    ]


# the cubes come with the movable balls (the shader with balls draws both)
CUBES = test_cubes() if BALLS and os.environ.get('WH_CUBES', '1') == '1' else []
# the fillet polynomials from a table, as Godot's shader without balls does (WH_TABLE=0: worked out
# per ray, as the shader with balls and the web preview do)
TABLE = os.environ.get('WH_TABLE', '0' if BALLS else '1') == '1'

FRAG = """#version 400
""" + ("" if BALLS else "#define WH_NO_BALLS\n") + ("#define WH_TABLE\nuniform sampler2D wh_tab;\nuniform vec4 wh_tabLo;\n"
                                                    "uniform vec4 wh_tabInv;\nuniform vec4 wh_tabReg;\n" if TABLE else "") + """
uniform float wh_rho0;
uniform float wh_h;
uniform float wh_fillet;
uniform vec4 wh_sph[6];
uniform vec4 wh_pil[4];
uniform vec4 wh_box[4];
uniform vec4 wh_ball[12];
uniform vec4 wh_ballCol[12];
uniform int wh_nBall;
uniform vec4 wh_cube[6];
uniform vec4 wh_cubeE[30];
uniform vec4 wh_cubeCol[6];
uniform int wh_nCube;
uniform vec4 wh_bound[4];
uniform float wh_pix;
uniform float uL0;
uniform vec3 uN0;
uniform vec4 uF;
uniform vec4 uRt;
uniform vec4 uUp;
uniform vec4 uTan;   // tan of left, right, down, up half-angles
uniform int uDebug;
uniform vec2 uSize;
in vec2 vUV;
out vec4 frag;
""" + CORE + """
void main() {
    vec2 uv = gl_FragCoord.xy / uSize;
    vec3 dl = normalize(vec3(mix(-uTan.x, uTan.y, uv.x), mix(-uTan.z, uTan.w, uv.y), 1.0));
    vec4 V = dl.x * uRt + dl.y * uUp + dl.z * uF;
    vec4 dbg;
    vec3 col = wh_render(uL0, uN0, V.x, V.yzw, dbg);
    frag = uDebug == 1 ? dbg : vec4(pow(clamp(col, 0.0, 1.0), vec3(1.0 / 2.2)), 1.0);
}
"""
VERT = """#version 400
in vec2 p; out vec2 vUV;
void main() { vUV = p * 0.5 + 0.5; gl_Position = vec4(p, 0.0, 1.0); }
"""


def frame_from_chart(side, x, fwd, up):
    """Eye in a flat region given in chart coordinates -> manifold state + frame."""
    M = np.array([1.0, 1, 1]) if side > 0 else np.array([-1.0, 1, 1])
    r = np.linalg.norm(x)
    n = M * x / r
    l0 = side * (r - W.Rout + W.L)
    rt = np.cross(fwd, up)

    def vec(d):
        md = M * d
        rad = md @ n
        return np.r_[side * rad, md - rad * n]
    return l0, n, vec(fwd), vec(rt), vec(up)


def render(ctx, state, size, tan, debug):
    l0, n0, F, Rt, Up = state
    prog = ctx.program(vertex_shader=VERT, fragment_shader=FRAG)
    vbo = ctx.buffer(np.array([-1, -1, 1, -1, -1, 1, 1, 1], 'f4').tobytes())
    vao = ctx.vertex_array(prog, [(vbo, '2f', 'p')])
    balls = [tuple(c) for c, _, _ in BALLS] + [(0.0, 0.0, 0.0, 0.0)] * (MAXB - len(BALLS))
    bcol = [tuple(col) + (rad,) for _, rad, col in BALLS] + [(0.0, 0.0, 0.0, 0.0)] * (MAXB - len(BALLS))
    # per cube: the four axes over the half size, then dot(centre, axis) for the four (main.set_objects)
    cpos = [tuple(c) for c, _, _, _ in CUBES] + [(0.0, 0.0, 0.0, 0.0)] * (MAXC - len(CUBES))
    cax = []
    for c, ax, half, _ in CUBES:
        cax += [tuple(a / half) for a in ax] + [tuple(float(np.dot(c, a / half)) for a in ax)]
    cax += [(0.0, 0.0, 0.0, 0.0)] * (5 * MAXC - len(cax))
    ccol = [tuple(col) + (half,) for _, _, half, col in CUBES] + [(0.0, 0.0, 0.0, 0.0)] * (MAXC - len(CUBES))
    # the bounding spheres of each universe's balls and of its cubes, as main.set_objects makes them
    bound = []
    for objs in ([(np.asarray(c), rad) for c, rad, _ in BALLS], [(np.asarray(c), 2.0 * half) for c, _, half, _ in CUBES]):
        for side in (1.0, -1.0):
            pts = [(c[:3], rr) for c, rr in objs if abs(c[3] - side * PROF[1]) < rr]
            if not pts:
                bound.append((0.0, 0.0, 0.0, -1.0))
                continue
            P = np.array([p for p, _ in pts])
            mid = 0.5 * (P.min(0) + P.max(0))
            bound.append(tuple(mid) + (max(np.linalg.norm(p - mid) + rr for p, rr in pts),))
    for k, v in dict(wh_sph=[tuple(x) for x in SCENE['spheres_A'] + SCENE['spheres_B']],
                     wh_pil=[tuple(x) for x in SCENE['pillars_A']], wh_box=[tuple(x) for x in SCENE['boxes_B']],
                     wh_ball=balls, wh_ballCol=bcol, wh_nBall=len(BALLS),
                     wh_cube=cpos, wh_cubeE=cax, wh_cubeCol=ccol, wh_nCube=len(CUBES), wh_bound=bound, wh_pix=0.002,
                     wh_rho0=PROF[0], wh_h=PROF[1], wh_fillet=PROF[2], uL0=l0, uN0=tuple(n0), uF=tuple(F), uRt=tuple(Rt),
                     uUp=tuple(Up), uTan=tuple(tan), uDebug=int(debug), uSize=(size, size)).items():
        if k in prog:      # the balls' and cubes' uniforms are gone from the shader without balls
            prog[k].value = v
    if TABLE:
        tab, lo, inv, reg = W.fillet_table()
        t = ctx.texture((tab.shape[1], 4), 4, tab.tobytes(), dtype='f4')
        t.filter = (moderngl.LINEAR, moderngl.LINEAR)
        t.repeat_x = t.repeat_y = False
        t.use(0)
        for k, v in dict(wh_tab=0, wh_tabLo=tuple(lo), wh_tabInv=tuple(inv), wh_tabReg=tuple(reg)).items():
            if k in prog:
                prog[k].value = v
    tex = ctx.texture((size, size), 4, dtype='f4' if debug else 'f1')
    fbo = ctx.framebuffer([tex])
    fbo.use(); fbo.clear()
    vao.render(moderngl.TRIANGLE_STRIP)
    data = np.frombuffer(fbo.read(components=4, dtype='f4' if debug else 'f1'),
                         dtype='f4' if debug else 'u1').reshape(size, size, 4)
    return data if debug else data[::-1]


# ---------------------------------------------------------------- reference
SPH = {1: SCENE['spheres_A'], -1: SCENE['spheres_B']}
PIL = SCENE['pillars_A']
BOX = SCENE['boxes_B']


def flat_hit(side, x, d, shell):
    """Returns (t, kind): kind 0 sky, 1 floor, 2 object, 3 shell, 10 + j ball j."""
    best, kind = 1e9, 0
    if d[2] < 0:
        t = -x[2] / d[2]
        if t > 0: best, kind = t, 1
    for s in SPH[side]:
        oc = x - np.array(s[:3]); bq = oc @ d; disc = bq * bq - (oc @ oc - s[3] ** 2)
        if disc >= 0:
            t = -bq - np.sqrt(disc)
            if 1e-4 < t < best: best, kind = t, 2
    if side > 0:
        for p in PIL:
            oc = x[:2] - p[:2]; A = d[:2] @ d[:2]
            if A < 1e-9: continue
            B = oc @ d[:2]; disc = B * B - A * (oc @ oc - p[2] ** 2)
            if disc >= 0:
                t = (-B - np.sqrt(disc)) / A; zz = x[2] + t * d[2]
                if 1e-4 < t < best and 0 < zz < p[3]: best, kind = t, 2
            if d[2] < 0:
                tt = (p[3] - x[2]) / d[2]; q = x[:2] + tt * d[:2] - p[:2]
                if 1e-4 < tt < best and q @ q < p[2] ** 2: best, kind = tt, 2
    else:
        for bx in BOX:
            c = np.array(bx[:3]); hs = bx[3]
            with np.errstate(divide='ignore', invalid='ignore'):
                t0 = (c - hs - x) / d; t1 = (c + hs - x) / d
            tin = np.max(np.minimum(t0, t1)); tout = np.min(np.maximum(t0, t1))
            if tin <= tout and 1e-4 < tin < best: best, kind = tin, 2
    M = np.array([1.0, 1, 1]) if side > 0 else np.array([-1.0, 1, 1])
    for j, (c, rad, _) in enumerate(BALLS):
        r2 = rad * rad - (c[3] - side * W.h) ** 2
        if r2 <= 0: continue
        oc = x - M * c[:3]; bq = oc @ d; cq = oc @ oc - r2; disc = bq * bq - cq
        if cq > 0 and disc >= 0:
            t = -bq - np.sqrt(disc)
            if 0 < t < best: best, kind = t, 10 + j
    for j, (c, ax, half, _) in enumerate(CUBES):
        X = np.r_[M * x, side * W.h] - c
        D = np.r_[M * d, 0.0]
        lo, hi = -np.inf, np.inf
        for a in ax:
            A, B = X @ a, D @ a
            if abs(B) < 1e-15:
                if abs(A) >= half: lo = np.inf
                continue
            t0, t1 = sorted(((-half - A) / B, (half - A) / B))
            lo, hi = max(lo, t0), min(hi, t1)
        if lo <= hi and 0 < lo < best:
            best, kind = lo, 10 + len(BALLS) + j
    if shell:
        bq = x @ d; disc = bq * bq - (x @ x - W.Rout ** 2)
        if disc > 0:
            t = -bq - np.sqrt(disc)
            if 0 < t < best: best, kind = t, 3
    return best, kind


def geom_flat(side, x, d, t, kind):
    if kind >= 10:
        M = np.array([1.0, 1, 1]) if side > 0 else np.array([-1.0, 1, 1])
        j = kind - 10
        return (100 + j if j < len(BALLS) else 200 + j - len(BALLS), *(M * (x + t * d)))
    code = 2 * kind + (1 if side > 0 else 0)
    if kind == 0:
        dn = d / np.linalg.norm(d)
        return (code, *dn)
    p = x + t * d
    if kind == 1:
        M = np.array([1.0, 1, 1]) if side > 0 else np.array([-1.0, 1, 1])
        npnt = M * p / np.linalg.norm(p)
        return (code, side * (np.linalg.norm(p) - W.Rout + W.L), npnt[0], npnt[1])
    return (code, *p)


def reference(state, size, tan):
    l0, n0, F, Rt, Up = state
    out = np.zeros((size, size, 4))
    pend = []    # rays needing the curved integration: (iy, ix, l, n, vl, w)
    for iy in range(size):
        for ix in range(size):
            u, v = (ix + 0.5) / size, (iy + 0.5) / size
            dl = np.array([-tan[0] + u * (tan[0] + tan[1]), -tan[2] + v * (tan[2] + tan[3]), 1.0])
            dl /= np.linalg.norm(dl)
            V = dl[0] * Rt + dl[1] * Up + dl[2] * F
            vl, w = V[0], V[1:]
            if abs(l0) < W.L:
                pend.append((iy, ix, l0, n0, vl, w)); continue
            side = 1.0 if l0 > 0 else -1.0
            M = np.array([1.0, 1, 1]) if side > 0 else np.array([-1.0, 1, 1])
            x = M * (abs(l0) - W.L + W.Rout) * n0
            d = M * (side * vl * n0 + w)
            t, kind = flat_hit(side, x, d, True)
            if kind != 3:
                out[iy, ix] = geom_flat(side, x, d, t, kind); continue
            p = x + t * d
            nn = M * p / np.linalg.norm(p); md = M * d; rad = md @ nn
            pend.append((iy, ix, side * W.L, nn, side * rad, md - rad * nn))
    if pend:
        res = W.brute(np.array([p[2] for p in pend]), np.array([p[3] for p in pend]),
                      np.array([p[4] for p in pend]), np.array([p[5] for p in pend]), h=W.rho0 * float(os.environ.get('WH_REFSTEP', '1e-3')),
                      balls=[(c, rad) for c, rad, _ in BALLS], cubes=[(c, ax, half) for c, ax, half, _ in CUBES])
        for k, (iy, ix, *_ ) in enumerate(pend):
            kind = res['kind'][k]
            if kind >= 10:
                j = kind - 10
                code = 100 + j if j < len(BALLS) else 200 + j - len(BALLS)
                out[iy, ix] = (code, *(W.r(res['l'][k]) * res['n'][k]))
                continue
            if kind == 2:
                n = res['n'][k]
                out[iy, ix] = (3 if res['l'][k] > 0 else 2, res['l'][k], n[0], n[1])
                continue
            if kind == 0:
                out[iy, ix] = (-9, 0, 0, 0); continue    # did not finish (trapped)
            side = float(kind)
            M = np.array([1.0, 1, 1]) if side > 0 else np.array([-1.0, 1, 1])
            n, vl, w = res['n'][k], res['vl'][k], res['w'][k]
            x = M * W.Rout * n
            d = M * (side * vl * n + w)
            t, fk = flat_hit(side, x, d, False)
            out[iy, ix] = geom_flat(side, x, d, t, fk)
    return out


def compare(gpu, ref, name):
    """Sky: angular error of the final direction. Floor and balls: hit-position error in units of
    the pixel footprint (distance to the neighbouring pixels' hits in the reference), converted to
    an equivalent viewing angle. Errors well below a pixel are invisible."""
    n = gpu.shape[0]
    px_deg = 90.0 / n
    valid = ref[..., 0] >= 0
    k_ok = (gpu[..., 0] == ref[..., 0]) & valid
    code = ref[..., 0]
    sky = k_ok & (code < 2)
    flo = k_ok & ((code == 2) | (code == 3))
    bal = k_ok & (code >= 100) & (code < 200)
    cub = k_ok & (code >= 200)
    g3 = gpu[..., 1:].astype(np.float64); g3 /= np.linalg.norm(g3, axis=-1, keepdims=True) + 1e-300
    e_sky = np.degrees(np.arctan2(np.linalg.norm(np.cross(g3, ref[..., 1:]), axis=-1), np.sum(g3 * ref[..., 1:], -1)))[sky]

    def emb(a):   # floor point as (l, r n_xy); ball hit as its R^4 xyz. Metres.
        fl = np.concatenate([a[..., 1:2], W.r(a[..., 1:2]) * a[..., 2:4]], -1)
        return np.where((a[..., :1] >= 100), a[..., 1:4], fl)
    E = emb(ref.astype(np.float64)); G = emb(gpu.astype(np.float64))
    err = np.linalg.norm(G - E, axis=-1)
    foot = np.full(err.shape, np.inf)
    for dy, dx in ((0, 1), (0, -1), (1, 0), (-1, 0)):
        sh = np.roll(E, (dy, dx), (0, 1)); same = np.roll(code, (dy, dx), (0, 1)) == code
        d = np.linalg.norm(sh - E, axis=-1)
        foot = np.minimum(foot, np.where(same, d, np.inf))
    ok = np.isfinite(foot) & (foot > 0)

    def ang(mask):
        e = (err / np.where(ok, foot, 1.0))[mask & ok] * px_deg
        return (np.percentile(e, 99), e.max(), e.size) if e.size else (0.0, 0.0, 0)
    f99, fmax, _ = ang(flo)
    b99, bmax, bn = ang(bal)
    c99, cmax, cn = ang(cub)
    nb_ref = int(((code >= 100) & (code < 200)).sum())
    nc_ref = int((code >= 200).sum())
    print(f"[{name}] class mismatch {(1 - k_ok[valid].mean()) * 100:.2f}% | sky max {e_sky.max() if e_sky.size else 0:.4f} deg"
          f" | floor p99 {f99:.4f} max {fmax:.4f} deg | balls {nb_ref} px, p99 {b99:.4f} max {bmax:.4f} deg"
          f" | cubes {nc_ref} px, p99 {c99:.4f} max {cmax:.4f} deg")
    return k_ok


if __name__ == '__main__':
    ctx = moderngl.create_standalone_context(backend='egl')
    tan = (1.0, 1.0, 1.0, 1.0)
    cams = {
        'outside_A': frame_from_chart(1, np.array([12.0, 1.0, 1.6]), np.array([-1.0, 0, 0]), np.array([0, 0, 1.0])),
        'outside_B_look_back': frame_from_chart(-1, np.array([-11.0, 2.0, 1.6]), np.array([1.0, 0, 0]), np.array([0, 0, 1.0])),
    }
    # cameras inside the shell (middle of the throat, and in a fillet), looking along the floor toward side B
    def inside(l0, tilt):
        n0 = np.array([1.0, 0.0, tilt]); n0 /= np.linalg.norm(n0)
        tz = np.array([0, 0, 1.0]) - n0 * n0[2]; tz /= np.linalg.norm(tz)
        ty = np.cross(tz, n0)   # (e_l, ty, tz) right-handed
        F = np.r_[-0.9, 0.2 * ty]; F /= np.linalg.norm(F)
        Up = np.r_[0.0, tz]
        to3 = lambda V: np.array([V[0], V[1:] @ ty, V[1:] @ tz])   # basis {e_l, ty, tz}
        from3 = lambda c: np.r_[c[0], c[1] * ty + c[2] * tz]
        return (l0, n0, F, from3(np.cross(to3(F), to3(Up))), Up)
    cams['in_throat_middle'] = inside(0.1 * max(W.Lc, W.L), 0.5)
    cams['in_fillet'] = inside(0.5 * (W.Lc + W.L), 0.35)

    def facing(l0, n0, fwd):
        """Camera at (l0, n0) looking along fwd = (e_l, ty, tz) components, tz up the floor normal."""
        n0 = np.asarray(n0, float); n0 /= np.linalg.norm(n0)
        tz = np.array([0, 0, 1.0]) - n0 * n0[2]; tz /= np.linalg.norm(tz)
        ty = np.cross(tz, n0)
        to3 = lambda V: np.array([V[0], V[1:] @ ty, V[1:] @ tz])
        from3 = lambda c: np.r_[c[0], c[1] * ty + c[2] * tz]
        F = np.asarray(fwd, float) / np.linalg.norm(fwd)
        up = np.array([0, 0, 1.0]) - F * F[2]; up /= np.linalg.norm(up)
        return (l0, n0, from3(F), from3(np.cross(F, up)), from3(up))
    # close to the cubes (and balls) of the throat and of the fillet, so that they cover many pixels
    if CUBES:
        if W.Lc > 0:
            cams['at_throat_cube'] = facing(0.4 * W.Lc + 1.4, [1.0, -0.3, 0.3], [-1.0, 0.0, -0.25])
        cams['at_fillet_cube'] = facing(W.L - 0.05, [1.0, 0.4, 0.35], [-1.0, 0.0, -0.3])
    if os.environ.get('WH_CAMS'):             # e.g. WH_CAMS=at_throat_cube,at_fillet_cube
        cams = {k: v for k, v in cams.items() if k in os.environ['WH_CAMS'].split(',')}
    tag = '_'.join(f'{v:g}' for v in PROF)

    os.makedirs(os.path.join(HERE, 'out'), exist_ok=True)
    for name, st in cams.items():
        img = render(ctx, st, 900, tan, False)
        Image.fromarray(img[..., :3]).save(os.path.join(HERE, 'out', f'{tag}_{name}.png'))
        n = int(sys.argv[1]) if len(sys.argv) > 1 else 96
        g = render(ctx, st, n, tan, True)
        ref = reference(st, n, tan)
        compare(g, ref, name)
