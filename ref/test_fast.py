"""Fast per-ray method vs brute-force 3D geodesic integration, for several profiles."""
import sys
import numpy as np
from wh import Wormhole

PROFILES = {                      # (rho0, h, R) in optozorax's units
    'video (0.3, 0.5, 0.1)': (0.3, 0.5, 0.1),
    'h = R, smooth, no cylinder': (0.3, 0.1, 0.1),
    'h < R, crease': (0.3, 0.04, 0.1),
    'thin shell limit': (0.3, 0.01, 0.02),
    'long fillet': (0.3, 0.3, 0.25),
}


def christoffel_check(W, rng):
    """(l, n, vl, w) ODE vs textbook Christoffel form in (l, theta, phi)."""
    def rhs(y):
        l, th, ph, dl, dth, dph = y
        r, dr = W.r(l), W.dr(l)
        return np.array([dl, dth, dph,
                         r * dr * (dth ** 2 + np.sin(th) ** 2 * dph ** 2),
                         -2 * dr / r * dl * dth + np.sin(th) * np.cos(th) * dph ** 2,
                         -2 * dr / r * dl * dph - 2 / np.tan(th) * dth * dph])
    err = 0.0
    for _ in range(10):
        l0 = rng.uniform(W.Lc, W.L) * rng.choice([-1, 1])    # stay off the crease
        th0, ph0 = rng.uniform(1.2, 1.9), rng.uniform(0, 2 * np.pi)
        d = rng.normal(size=3); d /= np.linalg.norm(d); d[0] = abs(d[0]) * np.sign(l0)
        r0 = W.r(l0)
        y = np.array([l0, th0, ph0, d[0], d[1] / r0, d[2] / (r0 * np.sin(th0))])
        n = np.array([np.sin(th0) * np.cos(ph0), np.sin(th0) * np.sin(ph0), np.cos(th0)])
        eth = np.array([np.cos(th0) * np.cos(ph0), np.cos(th0) * np.sin(ph0), -np.sin(th0)])
        eph = np.array([-np.sin(ph0), np.cos(ph0), 0])
        st = (np.array([l0]), n[None], np.array([d[0]]), (d[1] * eth + d[2] * eph)[None])
        h = 1e-4
        for _ in range(300):
            k1 = rhs(y); k2 = rhs(y + h / 2 * k1); k3 = rhs(y + h / 2 * k2); k4 = rhs(y + h * k3)
            y = y + h / 6 * (k1 + 2 * k2 + 2 * k3 + k4)
            st = W._rk4(st, h)
        nc = np.array([np.sin(y[1]) * np.cos(y[2]), np.sin(y[1]) * np.sin(y[2]), np.cos(y[1])])
        err = max(err, abs(y[0] - st[0][0]), np.linalg.norm(nc - st[1][0] / np.linalg.norm(st[1][0])))
    return err


def states(W, rng, m):
    S = []
    for i in range(m):
        if i % 3 == 0:                # from the shell boundary, inwards
            side = rng.choice([-1.0, 1.0]); l = side * W.L; vl = -side * rng.uniform(0, 1)
        elif i % 3 == 1:              # inside the shell
            l = rng.uniform(-W.L, W.L); vl = rng.uniform(-1, 1)
        else:                         # near-critical: b close to r_min
            side = rng.choice([-1.0, 1.0]); l = side * W.L
            b = W.rmin * (1 + rng.choice([-1, 1]) * 10.0 ** rng.uniform(-7, -1))
            vl = -side * np.sqrt(max(1 - (b / W.Rout) ** 2, 0))
        n = rng.normal(size=3); n /= np.linalg.norm(n); n[2] = abs(n[2])
        t = rng.normal(size=3); t -= n * (t @ n); t /= np.linalg.norm(t)
        S.append((l, n, vl, t * np.sqrt(1 - vl * vl)))
    return S


def run(name, prof, m, rng):
    W = Wormhole(*prof)
    S = states(W, rng, m)
    ref = W.brute(np.array([s[0] for s in S]), np.array([s[1] for s in S]),
                  np.array([s[2] for s in S]), np.array([s[3] for s in S]), h=W.rho0 * 2e-3, smax=60 * W.L)
    pos, dirr, flo, mism, steps, unfinished = [], [], [], 0, [], 0
    for i, s in enumerate(S):
        if ref['kind'][i] == 0:
            unfinished += 1
            continue
        f = W.fast(*s)
        if f['kind'] != ref['kind'][i]:
            mism += 1
            print(f"   mismatch {i}: fast {f['kind']} ref {ref['kind'][i]} b/rmin-1 = {W.r(s[0]) * np.linalg.norm(s[3]) / W.rmin - 1:+.1e}")
            continue
        if f['kind'] == 2:
            flo.append(max(abs(f['l'] - ref['l'][i]), W.r(f['l']) * np.linalg.norm(f['n'] - ref['n'][i])))
        else:
            steps.append(f['steps'])
            pos.append(W.Rout * np.linalg.norm(f['n'] - ref['n'][i]))
            dirr.append(np.linalg.norm(np.r_[f['vl'] - ref['vl'][i], f['w'] - ref['w'][i]]))
    u = W.rho0
    print(f"[{name}] L={W.L:.3f} Lc={W.Lc:.3f} r_min={W.rmin:.4f}  ODE check {christoffel_check(W, rng):.1e}")
    print(f"   rays {m}, class mismatches {mism}, brute unfinished {unfinished}")
    print(f"   exit pos err / rho0: max {max(pos) / u:.1e}  median {np.median(pos) / u:.1e}   exit dir err max {max(dirr):.1e}")
    print(f"   floor err / rho0:    max {max(flo) / u:.1e}  (n={len(flo)})   Gauss panels mean {np.mean(steps):.1f} max {max(steps)}")


if __name__ == '__main__':
    rng = np.random.default_rng(3)
    m = int(sys.argv[1]) if len(sys.argv) > 1 else 240
    for name, prof in PROFILES.items():
        run(name, prof, m, rng)
