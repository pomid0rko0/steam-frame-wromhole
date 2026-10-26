#!/usr/bin/env python3
"""The cones of the toys near the eye (wormhole_core.gdshaderinc, wh_nearCone), checked by brute force.

A ray from the eye meets a toy of reach rho (chord distance in R^4 from its centre) only if its
direction is within the cone round the geodesic to the centre (length D) whose half angle a0 has
sin a0 = sin(1.02 rho / rho0) / sin(D / rho0) (the space is CAT(1 / rho0^2)); the stencil then
leaves the toy out of the rays outside it (main._update_near). This traces rays from random eyes
in and near the shell (RK4 in float64, 2 mm steps, until the floor or far into a flat universe)
at random toys within a metre, and counts the rays that meet a toy from outside its cone: there
must be none. It also prints how near the cone's edge the nearest such ray came, and how far a ray
went before it came back within 2 m of its eye (the shader's argument needs that never past 8 m).

  python3 ref/test_near.py [--rays N]
"""
import os
import sys
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from wh import Wormhole

W = Wormhole(3.0, 5.0, 1.0)
RNG = np.random.default_rng(5)


def unit(v):
    return v / np.linalg.norm(v, axis=-1, keepdims=True)


def tangent_frame(n):
    """Two unit vectors orthogonal to n and each other."""
    a = np.where(np.abs(n[..., :1]) < 0.9, np.array([1.0, 0.0, 0.0]), np.array([0.0, 1.0, 0.0]))
    t1 = unit(np.cross(n, a))
    return t1, np.cross(n, t1)


def rk4(y, h):
    """W._rk4 with a step per ray (h an array)"""
    hh = [h, h[:, None], h, h[:, None]]

    def add(y, k, c):
        return tuple(yi + c * hi * ki for yi, ki, hi in zip(y, k, hh))
    k1 = W.geo_rhs(*y)
    k2 = W.geo_rhs(*add(y, k1, 0.5))
    k3 = W.geo_rhs(*add(y, k2, 0.5))
    k4 = W.geo_rhs(*add(y, k3, 1.0))
    return tuple(yi + hi / 6 * (a1 + 2 * a2 + 2 * a3 + a4) for yi, hi, a1, a2, a3, a4 in zip(y, hh, k1, k2, k3, k4))


def shoot(l, n, vl, w, length, h=2e-3):
    """Follow geodesics (arrays) for the given lengths: (l, n) where each ends."""
    l, n, vl, w = l.copy(), n.copy(), vl.copy(), w.copy()
    steps = int(np.ceil(length.max() / h))
    hs = length / steps
    for _ in range(steps):
        l, n, vl, w = rk4((l, n, vl, w), hs)
        n = unit(n)
        w = w - np.sum(w * n, -1, keepdims=True) * n
    return l, n


def near_cone(D, reach):
    """cos of the cone's half angle (wh_nearCone, its margins too), -2 for none."""
    rr = 1.02 * reach
    S = np.sin(rr / W.rho0) / np.sin(np.minimum(D, 1.5 * W.rho0) / W.rho0)
    ok = (reach > 0) & (D > rr) & (S < 1.0)
    return np.where(ok, np.cos(np.arcsin(np.minimum(S, 1.0)) + 0.005), -2.0)


def main():
    nrays = int(sys.argv[sys.argv.index('--rays') + 1]) if '--rays' in sys.argv else 40000
    # eyes: in the shell and up to 1.5 m outside it, on either side, 0.3..2 m above the floor
    m = nrays
    side = RNG.choice([-1.0, 1.0], m)
    le = side * RNG.uniform(0.0, W.L + 1.5, m)
    phi = RNG.uniform(0, 2 * np.pi, m)
    # n with n_z > 0: the height above the floor is r n_z
    hgt = RNG.uniform(0.3, 2.0, m)
    nz = np.clip(hgt / W.r(le), 0.0, 0.95)
    ne = np.stack([np.sqrt(1 - nz ** 2) * np.cos(phi), np.sqrt(1 - nz ** 2) * np.sin(phi), nz], -1)
    t1, t2 = tangent_frame(ne)

    def direction(c):
        """unit tangent (vl, w) from 3 coefficients on (d/dl, t1, t2)"""
        c = unit(c)
        return c[:, 0], c[:, 1:2] * t1 + c[:, 2:3] * t2
    # a toy within a metre: the end of a geodesic from the eye (its direction and length are the
    # geodesic to it, as toward finds it), reach 0.04 (a hand) .. 0.6 (a big cube)
    uv, uw = direction(RNG.normal(size=(m, 3)))
    D = RNG.uniform(0.1, 1.0, m)
    tl, tn = shoot(le, ne, uv, uw, D)
    T = W.embed(tl, tn)
    reach = np.exp(RNG.uniform(np.log(0.04), np.log(0.6), m))
    cosa = near_cone(D, reach)
    # rays: half of them near the cone's edge (just outside it), half anywhere
    U = np.concatenate([uv[:, None], uw], -1)
    a0 = np.arccos(np.clip(cosa, -1.0, 1.0))
    edge = RNG.random(m) < 0.5
    ang = np.where(edge, a0 + RNG.uniform(0.0, 0.3, m), np.arccos(RNG.uniform(-1, 1, m)))
    # a direction at angle ang from U: U cos + perp sin, perp a random unit tangent orthogonal to U
    pv, pw = direction(RNG.normal(size=(m, 3)))
    P = np.concatenate([pv[:, None], pw], -1)
    P = unit(P - np.sum(P * U, -1, keepdims=True) * U)
    V = np.cos(ang)[:, None] * U + np.sin(ang)[:, None] * P
    vl, w = V[:, 0].copy(), V[:, 1:].copy()
    outside_cone = np.sum(V * U, -1) < cosa
    # trace: the nearest chord distance to the toy's centre, until the floor, or 30 m
    l, n = le.copy(), ne.copy()
    alive = np.ones(m, bool)
    dmin = np.full(m, np.inf)
    back = 0.0          # the longest path after which a ray came within 2 m of its eye
    E0 = W.embed(le, ne)
    s = 0.0
    h = 2e-3
    while alive.any() and s < 30.0:
        idx = np.nonzero(alive)[0]
        y = W._rk4((l[idx], n[idx], vl[idx], w[idx]), h)
        ln, nn, vln, wn = y
        nn = unit(nn)
        wn = wn - np.sum(wn * nn, -1, keepdims=True) * nn
        floor = (n[idx, 2] > 0) & (nn[:, 2] <= 0)
        E = W.embed(ln, nn)
        dmin[idx] = np.minimum(dmin[idx], np.linalg.norm(E - T[idx], axis=-1))
        s += h
        if s > 2.5:
            near_eye = np.linalg.norm(E - E0[idx], axis=-1) < 2.0
            if near_eye.any():
                back = max(back, s)
        l[idx], n[idx], vl[idx], w[idx] = ln, nn, vln, wn
        alive[idx[floor]] = False
        # far into a flat universe, going away: straight from there on, away from the shell
        gone = (np.abs(ln) > W.L + 3.0) & (np.sign(ln) * vln > 0)
        alive[idx[gone]] = False
    hit = dmin < reach
    bad = hit & outside_cone
    print('rays %d, meeting their toy %d, from outside its cone %d' % (m, hit.sum(), bad.sum()))
    # how close the rays outside the cones came, against the reach: the cone's slack
    out = outside_cone & np.isfinite(dmin)
    print('outside the cones: nearest approach / reach, the smallest: %.3f' % (dmin[out] / reach[out]).min())
    print('longest path back within 2 m of the eye: %.2f m (the argument needs < 8 m)' % back)
    ok = bad.sum() == 0 and back < 8.0
    print('ok' if ok else 'FAILED')
    sys.exit(0 if ok else 1)


if __name__ == '__main__':
    main()
