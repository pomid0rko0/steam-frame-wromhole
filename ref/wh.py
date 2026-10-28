"""
Reference math for the wormhole renderer (float64, NumPy).

The space, its profile r(l) and the method: docs/geometry.md.

Points, tangents and the flat charts as the shader's (wormhole_core.gdshaderinc's top).
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

    def brute(self, l, n, vl, w, h=1e-3, smax=200.0, balls=(), cubes=()):
        """Integrate until the ray leaves the curved shell (|l| >= L moving outward)
        or crosses the floor n_z = 0 from above, or enters a ball (centre in R^4, radius):
        the ball is the set of points whose chord distance in R^4 to the centre is < radius;
        or enters a cube (centre in R^4, 4x4 orthonormal axes as rows, half size): the points
        of the 4D box |(P - centre) . axis_k| < half for all four axes.
        kind: +1/-1 exit side, 2 floor, 10 + j object j (the balls, then the cubes), 0 unfinished."""
        def ball_in(c, rad):
            return lambda E: np.sum((E - c) ** 2, -1) < rad * rad

        def cube_in(c, ax, a):
            return lambda E: np.all(np.abs((E - c) @ ax.T) < a, -1)
        objs = [ball_in(np.asarray(c, float), float(rad)) for c, rad in balls] + \
               [cube_in(np.asarray(c, float), np.asarray(ax, float), float(a)) for c, ax, a in cubes]
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
            if objs:
                Eo, En = self.embed(y[0], y[1]), self.embed(ln, nn)
                for jb, inside in enumerate(objs):
                    e = ~inside(Eo) & inside(En) & (enter < 0)
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
                for jb, inside in enumerate(objs):
                    if inside(self.embed(ln[j:j + 1], nn[j:j + 1]))[0] and not inside(self.embed(yy[0], yy[1]))[0]:
                        cands.append((10 + jb, lambda ym, inside=inside: inside(self.embed(ym[0], ym[1] / np.linalg.norm(ym[1])))[0]))
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
    # The fillet as the shader's "curved part" (wormhole_core.gdshaderinc), with G, the path length,
    # interpolated as F is.
    _X = (np.polynomial.legendre.leggauss(4)[0] + 1) / 2
    TAU = _X * _X
    A = np.linalg.inv(np.vander(TAU, 4, increasing=True))

    def fil(self, b, turn, reg=None):
        """reg: force the regime (the table's rows); by default it follows from b"""
        f = dict(ra=b if turn else self.rmin)
        f['span'] = max(self.Rout - f['ra'], 1e-6 * self.R)
        f['al'] = (f['ra'] - self.rho0) / f['span']
        f['ga'] = 0.0 if turn else (self.rmin - b) / f['span']
        mn, mx = min(f['al'], f['ga']), max(f['al'], f['ga'])
        f.update(mn=mn, mx=mx, reg=(0 if mx < 1 else (1 if mn < 1 else 2)) if reg is None else reg,
                 E0=max(np.sqrt(f['al']) + np.sqrt(f['ga']), 1e-12))
        r = f['ra'] + f['span'] * self.TAU
        u = (r - self.rho0) / (2 * self.R)
        G = np.sqrt(2 * self.R) * r / np.sqrt((1 - u) * (r + b))
        if f['reg'] >= 1: G = G / np.sqrt(self.TAU + mx)
        if f['reg'] == 2: G = G / np.sqrt(self.TAU + mn)
        f['e'] = self.A @ (b * G / (r * r))
        f['g'] = self.A @ G
        f['zlo'] = 0.0 if f['reg'] == 0 else np.sqrt(mn)
        f['zhi'] = self.fil_z(f, 1.0)
        f['psi'], f['arc'] = self.fil_at(f, f['zhi'])[:2]
        return f

    def fil_z(self, f, t):
        if f['reg'] == 0:
            return np.log((np.sqrt(t + f['al']) + np.sqrt(t + f['ga'])) / f['E0'])
        return np.sqrt(t + f['mn'])

    def fil_mom(self, f, z):
        """tau at z and the moments int_0^tau t^k w dt, k = 0..3"""
        al, ga, mn, mx = f['al'], f['ga'], f['mn'], f['mx']
        if f['reg'] == 0:
            E = f['E0'] * np.exp(z)
            sm = 0.5 * (E - (mx - mn) / E)
            t = max(sm * sm - mn, 0.0)
            S = sm * (E - sm)
            B, C = al + ga, al * ga
            D = [2 * z, S - np.sqrt(C) - 0.5 * B * 2 * z]
            for k in range(2, 4):
                D.append((t ** (k - 1) * S - (k - 0.5) * B * D[k - 1] - (k - 1) * C * D[k - 2]) / k)
            return t, 0.5 * np.array(D)
        t = max(z * z - mn, 0.0)
        if f['reg'] == 1:
            # int_0^t dt / (2 sqrt(t + mn)) = z - sqrt(mn): as t / (z + sqrt(mn)) it is 0 / 0 at a
            # turning ray's turning point (the shader's wh_filMom the same)
            n = [max(z - np.sqrt(mn), 0.0)]
            for k in range(1, 4):
                n.append((t ** k * z - 2 * k * mn * n[-1]) / (2 * k + 1))
            return t, np.array(n)
        return t, np.array([t ** (k + 1) / (2 * (k + 1)) for k in range(4)])

    def fil_at(self, f, z):
        """(psi, path length, tau) from the fillet's inner end to z"""
        t, m = self.fil_mom(f, z)
        return f['e'] @ m, f['g'] @ m, t

    def fil_solve(self, f, T):
        z = f['zlo'] + (f['zhi'] - f['zlo']) * min(max(T / max(f['psi'], 1e-300), 0.0), 1.0)
        for _ in range(2):
            t, m = self.fil_mom(f, z)
            dz = np.polyval(f['e'][::-1], t) * (z if f['reg'] == 2 else 1.0)
            z = min(max(z - (f['e'] @ m - T) / max(dz, 1e-300), f['zlo']), f['zhi'])
        return z

    def fil_l(self, f, t, side):
        s = np.sqrt(min(max((f['ra'] + f['span'] * t - self.rho0) / (2 * self.R), 0.0), 0.5))
        return side * (self.Lc + self.R * (2 * np.arcsin(s) - self.th0))

    def fillet_table(self, N=256):
        """The shader's fillet table, as WormholeSpace.fillet_table makes it. Returns (table (4, N, 4) float32, lo, inv, reg)."""
        sp = max(self.Rout - self.rmin, 1e-6 * self.R)
        alp = (self.rmin - self.rho0) / sp
        b1 = min(max(self.rmin - sp, 0.0), self.rmin)
        b3 = min(max(0.5 * (self.Rout + self.rho0), self.rmin), self.Rout)
        lo = [0.0, b1, self.rmin, b3]
        hi = [b1, self.rmin, b3, self.Rout]
        reg = [2 if alp >= 1 else 1, 1 if alp >= 1 else 0, 0, 1]
        tab = np.zeros((4, N, 4), np.float32)
        inv = np.zeros(4)
        for row in range(4):
            sb = hi[row] - lo[row]
            inv[row] = (N - 1) / sb if sb > 0 else 0.0
            for i in range(N):
                b = lo[row] + sb * i / (N - 1)
                f = self.fil(b, row >= 2, reg[row])
                sc = (np.sqrt(f['mx']) if reg[row] >= 1 else 1.0) * (np.sqrt(f['mn']) if reg[row] == 2 else 1.0)
                tab[row, i] = f['e'] * sc
        return tab, np.array(lo), inv, np.array(reg, float)

    def fast(self, l_s, n_s, vl, w):
        """The shader's wh_curved without balls: kind 2 floor (l, n), or +-1 exit side (n, vl, w)."""
        rho0, R, Lc, L = self.rho0, self.R, self.Lc, self.L
        wn = np.linalg.norm(w)
        als = abs(l_s)
        rs = float(self.r(l_s))
        b = rs * wn
        e1 = n_s
        e2 = w / wn if wn > 1e-12 else _any_perp(n_s)
        turn = b > self.rmin
        f = self.fil(b, turn)
        from_edge = als >= L * (1 - 1e-12)
        ths = self.th0 + max(als - Lc, 0.0) / R
        ts = rs * vl * vl / (1 + wn) if turn else 2 * R * np.sin((ths + self.th0) / 2) * np.sin((ths - self.th0) / 2)
        ts = 1.0 if from_edge else min(max(ts / f['span'], 0.0), 1.0)
        zs = self.fil_z(f, ts)
        Ss = np.array(self.fil_at(f, zs)[:2])
        d = 1.0 if vl >= 0 else -1.0
        x = l_s * d
        sideS = 1.0 if l_s > 0 else -1.0
        hasA = vl * sideS < 0 if turn else x < -Lc
        hasB = (not turn) and Lc > 0 and x < Lc
        cFromStart = (not hasA) if turn else x > Lc
        sideA = sideS if turn else -d
        sideC = sideS if turn else d
        x0B = max(x, -Lc)
        DB = Lc - x0B if hasB else 0.0
        wc = b / rho0
        # sqrt(1 - wc^2) as the shader takes it: (rho0 - b)(rho0 + b) / rho0^2, rho0 - b from vl^2
        omb = rs * vl * vl / (1 + wn) - (R if from_edge else 2 * R * np.sin((ths + self.th0) / 2) * np.sin((ths - self.th0) / 2))
        vlc = max(np.sqrt(max(omb * (rho0 + b), 0.0)) / rho0, 1e-300)
        kc = wc / (rho0 * vlc)
        PA = Ss if hasA else np.zeros(2)
        PB = np.array([kc, 1 / vlc]) * DB
        C0 = Ss if cFromStart else np.zeros(2)
        tot = PA + PB + np.array([f['psi'], f['arc']]) - C0
        # the floor in the shell: n.z starts positive and its zeros are pi apart (the shader's test)
        if n_s[2] > 0 and (tot[0] >= np.pi or n_s[2] * np.cos(tot[0]) + e2[2] * np.sin(tot[0]) < 0):
            psi_f = np.arctan2(e1[2], -e2[2])
            nF = np.cos(psi_f) * e1 + np.sin(psi_f) * e2
            if PA[0] <= psi_f < PA[0] + PB[0]:
                return dict(kind=2, l=d * (x0B + (psi_f - PA[0]) / kc), n=nF)
            inA = psi_f < PA[0]
            T = PA[0] - psi_f if inA else C0[0] + psi_f - PA[0] - PB[0]
            t = self.fil_at(f, self.fil_solve(f, min(max(T, 0.0), f['psi'])))[2]
            return dict(kind=2, l=self.fil_l(f, t, sideA if inA else sideC), n=nF)
        n = np.cos(tot[0]) * e1 + np.sin(tot[0]) * e2
        t = -np.sin(tot[0]) * e1 + np.cos(tot[0]) * e2
        bR = b / self.Rout
        return dict(kind=int(sideC), l=sideC * L, n=n, vl=sideC * np.sqrt(max(1 - bR * bR, 0.0)),
                    w=bR * t, steps=5)


def _any_perp(n):
    t = np.array([1.0, 0, 0]) if abs(n[0]) < 0.9 else np.array([0, 1.0, 0])
    t = t - n * np.dot(t, n)
    return t / np.linalg.norm(t)
