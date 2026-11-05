"""Stereo where light is bent (tests/curved_check.gd): each eye's picture against rays this script
traces itself, independently of the shaders' method: the eye moved from the head along a geodesic
and its frame carried along (RK4), each pixel's ray integrated as a geodesic of the space in 3D
(RK4, the equations of docs/geometry.md, «Движение»; steps of STEP and STEP_CYL in and near the
curved zone, longer out in the flat universes), however many times it goes round the throat, up to
RAY_MAX. In the throat's cylinder the space is a line times a sphere of radius rho0, and a geodesic
is uniform along l and along a great circle of the sphere: there a ray goes by that closed form,
in steps of STEP_CYL where it may meet a body (within the body's slab of l, and of the angle round
the throat the body spans) and in one jump to the next such place or the cylinder's end elsewhere,
so a ray goes round the throat thousands of times (the images converging next to the line across
it, seen from inside the cylinder); the
balls and cubes as BallWorld defines them (chord distance in R^4; the 4D box cut by the space), met
by each step's chord of R^4; the floor where the height r(l) n_z + lift goes through 0.
Checks per eye:
  bodies: in a band round each body's outline in the picture and inside it, the pixels whose ray
    meets a red ball or a green cube against the picture's red and green: at most MAX_FAR
    mismatches beyond MAX_EDGE px of the traced outline, and each body's image's centre within
    MAX_OFFSET px (images of at least MIN_IMAGE px and MIN_THICK: the slivers near the throat's
    photon sphere, a pixel or two thick, move by a pixel with the last digits of the eye's place,
    and the outline's check takes them); rays still going at RAY_MAX are left out, and so is a pixel
    whose ray a quarter of a pixel off its centre is;
  every image: on a grid of every GRID-th pixel, a traced body where the picture shows none within
    MAX_EDGE px counts as a mismatch too (an image the picture lacks);
  a mismatch counts where the pixel is what the trace says at its centre all across (rays a quarter
    of a pixel off each way agree): where they don't, a body's edge crosses the pixel, and near the
    photon sphere images a pixel across or less come and go with a hair of the ray's direction;
    a ball's pixel where the trace has a cube in front (or a cube's where a ball) is the front
    body's pixel its image lacks, judged by that body's outline, when a ray a quarter of a pixel off
    its centre meets this kind next with the other kind taken out (near the photon sphere both kinds' images, thinner than a pixel,
    lie in one band, and a hair off the front one shows the one behind);
  and a body's pixel whose rays pass it by counts only if no ray within MAX_EDGE px meets that
    kind (thin: an image thinner than a pixel, a hundredth of one at a cube's corner on the eye's
    axis, which the rays near the pixel's centre miss and the rasterizer draws where a triangle
    covers its centre; the ray is sought by Newton's steps on how near rays come to that kind);
  floor: sampled floor pixels: the checker cell the traced ray lands in (light or dark, after the
    haze) against the picture's colour, away from the cells' edges and lines (by the pixel's
    footprint on the floor, and under foveation by two of its texel's: the cell's edge filtered over
    the texel, then between neighbouring texels), where the texel's footprint leaves the checker its
    full contrast: AGREE of them at least (where FLOOR_MIN of them are usable).
   python3 tools/compare/curved.py prefix [left|right]   (prefix.json, prefix_app_left.png, prefix_app_right.png;
                                                          an eye named: that eye alone)
Rendered with foveation (the json's fovea: each eye's g x, y, r0 and m, foveation.gd's warp), the
floor and what is seen through the lens come from a texture whose texel at r pixels from g spans
sqrt(1 + (m (r - r0))^2) pixels along r beyond r0 (fewer across), one within: there MAX_EDGE,
MAX_OFFSET and the grid's reach are that many times the larger.
With CURVED_DIFF=1 in the environment it also writes prefix_diff_left.png, _right.png: the picture
dimmed, the traced bodies' pixels the picture lacks bright, the picture's the trace lacks dark, those
beyond MAX_EDGE yellow, the grid's lacking rays white."""
import json, os, sys
import numpy as np
from PIL import Image
from scipy import ndimage

MAX_EDGE = 2.0
MAX_FAR = 10
MAX_OFFSET = 0.5
AGREE = 0.995
BAND = 4
MIN_IMAGE = 30          # px: an image's centre is checked if it has this many
MIN_THICK = 2.0         # and its pixels are this many times its outline's (a disc of radius 4 px: 2)
STEP = 0.05             # m: RK4 steps on the fillets and near the zone (a chord strays 0.3 mm from
STEP_CYL = 0.1          # the path), on the cylinder (0.4 mm); out in a flat universe a tenth of the
STEP_MAX = 0.5          # way to the zone's edge, up to this
RAY_MAX = 30000.0       # m along a ray at most (the cylinder's jumps make a long one cheap)
FLOOR_SAMPLES = 1500
FLOOR_MIN = 100         # fewer usable floor samples (a view without much floor): no floor check
GRID = 4
THIN_STEPS = 8          # Newton's steps towards an image thinner than a pixel at most
THIN_H = 0.01           # px: the rays off a pixel's centre for the gradient of their gap
THIN_OVER = 1.1         # a step goes this much past where the gap's line crosses 0 (into the body)
THIN_GRID = 17          # rays across the reach's disc round a pixel to start Newton's steps from
THIN_STARTS = 3         # its nearest rays it starts from

pre = sys.argv[1]
EYES = sys.argv[2:3] or ['left', 'right']
D = json.load(open(pre + '.json'))
FOVEA = D.get('fovea') or None
rho0, h, R = D['profile']
lift = D['lift']
Lc = max(h - R, 0.0)
th0 = float(np.arcsin(max(1.0 - h / R, 0.0)))
L = Lc + R * (np.pi / 2 - th0)
Rout = rho0 + R
W, H = D['size']


def theta(al):
    return th0 + (np.clip(al, Lc, L) - Lc) / R


def r_of(l):
    al = np.abs(l)
    return np.where(al <= L, rho0 + R * (1 - np.cos(theta(al))), al - L + Rout)


def dr_of(l):
    al = np.abs(l)
    return np.sign(l) * np.where(al <= L, np.sin(theta(al)), 1.0)


def w_of(l):
    al = np.abs(l)
    inner = np.where(al <= Lc, al, h - R + R * np.sin(theta(al)))
    return np.sign(l) * np.where(al <= L, inner, h)


def embed(l, n):
    return np.concatenate([r_of(l)[..., None] * n, w_of(l)[..., None]], -1)


def rhs(l, n, vl, v, vecs):
    """The geodesic equations, and parallel transport of vecs [(U_l, u)...]."""
    r = r_of(l)[..., None]
    k = dr_of(l)[..., None] / r
    vv = np.sum(v * v, -1, keepdims=True)
    out = [vl, v / r, (k * vv)[..., 0], -k * vl[..., None] * v - (vv / r) * n]
    for Ul, u in vecs:
        uv = np.sum(u * v, -1, keepdims=True)
        out.append(((k * uv)[..., 0], -k * Ul[..., None] * v - (uv / r) * n))
    return out


def rk4(state, hs):
    def add(s, d, c):
        def m(x):
            return (c[..., None] if np.ndim(c) and np.ndim(x) > np.ndim(c) else c) * x
        out = [s[0] + m(d[0]), s[1] + m(d[1]), s[2] + m(d[2]), s[3] + m(d[3])]
        for (Ul, u), (dUl, du) in zip(s[4:], d[4:]):
            out.append((Ul + m(dUl), u + m(du)))
        return out

    def f(s):
        return rhs(s[0], s[1], s[2], s[3], s[4:])
    hs = np.asarray(hs, float)
    hv = hs[..., None] if hs.ndim else hs              # the step for vectors (n, v, u)

    def mul(c, x):
        return (c[..., None] if np.ndim(c) and np.ndim(x) > np.ndim(c) else c) * x
    k1 = f(state)
    k2 = f(add(state, k1, hs / 2))
    k3 = f(add(state, k2, hs / 2))
    k4 = f(add(state, k3, hs))
    new = [state[i] + mul(hs / 6, k1[i] + 2 * k2[i] + 2 * k3[i] + k4[i]) for i in range(4)]
    for j in range(len(state) - 4):
        Ul = state[4 + j][0] + mul(hs / 6, k1[4 + j][0] + 2 * k2[4 + j][0] + 2 * k3[4 + j][0] + k4[4 + j][0])
        u = state[4 + j][1] + mul(hs / 6, k1[4 + j][1] + 2 * k2[4 + j][1] + 2 * k3[4 + j][1] + k4[4 + j][1])
        new.append((Ul, u))
    n = new[1] / np.linalg.norm(new[1], axis=-1, keepdims=True)
    new[1] = n
    new[3] = new[3] - np.sum(new[3] * n, -1, keepdims=True) * n
    return new


def eye_of(e):
    """The eye in the curved space: the head moved along the geodesic of its play-space offset, the
    head's frame carried along; then the eye's camera axes (right, up, back) in that frame."""
    hd = D['head']
    l = np.array([hd['l']])
    n = np.array([hd['n']], float)
    f = [np.array(x, float) for x in hd['frame']]
    o = np.array(e['origin']) - np.array(hd['pos'])
    T = o[0] * f[0] + o[1] * f[1] + o[2] * f[2]
    dist = np.linalg.norm(T)
    vecs = [(np.array([x[0]]), np.array([x[1:]])) for x in f]
    if dist > 0:
        steps = 64
        state = [l, n, np.array([T[0] / dist]), np.array([T[1:] / dist])] + vecs
        for _ in range(steps):
            state = rk4(state, dist / steps)
        l, n, vecs = state[0], state[1], state[4:]
    F = [np.r_[Ul[0], u[0]] for Ul, u in vecs]
    B = np.array(e['basis'], float)       # columns: the eye's right, up, back in the play space
    axes = [B[k][0] * F[0] + B[k][1] * F[1] + B[k][2] * F[2] for k in range(3)]
    return float(l[0]), n[0], axes


def pixel_rays(e, px, py):
    """Pixel (px, py)'s ray in the eye's view space (x right, y up, -z forward); row 0 on top."""
    lt, rt, bt, tp = e['frustum']
    x = lt + (rt - lt) * (px + 0.5) / W
    y = tp - (tp - bt) * (py + 0.5) / H
    d = np.c_[x, y, -np.ones_like(x)]
    return d / np.linalg.norm(d, axis=-1, keepdims=True)


def unit4(v):
    v = np.asarray(v, float)
    return v / np.linalg.norm(v)


def normal4(C):
    """The space's normal at its point C (up to sign)."""
    x = C[:3]; rho = np.linalg.norm(x); a = abs(C[3]); sw = 1.0 if C[3] >= 0 else -1.0
    Ka = Lc - R * np.sin(th0)
    if rho >= Rout:
        return np.array([0, 0, 0, 1.0])
    if a <= Ka:
        return np.r_[x / rho, 0.0]
    q = np.array([rho - Rout, a - Ka]); q /= np.linalg.norm(q)
    return np.r_[-q[0] * x / rho, -q[1] * sw]


BALLS = [(np.array(b['c'], float), b['r']) for b in D['balls']]
CUBES = []
for c in D['cubes']:
    C = np.array(c['c'], float); e1 = unit4(c['e1']); e2 = unit4(c['e2']); N = normal4(C)
    M = np.array([e1, e2, N])
    e3 = np.linalg.svd(M)[2][-1]          # orthogonal to the other three
    CUBES.append((C, np.array([e1, e2, e3, N]), c['half']))


def seg_ball(P0, P1, C, rad):
    """Where along the chord P0 -> P1 it first enters the ball (0..1), else 2."""
    d = P1 - P0
    q = P0 - C
    a = np.maximum(np.sum(d * d, -1), 1e-30)
    b = np.sum(q * d, -1)
    c = np.sum(q * q, -1) - rad * rad
    disc = b * b - a * c
    u = (-b - np.sqrt(np.maximum(disc, 0))) / a
    u = np.where(c <= 0, 0.0, u)
    return np.where((disc >= 0) & (u >= 0) & (u <= 1), u, 2.0)


def seg_box(P0, P1, C, Ax, half):
    """Where along the chord P0 -> P1 it first enters the 4D box (0..1), else 2."""
    o = (P0 - C) @ Ax.T
    d = (P1 - P0) @ Ax.T
    with np.errstate(divide='ignore', invalid='ignore'):
        t1 = (-half - o) / d
        t2 = (half - o) / d
    # along an axis it does not move: inside that slab for good, or never in it
    t1 = np.where(d == 0, np.where(np.abs(o) <= half, -np.inf, np.inf), t1)
    t2 = np.where(d == 0, np.where(np.abs(o) <= half, np.inf, np.inf), t2)
    tin = np.max(np.minimum(t1, t2), -1)
    tout = np.min(np.maximum(t1, t2), -1)
    u = np.maximum(tin, 0)
    return np.where((tin <= tout) & (u <= 1) & (tout >= 0), u, 2.0)


def gap_ball(P0, P1, C, rad):
    """How far outside the ball the chord P0 -> P1 comes nearest it (negative: in it)."""
    d = P1 - P0
    q = P0 - C
    u = np.clip(-np.sum(q * d, -1) / np.maximum(np.sum(d * d, -1), 1e-30), 0.0, 1.0)
    return np.linalg.norm(q + u[:, None] * d, axis=-1) - rad


def gap_box(P0, P1, C, Ax, half):
    """How far outside the 4D box the chord P0 -> P1 comes nearest it, in the box's own measure (the
    largest of its slabs' distances; negative: in it). Along the chord that measure is the largest
    of eight linear functions: its least on the chord is at an end or where two of them cross."""
    o = (P0 - C) @ Ax.T
    d = (P1 - P0) @ Ax.T
    c = np.concatenate([o, -o], -1)                   # [m, 8]: c + k u
    k = np.concatenate([d, -d], -1)
    with np.errstate(divide='ignore', invalid='ignore'):
        u = (c[:, None, :] - c[:, :, None]) / (k[:, :, None] - k[:, None, :])
    u = np.concatenate([u.reshape(len(c), -1), np.zeros((len(c), 1)), np.ones((len(c), 1))], -1)
    u = np.where(np.isfinite(u), np.clip(u, 0.0, 1.0), 0.0)
    g = np.max(c[:, None, :] + k[:, None, :] * u[:, :, None], -1)
    return g.min(-1) - half


def height(l, n):
    return r_of(l) * n[..., 2] + lift


def cyl_go(l, n, vl, v, hs):
    """Rays in the throat's cylinder moved hs along their geodesics, in closed form."""
    vt = np.linalg.norm(v, axis=-1)
    vh = v / np.maximum(vt, 1e-300)[:, None]
    a = (vt / rho0 * hs)[:, None]
    n2 = np.cos(a) * n + np.sin(a) * vh
    v2 = vt[:, None] * (np.cos(a) * vh - np.sin(a) * n)
    n2 /= np.linalg.norm(n2, axis=-1, keepdims=True)
    return [l + vl * hs, n2, vl, v2 - np.sum(v2 * n2, -1, keepdims=True) * n2]


def cyl_jump(l, n, vl, v, reach, left):
    """For rays in the throat's cylinder, how far each may go before it could meet a body (reach:
    [centre (R^4), chord distance its points keep within]) or leave the cylinder, at most left: 0
    where it may meet one at once (in a body's slab of l and its window of angle). On the cylinder a
    point is (rho0 n, l) in R^4, and a ray's n turns round a fixed great circle at |v| / rho0 a
    metre: a point within chord c of C has |l - C_w| < c, and its angle round the circle from C's
    direction in the circle's plane (A: C's distance from the centre in that plane) has a cosine at
    least (rho0^2 + |C_xyz|^2 - c^2) / (2 rho0 A)."""
    m = len(l)
    out = np.minimum(left, np.where(vl > 0, (Lc - l) / np.where(vl > 0, vl, 1.0),
                                    np.where(vl < 0, (-Lc - l) / np.where(vl < 0, vl, 1.0), np.inf)))
    vt = np.linalg.norm(v, axis=-1)
    vh = v / np.maximum(vt, 1e-300)[:, None]
    om = vt / rho0
    for C, c in reach:
        cx = C[:3]
        dl = l - C[3]
        inside = np.abs(dl) < c
        to_slab = np.where(dl < -c, np.where(vl > 0, (-c - dl) / np.where(vl > 0, vl, 1.0), np.inf),
                           np.where(dl > c, np.where(vl < 0, (c - dl) / np.where(vl < 0, vl, 1.0), np.inf), 0.0))
        a = n @ cx
        b = vh @ cx
        A = np.hypot(a, b)
        kap = (rho0 * rho0 + cx @ cx - c * c) / np.maximum(2 * rho0 * A, 1e-300)
        dlt = np.arccos(np.clip(kap, -1.0, 1.0))
        phi = np.arctan2(b, a)
        in_win = np.cos(phi) >= kap
        to_win = np.where(in_win, 0.0, np.where(om > 1e-12, np.mod(phi - dlt, 2 * np.pi) / np.maximum(om, 1e-300), np.inf))
        to_win = np.where(kap > 1.0, np.inf, to_win)      # its plane passes the body by
        t = np.where(inside, to_win, to_slab)
        out = np.minimum(out, t)
    return np.maximum(out, 0.0)


def trace(l0, n0, D4, smax=RAY_MAX, bodies=(1, 2), gap=0):
    """Rays from (l0, n0) along unit tangent vectors D4 [m, 4]: what each meets first: 1 a ball,
    2 a cube, 3 the floor (with its l, n and the way), 0 the sky, -1 still going at smax. Only the
    body kinds in bodies are there. With gap a kind (1, 2), also how near each ray's steps come to
    a body of that kind on its way (gap_ball, gap_box: the least; negative where it meets one)."""
    m = D4.shape[0]
    g = np.full(m, np.inf)
    l = np.full(m, l0); n = np.tile(n0, (m, 1)); vl = D4[:, 0].copy(); v = D4[:, 1:].copy()
    kind = np.full(m, -1); hit_l = np.zeros(m); hit_n = np.zeros((m, 3)); way = np.zeros(m)
    s = np.zeros(m)
    alive = np.ones(m, bool)
    reach = ([(C, rad) for C, rad in BALLS] if 1 in bodies else []) + ([(C, 2.0 * a) for C, _, a in CUBES] if 2 in bodies else [])
    while alive.any():
        idx = np.nonzero(alive)[0]
        r = r_of(l[idx])
        al = np.abs(l[idx])
        hs = np.where(al < L + 0.5, np.where(al < Lc - 0.1, STEP_CYL, STEP), np.clip(0.1 * (r - Rout), STEP, STEP_MAX))
        st = rk4([l[idx], n[idx], vl[idx], v[idx]], hs)
        # in the cylinder: by the closed form, a step where a body may be met, else a jump to the
        # next such place (just short of it) or the cylinder's end
        cyl = al < Lc - 1e-6
        jumped = np.zeros(len(idx), bool)
        if cyl.any():
            ci = idx[cyl]
            jmp = cyl_jump(l[ci], n[ci], vl[ci], v[ci], reach, smax - s[ci])
            big = jmp > STEP_CYL
            hc = np.where(big, jmp * (1 - 1e-9) - 1e-6, np.minimum(STEP_CYL, np.maximum(cyl_jump(l[ci], n[ci], vl[ci], v[ci], [], np.inf), 1e-9)))
            hc = np.maximum(hc, 1e-9)
            go = cyl_go(l[ci], n[ci], vl[ci], v[ci], hc)
            for k in range(4):
                st[k][cyl] = go[k]
            hs = hs.copy()
            hs[cyl] = hc
            jumped[cyl] = big
        P0 = embed(l[idx], n[idx])
        P1 = embed(st[0], st[1])
        best = np.full(len(idx), 2.0)
        what = np.zeros(len(idx), int)
        if 1 in bodies:
            for C, rad in BALLS:
                u = np.where(jumped, 2.0, seg_ball(P0, P1, C, rad))
                what = np.where(u < best, 1, what); best = np.minimum(best, u)
        if 2 in bodies:
            for C, Ax, a in CUBES:
                u = np.where(jumped, 2.0, seg_box(P0, P1, C, Ax, a))
                what = np.where(u < best, 2, what); best = np.minimum(best, u)
        # a jump goes nowhere near a body
        if gap == 1:
            for C, rad in BALLS:
                g[idx] = np.minimum(g[idx], np.where(jumped, np.inf, gap_ball(P0, P1, C, rad)))
        elif gap == 2:
            for C, Ax, a in CUBES:
                g[idx] = np.minimum(g[idx], np.where(jumped, np.inf, gap_box(P0, P1, C, Ax, a)))
        h0 = height(l[idx], n[idx]); h1 = height(st[0], st[1])
        fl = (h0 > 0) & (h1 <= 0)
        uf = np.where(fl, h0 / np.where(fl, h0 - h1, 1.0), 2.0)
        what = np.where(uf < best, 3, what); best = np.minimum(best, uf)
        hit = best <= 1
        hi = idx[hit]
        kind[hi] = what[hit]
        f = best[hit]
        hit_l[hi] = l[hi] + f * (st[0][hit] - l[hi])
        nn = n[hi] + f[:, None] * (st[1][hit] - n[hi])
        hit_n[hi] = nn / np.linalg.norm(nn, axis=-1, keepdims=True)
        way[hi] = s[hi] + f * hs[hit]
        alive[hi] = False
        l[idx], n[idx], vl[idx], v[idx] = st[0], st[1], st[2], st[3]
        s[idx] += hs
        # out in a flat universe, going away from the zone and up (no floor ahead, nothing to meet
        # once past the bodies): the sky
        rr = r_of(l[idx])
        out = (np.abs(l[idx]) > L) & (vl[idx] * np.sign(l[idx]) > 0) & (rr > 60.0)
        sky = idx[out & alive[idx]]
        kind[sky] = 0
        alive[sky] = False
        alive[idx[alive[idx] & (s[idx] >= smax)]] = False
    if gap:
        return kind, hit_l, hit_n, way, g
    return kind, hit_l, hit_n, way


def to_tangent(n0, d, axes):
    D4 = d[:, 0:1] * axes[0] + d[:, 1:2] * axes[1] + d[:, 2:3] * axes[2]
    u = D4[:, 1:] - np.sum(D4[:, 1:] * n0, -1, keepdims=True) * n0
    D4 = np.c_[D4[:, 0], u]
    return D4 / np.linalg.norm(D4, axis=-1, keepdims=True)


def look_floor(l, way):
    """The floor's light and dark colours there after the haze (look.gdshaderinc), sRGB 0..255."""
    A = np.array([[0.7874, 0.6038, 0.4064], [0.6559, 0.4624, 0.2846]])
    B = np.array([[0.6383, 0.7106, 0.7874], [0.4624, 0.5542, 0.6739]])
    hA = np.array([1.0, 0.6739, 0.3931]); hB = np.array([0.5071, 0.7293, 1.0])
    side = l >= 0
    base = np.where(side[:, None, None], A[None], B[None])
    hor = np.where(side[:, None], hA[None], hB[None])
    k = (1 - np.exp(-way / 70.0))[:, None, None]
    lin = base * (1 - k) + hor[:, None, :] * k
    srgb = np.where(lin <= 0.0031308, lin * 12.92, 1.055 * lin ** (1 / 2.4) - 0.055)
    return srgb * 255


def chart_xy(l, n):
    """A floor point's chart x, y (chart B mirrored in x)."""
    x = r_of(l)[:, None] * n
    return np.c_[np.where(l < 0, -x[:, 0], x[:, 0]), x[:, 1]]


ok = True
for side_i, eye_name in enumerate(('left', 'right')):
    if eye_name not in EYES:
        continue
    e = D['eyes'][side_i]
    img = np.asarray(Image.open(f'{pre}_app_{eye_name}.png').convert('RGB'), int)
    l0, n0, axes = eye_of(e)
    red = (img[..., 0] - np.maximum(img[..., 1], img[..., 2])) > 60
    green = (img[..., 1] - np.maximum(img[..., 0], img[..., 2])) > 60
    body = red | green
    # every image: rays on a coarse grid over the whole picture
    gy, gx = np.mgrid[0:H:GRID, 0:W:GRID]
    gy = gy.ravel(); gx = gx.ravel()
    gk, _, _, _ = trace(l0, n0, to_tangent(n0, pixel_rays(e, gx.astype(float), gy.astype(float)), axes))
    # each pixel's texel size (foveation, FOVEA: along r, the larger), 1 without
    texel = np.ones((H, W))
    if FOVEA:
        fgx, fgy, fr0, fm = FOVEA[4 * side_i:4 * side_i + 4]
        r = np.hypot(np.arange(W)[None, :] + 0.5 - fgx, np.arange(H)[:, None] + 0.5 - fgy)
        texel = np.where(r > fr0, np.sqrt(1 + (fm * (r - fr0)) ** 2), 1.0)
    reach = int(np.ceil(MAX_EDGE * texel.max())) + 1
    near_red = ndimage.binary_dilation(red, iterations=reach)
    near_green = ndimage.binary_dilation(green, iterations=reach)
    def steady(xs, ys, kind, has, bodies=(1, 2)):
        """Whether pixels (xs, ys) are what the trace says at their centres all across: rays a quarter
        of a pixel from the centre each way meet the body kind (has) or don't (not has). Where they
        don't agree the body's edge crosses the pixel (near the photon sphere an image a pixel or
        less across, where a ray a hair off goes elsewhere), and either verdict is the pixel's; so
        where one of them is still going at RAY_MAX (it may yet meet a body)."""
        ok = np.ones(len(xs), bool)
        if len(xs) == 0:
            return ok
        for dx, dy in ((-0.25, -0.25), (0.25, -0.25), (-0.25, 0.25), (0.25, 0.25)):
            k, _, _, _ = trace(l0, n0, to_tangent(n0, pixel_rays(e, xs + dx, ys + dy), axes), bodies=bodies)
            ok &= ((k == kind) == has) & (k >= 0)
        return ok
    def thin(xs, ys, kind, reach, alone):
        """Whether a ray within reach px of pixels (xs, ys)'s centres meets a body of that kind
        first: an image thinner than a pixel, which the rays at the centre and a quarter off it all
        pass by. Sought by Newton's steps on how near a ray comes to the kind's bodies (trace's gap,
        its gradient across the picture by rays THIN_H px off), from the centre, then from the ray
        of a grid round it (THIN_GRID across the reach) that comes nearest (the nearest stretch of
        a ray jumps from one way round the throat to another, and with it the gap's gradient), until
        a ray meets one (and no body of the other kind in front, but where alone: there the other
        kind is in front, and its outline judges the pixel)."""
        def meets(j, x, y):
            k, _, _, _ = trace(l0, n0, to_tangent(n0, pixel_rays(e, x, y), axes))
            return (k == kind) | alone[j]

        def newton(j, x, y):
            ok = np.zeros(len(j), bool)
            x = x.copy(); y = y.copy()
            live = np.ones(len(j), bool)
            for _ in range(THIN_STEPS):
                i = np.nonzero(live)[0]
                if len(i) == 0:
                    break
                m = len(i)
                px = np.r_[x[i], x[i] + THIN_H, x[i]]; py = np.r_[y[i], y[i], y[i] + THIN_H]
                _, _, _, _, gp = trace(l0, n0, to_tangent(n0, pixel_rays(e, px, py), axes), bodies=(kind,), gap=kind)
                g0 = gp[:m]
                gx_, gy_ = (gp[m:2 * m] - g0) / THIN_H, (gp[2 * m:] - g0) / THIN_H
                met = g0 <= 0
                if met.any():
                    ok[i[met]] = meets(j[i[met]], x[i[met]], y[i[met]])
                    live[i[met]] = False
                gg = gx_ * gx_ + gy_ * gy_
                go = ~met & np.isfinite(g0) & (gg > 0)
                live[i[~met & ~go]] = False
                i = i[go]
                x[i] -= THIN_OVER * g0[go] * gx_[go] / gg[go]
                y[i] -= THIN_OVER * g0[go] * gy_[go] / gg[go]
                live[i[np.hypot(x[i] - xs[j[i]], y[i] - ys[j[i]]) > reach[j[i]]]] = False
            return ok
        everyone = np.arange(len(xs))
        found = newton(everyone, xs.astype(float), ys.astype(float))
        u = np.linspace(-1.0, 1.0, THIN_GRID)
        gu, gv = [a.ravel() for a in np.meshgrid(u, u)]
        disc = np.hypot(gu, gv) <= 1.0
        gu, gv = gu[disc], gv[disc]
        for j in np.nonzero(~found)[0]:
            px, py = xs[j] + reach[j] * gu, ys[j] + reach[j] * gv
            k, _, _, _, gp = trace(l0, n0, to_tangent(n0, pixel_rays(e, px, py), axes), bodies=(kind,), gap=kind)
            hit = np.nonzero(gp <= 0)[0]
            if len(hit) and meets(np.full(len(hit), j), px[hit], py[hit]).any():
                found[j] = True
                continue
            b = np.argsort(gp)[:THIN_STARTS]
            found[j] = newton(np.full(len(b), j), px[b], py[b]).any()
        return found
    lack = ((gk == 1) & ~near_red[gy, gx]) | ((gk == 2) & ~near_green[gy, gx])
    li = np.nonzero(lack)[0]
    lack[li] = steady(gx[li].astype(float), gy[li].astype(float), gk[li], True)
    lacking = int(lack.sum())
    # the bodies: a band round the picture's outlines and the grid's traced bodies, and inside
    seed = body.copy()
    seed[gy[gk == 1], gx[gk == 1]] = True
    seed[gy[gk == 2], gx[gk == 2]] = True
    region = ndimage.binary_dilation(seed, iterations=BAND + GRID)
    ys, xs = np.nonzero(region)
    d = pixel_rays(e, xs.astype(float), ys.astype(float))
    kind, _, _, _ = trace(l0, n0, to_tangent(n0, d, axes))
    known = np.ones_like(red)
    known[ys, xs] = kind >= 0
    ref_red = np.zeros_like(red); ref_green = np.zeros_like(green)
    ref_red[ys, xs] = kind == 1; ref_green[ys, xs] = kind == 2
    line = f'{eye_name}: eye l {l0:.3f}, {lacking} grid rays meet a body the picture lacks, {int((~known).sum())} rays still going'
    ok &= lacking == 0
    far_all = np.zeros_like(red)
    for name, A, Rf, code in (('balls', red, ref_red, 1), ('cubes', green, ref_green, 2)):
        mis = (A ^ Rf) & region & known
        dist = ndimage.distance_transform_edt(~(Rf ^ ndimage.binary_erosion(Rf)))   # px to the traced outline
        far = mis & (dist > MAX_EDGE * texel)
        fy, fx = np.nonzero(far)
        far[fy, fx] = steady(fx.astype(float), fy.astype(float), np.full(len(fx), code), Rf[fy, fx])
        # the picture's body where the other kind is in front: its pixel the other kind's image
        # lacks, judged by that kind's outline; this kind's own only if no ray of the pixel meets it
        # without the other kind there
        other = (ref_green if code == 1 else ref_red)
        fy, fx = np.nonzero(far & A & other)
        far[fy, fx] = steady(fx.astype(float), fy.astype(float), np.full(len(fx), code), False, bodies=(code,))
        # the picture's body where the rays pass by: its image may be thinner than a pixel
        fy, fx = np.nonzero(far & A & ~Rf)
        far[fy, fx] = ~thin(fx, fy, code, MAX_EDGE * texel[fy, fx], other[fy, fx])
        far_all |= far
        lab, nb = ndimage.label(ndimage.binary_dilation(Rf, iterations=2))
        worst = 0.0
        for k in range(1, nb + 1):
            reg = lab == k
            ry, rx = np.nonzero(Rf & reg); gy2, gx2 = np.nonzero(A & reg)
            img_k = Rf & reg
            outline = img_k & ~ndimage.binary_erosion(img_k)
            if len(rx) < MIN_IMAGE or len(rx) < MIN_THICK * outline.sum():
                continue
            if len(gx2) == 0:
                worst = 99.0; continue
            touches = rx.min() == 0 or ry.min() == 0 or rx.max() == W - 1 or ry.max() == H - 1
            if not touches:
                off = float(np.hypot(rx.mean() - gx2.mean(), ry.mean() - gy2.mean())) / texel[int(ry.mean()), int(rx.mean())]
                if os.environ.get('CURVED_DIFF') and off > MAX_OFFSET:
                    print(f'  {eye_name} {name}: image of {len(rx)} px at ({rx.mean():.0f}, {ry.mean():.0f}), '
                          f'{len(gx2)} in the picture, centre {off:.2f} px off')
                worst = max(worst, off)
        line += f' | {name} {nb} images: {int(mis.sum())} px differ, {int(far.sum())} beyond {MAX_EDGE} px of the outline, worst centre {worst:.2f} px'
        ok &= far.sum() <= MAX_FAR and worst <= MAX_OFFSET
    if os.environ.get('CURVED_DIFF'):
        out = (img * 0.4).astype(np.uint8)
        for A, Rf, c in ((red, ref_red, (255, 80, 80)), (green, ref_green, (80, 255, 80))):
            out[Rf & ~A & known] = c
            out[A & ~Rf & region & known] = (np.array(c) * 0.35).astype(np.uint8)
        out[gy[lack], gx[lack]] = (255, 255, 255)
        out[far_all] = (255, 255, 0)
        Image.fromarray(out).save(f'{pre}_diff_{eye_name}.png')
    # the floor: sampled pixels away from the bodies
    rng = np.random.default_rng(side_i)
    fy, fx = np.nonzero(~region)
    pick = rng.choice(len(fx), min(FLOOR_SAMPLES, len(fx)), replace=False)
    fx, fy = fx[pick], fy[pick]
    d = pixel_rays(e, fx.astype(float), fy.astype(float))
    # neighbours a pixel right and down, for the footprint of a pixel on the floor
    dxr = pixel_rays(e, fx + 1.0, fy.astype(float)); dyr = pixel_rays(e, fx.astype(float), fy + 1.0)
    T = to_tangent(n0, np.vstack([d, dxr, dyr]), axes)
    kind, hl, hn, way = trace(l0, n0, T, bodies=())
    m = len(fx)
    good = (kind[:m] == 3) & (kind[m:2 * m] == 3) & (kind[2 * m:] == 3)
    q = chart_xy(hl, hn)
    qq = q[:m]
    fw = np.maximum(np.abs(q[m:2 * m] - qq), np.abs(q[2 * m:] - qq))
    ft = fw * texel[fy, fx][:, None]                         # its texel's
    frac = np.abs(qq - np.round(qq))                         # cell units to the nearest edge or line
    good &= (np.all(frac > np.maximum(np.maximum(4 * fw, 2 * ft), 0.06), axis=1) & np.all(fw < 0.08, axis=1)
             & np.all(ft < 0.2, axis=1) & (way[:m] < 35))
    parity = (np.floor(qq[:, 0]) + np.floor(qq[:, 1])).astype(int) % 2
    cols = look_floor(hl[:m], way[:m])
    pix = img[fy, fx].astype(float)
    dl = np.abs(pix - cols[:, 0]).sum(-1); dd = np.abs(pix - cols[:, 1]).sum(-1)
    seen_light = dl < dd
    # look_checker gives 0 (the dark colour) where floor(x) + floor(y) is even
    agree = (seen_light == (parity == 1))[good]
    line += f' | floor: {int(good.sum())} samples, {100 * agree.mean() if agree.size else 0:.2f}% in the right cell'
    ok &= agree.size < FLOOR_MIN or agree.mean() >= AGREE
    print(line)
print('PASS' if ok else 'FAIL')
