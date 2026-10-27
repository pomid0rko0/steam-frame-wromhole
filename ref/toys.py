"""
The toys' search in the curved region, as the shader does it (godot/shaders/wormhole_toys.gdshaderinc,
wht_point, wht_accel and wht_march), in float64: the reference for it, and its step counts.

A ray in the shell (wh.py's fast(): pieces A, a fillet inward; B, the cylinder; C, a fillet outward)
lies in the subspace span(e1, e2, e_w) of R^4. Its point at the fraction sg of a piece, Q = (r cos psi,
r sin psi, w) in that subspace, and dQ/dsg are exact (the product integration's), and so is its
acceleration A (II(T, T) nu). One march along the path for all the ray's toys: at each point every toy
still in it gives the longest step that cannot pass its entry, and the march takes the shortest. A
toy is met only in its angular window (psi grows along the path, by less than pi in the shell): the
march starts at the first piece any window reaches, and a toy is dropped once past it. A ball's step:
the first root of a lower bound of F = |P - C|^2 - radius^2 from its exact first and second derivatives
and a bound on the change of A (j3); a cube's: certified steps on its four slabs (a slab's signed
distance h has |h''| <= k along the path).

  python3 ref/toys.py [N]     random rays near toys at the shell's edge, in the throat, grazing,
                              against wh.py's brute RK4: mismatches, hit errors, steps
"""
import sys
import numpy as np
from wh import Wormhole, _any_perp

ITER = 24        # the shader's WHT_ITER


class Ray:
    """wh_ray: a ray in the shell from (l_s, n_s) with direction (vl, w)"""

    def __init__(self, W, l_s, n_s, vl, w):
        self.W = W
        rho0, R, Lc, L = W.rho0, W.R, W.Lc, W.L
        wn = min(np.linalg.norm(w), 1.0)
        als = abs(l_s)
        rs = float(W.r(l_s))
        b = rs * wn
        self.b = b
        self.e1 = np.asarray(n_s, float)
        self.e2 = w / np.linalg.norm(w) if np.linalg.norm(w) > 1e-12 else _any_perp(n_s)
        turn = b > W.rmin
        f = W.fil(b, turn)
        self.f = f
        from_edge = als >= L * (1 - 1e-12)
        ths = W.th0 + max(als - Lc, 0.0) / R
        eyey = 2 * R * np.sin((ths + W.th0) / 2) * np.sin((ths - W.th0) / 2)
        ts = rs * vl * vl / (1 + wn) if turn else eyey
        ts = 1.0 if from_edge else min(max(ts / f['span'], 0.0), 1.0)
        self.ts = ts
        self.start = (l_s, vl, wn)
        self.zs = W.fil_z(f, ts)
        Ss = np.array(W.fil_at(f, self.zs)[:2])
        d = 1.0 if vl >= 0 else -1.0
        x = l_s * d
        sideS = 1.0 if l_s > 0 else -1.0
        self.d = d
        self.hasA = vl * sideS < 0 if turn else x < -Lc
        self.hasB = (not turn) and Lc > 0 and x < Lc
        self.cFromStart = (not self.hasA) if turn else x > Lc
        self.sideA = sideS if turn else -d
        self.sideC = sideS if turn else d
        self.x0B = max(x, -Lc)
        self.DB = Lc - self.x0B if self.hasB else 0.0
        omb = rs * vl * vl / (1 + wn) - (R if from_edge else eyey)
        self.ivlc = rho0 / np.sqrt(max(omb * (rho0 + b), 1e-14 * rho0 * rho0))
        self.kc = b / rho0 / rho0 * self.ivlc
        self.PA = Ss if self.hasA else np.zeros(2)
        self.PB = np.array([self.kc, self.ivlc]) * self.DB
        self.C0 = Ss if self.cFromStart else np.zeros(2)
        self.tot = self.PA + self.PB + np.array([f['psi'], f['arc']]) - self.C0
        e1, e2 = self.e1, self.e2
        self.floorHit = e1[2] > 0 and (self.tot[0] >= np.pi or e1[2] * np.cos(self.tot[0]) + e2[2] * np.sin(self.tot[0]) < 0)
        self.psiEnd = np.arctan2(e1[2], -e2[2]) if self.floorHit else self.tot[0]

    def point(self, p, sg):
        """wht_point: Q, dQ/dsg, psi, dpsi/dsg"""
        W, f = self.W, self.f
        rho0, R = W.rho0, W.R
        if p == 1:
            psi = self.PA[0] + self.PB[0] * sg
            dpsi = self.PB[0]
            r, dr = rho0, 0.0
            w, dw = self.d * (self.x0B + self.DB * sg), self.d * self.DB
        else:
            pA = p == 0
            z0 = self.zs if (pA or self.cFromStart) else f['zlo']
            dz = (f['zlo'] if pA else f['zhi']) - z0
            z = z0 + dz * sg
            t, m = W.fil_mom(f, z)
            if f['reg'] == 0:
                Es = f['E0'] * np.exp(z)
                sm = 0.5 * (Es - (f['mx'] - f['mn']) / Es)
                so = Es - sm
                dtz = 2 * sm * so
                H = so if f['al'] <= f['ga'] else sm
            else:
                dtz = 2 * z
                H = 1.0 if f['al'] <= f['ga'] else z / np.sqrt(t + f['al'])
            pin = f['e'] @ m
            dpin = np.polyval(f['e'][::-1], t) * (z if f['reg'] == 2 else 1.0) * dz
            psi = self.PA[0] - pin if pA else self.PA[0] + self.PB[0] - self.C0[0] + pin
            dpsi = -dpin if pA else dpin
            r = f['ra'] + f['span'] * t
            dr = f['span'] * dtz * dz
            X = r - rho0
            q = 2 * R - X
            side = self.sideA if pA else self.sideC
            w = side * (W.h - R + np.sqrt(max(X * q, 0.0)))
            dw = side * 2 * (R - X) * np.sqrt(f['span']) * H / np.sqrt(q) * dz
        c, s = np.cos(psi), np.sin(psi)
        return np.array([r * c, r * s, w]), np.array([dr * c - r * dpsi * s, dr * s + r * dpsi * c, dw]), psi, dpsi

    def kmax(self, p):
        """the path's largest curvature in R^4 on piece p: on a fillet 1 / min(R, rho0) (its profile's
        1 / R, or a parallel's cos th / r <= 1 / rho0), on the cylinder its helix's b^2 / rho0^3"""
        W = self.W
        return self.b * self.b / W.rho0 ** 3 if p == 1 else 1.0 / min(W.R, W.rho0)


def accel(ray, p, Q, psi):
    """wht_accel: the path's acceleration in R^4 (the ray's subspace) at its point Q on piece p, angle psi"""
    W = ray.W
    b = ray.b
    r = np.hypot(Q[0], Q[1])
    c, s = np.cos(psi), np.sin(psi)
    br = b / r
    if p == 1:
        return -(br * br / r) * np.array([c, s, 0.0])
    X = r - W.rho0
    cth = 1.0 - X / W.R
    sth = np.sqrt(max(X * (2 * W.R - X), 0.0)) / W.R
    side = ray.sideA if p == 0 else ray.sideC
    II = (1.0 - br * br) / W.R - cth / r * br * br
    return II * np.array([cth * c, cth * s, -side * sth])


def jmax(W, p, b):
    """a bound on |A'| along piece p (the shader's j3)"""
    k = 1.0 / min(W.R, W.rho0)
    if p == 1:
        return (b * b / W.rho0 ** 3) * b / W.rho0 ** 2
    return k * k + 1.155 * (1.0 / (W.R * W.rho0) + 1.0 / W.rho0 ** 2)


def _geom(ray, toy):
    isCube = toy[0] == 'cube'
    C = np.asarray(toy[1], float)
    size = toy[3] if isCube else toy[2]
    reach = 2 * size if isCube else size
    cb = np.array([C[:3] @ ray.e1, C[:3] @ ray.e2, C[3]])
    rho2 = cb[0] ** 2 + cb[1] ** 2
    perp2 = max(C[:3] @ C[:3] - rho2, 0.0)
    return isCube, C, size, reach, cb, perp2, reach * reach - perp2, rho2


def march(ray, toys, psiEnd, stats=None):
    """wht_march: (hitK, the index of the toy met first) along the ray in the shell, or None"""
    W = ray.W
    st = stats if stats is not None else {}
    live = []
    lo = 10.0
    for j, toy in enumerate(toys):
        isCube, C, size, reach, cb, perp2, re2, rho2 = _geom(ray, toy)
        psc = np.arctan2(cb[1], cb[0])
        if psc < -0.5 * np.pi:
            psc += 2 * np.pi
        dps = np.arcsin(np.sqrt(re2 / rho2)) if 0 < re2 < rho2 else 10.0
        if re2 <= 0 or psc + dps < 0 or psc - dps > psiEnd:
            continue
        live.append(j)
        lo = min(lo, psc - dps)
    if not live:
        return None
    st['cand'] = st.get('cand', 0) + len(live)
    p0 = 0 if ray.hasA else (1 if ray.hasB else 2)
    p = p0
    if p == 0 and lo > ray.PA[0]:
        p = 1 if ray.hasB else 2
    if p == 1 and lo > ray.PA[0] + ray.PB[0]:
        p = 2
    start = p == p0
    sg, sgo = 0.0, -1.0
    f = ray.f
    if start:
        # the ray's start: no point of the path to work out
        l_s, vl_s, wn = ray.start
        r_s = float(W.r(np.array(l_s)))
        w_s = float(W.w(np.array(l_s)))
        als = abs(l_s)
        ths = W.th0 + max(min(als, W.L) - W.Lc, 0.0) / W.R
        sg_ = 1.0 if l_s > 0 else -1.0
        dr, dw = (0.0, 1.0) if als <= W.Lc else (sg_ * np.sin(ths), np.cos(ths))
        Q = np.array([r_s, 0.0, w_s])
        T = np.array([vl_s * dr, wn, vl_s * dw])
        A = accel(ray, p, Q, 0.0)
        psi = 0.0
        if p == 1:
            speed = np.hypot(W.rho0 * ray.PB[0], ray.DB)
        else:
            poly = np.polyval(f['e'][::-1], ray.ts) * (ray.zs if f['reg'] == 2 else 1.0)
            speed = r_s * r_s / ray.b * abs(poly * ((f['zlo'] if p == 0 else f['zhi']) - ray.zs))
    have = start
    kf = 1.0 / min(W.R, W.rho0)
    for it in range(ITER):
        if not have:
            Q, dQ, psi, dpsi = ray.point(p, sg)
            st['ev'] = st.get('ev', 0) + 1
            speed = max(np.sqrt(dQ @ dQ), 1e-30)
            T = dQ / speed
            A = accel(ray, p, Q, psi)
        have = False
        st['it_max'] = max(st.get('it_max', 0), it + 1)
        if psi > psiEnd:
            return None
        kp = ray.kmax(p)
        j3 = jmax(W, p, ray.b)
        step = 1e9
        keep = []
        for j in live:
            isCube, C, size, reach, cb, perp2, re2, rho2 = _geom(ray, toys[j])
            D = Q - cb
            D2 = D @ D + perp2
            cr = cb[0] * Q[1] - cb[1] * Q[0]
            if re2 < rho2 and cr > 0 and cr * np.sqrt(rho2 - re2) > (cb[:2] @ Q[:2]) * np.sqrt(re2):
                continue                          # past its shadow
            if not isCube:
                F = D2 - reach * reach
                Fs = 2 * D @ T
                if F <= 0:
                    if start:
                        continue                  # the eye in it: not seen from inside
                    nx = sg - F / (Fs * speed) if Fs < 0 else sg
                    return 2 * (p - 1) + (nx if sgo < 0 else max(nx, sgo)), j
                Dn = np.sqrt(D2)
                if Dn * kp < 0.9:
                    if Fs >= 0:
                        continue                  # past the closest approach
                    S = min(0.9 / kp - Dn, -3.0 * F / Fs)
                    m = 2.0 * (1.0 + D @ A) - 2.0 * (Dn + S) * (j3 * S / 3.0 + 0.02 * kp)
                    disc = Fs * Fs - 2.0 * m * F
                    r1 = 2.0 * F / (-Fs + np.sqrt(max(disc, 0.0)))
                    root = disc >= 0 and r1 <= S
                    ds = r1 if root else S
                    if root and r1 < 1e-4:
                        return 2 * (p - 1) + sg + r1 / speed, j
                else:
                    ds = 0.8 * (Dn - reach)
                    st['far'] = st.get('far', 0) + 1
            else:
                ax = np.asarray(toys[j][2], float)
                P4 = np.r_[Q[0] * ray.e1 + Q[1] * ray.e2, Q[2]]
                dP4 = np.r_[T[0] * ray.e1 + T[1] * ray.e2, T[2]]
                h = ax @ (P4 - C)
                g = ax @ dP4
                e = np.abs(h) - size
                if np.all(e <= 0):
                    if start:
                        continue
                    return 2 * (p - 1) + sg, j
                if D2 > reach * reach and D @ T > 0:
                    continue
                v = -np.sign(h) * g
                ds = max(2 * ek / (vk + np.sqrt(vk * vk + 2 * kp * ek)) for ek, vk in zip(e, v) if ek > 0)
                if ds < 1e-6:
                    return 2 * (p - 1) + sg, j
            keep.append(j)
            step = min(step, ds)
        live = keep
        if not live:
            return None
        start = False
        sgo = sg
        nsg = sg + step / speed
        if nsg >= 1.0:
            if p == 2:
                return None
            p = 1 if (p == 0 and ray.hasB) else 2
            nsg, sgo = 0.0, -1.0
        sg = nsg
    st['maxit'] = st.get('maxit', 0) + 1
    return None


def key_point(ray, key):
    p = min(int(np.floor(0.5 * key)) + 1, 2)
    Q = ray.point(p, key - 2 * (p - 1))[0]
    return np.r_[Q[0] * ray.e1 + Q[1] * ray.e2, Q[2]]


def first_hit(W, ray_state, toys, stats=None):
    """index of the toy the ray meets first in the shell, and its hit (R^4), or (-1, None)"""
    ray = Ray(W, *ray_state)
    ev0 = stats.get('ev', 0) if stats is not None else 0
    r = march(ray, toys, ray.psiEnd, stats)
    if stats is not None:
        stats.setdefault('per_ray', []).append(stats.get('ev', 0) - ev0)
    if r is None:
        return -1, None, ray
    return r[1], key_point(ray, r[0]), ray


# ---------------------------------------------------------------- test scenes
def _frame_at(W, l, n):
    n = np.asarray(n, float); n /= np.linalg.norm(n)
    tz = np.array([0, 0, 1.0]) - n * n[2]; tz /= np.linalg.norm(tz)
    return n, np.cross(tz, n), tz


def ball(W, l, n, rad):
    n = np.asarray(n, float); n /= np.linalg.norm(n)
    return ('ball', np.r_[W.r(np.array(l)) * n, W.w(np.array(l))], rad)


def cube(W, l, n, half, yaw, tilt):
    """a cube at (l, n) turned by yaw and tilt against the floor's frame there"""
    n = np.asarray(n, float); n /= np.linalg.norm(n)
    el = W.embed(np.array(l + 1e-6), n) - W.embed(np.array(l - 1e-6), n); el /= np.linalg.norm(el)
    tz = np.array([0, 0, 1.0]) - n * n[2]; tz /= np.linalg.norm(tz)
    ty = np.cross(tz, n)
    T = np.array([el, np.r_[ty, 0.0], np.r_[tz, 0.0]])
    cy, sy, ct, st = np.cos(yaw), np.sin(yaw), np.cos(tilt), np.sin(tilt)
    Rm = np.array([[cy, -sy, 0], [sy, cy, 0], [0, 0, 1]]) @ np.array([[1, 0, 0], [0, ct, -st], [0, st, ct]])
    ax = Rm.T @ T
    return ('cube', W.embed(np.array(l), n), np.vstack([ax, np.linalg.svd(ax)[2][-1]]), half)


def rays_from(W, l0, n0, fwd, fov, N, rng):
    n0, ty, tz = _frame_at(W, l0, n0)
    F = np.asarray(fwd, float); F /= np.linalg.norm(F)
    out = []
    while len(out) < N:
        v = rng.normal(size=3); v /= np.linalg.norm(v)
        if v @ F >= np.cos(np.radians(fov)):
            out.append((l0, n0, v[0], v[1] * ty + v[2] * tz))
    return out


def grazing(W, N, rng, amax=0.35):
    """entering at the shell's edge nearly along it (b close to Rout), all round"""
    out = []
    while len(out) < N:
        n = rng.normal(size=3); n /= np.linalg.norm(n)
        if n[2] < 0.02:
            continue
        t = rng.normal(size=3); t -= (t @ n) * n; t /= np.linalg.norm(t)
        a = rng.uniform(0.0, amax)
        out.append((W.L, n, -np.sin(a), np.cos(a) * t))
    return out


def check(W, name, rays, toys):
    st = {}
    mine = [first_hit(W, r, toys, st) for r in rays]
    balls = [(t[1], t[2]) for t in toys if t[0] == 'ball']
    cubes = [(t[1], t[2], t[3]) for t in toys if t[0] == 'cube']
    order = [j for j, t in enumerate(toys) if t[0] == 'ball'] + [j for j, t in enumerate(toys) if t[0] == 'cube']
    ref = W.brute(np.array([r[0] for r in rays]), np.array([r[1] for r in rays]), np.array([r[2] for r in rays]),
                  np.array([r[3] for r in rays]), h=1e-3, balls=balls, cubes=cubes)
    bad, errs = [], []
    for k, (hj, P, ray) in enumerate(mine):
        rk = ref['kind'][k]
        rj = order[rk - 10] if rk >= 10 else -1
        if rj != hj:
            bad.append(k)
            continue
        if hj >= 0:
            errs.append(np.linalg.norm(P - W.embed(np.array(ref['l'][k]), ref['n'][k])))
    n = len(rays)
    print(f"{name}: {n} rays, {sum(1 for m in mine if m[0] >= 0)} hits, mismatch {len(bad)}, hit error max "
          f"{max(errs) if errs else 0:.1e} m | toys searched {st.get('cand', 0)}, points per searched toy "
          f"{st.get('ev', 0) / max(st.get('cand', 1), 1):.2f}, most points {st.get('it_max', 0)}, "
          f"out of steps {st.get('maxit', 0)}; points per ray mean {np.mean(st['per_ray']):.2f}, 90% "
          f"{np.percentile(st['per_ray'], 90):.0f}, 99% {np.percentile(st['per_ray'], 99):.0f}", flush=True)
    return bad


if __name__ == '__main__':
    W = Wormhole(3.0, 5.0, 1.0)
    N = int(sys.argv[1]) if len(sys.argv) > 1 else 600
    rng = np.random.default_rng(1)
    L = W.L
    l0 = 5.0
    n0, ty, tz = _frame_at(W, l0, [1.0, 0.0, 1.6 / 3.5])
    nbad = 0
    nbad += len(check(W, 'held ball at the edge', rays_from(W, l0, n0, [-1.0, 0.0, -0.3], 50, N, rng),
                      [ball(W, l0 - 0.38, n0 - 0.12 * tz, 0.25)]))
    nbad += len(check(W, 'held cube at the edge', rays_from(W, l0, n0, [-1.0, 0.0, -0.3], 50, N, rng),
                      [cube(W, l0 - 0.4, n0 - 0.12 * tz, 0.15, 0.3, 0.4)]))
    nbad += len(check(W, 'toys at the edge', rays_from(W, l0, n0, [-1.0, 0.0, -0.3], 50, N, rng),
                      [ball(W, 4.8, [1, 0.3, 0.09], 0.3), ball(W, 0.0, [1, 0.0, 0.12], 0.35),
                       cube(W, 4.6, [1, 0.3, 0.12], 0.3, 0.4, 0.3), cube(W, 0.0, [1, -0.1, 0.12], 0.3, 0.2, 0.5)]))
    nbad += len(check(W, 'throat, sideways', rays_from(W, 0.0, [1.0, 0, 0.5], [0, 1.0, -0.1], 60, N, rng),
                      [ball(W, 0.0, [1, 0.0, 0.12], 0.35), cube(W, 1.0, [0.5, 1.0, 0.12], 0.25, 0.7, 0.1)]))
    nbad += len(check(W, 'through the edge to the throat', rays_from(W, L, [1.0, 0.05, 0.3], [-1.0, 0.1, -0.1], 60, N, rng),
                      [ball(W, 5.2, [1, 0.25, 0.08], 0.3), cube(W, 0.8, [1, -0.45, 0.1], 0.3, 0.0, 0.0),
                       cube(W, 0.0, [1, 0.0, 0.12], 0.3, 0.2, 0.5)]))
    nbad += len(check(W, 'grazing the edge', grazing(W, N, rng),
                      [ball(W, L - 0.15, [1, 0.2, 0.1], 0.35), cube(W, L - 0.2, [0.7, -0.7, 0.1], 0.3, 0.3, 0.2),
                       cube(W, L - 0.5, [-0.5, -1, 0.12], 0.25, 0.7, 0.4)]))
    print('mismatches in all:', nbad)
    sys.exit(1 if nbad else 0)
