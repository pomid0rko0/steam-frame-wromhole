"""
Reference maths of the renderer, float64 (NumPy): the sweep of a ray round the throat, where a
ray leaves the curved zone. The renderer's method: docs/geometry.md,
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
import math
import os
import re
import numpy as np
from scipy import integrate


def _main_const(k):
    src = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'godot', 'main.gd')).read()
    return float(re.search(r'^const %s := ([\d.]+)' % k, src, re.M).group(1))


def app_profile():
    """The app's throat, (rho0, h, R) in metres: godot/main.gd's THROAT_RADIUS, HALF_LENGTH, FILLET."""
    return tuple(_main_const(k) for k in ('THROAT_RADIUS', 'HALF_LENGTH', 'FILLET'))


def app_lift():
    """The throat's centre above the floor in metres: godot/main.gd's LIFT."""
    return _main_const('LIFT')


def menu_corners():
    """The corners of the box of shapes the menu offers, each (rho0, h, R) in metres with h >= R:
    godot/wormhole_space.gd's SHAPE_MIN and SHAPE_MAX (WormholeSpace.fits)."""
    src = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'godot', 'wormhole_space.gd')).read()
    lo, hi = ([float(x) for x in re.search(r'^const %s := \[([^\]]*)\]' % k, src, re.M).group(1).split(',')]
              for k in ('SHAPE_MIN', 'SHAPE_MAX'))
    out = []
    for r in sorted({lo[0], hi[0]}):
        for h in sorted({lo[1], hi[1]}):
            for R in sorted({lo[2], hi[2]}):
                c = (r, max(h, R), R)
                if c not in out:
                    out.append(c)
    return out


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

    def gap0(self, al):
        """r(|l|) - rho0 without the difference (geo_dr): exact next to the cylinder's end."""
        if al >= self.L:
            return al - self.L + self.R
        return 2 * self.R * np.sin(self.theta(al) / 2) ** 2

    def l_turn(self, b):
        """|l| of the turning point of a ray with impact b >= r_min."""
        if b >= self.Rout:
            return b - self.Rout + self.L
        sig = (b - self.rho0) / (2 * self.R)
        return self.l_of_u(max(sig, self.u0))

    # ---------- the fillet's integrand ----------
    # sig: (b - rho0) / 2R if the caller knows it better than b does (b next to rho0 keeps only
    # its absolute digits), else from b
    def sigma(self, b, sig=None):
        return (b - self.rho0) / (2 * self.R) if sig is None else sig

    def F(self, b, u):
        """psi and length integrands on the fillet without the weight 1 / sqrt(u (u - sigma))."""
        r = self.rho0 + 2 * self.R * u
        c = np.sqrt(self.R / 2) / (np.sqrt(1 - u) * np.sqrt(r + b))
        return b * c / r, r * c

    def u_lo(self, b, sig=None):
        return max(self.sigma(b, sig), self.u0)

    def Fu(self, b, u):
        """dF/du (psi, length)."""
        r = self.rho0 + 2 * self.R * u
        f = np.array(self.F(b, u))
        return f * np.array([1 / (2 * (1 - u)) - 2 * self.R / r - self.R / (r + b),
                             1 / (2 * (1 - u)) + 2 * self.R / r - self.R / (r + b)])

    def closed(self, b, u, sig=None):
        """The closed-form part from u_lo to u: F(u_lo) W + F_u(u_lo) int (u - u_lo) dW."""
        sig = self.sigma(b, sig)
        ul = self.u_lo(b, sig)
        W = self.W(b, u, sig)
        I1 = np.sqrt(u * (u - sig)) - np.sqrt(ul * (ul - sig)) + sig / 2 * W
        return np.array(self.F(b, ul)) * W + self.Fu(b, ul) * (I1 - ul * W)

    def W(self, b, u, sig=None):
        """int from u_lo to u of du / sqrt(u (u - sigma)), closed form."""
        sig = self.sigma(b, sig)
        ul = self.u_lo(b, sig)
        return 2 * np.log((np.sqrt(u) + np.sqrt(u - sig)) / (np.sqrt(ul) + np.sqrt(ul - sig)))

    def G_exact(self, b, u, sig=None):
        """int from u_lo to u of (F - F(u_lo) - F_u(u_lo) (u - u_lo)) dW (psi, length), by
        quadrature in v."""
        sig = self.sigma(b, sig)
        ul = self.u_lo(b, sig)
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
    def fillet(self, b, u, table=False, sig=None):
        """(psi, length) over the fillet from u_lo to u."""
        ul = self.u_lo(b, sig)
        if u <= ul:
            return np.zeros(2)
        if table:
            v = np.sqrt((u - ul) / (0.5 - ul))
            g = self.G_table(b, v)
        else:
            g = self.G_exact(b, u, sig)
        return self.closed(b, u, sig) + g

    def sweep(self, b, l, table=False, sig=None):
        """(psi, length) from the ray's origin to l (docstring at the top). b >= r_min needs |l| >= l_turn(b)."""
        al = abs(l)
        if b >= self.Rout:
            r = float(self.r(al))
            q = np.sqrt(max(r * r - b * b, 0.0))
            return np.array([np.arctan2(q, b), q])
        out = np.zeros(2)
        sig = self.sigma(b, sig)
        passing = sig < self.u0
        if passing and self.Lc > 0:
            lc = min(al, self.Lc)
            k = np.sqrt(-2 * self.R * sig * (self.rho0 + b))      # sqrt(rho0^2 - b^2)
            out += np.array([b * lc / (self.rho0 * k), lc * self.rho0 / k])
        if al > self.Lc:
            out += self.fillet(b, float(self.u_of(min(al, self.L))), table, sig)
        if al > self.L:
            r = float(self.r(al))
            qo = np.sqrt(self.Rout ** 2 - b * b)
            q = np.sqrt(r * r - b * b)
            out += np.array([np.arctan2(q, b) - np.arctan2(qo, b), q - qo])
        return out * (np.sign(l) if passing else 1.0)


# ---------- independent check: the geodesic ODE in the ray's plane ----------
def plane_rhs(S, s, y, b):
    """The profile in scalars (S.r and S.dr, without NumPy's per-call cost)."""
    l, vl, phi = y
    al = abs(l)
    if al >= S.L:
        r, d = al - S.L + S.Rout, 1.0
    else:
        th = S.th0 + (max(al, S.Lc) - S.Lc) / S.R
        r, d = S.rho0 + S.R * (1 - math.cos(th)), math.sin(th)
    d = d if l > 0 else (-d if l < 0 else 0.0)
    return [vl, d * b * b / r ** 3, b / (r * r)]


def shoot(S, l0, alpha, smax=200.0, events=(), rtol=1e-11, max_step=0.05):
    """Integrate the ray from (l0, phi = 0) at angle alpha to the outward radial direction
    (outward: growing |l|). Returns the solve_ivp result; y = (l, dl/ds, phi)."""
    b = float(S.r(l0)) * np.sin(alpha)
    out = 1.0 if l0 >= 0 else -1.0
    return integrate.solve_ivp(lambda s, y: plane_rhs(S, s, y, b), (0, smax), [l0, out * np.cos(alpha), 0.0],
                               method='DOP853', rtol=rtol, atol=1e-12, events=list(events),
                               dense_output=True, max_step=max_step)


# ---------- where a ray leaves the curved zone ----------
def leave(S, el, ca, sa):
    """The ray from the eye at l = el launched at the angle to the outward radial direction whose
    cosine and sine are (ca, sa): None if it never enters the curved zone (an eye outside, the ray
    going out or passing the zone's ball by); else (sheet, psi, length) where it leaves the zone
    (|l| = L, out): the universe it goes on in (+1 A, -1 B), its position angle's turn and its
    length from the eye. By the sweeps from its origin (quadrature), however many turns; its
    (b - rho0) / 2R from the angle, not as a difference of b and rho0, in the precision ca and sa
    come in (np.longdouble: next to r_min, where the turn grows without bound, it keeps its digits
    from an eye far out)."""
    side = 1.0 if el >= 0 else -1.0
    le = abs(el)
    re = float(S.r(le))
    b = float(re * sa)
    if le >= S.L and (ca >= 0 or b >= S.Rout):
        return None
    sig = float((S.gap0(le) - re * ca * ca / (1 + sa)) / (2 * S.R))
    se = S.sweep(b, le, sig=sig)
    sl = S.sweep(b, S.L, sig=sig)
    if ca >= 0:
        return side, *(sl - se)
    return (-side if sig < S.u0 else side), *(sl + se)
