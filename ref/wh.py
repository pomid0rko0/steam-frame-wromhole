"""
Reference math for the wormhole renderer (float64, NumPy).

Geometry (optozorax's SDF construction, generalised):
    world = surface of  union_round(min(plane(w=-h), plane(w=+h)), extrude_w(sphere(rho0), h), R)
in R^4. It is SO(3)-symmetric, so its induced metric is exactly
    ds^2 = dl^2 + r(l)^2 dOmega^2
with the profile (l = arc length along the (rho, w) profile curve from the middle):
    cylinder  |l| <= Lc               r = rho0
    fillet    Lc <= |l| <= L          r = rho0 + R (1 - cos th),  th = th0 + (|l| - Lc)/R
    flat      |l| >= L                r = |l| - L + Rout
    Lc = max(h - R, 0),  th0 = asin(max(1 - h/R, 0)),  L = Lc + R (pi/2 - th0),  Rout = rho0 + R
For h < R the two fillets meet at a crease (r'(0+-) = +-sin th0): no cylinder, no photon sphere.
Static spacetime -dt^2 + ds^2 (Morris-Thorne, zero redshift): light = geodesics of ds^2.

Point on the manifold: (l, n), n a unit 3-vector. Tangent: (vl, w), w orthogonal to n.
Flat charts: side A (l >= L): x = r n;  side B (l <= -L): x = P r n,  P = diag(-1, 1, 1).
"""
import numpy as np


class Wormhole:
    def __init__(self, rho0=0.3, h=0.5, R=0.1):
        self.rho0, self.h, self.R = rho0, h, R
        self.Lc = max(h - R, 0.0)
        self.th0 = float(np.arcsin(max(1.0 - h / R, 0.0)))
        self.s0 = np.sin(self.th0 / 2)
        self.s1 = np.sqrt(0.5)
        self.L = self.Lc + R * (np.pi / 2 - self.th0)
        self.rmin = rho0 + 2 * R * self.s0 ** 2
        self.Rout = rho0 + R

    # ---------- profile ----------
    def theta(self, al):
        return self.th0 + (np.clip(al, self.Lc, self.L) - self.Lc) / self.R

    def r(self, l):
        al = np.abs(l)
        inner = self.rho0 + self.R * (1 - np.cos(self.theta(al)))
        return np.where(al <= self.L, inner, al - self.L + self.Rout)

    def w(self, l):
        """4th embedding coordinate of the profile curve (odd in l)."""
        al = np.abs(l)
        th = self.theta(al)
        inner = np.where(al <= self.Lc, al, self.h - self.R + self.R * np.sin(th))
        return np.sign(l) * np.where(al <= self.L, inner, self.h)

    def embed(self, l, n):
        """Point of the hypersurface in R^4: (r n, w(l))."""
        return np.concatenate([self.r(l)[..., None] * n, self.w(l)[..., None]], -1)

    def dr(self, l):
        al = np.abs(l)
        return np.sign(l) * np.where(al <= self.L, np.sin(self.theta(al)), 1.0)

    # ---------- brute force: full 3D geodesic ODE ----------
    def geo_rhs(self, l, n, vl, w):
        r = self.r(l)[..., None]
        dr = self.dr(l)[..., None]
        ww = np.sum(w * w, -1, keepdims=True)
        return vl, w / r, (dr / r)[..., 0] * ww[..., 0], -(dr / r) * vl[..., None] * w - (ww / r) * n

    def _rk4(self, y, h):
        def add(y, k, c):
            return tuple(yi + c * ki for yi, ki in zip(y, k))
        k1 = self.geo_rhs(*y)
        k2 = self.geo_rhs(*add(y, k1, h / 2))
        k3 = self.geo_rhs(*add(y, k2, h / 2))
        k4 = self.geo_rhs(*add(y, k3, h))
        return tuple(yi + h / 6 * (a1 + 2 * a2 + 2 * a3 + a4)
                     for yi, a1, a2, a3, a4 in zip(y, k1, k2, k3, k4))

    def brute(self, l, n, vl, w, h=1e-3, smax=200.0, balls=()):
        """Integrate until the ray leaves the curved shell (|l| >= L moving outward)
        or crosses the floor n_z = 0 from above, or enters a ball (centre in R^4, radius):
        the ball is the set of points whose chord distance in R^4 to the centre is < radius.
        kind: +1/-1 exit side, 2 floor, 10 + j ball j, 0 unfinished."""
        balls = [(np.asarray(c, float), float(rad)) for c, rad in balls]
        l, n, vl, w = l.copy(), n.copy(), vl.copy(), w.copy()
        m = l.shape[0]
        alive = np.ones(m, bool)
        out = dict(kind=np.zeros(m, int), l=np.zeros(m), n=np.zeros((m, 3)),
                   vl=np.zeros(m), w=np.zeros((m, 3)))
        s = 0.0
        while alive.any() and s < smax:
            idx = np.nonzero(alive)[0]
            y = (l[idx], n[idx], vl[idx], w[idx])
            ln, nn, vln, wn = self._rk4(y, h)
            nn = nn / np.linalg.norm(nn, axis=-1, keepdims=True)
            wn = wn - np.sum(wn * nn, -1, keepdims=True) * nn
            floor = (y[1][:, 2] > 0) & (nn[:, 2] <= 0)
            leave = (np.abs(ln) >= self.L) & (np.sign(ln) * vln > 0)
            ev = floor | leave
            enter = np.full(len(idx), -1)
            if balls:
                Eo, En = self.embed(y[0], y[1]), self.embed(ln, nn)
                for jb, (c, rad) in enumerate(balls):
                    e = (np.sum((Eo - c) ** 2, -1) >= rad * rad) & (np.sum((En - c) ** 2, -1) < rad * rad) & (enter < 0)
                    enter[e] = jb
                ev = ev | (enter >= 0)
            if self.th0 > 0:
                # h < R: r'(l) jumps at the crease l = 0. Land exactly on it so that no
                # RK4 step straddles the kink (keeps the reference 4th order).
                for j in np.nonzero(~ev & (np.sign(y[0]) * np.sign(ln) < 0))[0]:
                    yy = tuple(v[j:j + 1] for v in y)
                    lo, hi = 0.0, h
                    for _ in range(60):
                        mid = 0.5 * (lo + hi)
                        lo, hi = (lo, mid) if np.sign(self._rk4(yy, mid)[0][0]) != np.sign(yy[0][0]) else (mid, hi)
                    ym = self._rk4(yy, hi)
                    ln[j], nn[j], vln[j], wn[j] = ym[0][0], ym[1][0] / np.linalg.norm(ym[1][0]), ym[2][0], ym[3][0]
            for j in np.nonzero(ev)[0]:
                yy = tuple(v[j:j + 1] for v in y)
                # earliest of the events in this step
                cands = []
                if floor[j]:
                    cands.append(('floor', lambda ym: ym[1][0, 2] <= 0))
                if leave[j]:
                    cands.append(('leave', lambda ym: abs(ym[0][0]) >= self.L))
                for jb, (c, rad) in enumerate(balls):
                    if np.sum((self.embed(ln[j:j + 1], nn[j:j + 1])[0] - c) ** 2) < rad * rad and \
                            np.sum((self.embed(yy[0], yy[1])[0] - c) ** 2) >= rad * rad:
                        cands.append((10 + jb, lambda ym, c=c, rad=rad: np.sum((self.embed(ym[0], ym[1] / np.linalg.norm(ym[1]))[0] - c) ** 2) < rad * rad))
                best = None
                for tag, test in cands:
                    lo, hi = 0.0, h
                    for _ in range(50):
                        mid = 0.5 * (lo + hi)
                        lo, hi = (lo, mid) if test(self._rk4(yy, mid)) else (mid, hi)
                    if best is None or hi < best[1]:
                        best = (tag, hi)
                tag, hi = best
                ym = self._rk4(yy, hi)
                g = idx[j]
                out['kind'][g] = 2 if tag == 'floor' else (tag if isinstance(tag, int) else (1 if ym[0][0] > 0 else -1))
                out['l'][g] = ym[0][0]
                out['n'][g] = ym[1][0] / np.linalg.norm(ym[1][0])
                out['vl'][g] = ym[2][0]
                out['w'][g] = ym[3][0]
            alive[idx[ev]] = False
            keep = ~ev
            l[idx[keep]], n[idx[keep]], vl[idx[keep]], w[idx[keep]] = (
                ln[keep], nn[keep], vln[keep], wn[keep])
            s += h
        return out

    # ---------- fast method: one ray at a time, mirrors the shader ----------
    def fast(self, l_s, n_s, vl, w, hmax=1.5, nmax=48):
        """Angle in the orbit plane:  dpsi = b dl / (r sqrt(r^2 - b^2)).
        Cylinder: closed form. Fillet: s = sin(th/2), r = rho0 + 2R s^2, r - b = 2R (s^2 - sig),
        sig = (b - rho0)/(2R); s = q sinh v (sig < 0) or s = q cosh v (sig > 0) gives
        dpsi/dv = b sqrt(2R) / (r sqrt((1 - s^2)(r + b)))  -- smooth, no endpoint singularity,
        integrated with 4-point Gauss-Legendre panels of at most hmax in v. A floor crossing in a
        panel: on the integral of the cubic through the panel's nodes, then one Newton step."""
        rho0, R, Lc, L, s0, s1 = self.rho0, self.R, self.Lc, self.L, self.s0, self.s1
        wn = np.linalg.norm(w)
        b = float(self.r(l_s)) * wn
        e1 = n_s
        e2 = w / wn if wn > 1e-12 else _any_perp(n_s)
        sig = (b - rho0) / (2 * R)
        hyp = sig <= 0                      # sinh branch
        q = np.sqrt(max(-sig, 1e-12)) if hyp else np.sqrt(sig)

        def S(v):
            return q * np.sinh(v) if hyp else q * np.cosh(v)

        def V(s):
            return np.arcsinh(s / q) if hyp else np.arccosh(max(s / q, 1.0))

        def g(v):
            s = S(v)
            r = rho0 + 2 * R * s * s
            return b * np.sqrt(2 * R) / (r * np.sqrt((1 - s * s) * (r + b)))

        def s_of(al):
            return np.sin(self.theta(al) / 2)

        def l_of(v, side):
            return side * (Lc + R * (2 * np.arcsin(min(S(v), 1.0)) - self.th0))

        pieces = []                         # ('f', side, va, vb) | ('c', dir, la, lb) oriented coords
        if b <= self.rmin:                  # passes the throat: l monotonic towards sign(vl) * L
            d = 1.0 if vl >= 0 else -1.0
            x = l_s * d
            if x < -Lc:
                pieces.append(('f', -d, V(s_of(abs(l_s))), V(s0)))
            if Lc > 0 and x < Lc:
                pieces.append(('c', d, max(x, -Lc), Lc))
            pieces.append(('f', d, V(s_of(abs(l_s)) if x > Lc else s0), V(s1)))
            side_out = d
        else:                               # turns around inside the fillet on its own side
            side = 1.0 if l_s > 0 else -1.0
            vs = V(s_of(abs(l_s)))
            pieces.append(('f', side, -vs if vl * side < 0 else vs, V(s1)))
            side_out = side

        above = n_s[2] > 0
        psi_f = np.mod(np.arctan2(e2[2], e1[2]) + np.pi / 2, np.pi)
        psi = 0.0
        steps = 0
        for kind, side, a, c in pieces:
            if kind == 'c':                 # r = rho0: dpsi/dl = wc / (rho0 vlc)
                wc = b / rho0
                vlc = np.sqrt(max(1 - wc * wc, 0.0))
                D = c - a
                if above and D * wc >= (psi_f - psi) * rho0 * vlc:
                    lh = side * (a + (psi_f - psi) * rho0 * vlc / wc)
                    return dict(kind=2, l=lh, n=np.cos(psi_f) * e1 + np.sin(psi_f) * e2)
                psi += D * wc / (rho0 * max(vlc, 1e-300))
                continue
            U = abs(c - a)
            dv = 1.0 if c >= a else -1.0
            N = int(min(max(np.ceil(U / hmax), 1), nmax))
            hs = U / N
            steps += N
            for k in range(N):
                va = a + dv * k * hs
                gv = np.array([g(va + dv * hs * t) for t in GAUSS_T])
                dpsi = hs * (GAUSS_W @ gv)
                if above and psi + dpsi >= psi_f:
                    target = psi_f - psi
                    cpoly = hs * (GAUSS_POLY @ gv)          # psi - psi0 = sum_k cpoly[k] t^(k+1), t = u / hs
                    t = target / dpsi
                    for _ in range(4):
                        P = sum(cpoly[j] * t ** (j + 1) for j in range(4))
                        dP = sum((j + 1) * cpoly[j] * t ** j for j in range(4))
                        t = min(max(t - (P - target) / dP, 0.0), 1.0)
                    u = t * hs
                    I = u * (GAUSS_W @ np.array([g(va + dv * u * tt) for tt in GAUSS_T]))
                    u = min(max(u - (I - target) / g(va + dv * u), 0.0), hs)
                    return dict(kind=2, l=l_of(va + dv * u, side), n=np.cos(psi_f) * e1 + np.sin(psi_f) * e2)
                psi += dpsi
        n = np.cos(psi) * e1 + np.sin(psi) * e2
        t = -np.sin(psi) * e1 + np.cos(psi) * e2
        bR = b / self.Rout
        return dict(kind=int(side_out), l=side_out * L, n=n, vl=side_out * np.sqrt(max(1 - bR * bR, 0.0)),
                    w=bR * t, steps=steps)


# 4-point Gauss-Legendre on [0, 1], and the integral from 0 to t of the cubic through its nodes:
# GAUSS_POLY[k, i] is the coefficient of t^(k+1) per unit value at node i
GAUSS_T, GAUSS_W = np.polynomial.legendre.leggauss(4)
GAUSS_T, GAUSS_W = 0.5 * (GAUSS_T + 1), 0.5 * GAUSS_W
GAUSS_POLY = np.array([np.polyint(np.poly1d(np.poly(np.delete(GAUSS_T, i))) / np.prod(GAUSS_T[i] - np.delete(GAUSS_T, i))).coeffs[::-1][1:]
                       for i in range(4)]).T


def _any_perp(n):
    t = np.array([1.0, 0, 0]) if abs(n[0]) < 0.9 else np.array([0, 1.0, 0])
    t = t - n * np.dot(t, n)
    return t / np.linalg.norm(t)
