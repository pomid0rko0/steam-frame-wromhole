"""
Which toys a ray of the shell's pass can meet at all, before any search (wormhole_toys.gdshaderinc,
wht_near): the tests are exact bounds, so a toy they drop must never be met. Checked here against
wh.py's brute RK4 rays, each toy alone.

- The plane: a ray's whole path lies in span(e1, e2, the w axis); a toy farther than its reach from
  that subspace is never met.
- l: a toy's points lie within its reach (chord distance in R^4) of the meridian's points (r(l), w(l))
  only for l in a window (the chord distance is at least the distance in the (r, w) half-plane): the
  cylinder a segment, a fillet a quarter circle, so the window is analytic. A ray reaches the l on
  its way from the eye (or the shell's edge) on: away from the throat, or through it (impact
  parameter b <= rho0), all l beyond l0 in its direction; one that turns (b > rho0) only |l| >= its
  turning point's, on its side.
- The exit side: a toy of a flat universe is met after the shell only by a ray that leaves into it:
  one that turns or moves away from the throat leaves on the eye's side, one through the throat on
  the other.
- A toy near the eye (a hand, a toy held): the cone of directions around the geodesic's direction
  from the eye to its centre. The space's sectional curvature is at most K = 1 / rho0^2, so by the
  hinge comparison (CAT(K)) a geodesic leaving at an angle theta from that direction stays at least
  asin(sin(sqrt(K) d) sin(theta)) / sqrt(K) from the centre at geodesic distance d: it misses a toy
  of intrinsic radius delta (>= its chord radius: (2 / k) asin(k c / 2) for a curvature k of the
  space's geodesics in R^4 at most 1 / min(R, rho0)) when sin(theta) > sin(sqrt(K) delta) /
  sin(sqrt(K) d).

  python3 ref/cull.py [N]     random rays from eyes at the shell's edge, in the throat and outside:
                              for each toy, how many rays each test keeps, and that RK4 meets it
                              on none of the dropped ones
"""
import sys
import numpy as np
from wh import Wormhole


def lwindow(W, C, reach):
    """The l in [-L, L] whose meridian point is within reach of the toy's (r, w): (lo, hi), lo > hi
    for none (the hull of the cylinder's and the fillets' parts)."""
    rc, wc = np.linalg.norm(C[:3]), C[3]
    lo, hi = np.inf, -np.inf
    q = reach * reach - (rc - W.rho0) ** 2
    if q >= 0 and W.Lc > 0:
        a, b = max(wc - np.sqrt(q), -W.Lc), min(wc + np.sqrt(q), W.Lc)
        if a <= b:
            lo, hi = min(lo, a), max(hi, b)
    for s in (1.0, -1.0):
        O = np.array([W.rho0 + W.R, s * (W.h - W.R)])
        v = np.array([rc, wc]) - O
        rho = np.linalg.norm(v)
        if rho < 1e-12:
            continue
        thc = np.arctan2(s * v[1], -v[0])             # P(th) - O = R (-cos th, s sin th)
        c = (W.R ** 2 + rho ** 2 - reach ** 2) / (2 * W.R * rho)
        if c > 1:
            continue
        dl = np.arccos(max(c, -1.0))
        a, b = max(thc - dl, W.th0), min(thc + dl, 0.5 * np.pi)
        if a > b:
            continue
        la, lb = W.Lc + W.R * (a - W.th0), W.Lc + W.R * (b - W.th0)
        lo, hi = min(lo, s * la, s * lb), max(hi, s * la, s * lb)
    return lo, hi


def turn_l(W, b):
    """|l| of the turning point of a ray with impact parameter b in (rho0, Rout)"""
    th = np.arccos(np.clip(1.0 - (b - W.rho0) / W.R, -1.0, 1.0))
    return W.Lc + W.R * (th - W.th0)


def reaches(W, l0, vl, b, lo, hi):
    """Whether a ray from l0 in the shell (direction vl along l, impact parameter b) reaches some l
    of [lo, hi]; and the side it leaves the shell on"""
    s = 1.0 if l0 > 0 else -1.0
    sig = 1.0 if vl > 0 else -1.0
    if sig * l0 >= 0 or b <= W.rho0:
        # away from the throat, or through it: every l beyond l0 in its direction
        ok = (hi >= l0) if sig > 0 else (lo <= l0)
        return ok, sig
    lt = turn_l(W, b)
    ok = (hi >= lt) if s > 0 else (lo <= -lt)
    return ok, s


def geo(W, l, n, U, dist, h=2e-3):
    """the geodesic from (l, n) along the tangent U (unit, (U_l, u)) for dist: (l, n)"""
    steps = max(1, int(np.ceil(dist / h)))
    hh = dist / steps
    y = (np.array([l]), np.asarray(n, float)[None], np.array([U[0]]), np.asarray(U[1:], float)[None])
    for _ in range(steps):
        y = W._rk4(y, hh)
        nn = y[1] / np.linalg.norm(y[1], axis=-1, keepdims=True)
        y = (y[0], nn, y[2], y[3] - np.sum(y[3] * nn, -1, keepdims=True) * nn)
    return float(y[0][0]), y[1][0]


def project(W, l, n, D):
    rad = D[:3] @ n
    u = D[:3] - rad * n
    th = W.theta(abs(l))
    al = abs(l)
    dr = float(W.dr(np.array(l)))
    dw = 1.0 if al <= W.Lc else (0.0 if al >= W.L else np.cos(th))
    return np.r_[dr * rad + dw * D[3], u]


def toward(W, l, n, tl, tn):
    """the tangent at (l, n) whose geodesic, followed for its length, reaches (tl, tn)"""
    E = W.embed(np.array(l), np.asarray(n, float))
    T = W.embed(np.array(tl), np.asarray(tn, float))
    D = project(W, l, n, T - E)
    D = D / np.linalg.norm(D) * np.linalg.norm(T - E)
    for _ in range(3):
        el, en = geo(W, l, n, D / np.linalg.norm(D), np.linalg.norm(D))
        D = D + project(W, l, n, T - W.embed(np.array(el), en))
    return D


def cone(W, l, n, tl, tn, chord):
    """(unit direction, cos of the half angle) of the directions from (l, n) that can meet the toy
    of chord radius chord centred at (tl, tn)"""
    D = toward(W, l, n, tl, tn)
    d = np.linalg.norm(D)
    k = 1.0 / min(W.R, W.rho0)
    delta = 2.0 / k * np.arcsin(min(k * chord / 2.0, 1.0))
    sk = 1.0 / W.rho0
    if d <= delta:
        return D / max(d, 1e-12), -2.0
    s = np.sin(sk * delta) / np.sin(sk * min(d, 0.5 * np.pi / sk))
    return D / d, np.cos(min(np.arcsin(min(s, 1.0)) + 2e-3, np.pi))


def frame_at(W, l, n):
    n = np.asarray(n, float); n /= np.linalg.norm(n)
    tz = np.array([0, 0, 1.0]) - n * n[2]; tz /= np.linalg.norm(tz)
    return n, np.cross(tz, n), tz


def ln_of(W, C):
    """(l, n) of a point of the space given in R^4"""
    n = C[:3] / np.linalg.norm(C[:3])
    ls = np.linspace(-W.L - 3, W.L + 3, 200001)
    err = (W.r(ls) - np.linalg.norm(C[:3])) ** 2 + (W.w(ls) - C[3]) ** 2
    return float(ls[np.argmin(err)]), n


def scene(W, name, l0, nlook, fwd, toys, N, rng, near=()):
    """toys: ('ball', C, radius) / ('cube', C, axes, half); near: indices given a cone"""
    n0, ty, tz = frame_at(W, l0, nlook)
    F = np.asarray(fwd, float); F /= np.linalg.norm(F)
    # rays: directions within 60 degrees of fwd, in (U_l, u) at the eye
    dirs = []
    while len(dirs) < N:
        v = rng.normal(size=3); v /= np.linalg.norm(v)
        if v @ F > 0.5:
            dirs.append(v)
    dirs = np.array(dirs)
    vl = dirs[:, 0]
    w = dirs[:, 1:2] * ty + dirs[:, 2:3] * tz
    b = float(W.r(np.array(l0))) * np.linalg.norm(w, axis=1)
    Nrm = np.cross(np.broadcast_to(n0, w.shape), w)
    cones = {}
    for j in near:
        t = toys[j]
        tl, tn = ln_of(W, np.asarray(t[1], float))
        cones[j] = cone(W, l0, n0, tl, tn, t[2] if t[0] == 'ball' else 2 * t[3])
    bad = 0
    for j, t in enumerate(toys):
        C = np.asarray(t[1], float)
        reach = t[2] if t[0] == 'ball' else 2 * t[3]
        plane = (Nrm @ C[:3]) ** 2 <= reach * reach * np.sum(Nrm * Nrm, 1)
        lo, hi = lwindow(W, C, reach)
        side = 1.0 if C[3] > 0 else -1.0
        flat = abs(C[3] - side * W.h) < reach
        keep_l = np.zeros(N, bool)
        for i in range(N):
            ok, ex = reaches(W, l0, vl[i], b[i], lo, hi)
            keep_l[i] = ok or (flat and ex == side)
        keep = plane & keep_l
        if j in cones:
            u, cth = cones[j]
            keep &= (dirs[:, 0] * u[0] + w @ u[1:]) >= cth
        # RK4 on every ray against this toy alone: none it drops may meet it
        balls = [(C, t[2])] if t[0] == 'ball' else []
        cubes = [(C, np.asarray(t[2], float), t[3])] if t[0] == 'cube' else []
        res = W.brute(np.full(N, l0), np.broadcast_to(n0, (N, 3)).copy(), vl.copy(), w.copy(), h=2e-3,
                      balls=balls, cubes=cubes)
        hit = res['kind'] == 10
        # a flat toy is met after the shell: the exit side and its straight line
        if flat:
            for i in np.nonzero((res['kind'] == side) & ~hit)[0]:
                M = np.array([side, 1, 1])
                x = M * W.Rout * res['n'][i]
                d = M * (side * res['vl'][i] * res['n'][i] + res['w'][i])
                d /= np.linalg.norm(d)
                X = np.r_[M * x, side * W.h]
                Dd = np.r_[M * d, 0.0]
                if t[0] == 'ball':
                    oc = X - C; bq = oc @ Dd; cq = oc @ oc - t[2] ** 2
                    hit[i] = bq * bq - cq >= 0 and -bq + np.sqrt(max(bq * bq - cq, 0)) > 0
                else:
                    ax = np.asarray(t[2], float); lo_t, hi_t = 0.0, np.inf
                    for a in ax:
                        A, B = (X - C) @ a, Dd @ a
                        if abs(B) < 1e-12:
                            if abs(A) >= t[3]: lo_t = np.inf
                            continue
                        t0, t1 = sorted(((-t[3] - A) / B, (t[3] - A) / B))
                        lo_t, hi_t = max(lo_t, t0), min(hi_t, t1)
                    hit[i] = lo_t <= hi_t
        lost = hit & ~keep
        bad += int(lost.sum())
        print(f"{name}: toy {j} ({t[0]}{', cone' if j in cones else ''}): met by {hit.mean():.0%} of the rays; kept by the plane "
              f"{plane.mean():.0%}, + l and the exit side {(plane & keep_l).mean():.0%}, all {keep.mean():.0%}; dropped but met: {lost.sum()}",
              flush=True)
    return bad


def ball_at(W, l, n, rad):
    n = np.asarray(n, float); n /= np.linalg.norm(n)
    return ('ball', W.embed(np.array(l), n), rad)


def cube_at(W, l, n, half, yaw, tilt):
    n = np.asarray(n, float); n /= np.linalg.norm(n)
    el = W.embed(np.array(l + 1e-6), n) - W.embed(np.array(l - 1e-6), n); el /= np.linalg.norm(el)
    tz = np.array([0, 0, 1.0]) - n * n[2]; tz /= np.linalg.norm(tz)
    ty = np.cross(tz, n)
    T = np.array([el, np.r_[ty, 0.0], np.r_[tz, 0.0]])
    cy, sy, ct, st = np.cos(yaw), np.sin(yaw), np.cos(tilt), np.sin(tilt)
    Rm = np.array([[cy, -sy, 0], [sy, cy, 0], [0, 0, 1]]) @ np.array([[1, 0, 0], [0, ct, -st], [0, st, ct]])
    ax = Rm.T @ T
    nrm = np.linalg.svd(ax)[2][-1]
    return ('cube', W.embed(np.array(l), n), np.vstack([ax, nrm]), half)


if __name__ == '__main__':
    W = Wormhole(3.0, 5.0, 1.0)
    N = int(sys.argv[1]) if len(sys.argv) > 1 else 300
    rng = np.random.default_rng(3)
    nb = 0
    # at the shell's edge, a ball held 0.5 m ahead and a hand, the throat's ball and cube, toys of A
    l0 = 5.0
    n0 = np.array([1.0, 0.0, 1.6 / 3.5]); n0 /= np.linalg.norm(n0)
    _, ty, tz = frame_at(W, l0, n0)
    held = ball_at(W, l0 - 0.45, n0 - 0.1 * tz, 0.25)
    hand = ball_at(W, l0 - 0.3, n0 + 0.06 * ty - 0.1 * tz, 0.04)
    throat_ball = ball_at(W, 0.0, [1.0, 0.0, 0.117], 0.35)
    throat_cube = cube_at(W, 0.8, [0.9, -0.43, 0.1], 0.3, 0.3, 0.2)
    flat_a = ball_at(W, W.L + 2.0, [1.0, 0.1, 0.06], 0.35)
    edge = cube_at(W, W.L - 0.1, [1.0, -0.45, 0.05], 0.3, 0.4, 0.1)
    toys = [held, hand, throat_ball, throat_cube, flat_a, edge]
    nb += scene(W, 'edge, toward the throat', l0, n0, [-1.0, 0.0, -0.3], toys, N, rng, near=(0, 1))
    nb += scene(W, 'edge, sideways', l0, n0, [0.0, 1.0, -0.2], toys, N, rng, near=(0, 1))
    nb += scene(W, 'edge, away', l0, n0, [1.0, 0.0, -0.2], toys, N, rng, near=(0, 1))
    # in the throat, with the throat's toys and a held ball
    l1 = 0.3
    n1 = np.array([1.0, 0.0, 0.5]); n1 /= np.linalg.norm(n1)
    _, ty1, tz1 = frame_at(W, l1, n1)
    held1 = ball_at(W, l1 - 0.4, n1 + 0.05 * ty1 - 0.08 * tz1, 0.25)
    nb += scene(W, 'throat, sideways', l1, n1, [0.0, 1.0, -0.2], [held1, throat_ball, throat_cube, flat_a], N, rng, near=(0,))
    nb += scene(W, 'throat, along', l1, n1, [-1.0, 0.1, -0.2], [held1, throat_ball, throat_cube, flat_a], N, rng, near=(0,))
    # cones for toys a few metres off: the throat's ball and cube from along the cylinder and the fillet
    l2 = 2.5
    n2 = np.array([1.0, 0.0, 0.45]); n2 /= np.linalg.norm(n2)
    nb += scene(W, 'cylinder, toward the throat\'s toys', l2, n2, [-1.0, 0.0, -0.3], [throat_ball, throat_cube, flat_a], N, rng, near=(0, 1))
    nb += scene(W, 'fillet, toward the throat\'s toys', 4.3, n2, [-1.0, 0.0, -0.3], [throat_ball, throat_cube], N, rng, near=(0, 1))
    print('met but dropped, in all:', nb)
    sys.exit(1 if nb else 0)
