"""The wormhole space in float64 (NumPy, SciPy): the reference the shaders are checked against.

The space, its profile and the method: docs/geometry.md. A point is (l, n), n a unit 3-vector; a
tangent vector at it is (V_l, v), v orthogonal to n, |V|^2 = V_l^2 + |v|^2. The flat charts: side
A (l >= L) x = r n, side B x = M r n with M = diag(-1, 1, 1). The floor is n_z = 0.

Everything here is computed without the shaders' shortcuts: sweeps and path lengths are integrals
taken by adaptive quadrature, roots by bracketing (brentq). brute() integrates the geodesic
equations themselves with small RK4 steps, without the plane of the ray: what the rest is checked
against.
"""
import os
import re

import numpy as np
from scipy.integrate import quad
from scipy.optimize import brentq

HERE = os.path.dirname(os.path.abspath(__file__))


def app_profile():
    """The app's throat, (rho0, h, R) in metres: godot/main.gd's THROAT_RADIUS, HALF_LENGTH, FILLET."""
    src = open(os.path.join(HERE, '..', 'godot', 'main.gd')).read()
    return tuple(float(re.search(r'^const %s := ([\d.]+)' % k, src, re.M).group(1))
                 for k in ('THROAT_RADIUS', 'HALF_LENGTH', 'FILLET'))


class Space:
    """The throat: radius rho0, half length h (along w), fillet radius R, h >= R (a cylinder of
    half length Lc = h - R between the fillets, possibly of length 0)."""

    def __init__(self, rho0, h, R):
        assert h >= R, "the fillets start at the cylinder: h >= R"
        self.rho0, self.h, self.R = rho0, h, R
        self.Lc = h - R
        self.L = self.Lc + R * np.pi / 2
        self.Rout = rho0 + R
        self.s1 = np.sqrt(0.5)          # sin(theta / 2) at the fillet's outer end

    # ---------- profile ----------
    def r(self, l):
        al = abs(l)
        if al <= self.Lc:
            return self.rho0
        if al <= self.L:
            return self.rho0 + self.R * (1 - np.cos((al - self.Lc) / self.R))
        return al - self.L + self.Rout

    def dr(self, l):
        al = abs(l)
        sg = 1.0 if l >= 0 else -1.0
        if al <= self.Lc:
            return 0.0
        if al <= self.L:
            return sg * np.sin((al - self.Lc) / self.R)
        return sg

    def w(self, l):
        al = abs(l)
        sg = 1.0 if l >= 0 else -1.0
        if al <= self.Lc:
            return l
        if al <= self.L:
            return sg * (self.Lc + self.R * np.sin((al - self.Lc) / self.R))
        return sg * self.h

    def embed(self, l, n):
        return np.r_[self.r(l) * np.asarray(n, float), self.w(l)]

    def chart(self, l, n):
        """(side, chart position) of a point in a flat region."""
        side = 1.0 if l > 0 else -1.0
        x = self.r(l) * np.asarray(n, float)
        return side, (x if side > 0 else x * np.array([-1.0, 1, 1]))

    def from_chart(self, side, x):
        x = np.asarray(x, float)
        if side < 0:
            x = x * np.array([-1.0, 1, 1])
        rr = np.linalg.norm(x)
        return side * (rr - self.Rout + self.L), x / rr

    def from_r4(self, P):
        """The point of the space at a point P of R^4 on the hypersurface."""
        X, W = np.asarray(P[:3], float), float(P[3])
        rr = np.linalg.norm(X)
        n = X / rr
        sg = 1.0 if W >= 0 else -1.0
        if abs(W) <= self.Lc and abs(rr - self.rho0) < 1e-9 * self.R + 1e-12:
            return W, n
        if abs(abs(W) - self.h) < 1e-12 and rr >= self.Rout:
            return sg * (rr - self.Rout + self.L), n
        th = np.arctan2(abs(W) - self.Lc, self.Rout - rr)
        return sg * (self.Lc + self.R * th), n

    # ---------- a ray of impact parameter b on a fillet ----------
    # s = sin(theta / 2), r = rho0 + 2 R s^2. sigma = (b - rho0) / 2R, c = sqrt|sigma|;
    # s = c sinh y (sigma < 0: the ray passes the throat) or c cosh y (sigma >= 0: it turns where
    # y = 0, s = c). In y the sweep and the path length have smooth integrands A and P.
    def sig(self, b):
        sigma = (b - self.rho0) / (2 * self.R)
        return sigma, np.sqrt(abs(sigma))

    def y_of_s(self, b, s):
        sigma, c = self.sig(b)
        return np.arcsinh(s / c) if sigma < 0 else np.arccosh(max(s / c, 1.0))

    def s_of_y(self, b, y):
        sigma, c = self.sig(b)
        return c * np.sinh(y) if sigma < 0 else c * np.cosh(y)

    def A(self, b, y):
        s = self.s_of_y(b, y)
        r = self.rho0 + 2 * self.R * s * s
        return b * np.sqrt(2 * self.R) / (r * np.sqrt(r + b) * np.sqrt(1 - s * s))

    def P(self, b, y):
        s = self.s_of_y(b, y)
        r = self.rho0 + 2 * self.R * s * s
        return np.sqrt(2 * self.R) * r / (np.sqrt(r + b) * np.sqrt(1 - s * s))

    def s_of_l(self, l):
        return np.sin((abs(l) - self.Lc) / (2 * self.R))

    def l_of_s(self, s, side):
        return side * (self.Lc + 2 * self.R * np.arcsin(s))

    def fil(self, b, sa, sb):
        """Sweep and path length of the ray between s = sa and s = sb on one fillet (no turning
        point between them)."""
        ya, yb = sorted((self.y_of_s(b, sa), self.y_of_s(b, sb)))
        sw = quad(lambda y: self.A(b, y), ya, yb, epsabs=1e-14, epsrel=1e-13, limit=200)[0]
        pa = quad(lambda y: self.P(b, y), ya, yb, epsabs=1e-14, epsrel=1e-13, limit=200)[0]
        return sw, pa

    def s_inner(self, b):
        """Where the ray's fillet leg ends inward: the turning point, or 0 (the cylinder's end)."""
        sigma, c = self.sig(b)
        return c if sigma > 0 else 0.0

    def cyl(self, b, dl):
        """Sweep and path length over dl of the cylinder (b < rho0)."""
        q = np.sqrt(self.rho0 ** 2 - b * b)
        return b * dl / (self.rho0 * q), self.rho0 * dl / q

    # ---------- the legs of a ray ----------
    def legs(self, l, vl, b):
        """The ray from l moving radially with sign vl (+: l grows), impact b, until it leaves the
        curved zone or would go on in a flat region: a list of legs (kind, side, from, to, sweep,
        path): kind 'fil' (from, to: s), 'cyl' (from, to: l). The last element: (side, 'exit')."""
        out = []
        side = 1.0 if l > 0 else (-1.0 if l < 0 else (1.0 if vl > 0 else -1.0))
        al = abs(l)
        outward = side * vl > 0
        passing = b < self.rho0
        if al >= self.L:
            assert not outward
            al = self.L
        if al > self.Lc:
            s = self.s_of_l(al)
            if outward:
                sw, pa = self.fil(b, s, self.s1)
                out.append(('fil', side, s, self.s1, sw, pa))
                return out + [(side, 'exit')]
            si = self.s_inner(b)
            sw, pa = self.fil(b, s, si)
            out.append(('fil', side, s, si, sw, pa))
            if not passing:
                sw, pa = self.fil(b, si, self.s1)
                out.append(('fil', side, si, self.s1, sw, pa))
                return out + [(side, 'exit')]
            al = self.Lc
        # on the cylinder at side * al, moving with vl (passing: b < rho0)
        assert passing
        start = side * al if al > 0 else 0.0
        end = self.Lc if vl > 0 else -self.Lc
        sw, pa = self.cyl(b, abs(end - start))
        if abs(end - start) > 0:
            out.append(('cyl', 0.0, start, end, sw, pa))
        ex = 1.0 if vl > 0 else -1.0
        sw, pa = self.fil(b, 0.0, self.s1)
        out.append(('fil', ex, 0.0, self.s1, sw, pa))
        return out + [(ex, 'exit')]

    def at_sweep(self, leg, b, phi):
        """The l of the point a sweep phi into a leg."""
        kind, side, a, e, sw, pa = leg
        if kind == 'cyl':
            q = np.sqrt(self.rho0 ** 2 - b * b)
            return a + np.sign(e - a) * phi * self.rho0 * q / b
        ya, ye = self.y_of_s(b, a), self.y_of_s(b, e)
        dirn = 1.0 if ye > ya else -1.0
        f = lambda y: quad(lambda t: self.A(b, t), ya, y, epsabs=1e-14, epsrel=1e-13)[0] * dirn - phi
        y = brentq(f, min(ya, ye), max(ya, ye), xtol=1e-15)
        return self.l_of_s(self.s_of_y(b, y), side)

    # ---------- a pixel's ray: the floor or the sky ----------
    def trace(self, l, n, V):
        """The ray from (l, n) with unit direction V = (V_l, v): ('floor', l, n) where it meets the
        floor, ('sky', side, chart direction) where it goes off to infinity."""
        n = np.asarray(n, float)
        vl, v = float(V[0]), np.asarray(V[1:], float)
        st = np.linalg.norm(v)
        t = v / st if st > 1e-15 else np.cross(n, [0.0, 0.0, 1.0]) / max(np.linalg.norm(np.cross(n, [0, 0, 1.0])), 1e-30)
        acc = 0.0                   # sweep so far
        phi_f = np.arctan2(n[2], -t[2]) if st > 1e-15 else np.inf
        if phi_f < 0:
            phi_f += 2 * np.pi
        if abs(l) >= self.L:
            side, X = self.chart(l, n)
            M = np.array([1.0 if side > 0 else -1.0, 1, 1])
            D = M * (side * vl * n + v)
            hit = self._sphere(X, D)
            if hit is None:
                return self._flat(side, X, D)
            tin, b = hit
            if D[2] < 0 and -X[2] / D[2] < tin:
                return self._flat(side, X, D)
            Xi = X + tin * D
            ni = M * Xi / np.linalg.norm(Xi)
            acc = np.arccos(np.clip(n @ ni, -1, 1))
            l0, b0 = side * self.L, b
            vl0 = -side
        else:
            b0 = self.r(l) * st
            l0 = l
            vl0 = vl if abs(vl) > 0 else 1.0
        rho0 = self.rho0
        lg = self.legs(l0, vl0, b0)
        for leg in lg[:-1]:
            if acc + leg[4] >= phi_f:
                lf = self.at_sweep(leg, b0, phi_f - acc)
                return ('floor', lf, np.cos(phi_f) * n + np.sin(phi_f) * t)
            acc += leg[4]
        side = lg[-1][0]
        no = np.cos(acc) * n + np.sin(acc) * t
        to = -np.sin(acc) * n + np.cos(acc) * t
        cb = np.sqrt(max(1 - (b0 / self.Rout) ** 2, 0.0))
        M = np.array([1.0 if side > 0 else -1.0, 1, 1])
        return self._flat(side, M * self.Rout * no, M * (cb * no + b0 / self.Rout * to))

    def _sphere(self, X, D):
        """Where the line X + t D (|D| = 1) enters the sphere |x| = Rout ahead: (t, impact) or None."""
        tc = -X @ D
        d2 = X @ X - tc * tc
        if tc <= 0 or d2 >= self.Rout ** 2:
            return None
        return tc - np.sqrt(self.Rout ** 2 - d2), np.sqrt(max(d2, 0.0))

    def _flat(self, side, X, D):
        if D[2] < 0:
            p = X - X[2] / D[2] * D
            lf, nf = self.from_chart(side, p)
            return ('floor', lf, nf)
        return ('sky', side, D / np.linalg.norm(D))

    # ---------- the inverse: which direction from an eye reaches a point ----------
    def sweep_to(self, le, lp, b, branch):
        """Sweep and path length from l = le to l = lp along the ray of impact b; branch 'direct'
        (l moves monotonically) or 'turn' (in toward the throat, a turning point, out again)."""
        if branch == 'direct':
            return self._mono(le, lp, b)
        side = 1.0 if le > 0 else -1.0
        lt = self._l_turn(b, side)
        a = self._mono(le, lt, b)
        e = self._mono(lt, lp, b)
        return a[0] + e[0], a[1] + e[1]

    def _l_turn(self, b, side):
        if b >= self.Rout:
            return side * (b - self.Rout + self.L)
        return self.l_of_s(np.sqrt((b - self.rho0) / (2 * self.R)), side)

    def _mono(self, la, lb, b):
        """Sweep and path between la and lb, l monotonic between them."""
        if la == lb:
            return 0.0, 0.0
        if la > lb:
            la, lb = lb, la
        knots = [-np.inf, -self.L, -self.Lc, 0.0, self.Lc, self.L, np.inf]
        sw = pa = 0.0
        for k0, k1 in zip(knots[:-1], knots[1:]):
            a, e = max(la, k0), min(lb, k1)
            if e <= a:
                continue
            ra, re_ = self.r(a), self.r(e)
            if abs(a) >= self.L - 1e-15 and abs(e) >= self.L - 1e-15:       # flat: a straight line
                lo, hi = min(ra, re_), max(ra, re_)
                sw += np.arccos(min(b / hi, 1)) - np.arccos(min(b / lo, 1))
                pa += np.sqrt(max(hi * hi - b * b, 0)) - np.sqrt(max(lo * lo - b * b, 0))
            elif abs(a) <= self.Lc + 1e-15 and abs(e) <= self.Lc + 1e-15:
                q = self.cyl(b, e - a)
                sw += q[0]
                pa += q[1]
            else:
                q = self.fil(b, self.s_of_l(a), self.s_of_l(e))
                sw += q[0]
                pa += q[1]
        return sw, pa

    def inverse(self, le, ne, lp, np_):
        """The unit tangent V = (V_l, v) at the eye (le, ne) whose geodesic reaches (lp, np_) with
        the minor arc of directions, and its length. None where no such ray exists."""
        ne, np_ = np.asarray(ne, float), np.asarray(np_, float)
        cs = np.clip(ne @ np_, -1, 1)
        tv = np_ - cs * ne
        sn = np.linalg.norm(tv)
        delta = np.arctan2(sn, cs)
        t = tv / sn if sn > 1e-300 else np.zeros(3)
        re_, rp = self.r(le), self.r(lp)
        if delta < 1e-15:
            V = np.r_[np.sign(lp - le) if lp != le else 1.0, 0, 0, 0]
            return V, abs(self._mono(le, lp, 0.0)[1]) if lp != le else 0.0
        same = le * lp > 0
        r_lo = min(re_, rp) if same else self.rho0
        top = r_lo * (1 - 1e-15)
        f = lambda b: self._mono(le, lp, b)[0] - delta
        if not same or r_lo <= self.rho0 or delta <= self._mono(le, lp, top)[0]:
            if f(top) < 0:
                return None             # beyond the sweep of every ray that gets there
            b = brentq(f, 0.0, top, xtol=1e-15, rtol=1e-15)
            pa = self._mono(le, lp, b)[1]
            vl = np.sign(lp - le) * np.sqrt(max(1 - (b / re_) ** 2, 0))
        else:
            g = lambda b: self.sweep_to(le, lp, b, 'turn')[0] - delta
            b = brentq(g, self.rho0 * (1 + 1e-13), top, xtol=1e-15, rtol=1e-15)
            pa = self.sweep_to(le, lp, b, 'turn')[1]
            vl = -np.sign(le) * np.sqrt(max(1 - (b / re_) ** 2, 0))
        return np.r_[vl, (b / re_) * t], pa

    # ---------- brute force ----------
    def rhs(self, y):
        l, n, vl, w = y[0], y[1:4], y[4], y[5:8]
        r, dr = self.r(l), self.dr(l)
        ww = w @ w
        return np.r_[vl, w / r, dr / r * ww, -(dr / r) * vl * w - (ww / r) * n]

    def brute_frame(self, l, n, V, dist, frame, h=1e-3):
        """brute() also transporting the tangent vectors of frame: (l, n, V, frame)."""
        def rate(y):
            l, n, vl, v = y[0], y[1:4], y[4], y[5:8]
            r, dr = self.r(l), self.dr(l)
            k = dr / r
            out = [self.rhs(y[:8])]
            for j in range(len(frame)):
                U = y[8 + 4 * j: 12 + 4 * j]
                out.append(np.r_[k * (v @ U[1:]), -k * U[0] * v - (U[1:] @ v) / r * n])
            return np.concatenate(out)
        y = np.concatenate([np.r_[l, n, V[0], V[1:]]] + [np.asarray(f, float) for f in frame])
        steps = max(int(np.ceil(dist / h)), 1)
        hh = dist / steps
        for _ in range(steps):
            k1 = rate(y)
            k2 = rate(y + hh / 2 * k1)
            k3 = rate(y + hh / 2 * k2)
            k4 = rate(y + hh * k3)
            y = y + hh / 6 * (k1 + 2 * k2 + 2 * k3 + k4)
            y[1:4] /= np.linalg.norm(y[1:4])
        return y[0], y[1:4], np.r_[y[4], y[5:8]], [y[8 + 4 * j: 12 + 4 * j] for j in range(len(frame))]

    def brute(self, l, n, V, dist, h=1e-3):
        """Follow the geodesic from (l, n) with unit direction V for length dist by RK4 steps on
        the geodesic equations (docs/geometry.md): (l, n, V) at its end."""
        y = np.r_[l, n, V[0], V[1:]]
        steps = max(int(np.ceil(dist / h)), 1)
        hh = dist / steps
        for _ in range(steps):
            k1 = self.rhs(y)
            k2 = self.rhs(y + hh / 2 * k1)
            k3 = self.rhs(y + hh / 2 * k2)
            k4 = self.rhs(y + hh * k3)
            y = y + hh / 6 * (k1 + 2 * k2 + 2 * k3 + k4)
            y[1:4] /= np.linalg.norm(y[1:4])
            y[5:8] -= (y[5:8] @ y[1:4]) * y[1:4]
        return y[0], y[1:4], np.r_[y[4], y[5:8]]
