"""Gravity through the wormhole (ref/gravity.py): the separated ODE against an independent 2D
solve of Laplace's equation, for several profiles; prints the numbers the Godot test checks.
Exit status 1 on any failure."""
import os
import re
import sys
import in_box  # noqa: F401 (first: on the Frame, into tools/box.sh's container)
import numpy as np
from geo import Space as Wormhole, app_profile, lift_of
from gravity import Gravity, solve_2d

PROFILES = {                      # (rho0, h, R) in metres
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
    print(f'--- {name}: beta = {G.beta:+.4f} m^3, g on the throat\'s side (n_z = 0) at its middle {G.side_g(0.0):.4f}, '
          f'at the curved zone\'s edge (l = L) {G.side_g(W.L):.4f}')
    # 1. the ODE holds: (r^2 f')' - 2 f = 0, by finite differences of the solution
    ls = np.linspace(-W.L - 6, W.L + 6, 401)
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
    check('2D Laplace solve agrees (g on the side, n_z = 0)', err < 2e-3,
          f'g on the side at l = {np.round(probe, 2)}: ODE {np.round(fo / W.r(probe), 4)}, 2D {np.round(fx / W.r(probe), 4)}, '
          f'max diff {err:.1e}; non-cos(theta) part of the 2D solution {out[1][2]:.1e} m')
    # 4. the size axiom (docs/gravity.md, «Размер»)
    Gs = Gravity(Wormhole(rho0 / 10, h / 10, R / 10))
    check('size: beta scales as k^3', abs(Gs.beta * 1000 / G.beta - 1) < 1e-6,
          f'beta at 1/10 size x 1000 = {Gs.beta * 1000:+.5f}')

W = Wormhole(*app_profile())
G = Gravity(W)
LIFT = lift_of(app_profile())
src = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'godot', 'ball_world.gd')).read()
RR = float(re.search(r'^const ROLLING_RESISTANCE := ([\d.]+)', src, re.M).group(1))


def floor_field(rho):
    """On the floor rho metres along it from the point under the throat's centre (lift below it):
    gravity's part along the floor, outward, and down, in g, from phi = z (1 + beta / r^3), z and r
    from the centre (WormholeSpace.floor_gravity)."""
    r2 = rho * rho + LIFT * LIFT
    r5 = r2 * r2 * np.sqrt(r2)
    return -3 * G.beta * LIFT * rho / r5, 1 + G.beta / r2 ** 1.5 - 3 * G.beta * LIFT * LIFT / r5


rhos = np.array([0.0, 2.5, 5.0, 10.0, 20.0])
along, up = floor_field(rhos)
print('\nnumbers for godot/tests/gravity_test.gd (the throat of godot/main.gd, lift %.1f m): beta = %.5f, '
      'floor g at rho = 0, 2.5, 5, 10, 20: %s' % (LIFT, G.beta, np.array2string(np.hypot(along, up), precision=5)))

# numbers for docs/gravity.md
from scipy.integrate import solve_ivp
from scipy.optimize import brentq, minimize_scalar
g = 9.81
best = minimize_scalar(lambda x: -floor_field(x)[0], bounds=(0.0, 3 * LIFT), method='bounded')
print('the floor: g %.3f under the throat\'s centre, %.3f at 2.5 m along it, %.3f at 5 m, %.3f at 10 m; '
      'the push along it outward, at most %.4f g at %.2f m' % (*np.hypot(along[:4], up[:4]), floor_field(best.x)[0], best.x))
ratio = lambda x: floor_field(x)[0] / floor_field(x)[1] - RR
print('  more than rolling friction (BallWorld.ROLLING_RESISTANCE %.3f of the weight) from %.2f to %.2f m along the floor'
      % (RR, brentq(ratio, 1e-6, best.x), brentq(ratio, best.x, 10 * LIFT)))


# in a flat universe's chart (the floor at z = 0, the throat's centre at (0, 0, lift)): docs/gravity.md's
# field
def flat(t, y):
    x = y[:3] - np.array([0, 0, LIFT])
    r = np.linalg.norm(x)
    return np.r_[y[3:], -g * (np.array([0, 0, 1.0]) * (1 + G.beta / r ** 3) - 3 * G.beta * x[2] / r ** 5 * x)]


land = lambda t, y: y[2]
land.terminal, land.direction = True, -1
for x0 in (2.5, 5.0):
    y = solve_ivp(flat, [0, 5], [x0, 0, 2.0, 0, 0, 0], events=land, rtol=1e-10, atol=1e-12)
    print('  let go 2 m over the floor %.1f m along it from under the throat\'s centre: lands %.1f cm farther out, '
          'after %.4f s (%.4f s in a uniform field)' % (x0, 100 * (y.y_events[0][0][0] - x0), y.t_events[0][0], np.sqrt(2 * 2.0 / g)))
# over the throat's centre, n = +z: phi = f(l) + lift, so l'' = -g f'(l), in a straight line through
# the throat from universe A to B and back, without air
l0 = W.L + 1.5
mid = lambda t, y: y[0]
mid.terminal, mid.direction = True, -1
fall = solve_ivp(lambda t, y: [y[1], -g * G.f(np.array([y[0]]))[1][0]], [0, 10], [l0, 0.0], events=mid,
                 rtol=1e-10, atol=1e-12).t_events[0][0]
print('let go on the axis over the throat\'s centre, 1.5 m over the curved zone: to the throat\'s middle in %.3f s '
      '(%.3f s in a uniform field over the same %.2f m), there and back to A in %.2f s, without air' %
      (fall, np.sqrt(2 * l0 / g), l0, 4 * fall))
print('FAILURES:', fails)
sys.exit(1 if fails else 0)
