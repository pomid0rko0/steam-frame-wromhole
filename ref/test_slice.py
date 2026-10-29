"""The gravity arrows' surface (n.x = 0 through the wormhole, wormhole_core's WH_ARROWS): where
the shader's rays first cross it, against brute-force RK4 rays (ref/wh.py) through flat and curved
space, as test_gpu.py does for the floor. The shader runs as the gravity view with arrows does
(wormhole_arrows.gdshader: no movable balls, the fillet table). Exit status 1 on failure.
    python3 ref/test_slice.py [pixels]"""
import os, sys
import in_box  # noqa: F401 (first: on the Frame, into tools/box.sh's container)
os.environ['WH_BALLS'] = '0'
import numpy as np
import moderngl
import test_gpu as T
from test_gpu import W, CORE, TAN, frame_from_chart, flat_hit

HEADER = T.FRAG.split(CORE)[0]
FRAG = HEADER.replace('#define WH_NO_BALLS\n', '#define WH_NO_BALLS\n#define WH_GRAVITY\n#define WH_ARROWS\n#define WH_SLICE_OUT wh_sl\n') + """
uniform vec4 grav_cyl;
uniform vec4 grav_g[2];
uniform vec4 grav_d[2];
vec3 wh_sl;
""" + CORE + """
void main() {
    vec2 uv = gl_FragCoord.xy / uSize;
    vec3 dl = normalize(vec3(mix(-uTan.x, uTan.y, uv.x), mix(-uTan.z, uTan.w, uv.y), 1.0));
    vec4 V = dl.x * uRt + dl.y * uUp + dl.z * uF;
    vec4 dbg;
    wh_sl = vec3(-1.0);
    vec3 col = wh_render(uL0, uN0, V.x, V.yzw, dbg);
    frag = wh_sl.z >= 0.0 ? vec4(wh_sl.xy, cos(wh_sl.y), 1.0 + 1e-9 * col.x) : vec4(0.0, 0.0, 0.0, -1.0);
}
"""


def render(ctx, state, size, tan):
    l0, n0, F, Rt, Up = state
    prog = ctx.program(vertex_shader=T.VERT, fragment_shader=FRAG)
    vbo = ctx.buffer(np.array([-1, -1, 1, -1, -1, 1, 1, 1], 'f4').tobytes())
    vao = ctx.vertex_array(prog, [(vbo, '2f', 'p')])
    tab, lo, inv, reg = W.fillet_table()
    t = ctx.texture((tab.shape[1], 4), 4, tab.tobytes(), dtype='f4')
    t.filter = (moderngl.LINEAR, moderngl.LINEAR)
    t.repeat_x = t.repeat_y = False
    t.use(0)
    for k, v in dict(wh_sph=[tuple(x) for x in T.SCENE['spheres_A'] + T.SCENE['spheres_B']],
                     wh_pil=[tuple(x) for x in T.SCENE['pillars_A']], wh_box=[tuple(x) for x in T.SCENE['boxes_B']],
                     wh_tab=0, wh_tabLo=tuple(lo), wh_tabInv=tuple(inv), wh_tabReg=tuple(reg),
                     wh_pix=0.001, grav_cyl=(0.2, 0.47, 0.29, -3.2),
                     wh_rho0=T.PROF[0], wh_h=T.PROF[1], wh_fillet=T.PROF[2], uL0=l0, uN0=tuple(n0), uF=tuple(F),
                     uRt=tuple(Rt), uUp=tuple(Up), uTan=tuple(tan), uSize=(size, size)).items():
        if k in prog:
            prog[k].value = v
    tex = ctx.texture((size, size), 4, dtype='f4')
    fbo = ctx.framebuffer([tex])
    fbo.use(); fbo.clear()
    vao.render(moderngl.TRIANGLE_STRIP)
    out = np.frombuffer(fbo.read(components=4, dtype='f4'), dtype='f4').reshape(size, size, 4)
    # as the reference: (found, l, n.y, n.z); the shader gives the angle of n from +y toward +z
    a = out[..., 1].astype(np.float64)
    return np.stack([np.where(out[..., 3] >= 0, 1.0, -1.0), out[..., 0], np.cos(a), np.sin(a)], -1)


def flat_cross(side, x, d, t_end):
    """First crossing of x = 0 by the chart segment x + t d, 0 < t < t_end: (l, n) or None."""
    if abs(d[0]) < 1e-12:
        return None
    t = -x[0] / d[0]
    if not 0 < t < t_end:
        return None
    p = x + t * d
    M = np.array([1.0, 1, 1]) if side > 0 else np.array([-1.0, 1, 1])
    return side * (np.linalg.norm(p) - W.Rout + W.L), M * p / np.linalg.norm(p)


def curved(l, n, vl, w, h):
    """Brute-force RK4 rays from inside the shell: the first crossing of n.x = 0 before the ray
    hits the floor or leaves the shell. Returns found, l, n at the crossing, and how it ended
    (kind 2 floor, +-1 left on that side) with the final state."""
    m = len(l)
    alive = np.ones(m, bool)
    found = np.zeros(m, bool)
    cl, cn = np.zeros(m), np.zeros((m, 3))
    kind = np.zeros(m, int)
    fl, fn, fvl, fw = l.copy(), n.copy(), vl.copy(), w.copy()
    s = 0.0
    while alive.any() and s < 300.0:
        idx = np.nonzero(alive)[0]
        y = (l[idx], n[idx], vl[idx], w[idx])
        ln, nn, vln, wn = W._rk4(y, h)
        nn = nn / np.linalg.norm(nn, axis=-1, keepdims=True)
        wn = wn - np.sum(wn * nn, -1, keepdims=True) * nn
        floor = (y[1][:, 2] > 0) & (nn[:, 2] <= 0)
        leave = (np.abs(ln) >= W.L) & (np.sign(ln) * vln > 0)
        cross = ~found[idx] & (np.sign(y[1][:, 0]) != np.sign(nn[:, 0]))
        for j in np.nonzero(cross)[0]:
            yy = tuple(v[j:j + 1] for v in y)
            lo, hi = 0.0, h
            for _ in range(50):
                mid = 0.5 * (lo + hi)
                ym = W._rk4(yy, mid)
                lo, hi = (lo, mid) if np.sign(ym[1][0, 0]) != np.sign(yy[1][0, 0]) else (mid, hi)
            ym = W._rk4(yy, hi)
            g = idx[j]
            found[g] = True
            cl[g] = ym[0][0]
            cn[g] = ym[1][0] / np.linalg.norm(ym[1][0])
        ev = floor | leave
        for j in np.nonzero(ev)[0]:
            g = idx[j]
            kind[g] = 2 if floor[j] else (1 if ln[j] > 0 else -1)
            fl[g], fn[g], fvl[g], fw[g] = ln[j], nn[j], vln[j], wn[j]
        alive[idx[ev]] = False
        keep = ~ev
        l[idx[keep]], n[idx[keep]], vl[idx[keep]], w[idx[keep]] = ln[keep], nn[keep], vln[keep], wn[keep]
        s += h
    return found, cl, cn, kind, fl, fn, fvl, fw


def reference(state, size, tan):
    l0, n0, F, Rt, Up = state
    out = np.zeros((size, size, 4))
    out[..., 0] = -1
    pend = []
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
            c = flat_cross(side, x, d, t)
            if c is not None:
                out[iy, ix] = (1.0, c[0], c[1][1], c[1][2]); continue
            if kind != 3:
                continue
            p = x + t * d
            nn = M * p / np.linalg.norm(p); md = M * d; rad = md @ nn
            pend.append((iy, ix, side * W.L, nn, side * rad, md - rad * nn))
    if pend:
        found, cl, cn, kind, fl, fn, fvl, fw = curved(
            np.array([p[2] for p in pend], float), np.array([p[3] for p in pend], float),
            np.array([p[4] for p in pend], float), np.array([p[5] for p in pend], float), W.rho0 * 1e-3)
        for k, (iy, ix, *_) in enumerate(pend):
            if found[k]:
                out[iy, ix] = (1.0, cl[k], cn[k][1], cn[k][2]); continue
            if abs(kind[k]) != 1:
                continue
            side = float(kind[k])
            M = np.array([1.0, 1, 1]) if side > 0 else np.array([-1.0, 1, 1])
            x = M * W.Rout * fn[k]
            d = M * (side * fvl[k] * fn[k] + fw[k])
            t, _ = flat_hit(side, x, d, False)
            c = flat_cross(side, x, d, t)
            if c is not None:
                out[iy, ix] = (1.0, c[0], c[1][1], c[1][2])
    return out


def compare(gpu, ref, name):
    """Found / not found per pixel, then the crossing point's error in units of the pixel
    footprint (distance between neighbouring pixels' crossings), as a viewing angle."""
    n = gpu.shape[0]
    px_deg = np.degrees(2.0 * np.arctan(TAN)) / n
    fg, fr = gpu[..., 0] > 0, ref[..., 0] > 0
    mism = (fg != fr).mean() * 100
    both = fg & fr
    emb = lambda a: np.stack([a[..., 1], W.r(a[..., 1]) * a[..., 2], W.r(a[..., 1]) * a[..., 3]], -1)
    E, G = emb(ref.astype(np.float64)), emb(gpu.astype(np.float64))
    err = np.linalg.norm(G - E, axis=-1)
    foot = np.full(err.shape, np.inf)
    for dy, dx in ((0, 1), (0, -1), (1, 0), (-1, 0)):
        sh = np.roll(E, (dy, dx), (0, 1)); same = np.roll(fr, (dy, dx), (0, 1)) & fr
        foot = np.minimum(foot, np.where(same, np.linalg.norm(sh - E, axis=-1), np.inf))
    ok = both & np.isfinite(foot) & (foot > 0)
    e = (err / np.where(ok, foot, 1.0))[ok] * px_deg
    p99, mx = (np.percentile(e, 99), e.max()) if e.size else (0.0, 0.0)
    print(f'[{name}] surface pixels {int(fr.sum())}, found / not found differs {mism:.2f}% | crossing p99 {p99:.4f} max {mx:.4f} deg')
    return mism, p99, mx, int(fr.sum())


if __name__ == '__main__':
    ctx = moderngl.create_standalone_context(backend='egl')
    tan = (TAN,) * 4

    def look(side, x, at):
        f = np.asarray(at, float) - x; f /= np.linalg.norm(f)
        up = np.array([0, 0, 1.0]) - f * f[2]; up /= np.linalg.norm(up)
        return frame_from_chart(side, np.asarray(x, float), f, up)

    def facing(l0, n0, fwd):
        n0 = np.asarray(n0, float); n0 /= np.linalg.norm(n0)
        tz = np.array([0, 0, 1.0]) - n0 * n0[2]; tz /= np.linalg.norm(tz)
        ty = np.cross(tz, n0)
        from3 = lambda c: np.r_[c[0], c[1] * ty + c[2] * tz]
        F = np.asarray(fwd, float) / np.linalg.norm(fwd)
        up = np.array([0, 0, 1.0]) - F * F[2]; up /= np.linalg.norm(up)
        return (l0, n0, from3(F), from3(np.cross(F, up)), from3(up))

    cams = {
        'start': look(1, [10.0, 0.0, 1.6], [0.0, 0.0, 1.6]),
        'oblique_A': look(1, [7.0, 6.0, 2.5], [0.0, 0.0, 1.0]),
        'from_B': look(-1, [-9.0, 3.0, 1.6], [0.0, 0.0, 1.5]),
        'in_throat': facing(1.0, [1.0, 0.2, 0.3], [-1.0, 0.3, 0.1]),
        'in_fillet': facing(0.5 * (W.Lc + W.L), [1.0, -0.3, 0.25], [-1.0, 0.2, 0.05]),
    }
    size = int(sys.argv[1]) if len(sys.argv) > 1 else 96
    fails = 0
    for name, st in cams.items():
        g = render(ctx, st, size, tan)
        r = reference(st, size, tan)
        mism, p99, mx, npx = compare(g, r, name)
        if mism > 1.0 or p99 > 0.05 or npx < 50:
            fails += 1
    print('FAILURES:', fails)
    sys.exit(1 if fails else 0)
