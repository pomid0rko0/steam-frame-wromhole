"""
Gravity through the wormhole, as in optozorax's video about gravity and portals: the
gravitational potential obeys Poisson's equation on the curved space itself. Near the wormhole
there is no mass (the field comes from far away, like the Earth's), so the potential is harmonic:

    Laplacian_g phi = 0,   phi -> g z  far away in both universes

(z is the chart height in universe A and in universe B; the floor is z = 0). The video solves
this with finite elements in 2D. The wormhole is SO(3)-symmetric, so here it separates exactly:
with phi = g f(l) n_z (n_z = cos of the polar angle, an l = 1 spherical harmonic) the Laplacian
of ds^2 = dl^2 + r(l)^2 dOmega^2 gives one ODE for f:

    (r^2 f')' = 2 f,      f even in l,      f = r + beta / r^2 in the flat universes

(a + b / r^2 is the general solution where r = |l| - L + Rout; the r^-2 part is the dipole the
wormhole adds). On the throat's cylinder r = rho0 and f = A cosh(sqrt(2) l / rho0): the field is
screened there and gravity in the middle of a long throat is weak.

The field is g_vec = -grad phi, in the (U_l, u) representation of a tangent vector at (l, n):
    grad phi = g (f' n_z,  (f / r) (e_z - n_z n))
On the floor (n_z = 0) it points straight down with strength g f / r.

The simple field -g grad(r n_z) is the same with f = r: conservative, but
not harmonic in the shell (as if mass sat in the throat: Laplacian = (r'' + 2 (r'^2 - 1) / r) n_z).

The odd solution (the l = 0 mode, phi' = C / r^2) would make the two universes' potentials differ
at infinity and the throat look like a positive mass from one side and a negative one from the
other; both universes have the same field at infinity, so it is absent.
"""
import numpy as np
from scipy.integrate import solve_ivp


class Gravity:
    """f(l), f'(l) for the wormhole W (ref/wh.py), normalised so that f = r + beta / r^2 outside."""

    def __init__(self, W):
        self.W = W

        def rhs(l, y):
            r = float(W.r(np.array(l)))
            return [y[1] / r ** 2, 2.0 * y[0]]

        # p = r^2 f' (the flux) is continuous even across the crease of an h < R profile
        segs = [(0.0, W.Lc), (W.Lc, W.L)] if W.Lc > 0 else [(0.0, W.L)]
        y = [1.0, 0.0]
        self.sols = []
        for a, b in segs:
            s = solve_ivp(rhs, [a, b], y, method='DOP853', rtol=1e-13, atol=1e-15, dense_output=True)
            self.sols.append((a, b, s))
            y = s.y[:, -1]
        r = W.Rout
        f, fp = y[0], y[1] / r ** 2
        a = (2.0 * f + r * fp) / (3.0 * r)
        b = r * r * (f - r * fp) / 3.0
        self.scale = 1.0 / a
        self.beta = b / a

    def f(self, l):
        """(f, f') at l (arrays)."""
        l = np.asarray(l, dtype=float)
        al = np.abs(l)
        sg = np.where(l < 0, -1.0, 1.0)
        out_f = np.zeros_like(al)
        out_p = np.zeros_like(al)
        for a, b, s in self.sols:
            m = (al >= a) & (al <= b)
            if np.any(m):
                y = s.sol(al[m])
                out_f[m] = y[0] * self.scale
                out_p[m] = y[1] / self.W.r(al[m]) ** 2 * self.scale
        m = al > self.W.L
        r = al[m] - self.W.L + self.W.Rout
        out_f[m] = r + self.beta / r ** 2
        out_p[m] = 1.0 - 2.0 * self.beta / r ** 3
        return out_f, sg * out_p

    def floor_g(self, l):
        """Strength of gravity on the floor, in g."""
        f, _ = self.f(l)
        return f / self.W.r(np.asarray(l, dtype=float))


def solve_2d(W, lmax=60.0, dl=0.05, m=128):
    """Independent check: Laplace's equation in (l, theta) on a grid, no separation of variables.
    sin(th) d/dl (r^2 dphi/dl) + d/dth (sin(th) dphi/dth) = 0, phi = r cos(th) at l = +-lmax
    (the far field without its small r^-2 part). Returns l nodes and the cos(th) component of phi."""
    from scipy.sparse import coo_matrix
    from scipy.sparse.linalg import spsolve
    n = int(round(2 * lmax / dl))
    ls = np.linspace(-lmax, lmax, n + 1)
    dth = np.pi / m
    th = (np.arange(m) + 0.5) * dth
    s_face = np.sin(np.arange(m + 1) * dth)               # sin at the cell faces; 0 at the poles
    r_half = W.r(0.5 * (ls[1:] + ls[:-1])) ** 2              # r^2 between nodes
    inner = n - 1
    idx = lambda i, j: (i - 1) * m + j
    rows, cols, vals = [], [], []
    rhs = np.zeros(inner * m)
    for i in range(1, n):
        for j in range(m):
            k = idx(i, j)
            cw = np.sin(th[j]) * r_half[i - 1] / dl ** 2
            ce = np.sin(th[j]) * r_half[i] / dl ** 2
            cs = s_face[j] / dth ** 2
            cn = s_face[j + 1] / dth ** 2
            rows.append(k); cols.append(k); vals.append(-(cw + ce + cs + cn))
            for c, ii, jj in ((cw, i - 1, j), (ce, i + 1, j)):
                if ii == 0 or ii == n:
                    rhs[k] -= c * W.r(ls[ii]) * np.cos(th[jj])
                else:
                    rows.append(k); cols.append(idx(ii, jj)); vals.append(c)
            if j > 0:
                rows.append(k); cols.append(idx(i, j - 1)); vals.append(cs)
            if j < m - 1:
                rows.append(k); cols.append(idx(i, j + 1)); vals.append(cn)
    A = coo_matrix((vals, (rows, cols)), shape=(inner * m, inner * m)).tocsr()
    phi = spsolve(A, rhs).reshape(inner, m)
    wgt = np.cos(th) * np.sin(th)
    f = phi @ wgt / np.sum(np.cos(th) * wgt)                # cos(th) component
    rest = np.max(np.abs(phi - f[:, None] * np.cos(th)[None, :]))
    return ls[1:-1], f, rest
