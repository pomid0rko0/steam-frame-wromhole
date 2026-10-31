"""
The wormhole's profile r(l), w(l) in float64 (NumPy, vectorized), for every h and R (h < R: the
fillets meet in a crease), for ref/gravity.py. The space and its profile: docs/geometry.md. What
the renderer computes is checked against ref/space.py.
"""
import os
import re

import numpy as np


def app_profile():
    """The app's throat, (rho0, h, R) in metres: godot/main.gd's THROAT_RADIUS, HALF_LENGTH, FILLET."""
    src = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'godot', 'main.gd')).read()
    return tuple(float(re.search(r'^const %s := ([\d.]+)' % k, src, re.M).group(1))
                 for k in ('THROAT_RADIUS', 'HALF_LENGTH', 'FILLET'))


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
