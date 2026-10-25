"""Gravity through the wormhole (ref/gravity.py): the separated ODE against an independent 2D
solve of Laplace's equation, for several profiles; prints the numbers the Godot test checks.
Exit status 1 on any failure."""
import sys
import numpy as np
from wh import Wormhole
from gravity import Gravity, solve_2d

PROFILES = {                      # (rho0, h, R) in metres, 1 unit of the video = 10 m
    'video (3, 5, 1)': (3.0, 5.0, 1.0),
    'h = R (3, 1, 1)': (3.0, 1.0, 1.0),
    'h < R, crease (3, 0.4, 1)': (3.0, 0.4, 1.0),
    'long fillet (3, 3, 2.5)': (3.0, 3.0, 2.5),
}

fails = 0


def check(name, ok, detail):
    global fails
    print(('PASS ' if ok else 'FAIL ') + name + '  ' + detail)
    fails += 0 if ok else 1


for name, (rho0, h, R) in PROFILES.items():
    W = Wormhole(rho0, h, R)
    G = Gravity(W)
    print(f'--- {name}: beta = {G.beta:+.4f} m^3, floor g at the middle {G.floor_g(0.0):.4f}, '
          f'at the mouth (l = L) {G.floor_g(W.L):.4f}')
    # 1. the ODE holds: (r^2 f')' - 2 f = 0, by finite differences of the solution
    ls = np.concatenate([np.linspace(-W.L - 6, W.L + 6, 401)])
    ls = ls[np.min(np.abs(ls[:, None] - np.array([-W.L, -W.Lc, 0, W.Lc, W.L])[None]), axis=1) > 2e-3]
    e = 1e-4
    flux = lambda l: W.r(l) ** 2 * G.f(l)[1]
    res = (flux(ls + e) - flux(ls - e)) / (2 * e) - 2 * G.f(ls)[0]
    check('ODE residual', np.max(np.abs(res)) < 1e-5, f'max |(r^2 f\')\' - 2 f| = {np.max(np.abs(res)):.2e}')
    # 2. continuity across the joins of the profile (cylinder / fillet / flat)
    jump = 0.0
    for lj in (W.Lc, W.L):
        a, b = G.f(np.array([lj - 1e-9, lj + 1e-9]))
        jump = max(jump, abs(a[1] - a[0]), abs(b[1] - b[0]))
    check('f and f\' continuous at the joins', jump < 1e-6, f'max jump {jump:.1e}')
    # 3. independent: Laplace's equation on a (l, theta) grid at two resolutions, extrapolated
    out = []
    for dl, m in ((0.1, 64), (0.05, 128)):
        lg, fg, rest = solve_2d(W, dl=dl, m=m)
        out.append((lg, fg, rest))
    probe = np.array([0.0, W.Lc, 0.5 * (W.Lc + W.L), W.L, W.L + 2.0])
    f1 = np.interp(probe, out[0][0], out[0][1])
    f2 = np.interp(probe, out[1][0], out[1][1])
    fx = (4 * f2 - f1) / 3                       # Richardson: second-order scheme
    fo = G.f(probe)[0]
    err = np.max(np.abs(fx - fo) / W.r(probe))
    check('2D Laplace solve agrees (floor g)', err < 2e-3,
          f'floor g at l = {np.round(probe, 2)}: ODE {np.round(fo / W.r(probe), 4)}, 2D {np.round(fx / W.r(probe), 4)}, '
          f'max diff {err:.1e}; non-cos(theta) part of the 2D solution {out[1][2]:.1e} m')
    # 4. the size axiom of the video (a smaller portal disturbs the world less): scaling the
    #    wormhole by k scales beta by k^3, so at a fixed distance the disturbance falls as k^3
    Gs = Gravity(Wormhole(rho0 / 10, h / 10, R / 10))
    check('size: beta scales as k^3', abs(Gs.beta * 1000 / G.beta - 1) < 1e-6,
          f'beta at 1/10 size x 1000 = {Gs.beta * 1000:+.5f}')

W = Wormhole(3.0, 5.0, 1.0)
G = Gravity(W)
print('\nnumbers for godot/tests/physics_test.gd (video profile): beta = %.5f, floor g at l = 0, 2, 4, 5, L: %s'
      % (G.beta, np.array2string(G.floor_g(np.array([0.0, 2.0, 4.0, 5.0, W.L])), precision=5)))
print('FAILURES:', fails)
sys.exit(1 if fails else 0)
