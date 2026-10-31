"""The fillet's tables the shaders read (godot/shaders/space.gdshaderinc, sp_tabAt), as
godot/space.gd builds them, in float64: E(b, z) and F(b, z), the sweep's and the path length's
parts that are not linear in z (Space below: the substitution; space.gdshaderinc's top).

Columns: b by the square root of its distance from rho0 on [0, rho0] and on [rho0, Rout] (u = 0.5
at rho0); knots: z = ZCAP v^2, v uniform. Texel (i, j) of each table holds the knots j and j + 1 of
column i, value and slope times the knot spacing: (E_j, D_j, E_j+1, D_j+1)."""
import numpy as np

NB, NZ, ZCAP = 256, 64, 6.0
S1 = np.sqrt(0.5)
# Gauss-Legendre on [0, 1]: 6 nodes per knot interval
_X, _W = np.polynomial.legendre.leggauss(6)
_X, _W = (_X + 1) / 2, _W / 2


def b_of_u(sp, u):
    if u <= 0.5:
        return sp.rho0 * (1 - (1 - 2 * u) ** 2)
    return sp.rho0 + (sp.Rout - sp.rho0) * (2 * u - 1) ** 2


def build(sp):
    with np.errstate(invalid="ignore"):
        return _build(sp)


def _build(sp):
    """(tab, ptab): float32 arrays (NZ - 1, NB, 4), row j, column i."""
    rho0, R = sp.rho0, sp.R
    tab = np.zeros((NZ - 1, NB, 4))
    ptab = np.zeros((NZ - 1, NB, 4))
    for i in range(NB):
        b = b_of_u(sp, i / (NB - 1))
        sig = (b - rho0) / (2 * R)
        k = np.sqrt(max(0.5 - sig, 0.0))
        a0 = b * np.sqrt(2 * R / (rho0 + b)) / rho0
        p0 = rho0 * np.sqrt(2 * R / (rho0 + b))

        def integrands(z):
            e = np.exp(z)
            s = 0.5 * (sig * e / (S1 + k) + (S1 + k) / e)
            r = rho0 + 2 * R * s * s
            c = np.sqrt(2 * R / ((r + b) * (1 - s * s)))
            return b * c / r - a0, c * r - p0, abs(s)
        E = np.zeros(NZ)
        F = np.zeros(NZ)
        dE = np.zeros(NZ)
        dF = np.zeros(NZ)
        ok = True
        for j in range(NZ):
            v = j / (NZ - 1)
            z = ZCAP * v * v
            if j > 0 and ok:
                zp = ZCAP * ((j - 1) / (NZ - 1)) ** 2
                zz = zp + (z - zp) * _X
                ie, ip, sa = integrands(zz)
                if np.max(sa) >= 0.95:
                    ok = False
                else:
                    E[j] = E[j - 1] + (z - zp) * (_W @ ie)
                    F[j] = F[j - 1] + (z - zp) * (_W @ ip)
            if not ok:
                E[j], F[j] = E[j - 1], F[j - 1]
                continue
            ie, ip, _ = integrands(np.array([z]))
            dz = 2 * ZCAP * v / (NZ - 1)
            dE[j], dF[j] = ie[0] * dz, ip[0] * dz
        for j in range(NZ - 1):
            tab[j, i] = (E[j], dE[j], E[j + 1], dE[j + 1])
            ptab[j, i] = (F[j], dF[j], F[j + 1], dF[j + 1])
    return tab.astype(np.float32), ptab.astype(np.float32)
