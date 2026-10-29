"""wh_geodesic (the GPU move from the head to an eye) vs a float64 fine-step reference:
eye position and transported frame for random heads and offsets, on three profiles."""
import os, re
import in_box  # noqa: F401 (first: on the Frame, into tools/box.sh's container)
import numpy as np
import moderngl
from wh import Wormhole, app_scene_sizes

HERE = os.path.dirname(os.path.abspath(__file__))
CORE = open(os.path.join(HERE, '..', 'godot', 'shaders', 'wormhole_core.gdshaderinc')).read()
MAXB = re.search(r'const int WH_MAXB = (\d+);', CORE).group(1)     # the shader's ball slots
SPH, PIL, BOX = app_scene_sizes()
N = 64

FRAG = """#version 330
#define WH_NO_BALLS
uniform float wh_rho0; uniform float wh_h; uniform float wh_fillet;
uniform vec4 wh_sph[""" + str(SPH) + """]; uniform vec4 wh_pil[""" + str(PIL) + """]; uniform vec4 wh_box[""" + str(BOX) + """];
uniform vec4 wh_ball[""" + MAXB + """]; uniform vec4 wh_ballCol[""" + MAXB + """]; uniform int wh_nBall;
uniform sampler2D wh_tab; uniform vec4 wh_tabLo; uniform vec4 wh_tabInv; uniform vec4 wh_tabReg;
uniform sampler2D uIn;    // rows: (l, n.xyz) (off.xyz, 0) f0 f1 f2
out vec4 o[4];
""" + CORE + """
void main() {
    int i = int(gl_FragCoord.x);
    vec4 a = texelFetch(uIn, ivec2(i, 0), 0);
    vec3 off = texelFetch(uIn, ivec2(i, 1), 0).xyz;
    vec4 f0 = texelFetch(uIn, ivec2(i, 2), 0);
    vec4 f1 = texelFetch(uIn, ivec2(i, 3), 0);
    vec4 f2 = texelFetch(uIn, ivec2(i, 4), 0);
    float l = a.x; vec3 n = a.yzw;
    float len = length(off);
    vec4 dir = (off.x * f0 + off.y * f1 + off.z * f2) / len;
    wh_geodesic(l, n, dir, len, f0, f1, f2);
    o[0] = vec4(l, n); o[1] = f0; o[2] = f1; o[3] = f2;
}
"""
VERT = "#version 330\nin vec2 p; void main() { gl_Position = vec4(p, 0.0, 1.0); }"


def deriv(W, l, n, vecs):
    r, k = float(W.r(np.array(l))), float(W.dr(np.array(l))) / float(W.r(np.array(l)))
    v = vecs[0][1:]
    out = [np.r_[k * (v @ U[1:]), -k * U[0] * v - (U[1:] @ v) / r * n] for U in vecs]
    return vecs[0][0], v / r, out


def reference(W, l, n, f, off, steps=2000):
    vecs = [sum(c * fi for c, fi in zip(off, f)) / np.linalg.norm(off)] + list(f)
    h = np.linalg.norm(off) / steps
    for _ in range(steps):
        k1 = deriv(W, l, n, vecs)
        def sh(k, c): return l + c * k[0], n + c * k[1], [U + c * dU for U, dU in zip(vecs, k[2])]
        k2 = deriv(W, *sh(k1, h / 2)); k3 = deriv(W, *sh(k2, h / 2)); k4 = deriv(W, *sh(k3, h))
        l += h / 6 * (k1[0] + 2 * k2[0] + 2 * k3[0] + k4[0])
        n = n + h / 6 * (k1[1] + 2 * k2[1] + 2 * k3[1] + k4[1]); n /= np.linalg.norm(n)
        vecs = [U + h / 6 * (a + 2 * b + 2 * c + d) for U, a, b, c, d in zip(vecs, k1[2], k2[2], k3[2], k4[2])]
        vecs = [np.r_[U[0], U[1:] - (U[1:] @ n) * n] for U in vecs]
    return l, n, vecs[1:]


def run(prof, rng):
    W = Wormhole(*prof)
    ctx = moderngl.create_standalone_context(backend='egl')
    cases, data = [], np.zeros((5, N, 4), 'f4')
    for i in range(N):
        l = rng.uniform(-W.L - 2, W.L + 2)
        n = rng.normal(size=3); n /= np.linalg.norm(n)
        # random orthonormal frame in the tangent space (basis e_l, t1, t2)
        t1 = np.cross(n, [0.3, 0.5, 0.8]); t1 /= np.linalg.norm(t1); t2 = np.cross(n, t1)
        Q, _ = np.linalg.qr(rng.normal(size=(3, 3)))
        f = [np.r_[Q[0, j], Q[1, j] * t1 + Q[2, j] * t2] for j in range(3)]
        off = rng.normal(size=3) * 0.05            # eye offsets and per-frame head motion: centimetres
        cases.append((l, n, f, off))
        data[0, i] = (l, *n); data[1, i, :3] = off
        for j in range(3): data[2 + j, i] = f[j]
    tex = ctx.texture((N, 5), 4, data.tobytes(), dtype='f4')
    prog = ctx.program(vertex_shader=VERT, fragment_shader=FRAG)
    for k, v in dict(wh_rho0=prof[0], wh_h=prof[1], wh_fillet=prof[2]).items():
        if k in prog: prog[k].value = v
    tex.use(0); prog['uIn'].value = 0
    outs = [ctx.texture((N, 1), 4, dtype='f4') for _ in range(4)]
    fbo = ctx.framebuffer(outs); fbo.use()
    vbo = ctx.buffer(np.array([-1, -1, 1, -1, -1, 1, 1, 1], 'f4').tobytes())
    ctx.vertex_array(prog, [(vbo, '2f', 'p')]).render(moderngl.TRIANGLE_STRIP)
    res = [np.frombuffer(t.read(), 'f4').reshape(N, 4) for t in outs]
    e_pos, e_rot = 0.0, 0.0
    for i, (l, n, f, off) in enumerate(cases):
        lr, nr, fr = reference(W, l, n, f, off)
        E = lambda l, n: np.r_[W.r(np.array(l)) * n, W.w(np.array(l))]
        e_pos = max(e_pos, np.linalg.norm(E(res[0][i, 0], res[0][i, 1:]) - E(lr, nr)))
        e_rot = max(e_rot, max(np.linalg.norm(res[1 + j][i] - fr[j]) for j in range(3)))
    print(f"profile {prof}: eye position err max {e_pos * 1000:.4f} mm, frame err max {np.degrees(e_rot):.5f} deg")


if __name__ == '__main__':
    rng = np.random.default_rng(5)
    for prof in [(3, 5, 1), (3, 1, 1), (3, 0.4, 1)]:
        run(prof, rng)
