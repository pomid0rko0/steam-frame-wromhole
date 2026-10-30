"""
Reference maths of the renderer, float64 (NumPy): the sweep of a ray round the throat, where a
ray meets the floor, which way an eye sees a point. The renderer's method: docs/geometry.md,
«Как рисуется кадр». The shaders (godot/shaders/geo.gdshaderinc) do the same in float32 with the
table this module builds the same way as WormholeSpace.sweep_table.

Profile helpers (r, dr, w, dw) are also what ref/gravity.py and ref/test_gravity.py use.

A ray lies in a plane through the centre. In it, with impact parameter b (= r sin of the angle to
the radial direction), its position angle turns by
    psi(b, l) = int b dl / (r sqrt(r^2 - b^2))
and its length grows by
    len(b, l) = int r dl / sqrt(r^2 - b^2),
both counted from where the ray is nearest the throat: its turning point if b >= r_min (then even
in l), l = 0 if b < r_min (then odd in l). On the cylinder and in the flat universes both have
closed forms; on the fillet, in u = sin^2(theta/2), the integrand is F(u) du / sqrt(u (u - sigma)),
sigma = (b - rho0) / 2R, with a smooth F. The weight integrates in closed form (W below), so
    int F dW = F(u_lo) (W(u) - W(u_lo)) + int (F - F(u_lo)) dW
and of the rest the part linear in u - u_lo has a closed form too (F_u(u_lo) times
int (u - u_lo) dW); what is left, G(b, u), small and smooth, comes from a table (over the whole
fillet, its last row).
"""
import os
import re
import numpy as np
from scipy import integrate


def app_profile():
    """The app's throat, (rho0, h, R) in metres: godot/main.gd's THROAT_RADIUS, HALF_LENGTH, FILLET."""
    src = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'godot', 'main.gd')).read()
    return tuple(float(re.search(r'^const %s := ([\d.]+)' % k, src, re.M).group(1))
                 for k in ('THROAT_RADIUS', 'HALF_LENGTH', 'FILLET'))


class Space:
    def __init__(self, rho0=3.0, h=5.0, R=1.0):
        self.rho0, self.h, self.R = rho0, h, R
        self.Lc = max(h - R, 0.0)
        self.th0 = float(np.arcsin(max(1.0 - h / R, 0.0)))
        self.u0 = float(np.sin(self.th0 / 2) ** 2)
        self.L = self.Lc + R * (np.pi / 2 - self.th0)
        self.Rout = rho0 + R
        self.rmin = rho0 + 2 * R * self.u0

    # ---------- the profile ----------
    def theta(self, al):
        return self.th0 + (np.clip(al, self.Lc, self.L) - self.Lc) / self.R

    def r(self, l):
        al = np.abs(l)
        inner = self.rho0 + self.R * (1 - np.cos(self.theta(al)))
        return np.where(al <= self.L, inner, al - self.L + self.Rout)

    def dr(self, l):
        al = np.abs(l)
        return np.sign(l) * np.where(al <= self.L, np.sin(self.theta(al)), 1.0)

    def w(self, l):
        al = np.abs(l)
        inner = np.where(al <= self.Lc, al, self.h - self.R + self.R * np.sin(self.theta(al)))
        return np.sign(l) * np.where(al <= self.L, inner, self.h)

    def dw(self, l):
        al = np.abs(l)
        return np.where(al <= self.Lc, 1.0, np.where(al <= self.L, np.cos(self.theta(al)), 0.0))

    def u_of(self, al):
        return np.sin(self.theta(al) / 2) ** 2

    def l_of_u(self, u):
        return self.Lc + self.R * (2 * np.arcsin(np.sqrt(u)) - self.th0)

    def l_turn(self, b):
        """|l| of the turning point of a ray with impact b >= r_min."""
        if b >= self.Rout:
            return b - self.Rout + self.L
        sig = (b - self.rho0) / (2 * self.R)
        return self.l_of_u(max(sig, self.u0))

    # ---------- the fillet's integrand ----------
    def sigma(self, b):
        return (b - self.rho0) / (2 * self.R)

    def F(self, b, u):
        """psi and length integrands on the fillet without the weight 1 / sqrt(u (u - sigma))."""
        r = self.rho0 + 2 * self.R * u
        c = np.sqrt(self.R / 2) / (np.sqrt(1 - u) * np.sqrt(r + b))
        return b * c / r, r * c

    def u_lo(self, b):
        return max(self.sigma(b), self.u0)

    def Fu(self, b, u):
        """dF/du (psi, length)."""
        r = self.rho0 + 2 * self.R * u
        f = np.array(self.F(b, u))
        return f * np.array([1 / (2 * (1 - u)) - 2 * self.R / r - self.R / (r + b),
                             1 / (2 * (1 - u)) + 2 * self.R / r - self.R / (r + b)])

    def closed(self, b, u):
        """The closed-form part from u_lo to u: F(u_lo) W + F_u(u_lo) int (u - u_lo) dW."""
        sig = self.sigma(b)
        ul = self.u_lo(b)
        W = self.W(b, u)
        I1 = np.sqrt(u * (u - sig)) - np.sqrt(ul * (ul - sig)) + sig / 2 * W
        return np.array(self.F(b, ul)) * W + self.Fu(b, ul) * (I1 - ul * W)

    def W(self, b, u):
        """int from u_lo to u of du / sqrt(u (u - sigma)), closed form."""
        sig = self.sigma(b)
        ul = self.u_lo(b)
        return 2 * np.log((np.sqrt(u) + np.sqrt(u - sig)) / (np.sqrt(ul) + np.sqrt(ul - sig)))

    def G_exact(self, b, u):
        """int from u_lo to u of (F - F(u_lo) - F_u(u_lo) (u - u_lo)) dW (psi, length), by
        quadrature in v."""
        sig = self.sigma(b)
        ul = self.u_lo(b)
        span = 0.5 - ul
        if span <= 0 or u <= ul:
            return np.zeros(2)
        f0 = np.array(self.F(b, ul))
        f1 = self.Fu(b, ul)
        v1 = np.sqrt((u - ul) / span)

        def g(v, k):
            uu = ul + span * v * v
            q = uu * (uu - sig)
            return (self.F(b, uu)[k] - f0[k] - f1[k] * (uu - ul)) * 2 * span * v / np.sqrt(q) if q > 0 else 0.0
        return np.array([integrate.quad(g, 0, v1, args=(k,), epsabs=1e-14, epsrel=1e-12, limit=200)[0]
                         for k in (0, 1)])

    # ---------- the table ----------
    # b's axis: t = sign(sigma - u0) sqrt(|sigma - u0|), even steps; u's axis: v = sqrt((u - u_lo) / (1/2 - u_lo))
    def t_of_b(self, b):
        s = self.sigma(b) - self.u0
        return np.sign(s) * np.sqrt(np.abs(s))

    def b_of_t(self, t):
        return self.rho0 + 2 * self.R * (np.sign(t) * t * t + self.u0)

    def build_table(self, nb=256, nv=64, sub=4):
        """G on nb x nv nodes, both ends included: [nb, nv, 2], cumulative Gauss-Legendre with sub
        points per span (WormholeSpace.sweep_table does the same)."""
        t0, t1 = self.t_of_b(0.0), self.t_of_b(self.Rout)
        xg, wg = np.polynomial.legendre.leggauss(sub)
        tab = np.zeros((nb, nv, 2))
        for i in range(nb):
            b = self.b_of_t(t0 + (t1 - t0) * i / (nb - 1))
            b = min(max(b, 0.0), self.Rout)
            sig = self.sigma(b)
            ul = self.u_lo(b)
            span = 0.5 - ul
            if span <= 1e-12:
                continue
            f0 = np.array(self.F(b, ul))
            f1 = self.Fu(b, ul)
            acc = np.zeros(2)
            for j in range(1, nv):
                va, vb = (j - 1) / (nv - 1), j / (nv - 1)
                vv = 0.5 * (va + vb) + 0.5 * (vb - va) * xg
                uu = ul + span * vv * vv
                fv = np.array(self.F(b, uu)).T
                jac = 2 * span * vv / np.sqrt(uu * (uu - sig))
                acc = acc + 0.5 * (vb - va) * ((fv - f0 - f1 * (uu - ul)[:, None]) * (wg * jac)[:, None]).sum(0)
                tab[i, j] = acc
        self.tab = tab
        self.t0, self.t1 = t0, t1
        return tab

    def _column(self, b, nv, xg, wg):
        sig = self.sigma(b)
        ul = self.u_lo(b)
        span = 0.5 - ul
        col = np.zeros((nv, 2))
        if span <= 1e-12:
            return col
        f0 = np.array(self.F(b, ul))
        f1 = self.Fu(b, ul)
        acc = np.zeros(2)
        for j in range(1, nv):
            va, vb = (j - 1) / (nv - 1), j / (nv - 1)
            vv = 0.5 * (va + vb) + 0.5 * (vb - va) * xg
            uu = ul + span * vv * vv
            fv = np.array(self.F(b, uu)).T
            jac = 2 * span * vv / np.sqrt(uu * (uu - sig))
            acc = acc + 0.5 * (vb - va) * ((fv - f0 - f1 * (uu - ul)[:, None]) * (wg * jac)[:, None]).sum(0)
            col[j] = acc
        return col

    def G_table(self, b, v, hw8=True):
        """Bilinear in the table, weights rounded to 1/256 like a GPU's filtering if hw8."""
        nb, nv, _ = self.tab.shape
        x = (self.t_of_b(b) - self.t0) / (self.t1 - self.t0) * (nb - 1)
        y = v * (nv - 1)
        i = int(np.clip(np.floor(x), 0, nb - 2))
        j = int(np.clip(np.floor(y), 0, nv - 2))
        fx, fy = np.clip(x - i, 0, 1), np.clip(y - j, 0, 1)
        if hw8:
            fx, fy = np.round(fx * 256) / 256, np.round(fy * 256) / 256
        T = self.tab
        return ((1 - fx) * (1 - fy) * T[i, j] + fx * (1 - fy) * T[i + 1, j]
                + (1 - fx) * fy * T[i, j + 1] + fx * fy * T[i + 1, j + 1])

    # ---------- sweep and length ----------
    def fillet(self, b, u, table=False):
        """(psi, length) over the fillet from u_lo to u."""
        ul = self.u_lo(b)
        if u <= ul:
            return np.zeros(2)
        if table:
            v = np.sqrt((u - ul) / (0.5 - ul))
            g = self.G_table(b, v)
        else:
            g = self.G_exact(b, u)
        return self.closed(b, u) + g

    def sweep(self, b, l, table=False):
        """(psi, length) from the ray's origin to l (docstring at the top). b >= r_min needs |l| >= l_turn(b)."""
        al = abs(l)
        if b >= self.Rout:
            r = float(self.r(al))
            q = np.sqrt(max(r * r - b * b, 0.0))
            return np.array([np.arctan2(q, b), q])
        out = np.zeros(2)
        passing = b < self.rmin
        if passing and self.Lc > 0:
            lc = min(al, self.Lc)
            k = np.sqrt(self.rho0 ** 2 - b * b)
            out += np.array([b * lc / (self.rho0 * k), lc * self.rho0 / k])
        if al > self.Lc:
            out += self.fillet(b, float(self.u_of(min(al, self.L))), table)
        if al > self.L:
            r = float(self.r(al))
            qo = np.sqrt(self.Rout ** 2 - b * b)
            q = np.sqrt(r * r - b * b)
            out += np.array([np.arctan2(q, b) - np.arctan2(qo, b), q - qo])
        return out * (np.sign(l) if passing else 1.0)

    def sweep_inf(self, b, table=False):
        """psi from the origin to infinity on one side."""
        if b >= self.Rout:
            return np.pi / 2
        return self.sweep(b, self.L, table)[0] + np.arcsin(b / self.Rout)

    def l_at(self, b, psi, table=False, newton=3):
        """|l| (or l, for b < r_min, with psi's sign) where the sweep from the origin is psi; inf
        if the ray gets there only at infinity."""
        sg = np.sign(psi) if b < self.rmin else 1.0
        psi = abs(psi)
        if b >= self.Rout:
            return sg * (b / np.cos(psi) - self.Rout + self.L if psi < np.pi / 2 else np.inf)
        pc = 0.0
        if b < self.rmin and self.Lc > 0:
            k = np.sqrt(self.rho0 ** 2 - b * b)
            pc = b * self.Lc / (self.rho0 * k)
            if psi <= pc:
                return sg * psi * self.rho0 * k / max(b, 1e-30)
        pf = pc + self.fillet(b, 0.5, table)[0]
        if psi > pf:
            a = psi - pf + np.arccos(b / self.Rout)
            return sg * (b / np.cos(a) - self.Rout + self.L if a < np.pi / 2 else np.inf)
        # the fillet: invert F(u_lo) W exactly, then Newton in v on the whole
        sig = self.sigma(b)
        ul = self.u_lo(b)
        span = 0.5 - ul
        f0 = self.F(b, ul)[0]
        target = psi - pc
        D = np.sqrt(ul) + np.sqrt(ul - sig)
        X = D * np.exp(target / max(f0, 1e-30) / 2)
        u = ((X + sig / X) / 2) ** 2
        v = np.sqrt(max(u - ul, 0.0) / span) if span > 0 else 0.0
        v = min(max(v, 0.0), 1.0)
        for _ in range(newton):
            u = ul + span * v * v
            val = self.fillet(b, u, table)[0]
            der = self.F(b, u)[0] * 2 * span * v / np.sqrt(u * (u - sig)) if v > 0 else np.inf
            if not np.isfinite(der) or der <= 0:
                break
            v = min(max(v - (val - target) / der, 0.0), 1.0)
        return sg * float(self.l_of_u(ul + span * v * v))


# ---------- independent check: the geodesic ODE in the ray's plane ----------
def plane_rhs(S, s, y, b):
    l, vl, phi = y
    r = float(S.r(l))
    return [vl, float(S.dr(l)) * b * b / r ** 3, b / r ** 2]


def shoot(S, l0, alpha, smax=200.0, events=(), rtol=1e-11):
    """Integrate the ray from (l0, phi = 0) at angle alpha to the outward radial direction
    (outward: growing |l|). Returns the solve_ivp result; y = (l, dl/ds, phi)."""
    b = float(S.r(l0)) * np.sin(alpha)
    out = 1.0 if l0 >= 0 else -1.0
    return integrate.solve_ivp(lambda s, y: plane_rhs(S, s, y, b), (0, smax), [l0, out * np.cos(alpha), 0.0],
                               method='DOP853', rtol=rtol, atol=1e-12, events=list(events),
                               dense_output=True, max_step=0.05)


# ---------- what a ray meets: the floor or the sky ----------
def floor_hit(S, l0, alpha, phi_f, table=False):
    """A ray from (l0, phi = 0) at angle alpha to the outward radial direction, in a plane where the
    floor is at position angle phi_f (0 < phi_f < pi): (l, length) where it meets the floor, or
    (None, sweep to infinity, side at infinity)."""
    side = 1.0 if l0 >= 0 else -1.0
    al = abs(l0)
    b = float(S.r(al)) * np.sin(alpha)
    se, le = S.sweep(b, al, table)      # from the origin to the eye
    if b >= S.rmin and al < S.l_turn(b):
        se, le = 0.0, 0.0
    outward = np.cos(alpha) >= 0
    if outward:
        tot = S.sweep_inf(b, table) - se
        if phi_f >= tot:
            return None, tot, side
        l = S.l_at(b, se + phi_f, table)
        return side * l, S.sweep(b, l, table)[1] - le
    if b >= S.rmin:                      # turns
        if phi_f <= se:
            l = S.l_at(b, se - phi_f, table)
            return side * l, le - S.sweep(b, l, table)[1]
        tot = se + S.sweep_inf(b, table)
        if phi_f >= tot:
            return None, tot, side
        l = S.l_at(b, phi_f - se, table)
        return side * l, le + S.sweep(b, l, table)[1]
    # passes the throat: psi odd, falls from se
    tot = se + S.sweep_inf(b, table)
    if phi_f >= tot:
        return None, tot, -side
    l = S.l_at(b, se - phi_f, table)      # signed
    return side * l, le - S.sweep(b, l, table)[1]


# ---------- which way an eye sees a point ----------
def log_map(S, le, lp, delta, table=False, iters=60):
    """The geodesic from the eye at le to the point at lp whose position angles differ by delta
    (0 <= delta < pi): the one along which the point is seen (docs/geometry.md). Returns
    (alpha, length): the angle to the eye's outward radial direction and the geodesic's length.
    The rays that reach |l| = |lp| form one family along which the sweep there grows from 0 without
    bound: q in [0, qmax) (below), solved by bisection with the false position's steps."""
    if le < 0:
        le, lp = -le, -lp
    re, rp = float(S.r(le)), float(S.r(lp))
    rmin = S.rmin
    sw = lambda b, l: S.sweep(b, l, table)
    if lp >= le:
        # outward rays b = q re (q in [0, 1]), then inward ones that turn, b from re down to rmin
        qmax = 2.0 if re > rmin * (1 + 1e-9) else 1.0

        def f(q):
            if q <= 1.0:
                b = q * re
                if b >= rmin and le < S.l_turn(b):
                    se = np.zeros(2)
                else:
                    se = sw(b, le)
                p = sw(b, lp)
                return p - se, b
            b = re - (q - 1.0) * (re - rmin)
            return sw(b, le) + sw(b, lp), b
        inward = lambda q: q > 1.0
    else:
        # inward rays straight to lp: b up to bmax; then (lp > 0 with rp > rmin) the turned ones
        cross = lp <= 0 or rp <= rmin * (1 + 1e-9)
        bmax = rmin if cross else rp
        qmax = 1.0 if cross else 2.0

        def f(q):
            if q <= 1.0:
                b = q * bmax
                d = sw(b, le) - (sw(b, lp) if (b < rmin or abs(lp) >= S.l_turn(b)) else 0.0)
                return d, b
            b = rp - (q - 1.0) * (rp - rmin)
            return sw(b, le) + sw(b, lp), b
        inward = lambda q: True
    lo, hi = 0.0, qmax
    flo = -delta
    fhi = np.inf
    q = 0.5 * qmax
    for _ in range(iters):
        val = f(q)[0][0] - delta
        if val > 0:
            hi, fhi = q, val
        else:
            lo, flo = q, val
        if np.isfinite(fhi):
            qn = lo - flo * (hi - lo) / (fhi - flo)
            q = qn if lo < qn < hi and min(qn - lo, hi - qn) > 0.05 * (hi - lo) else 0.5 * (lo + hi)
        else:
            q = 0.5 * (lo + hi)
        if hi - lo < 1e-15:
            break
    d, b = f(q)
    alpha = np.arcsin(min(b / re, 1.0))
    if inward(q):
        alpha = np.pi - alpha
    return alpha, d[1]
