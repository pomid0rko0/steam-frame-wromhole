"""Stereo in the curved zone (tests/curved_check.gd): each eye's picture against rays this script
traces itself, independently of the shaders' method: the eye moved from the head along a geodesic
and its frame carried along (RK4), each pixel's ray integrated as a geodesic of the space in 3D
(RK4, the equations of docs/geometry.md, «Движение»), the balls and cubes as BallWorld defines them
(chord distance in R^4; the 4D box cut by the space), the floor n.z = 0.
Checks per eye:
  bodies: in a band round each body's outline in the picture and inside it, the pixels whose ray
    meets a red ball or a green cube against the picture's red and green: at most MAX_FAR
    mismatches beyond MAX_EDGE px of the traced outline (the rays sample a body every STEP), and
    each body's centre within MAX_OFFSET px;
  floor: sampled floor pixels: the checker cell the traced ray lands in (light or dark, after the
    haze) against the picture's colour, away from the cells' edges and lines: AGREE of them at least.
   python3 tools/compare/curved.py prefix      (prefix.json, prefix_app_left.png, prefix_app_right.png)"""
import json, sys
import numpy as np
from PIL import Image
from scipy import ndimage

MAX_EDGE = 2.0
MAX_FAR = 10
MAX_OFFSET = 0.5
AGREE = 0.995
BAND = 4
STEP = 0.005            # m: RK4 steps of the bodies' rays
FLOOR_STEP = 0.02       # m: of the floor's
FLOOR_SAMPLES = 1500

pre = sys.argv[1]
D = json.load(open(pre + '.json'))
rho0, h, R = D['profile']
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
        out = [s[0] + c * d[0], s[1] + c * d[1], s[2] + c * d[2], s[3] + c * d[3]]
        for (Ul, u), (dUl, du) in zip(s[4:], d[4:]):
            out.append((Ul + c * dUl, u + c * du))
        return out

    def f(s):
        return rhs(s[0], s[1], s[2], s[3], s[4:])
    k1 = f(state)
    k2 = f(add(state, k1, hs / 2))
    k3 = f(add(state, k2, hs / 2))
    k4 = f(add(state, k3, hs))
    new = [state[i] + hs / 6 * (k1[i] + 2 * k2[i] + 2 * k3[i] + k4[i]) for i in range(4)]
    for j in range(len(state) - 4):
        Ul = state[4 + j][0] + hs / 6 * (k1[4 + j][0] + 2 * k2[4 + j][0] + 2 * k3[4 + j][0] + k4[4 + j][0])
        u = state[4 + j][1] + hs / 6 * (k1[4 + j][1] + 2 * k2[4 + j][1] + 2 * k3[4 + j][1] + k4[4 + j][1])
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


def trace(l0, n0, D4, smax, hs, bodies=True):
    """Rays from (l0, n0) along unit tangent vectors D4 [m, 4]: what each meets first: 1 a ball,
    2 a cube, 3 the floor (with its l, n and the way), 0 nothing within smax."""
    m = D4.shape[0]
    l = np.full(m, l0); n = np.tile(n0, (m, 1)); vl = D4[:, 0].copy(); v = D4[:, 1:].copy()
    kind = np.zeros(m, int); hit_l = np.zeros(m); hit_n = np.zeros((m, 3)); way = np.zeros(m)
    alive = np.ones(m, bool)
    s = 0.0
    while s < smax and alive.any():
        idx = np.nonzero(alive)[0]
        st = rk4([l[idx], n[idx], vl[idx], v[idx]], hs)
        P = embed(st[0], st[1])
        inside = np.zeros((len(idx), 2), bool)
        if bodies:
            for C, rad in BALLS:
                inside[:, 0] |= np.sum((P - C) ** 2, -1) < rad * rad
            for C, Ax, a in CUBES:
                inside[:, 1] |= np.all(np.abs((P - C) @ Ax.T) < a, -1)
        floor = (n[idx, 2] > 0) & (st[1][:, 2] <= 0) & ~inside[:, 0] & ~inside[:, 1]
        kind[idx[inside[:, 0]]] = 1
        kind[idx[inside[:, 1] & ~inside[:, 0]]] = 2
        fi = idx[floor]
        f = n[fi, 2] / (n[fi, 2] - st[1][floor, 2])
        kind[fi] = 3
        hit_l[fi] = l[fi] + f * (st[0][floor] - l[fi])
        nn = n[fi] + f[:, None] * (st[1][floor] - n[fi])
        nn[:, 2] = 0
        hit_n[fi] = nn / np.linalg.norm(nn, axis=-1, keepdims=True)
        way[fi] = s + f * hs
        alive[idx[inside[:, 0] | inside[:, 1] | floor]] = False
        l[idx], n[idx], vl[idx], v[idx] = st[0], st[1], st[2], st[3]
        s += hs
    return kind, hit_l, hit_n, way


def to_tangent(n0, d, axes):
    D4 = d[:, 0:1] * axes[0] + d[:, 1:2] * axes[1] + d[:, 2:3] * axes[2]
    u = D4[:, 1:] - np.sum(D4[:, 1:] * n0, -1, keepdims=True) * n0
    D4 = np.c_[D4[:, 0], u]
    return D4 / np.linalg.norm(D4, axis=-1, keepdims=True)


def look_floor(l, n, way):
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


ok = True
for side_i, eye_name in enumerate(('left', 'right')):
    e = D['eyes'][side_i]
    img = np.asarray(Image.open(f'{pre}_app_{eye_name}.png').convert('RGB'), int)
    l0, n0, axes = eye_of(e)
    red = (img[..., 0] - np.maximum(img[..., 1], img[..., 2])) > 60
    green = (img[..., 1] - np.maximum(img[..., 0], img[..., 2])) > 60
    body = red | green
    # the bodies: a band round the picture's outlines, and inside
    region = ndimage.binary_dilation(body, iterations=BAND)
    ys, xs = np.nonzero(region)
    d = pixel_rays(e, xs.astype(float), ys.astype(float))
    kind, _, _, _ = trace(l0, n0, to_tangent(n0, d, axes), 8.0, STEP)
    ref_red = np.zeros_like(red); ref_green = np.zeros_like(green)
    ref_red[ys, xs] = kind == 1; ref_green[ys, xs] = kind == 2
    line = f'{eye_name}: eye l {l0:.3f}'
    for name, A, Rf in (('balls', red, ref_red), ('cubes', green, ref_green)):
        mis = (A ^ Rf) & region
        dist = ndimage.distance_transform_edt(~(Rf ^ ndimage.binary_erosion(Rf)))   # px to the traced outline
        far = mis & (dist > MAX_EDGE)
        lab, nb = ndimage.label(ndimage.binary_dilation(Rf, iterations=2))
        worst = 0.0
        for k in range(1, nb + 1):
            reg = lab == k
            ry, rx = np.nonzero(Rf & reg); gy, gx = np.nonzero(A & reg)
            if len(gx) == 0 or len(rx) == 0:
                worst = 99.0; continue
            touches = rx.min() == 0 or ry.min() == 0 or rx.max() == W - 1 or ry.max() == H - 1
            if not touches:
                worst = max(worst, float(np.hypot(rx.mean() - gx.mean(), ry.mean() - gy.mean())))
        line += f' | {name} {nb}: {int(mis.sum())} px differ, {int(far.sum())} beyond {MAX_EDGE} px of the outline, worst centre {worst:.2f} px'
        ok &= nb >= 1 and far.sum() <= MAX_FAR and worst <= MAX_OFFSET
    # the floor: sampled pixels away from the bodies
    rng = np.random.default_rng(side_i)
    fy, fx = np.nonzero(~region)
    pick = rng.choice(len(fx), min(FLOOR_SAMPLES, len(fx)), replace=False)
    fx, fy = fx[pick], fy[pick]
    d = pixel_rays(e, fx.astype(float), fy.astype(float))
    # neighbours a pixel right and down, for the footprint of a pixel on the floor
    dxr = pixel_rays(e, fx + 1.0, fy.astype(float)); dyr = pixel_rays(e, fx.astype(float), fy + 1.0)
    T = to_tangent(n0, np.vstack([d, dxr, dyr]), axes)
    kind, hl, hn, way = trace(l0, n0, T, 40.0, FLOOR_STEP, bodies=False)
    m = len(fx)
    q = np.c_[np.abs(hl), np.arctan2(hn[:, 1], np.where(hl < 0, -hn[:, 0], hn[:, 0])) * 24 / (2 * np.pi)]
    qx = np.c_[np.abs(hl[m:2 * m]), np.arctan2(hn[m:2 * m, 1], np.where(hl[m:2 * m] < 0, -hn[m:2 * m, 0], hn[m:2 * m, 0])) * 24 / (2 * np.pi)]
    qy = np.c_[np.abs(hl[2 * m:]), np.arctan2(hn[2 * m:, 1], np.where(hl[2 * m:] < 0, -hn[2 * m:, 0], hn[2 * m:, 0])) * 24 / (2 * np.pi)]
    qq = q[:m]
    fw = np.maximum(np.abs(qx - qq), np.abs(qy - qq))
    fw = np.where(fw > 12, 24 - fw, fw)                      # the sectors' seam
    good = (kind[:m] == 3) & (kind[m:2 * m] == 3) & (kind[2 * m:] == 3)
    frac = np.abs(qq - np.round(qq))                         # cell units to the nearest edge or line
    good &= np.all(frac > np.maximum(4 * fw, 0.06), axis=1) & np.all(fw < 0.08, axis=1) & (way[:m] < 35)
    parity = (np.floor(qq[:, 0]) + np.floor(qq[:, 1])).astype(int) % 2
    cols = look_floor(hl[:m], hn[:m], way[:m])
    pix = img[fy, fx].astype(float)
    dl = np.abs(pix - cols[:, 0]).sum(-1); dd = np.abs(pix - cols[:, 1]).sum(-1)
    seen_light = dl < dd
    # look_checker gives 0 (the dark colour) where floor(x) + floor(y) is even
    agree = (seen_light == (parity == 1))[good]
    line += f' | floor: {int(good.sum())} samples, {100 * agree.mean() if agree.size else 0:.2f}% in the right cell'
    ok &= agree.size >= 200 and agree.mean() >= AGREE
    print(line)
print('PASS' if ok else 'FAIL')
