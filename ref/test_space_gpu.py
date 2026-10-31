"""godot/shaders/space.gdshaderinc on a GPU (EGL; in a cloud session llvmpipe) in float32 against
ref/space.py's float64: sp_trace, a pixel's ray to the floor or the sky; sp_toward, the direction
from an eye to a point (the bodies' vertices); sp_walk, an eye from the head with the play-space
axes carried along. Random eyes everywhere in the space,
random directions and points, near and far, on the app's throat (WH_PROFILE="rho0,h,R" for
another). Prints the errors and fails past the limits below (angles in radians, seen from the eye).

  python3 ref/test_space_gpu.py [N]
"""
import os
import sys

import in_box  # noqa: F401 (first: on the Frame, into tools/box.sh's container)
import subprocess
import tempfile

import moderngl
import numpy as np

from space import Space, app_profile
import tables

HERE = os.path.dirname(os.path.abspath(__file__))
CORE = open(os.path.join(HERE, '..', 'godot', 'shaders', 'space.gdshaderinc')).read()
PROF = tuple(float(v) for v in os.environ['WH_PROFILE'].split(',')) if 'WH_PROFILE' in os.environ else app_profile()
S = Space(*PROF)
N = int(sys.argv[1]) if len(sys.argv) > 1 else 4000
# the limits: a floor point or a sky direction as seen from the eye; a vertex's direction
LIM_TRACE = 2e-4
LIM_TOWARD = 1e-4
LIM_WALK = 1e-5     # m, and radians for the axes: one RK4 step over the profile's kinks; seen from 5 cm, 2e-4 rad

HEAD = """#version 430
layout(local_size_x = 64) in;
uniform float sp_rho0; uniform float sp_R; uniform float sp_Lc; uniform float sp_L; uniform float sp_Rout;
uniform sampler2D sp_tab; uniform sampler2D sp_ptab; uniform sampler2D sp_ytab;
layout(std430, binding = 0) buffer In { vec4 inp[]; };
layout(std430, binding = 1) buffer Out { vec4 outp[]; };
uniform int count;
"""
TRACE = HEAD + CORE + """
void main() {
    uint i = gl_GlobalInvocationID.x;
    if (i >= uint(count)) return;
    vec4 a = inp[2u * i];
    vec4 V = inp[2u * i + 1u];
    float side; vec3 d; float fl; float dist;
    int kind = sp_trace(a.x, a.yzw, V, side, d, fl, dist);
    outp[2u * i] = vec4(float(kind), side, fl, dist);
    outp[2u * i + 1u] = vec4(d, 0.0);
}
"""
WALK = HEAD + CORE + """
void main() {
    uint i = gl_GlobalInvocationID.x;
    if (i >= uint(count)) return;
    vec4 a = inp[5u * i];
    vec4 V = inp[5u * i + 1u];
    float l = a.x;
    vec3 n = a.yzw;
    vec4 f0 = inp[5u * i + 2u];
    vec4 f1 = inp[5u * i + 3u];
    vec4 f2 = inp[5u * i + 4u];
    sp_walk(l, n, V, V.x == 0.0 ? 0.0 : 1.0, f0, f1, f2);
    outp[5u * i] = vec4(l, n);
    outp[5u * i + 2u] = f0;
    outp[5u * i + 3u] = f1;
    outp[5u * i + 4u] = f2;
}
"""
TOWARD = HEAD + CORE + """
void main() {
    uint i = gl_GlobalInvocationID.x;
    if (i >= uint(count)) return;
    vec4 a = inp[2u * i];
    vec4 p = inp[2u * i + 1u];
    float dist;
    vec4 V = sp_toward(a.x, a.yzw, sp_r(abs(a.x)), p.x, p.yzw, dist);
    outp[2u * i] = V;
    outp[2u * i + 1u] = vec4(dist, 0.0, 0.0, 0.0);
}
"""


def run(ctx, src, rows, texs, per=2):
    prog = ctx.compute_shader(src)
    for k, v in (('sp_rho0', S.rho0), ('sp_R', S.R), ('sp_Lc', S.Lc), ('sp_L', S.L), ('sp_Rout', S.Rout)):
        if k in prog:
            prog[k].value = v
    prog['count'].value = len(rows) // per
    texs[0].use(0)
    texs[1].use(1)
    texs[2].use(2)
    for k, u in (('sp_tab', 0), ('sp_ptab', 1), ('sp_ytab', 2)):
        if k in prog:
            prog[k].value = u
    bi = ctx.buffer(np.asarray(rows, np.float32).tobytes())
    bo = ctx.buffer(reserve=len(rows) * 16)
    bi.bind_to_storage_buffer(0)
    bo.bind_to_storage_buffer(1)
    prog.run((len(rows) // per + 63) // 64)
    return np.frombuffer(bo.read(), np.float32).reshape(-1, 4).astype(float)


def rand_n(rng, zlo=0.0):
    while True:
        v = rng.normal(size=3)
        v /= np.linalg.norm(v)
        if v[2] > zlo:
            return v


def eye_l(rng, k):
    """eyes everywhere: flat A and B, the edges, fillets, the cylinder"""
    return [rng.uniform(S.L, S.L + 12), rng.uniform(S.Lc, S.L), rng.uniform(-S.Lc, S.Lc),
            -rng.uniform(S.Lc, S.L), -rng.uniform(S.L, S.L + 12), S.L + rng.uniform(-0.05, 0.05)][k % 6]


def app_tables():
    """The tables as the app builds them (godot/tests/dump_tables.gd), or None without Godot."""
    godot = os.path.join(HERE, '..', 'tools', '.bin', 'godot')
    if not os.path.exists(godot):
        return None
    with tempfile.TemporaryDirectory() as d:
        subprocess.run([godot, '--headless', '--path', os.path.join(HERE, '..', 'godot'), '-s', 'res://tests/dump_tables.gd',
                        '--', os.path.join(d, 't'), *map(str, PROF)], check=True, capture_output=True, timeout=300)
        shapes = {'tab': (tables.NZ - 1, tables.NB, 4), 'ptab': (tables.NZ - 1, tables.NB, 4), 'ytab': (2, tables.NB, 4)}
        return [np.fromfile(os.path.join(d, 't_%s.f32' % k), np.float32).reshape(shapes[k]) for k in ('tab', 'ptab', 'ytab')]


def main():
    ctx = moderngl.create_standalone_context(require=430, backend='egl')
    tab, ptab = tables.build(S)
    ytab = tables.build_y(S)
    ok = True
    app = app_tables()
    if app is None:
        print('no Godot (tools/setup.sh): the GPU runs ref/tables.py\'s tables')
    else:
        diff = max(np.max(np.abs(a.astype(float) - b)) for a, b in zip(app, (tab, ptab, ytab)))
        print('the app\'s tables (WormholeSpace.shader_tables) against ref/tables.py: largest difference %.1e' % diff)
        if diff > 1e-6:
            ok = False
        tab, ptab, ytab = app
    texs = []
    for t in (tab, ptab):
        tx = ctx.texture((tables.NB, tables.NZ - 1), 4, t.tobytes(), dtype='f4')
        tx.filter = (moderngl.NEAREST, moderngl.NEAREST)
        texs.append(tx)
    ty = ctx.texture((tables.NB, 2), 4, ytab.tobytes(), dtype='f4')
    ty.filter = (moderngl.NEAREST, moderngl.NEAREST)
    texs.append(ty)
    rng = np.random.default_rng(7)

    # ---- sp_trace
    rows, cases = [], []
    for k in range(N):
        l = eye_l(rng, k)
        n = rand_n(rng, 0.02)
        # a head 1.6 m above the floor or less
        n[2] = min(n[2], 1.6 / S.r(l))
        n /= np.linalg.norm(n)
        V = rng.normal(size=4)
        V[1:] -= (V[1:] @ n) * n
        V /= np.linalg.norm(V)
        rows += [[l, *n], list(V)]
        cases.append((l, n, V))
    out = run(ctx, TRACE, rows, texs)
    errs, kinds, bad = [], [0, 0], 0
    for c, (l, n, V) in enumerate(cases):
        ref = S.trace(l, n, V)
        g0, g1 = out[2 * c], out[2 * c + 1]
        kind = 'floor' if g0[0] > 0.5 else 'sky'
        if kind != ref[0]:
            # a ray grazing the horizon or the floor's edge can go either way
            bad += 1
            continue
        kinds[kind == 'floor'] += 1
        if kind == 'floor' and abs(ref[1]) > 100:
            continue        # the far floor at the horizon: float32's, and sub-pixel there
        if kind == 'sky':
            e = np.linalg.norm(g1[:3] - ref[2]) + (2 if g0[1] != ref[1] else 0)
        else:
            # the error as an angle at the eye: the floor point's displacement over its distance
            Pg = S.embed(g0[2], g1[:3])
            Pr = S.embed(ref[1], ref[2])
            e = np.linalg.norm(Pg - Pr) / max(np.linalg.norm(Pr - S.embed(l, n)), 0.3)
        errs.append(e)
    errs = np.array(errs)
    print('sp_trace: %d rays (%d floor, %d sky), kind differs %d; angle error median %.1e, 99%% %.1e, max %.1e'
          % (len(cases), kinds[1], kinds[0], bad, np.median(errs), np.percentile(errs, 99), errs.max()))
    if errs.max() > LIM_TRACE or bad > len(cases) // 500:
        ok = False
        print('  FAIL: worst', np.argsort(errs)[-3:])

    # ---- sp_toward
    rows, cases = [], []
    for k in range(N):
        le = eye_l(rng, k)
        ne = rand_n(rng, 0.02)
        ne[2] = min(ne[2], 1.6 / S.r(le))
        ne /= np.linalg.norm(ne)
        if k % 3 == 0:
            # near the eye: up to 0.6 m
            V = rng.normal(size=4)
            V[1:] -= (V[1:] @ ne) * ne
            V /= np.linalg.norm(V)
            lp, np_, _ = S.brute(le, ne, V, rng.uniform(0.05, 0.6), h=5e-3)
        else:
            lp = eye_l(rng, k + rng.integers(6))
            np_ = rand_n(rng, 0.0)
            np_[2] *= 0.5
            np_ /= np.linalg.norm(np_)
        rows += [[le, *ne], [lp, *np_]]
        cases.append((le, ne, lp, np_))
    out = run(ctx, TOWARD, rows, texs)
    errs, near, derr = [], [], []
    for c, (le, ne, lp, np_) in enumerate(cases):
        ref = S.inverse(le, ne, lp, np_)
        if ref is None:
            continue
        V = out[2 * c]
        e = np.arccos(np.clip(V @ ref[0] / np.linalg.norm(V), -1, 1))
        errs.append(e)
        derr.append(abs(out[2 * c + 1][0] - ref[1]))
        if c % 3 == 0:
            near.append(e)
    errs, near, derr = np.array(errs), np.array(near), np.array(derr)
    print('sp_toward: %d points; direction error median %.1e, 99%% %.1e, max %.1e (near the eye: max %.1e); '
          'path length error max %.1e m' % (len(errs), np.median(errs), np.percentile(errs, 99), errs.max(),
                                                   near.max(), derr.max()))
    if errs.max() > LIM_TOWARD:
        ok = False
        w = np.argsort(errs)[-3:]
        print('  FAIL: worst', [(cases[i][0], cases[i][2], errs[i]) for i in w])
    # ---- sp_walk: the eye from the head, up to 6 cm (the shader's walk is meant for that), the
    # direction scaled to the length (the kernel walks length 1 along it)
    rows, cases = [], []
    for k in range(N // 3):
        l = eye_l(rng, k)
        n = rand_n(rng, 0.02)
        V = rng.normal(size=4)
        V[1:] -= (V[1:] @ n) * n
        V /= np.linalg.norm(V)
        F = []
        for j in range(3):
            U = rng.normal(size=4)
            U[1:] -= (U[1:] @ n) * n
            for G in F:
                U -= (U @ G) * G
            F.append(U / np.linalg.norm(U))
        d = rng.uniform(0.01, 0.06)
        rows += [[l, *n], list(V * d), *[list(f) for f in F]]
        cases.append((l, n, V, d, F))
    out = run(ctx, WALK, rows, texs, per=5)
    werr = []
    for c, (l, n, V, d, F) in enumerate(cases):
        lr, nr, _, Fr = S.brute_frame(l, n, V, d, F, h=1e-3)
        g = out[5 * c]
        e = abs(g[0] - lr) + np.linalg.norm(g[1:] - nr) * S.r(lr)
        e = max(e, max(np.linalg.norm(out[5 * c + 2 + j] - Fr[j]) for j in range(3)))
        werr.append(e)
    werr = np.array(werr)
    print('sp_walk: %d eyes; place and axes error median %.1e, max %.1e' % (len(werr), np.median(werr), werr.max()))
    if werr.max() > LIM_WALK:
        ok = False
    print('PASS' if ok else 'FAIL')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
