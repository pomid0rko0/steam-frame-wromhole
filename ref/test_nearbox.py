#!/usr/bin/env python3
"""How far a cube near the eye, seen along the curved space's geodesics, is from its flat picture.

In the eye's normal coordinates (directions times path length) a ray from the eye is a straight
line. A cube near the eye there is almost its flat self: centre at the end of the geodesic to it
(direction U, length D), its body axes carried back to the eye along that geodesic. This traces
rays from random eyes in and near the shell (RK4, float64) at random cubes 0.2-1.5 m off, and for
every ray that meets a cube's cut (the 4D box test, as the shader's) the distance from the ray's
straight line to the flat box: what a mark that tests the flat box must add. Prints its worst over
the cases against D, the half size and the curvature there.

  SEED=7 python3 ref/test_nearbox.py [--cases N] [--rays M]

main.BOX_GROW is fitted on the slabs' growth (what the shader's slab test needs, less than the
distance to the box): seeds 31-36 (1352 cases with hits) gave at most 0.057 D (half + eye) within
1.5 m and 0.081 at 3 m; main grows each slab by D (half + eye) (0.07 + 0.017 D), 1.4 times
0.05 + 0.012 D.
"""
import os
import sys
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from wh import Wormhole

W = Wormhole(3.0, 5.0, 1.0)
RNG = np.random.default_rng(int(os.environ.get("SEED", "7")))


def unit(v):
    return v / np.linalg.norm(v, axis=-1, keepdims=True)


def wp(l):
    """dw/dl"""
    al = np.abs(l)
    th = W.theta(al)
    return np.where(al <= W.Lc, 1.0, np.where(al <= W.L, np.cos(th), 0.0))


def embed_vec(l, n, U):
    """A tangent vector (U_l, u) at (l, n) as a vector of R^4."""
    return np.concatenate([W.dr(l)[..., None] * U[..., :1] * n + U[..., 1:], wp(l)[..., None] * U[..., :1]], -1)


def normal4(l, n):
    """The hypersurface's unit normal in R^4 at (l, n)."""
    return np.concatenate([wp(l)[..., None] * n, -W.dr(l)[..., None]], -1)


def rhs(l, n, vl, w, F):
    """the geodesic (l, n, vl, w) and frame vectors F (k, 4) as (U_l, u), transported"""
    r = W.r(l)
    k = W.dr(l) / r
    dl, dn, dvl, dw = W.geo_rhs(l, n, vl, w)
    dF = []
    for U in F:
        Ul, u = U[0], U[1:]
        dUl = k * np.dot(w, u)
        du = -k * Ul * w - np.dot(u, w) / r * n
        dF.append(np.concatenate([[dUl], du]))
    return dl, dn, dvl, dw, np.array(dF)


def transport(l, n, vl, w, F, length, h=2e-3):
    """Follow one geodesic for length, carrying the frame F: (l, n, vl, w, F) at its end."""
    steps = max(1, int(np.ceil(length / h)))
    hs = length / steps
    y = (l, np.array(n, float), vl, np.array(w, float), np.array(F, float))
    for _ in range(steps):
        def add(y, k, c):
            return tuple(a + c * b for a, b in zip(y, k))
        k1 = rhs(*y)
        k2 = rhs(*add(y, k1, hs / 2))
        k3 = rhs(*add(y, k2, hs / 2))
        k4 = rhs(*add(y, k3, hs))
        y = tuple(a + hs / 6 * (b1 + 2 * b2 + 2 * b3 + b4) for a, b1, b2, b3, b4 in zip(y, k1, k2, k3, k4))
        l, n, vl, w, F = y
        n = unit(n)
        w = w - np.dot(w, n) * n
        F = np.array([np.concatenate([[U[0]], U[1:] - np.dot(U[1:], n) * n]) for U in F])
        y = (l, n, vl, w, F)
    return y


def trace_hits(le, ne, V, C, A, half, smax, h=2e-3):
    """Rays from (le, ne) with directions V (m, 4) as (U_l, u): which meet the 4D box (centre C,
    axes A rows, half size) before smax, and where on the path (s), as the shader's cut."""
    m = len(V)
    l = np.full(m, le)
    n = np.tile(ne, (m, 1))
    vl = V[:, 0].copy()
    w = V[:, 1:].copy()
    hit = np.zeros(m, bool)
    s_hit = np.full(m, np.inf)
    alive = np.ones(m, bool)
    s = 0.0
    while alive.any() and s < smax:
        idx = np.nonzero(alive)[0]
        y = W._rk4((l[idx], n[idx], vl[idx], w[idx]), h)
        ln, nn, vln, wn = y
        nn = unit(nn)
        wn = wn - np.sum(wn * nn, -1, keepdims=True) * nn
        s += h
        P = W.embed(ln, nn) - C
        inside = np.all(np.abs(P @ A.T) < half, -1)
        new = inside & ~hit[idx]
        s_hit[idx[new]] = s
        hit[idx[new]] = True
        floor = (n[idx, 2] > 0) & (nn[:, 2] <= 0)
        l[idx], n[idx], vl[idx], w[idx] = ln, nn, vln, wn
        alive[idx[floor | inside]] = False
    return hit, s_hit


def line_box_gap(V, e, c, a, half):
    """For each unit direction V (m, 3): the distance from the ray e + s V (s >= 0) to the box
    (centre c, unit axes a rows, half size), by sampling s finely (the distance is convex in s)."""
    s = np.linspace(0.0, 4.5, 4501)
    best = np.full(len(V), np.inf)
    for k in range(0, len(s), 500):
        P = e + s[None, k:k + 500, None] * V[:, None, :] - c        # (m, S, 3)
        q = np.einsum('msi,ki->msk', P, a)
        d = np.linalg.norm(np.maximum(np.abs(q) - half, 0.0), axis=-1)
        best = np.minimum(best, d.min(1))
    return best


def slab_growth(V, e, c, a, half):
    """What the shader's slab test needs: for each ray e + s V, how much every slab of the box (unit
    axes a rows, half size) must grow for the ray to pass it, min over s >= 0 of
    max_k (|(X - c) . a_k| - half)."""
    s = np.linspace(0.0, 4.5, 4501)
    best = np.full(len(V), np.inf)
    for k in range(0, len(s), 500):
        P = e + s[None, k:k + 500, None] * V[:, None, :] - c
        q = np.abs(np.einsum('msi,ki->msk', P, a)) - half
        best = np.minimum(best, q.max(-1).min(1))
    return best


def main():
    ncase = int(sys.argv[sys.argv.index('--cases') + 1]) if '--cases' in sys.argv else 200
    nray = int(sys.argv[sys.argv.index('--rays') + 1]) if '--rays' in sys.argv else 1500
    worst = []
    for case in range(ncase):
        # the head: in the shell or up to a metre outside it, 0.5-1.9 m above the floor
        side = RNG.choice([-1.0, 1.0])
        lh = side * RNG.uniform(0.0, W.L + 1.0)
        phi = RNG.uniform(0, 2 * np.pi)
        nz = np.clip(RNG.uniform(0.5, 1.9) / W.r(lh), 0.0, 0.9)
        nh = np.array([np.sqrt(1 - nz ** 2) * np.cos(phi), np.sqrt(1 - nz ** 2) * np.sin(phi), nz])
        # the head's tangent basis as (U_l, u): d/dl and two across (the room's axes there)
        t1 = unit(np.cross(nh, [0.0, 0.0, 1.0] if abs(nh[2]) < 0.9 else [1.0, 0.0, 0.0]))
        t2 = np.cross(nh, t1)
        B = np.array([[1.0, 0, 0, 0], np.concatenate([[0.0], t1]), np.concatenate([[0.0], t2])])
        # the cube: the end of a geodesic from the head (main._update_near: toward_fast)
        c3 = unit(RNG.normal(size=3))
        D = RNG.uniform(0.2, 3.0)
        half = RNG.uniform(0.05, 0.4)
        lt, nt, vlt, wt, FT = transport(lh, nh, *(lambda U: (U[0], U[1:]))(c3 @ B), B, D)
        # body axes at the cube: a random turn of the carried head basis, as R^4 vectors; the
        # fourth axis the normal there
        Q, _ = np.linalg.qr(RNG.normal(size=(3, 3)))
        body = Q @ FT                                   # (3, 4) as (U_l, u)
        A = np.vstack([embed_vec(lt, nt, body), normal4(lt, nt)[None]])
        C = W.embed(lt, nt)
        # the eye: up to 8 cm from the head (half the eyes' distance, and where the head has gone
        # since main placed it), along a geodesic carrying the basis: its rays' directions in it
        e = unit(RNG.normal(size=3)) * RNG.uniform(0.0, 0.08)
        le, ne, _, _, Be = transport(lh, nh, *(lambda U: (U[0], U[1:]))(unit(e) @ B), B, np.linalg.norm(e))
        # rays: directions within the cube's bounding cone from the eye, more near its edge
        axis = unit(D * c3 - e)
        ang = np.arcsin(min(1.0, 1.8 * half / D)) * np.sqrt(RNG.uniform(0, 1, nray))
        perp = unit(RNG.normal(size=(nray, 3)))
        perp = unit(perp - np.outer(perp @ axis, axis))
        dirs = np.cos(ang)[:, None] * axis + np.sin(ang)[:, None] * perp
        V = dirs @ Be
        hit, _ = trace_hits(le, ne, V, C, A, half, D + 2.5 * half)
        if not hit.any():
            continue
        # the flat picture in the head's coordinates: centre D c3, axes Q, the ray from e
        gap = line_box_gap(dirs[hit], e, D * c3, Q, half)
        g = gap.max()
        gs = max(slab_growth(dirs[hit], e, D * c3, Q, half).max(), 0.0)
        worst.append((g, D, half, lh, np.linalg.norm(e), gs))
        print('case %3d: head l %6.2f, D %.2f, half %.2f, eye %.3f off: %4d rays meet it; flat box missed by up to %.4f m, its slabs by %.4f (%.4f of D (half + eye))'
              % (case, lh, D, half, np.linalg.norm(e), hit.sum(), g, gs, gs / (D * (half + np.linalg.norm(e)))), flush=True)
    w = np.array(worst)
    print('worst gap %.4f m; gap / (D half): %.4f max; gap / D^2: %.4f max; gap / (D (half + eye)): %.4f max'
          % (w[:, 0].max(), (w[:, 0] / (w[:, 1] * w[:, 2])).max(), (w[:, 0] / w[:, 1] ** 2).max(),
             (w[:, 0] / (w[:, 1] * (w[:, 2] + w[:, 4]))).max()))
    print('slabs (what the shader tests, main.BOX_GROW): worst growth %.4f m; / (D (half + eye)): %.4f max over %d cases'
          % (w[:, 5].max(), (w[:, 5] / (w[:, 1] * (w[:, 2] + w[:, 4]))).max(), len(w)))


if __name__ == '__main__':
    main()
