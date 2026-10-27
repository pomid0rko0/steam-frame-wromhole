#!/usr/bin/env python3
"""What a frame of the ray tracer costs on the Steam Frame's GPU, by the issue model of tools/ir3_emu.py.

The Frame's compiler (Mesa's ir3 in Turnip, Adreno 750) compiles the shader (tools/adreno_stats.sh
keeps its log with KEEP_LOG); this runs the specialised program it made on waves of 64 pixels
(8x8 tiles of 2x2 quads) at given poses, and sums what the waves issue. Divergent branches cost
a wave both sides, as on the GPU. It is a model: no timings, no waits on transcendental or
texture-unit results (counted apart: cat4, cat5), no memory.

  python3 tools/adreno_cost.py LOG DUMP.json [--tiles N] [--size S] [--fov F] [--check] [--split PLAINLOG [--flat FLATLOG]]
LOG: the compiler log (KEEP_LOG=... tools/adreno_stats.sh plain); DUMP.json: tests/emu_dump.gd's
output (the poses). --check compares the emulated colours with the dumped pictures (the pose is
then emulated at the picture's size and FOV); otherwise each pose is emulated as one eye of the
headset, S x S pixels (default 1728) and F degrees of vertical field of view (default 104),
on N random tiles (default 300; the same tiles for every LOG with the same seed).
--split: the frame split by the stencil (main.gd, _update_proxies): LOG's ray tracer (with the
toys) where a pixel's straight ray from the head meets one of the dump's proxy spheres, PLAINLOG's
(the plain one) elsewhere; each tile's cost is weighted by the share of its pixels each runs (the
GPU packs the passing pixels into waves). The marks' own passes are not counted. With --flat, the
split as main.gd now makes it (toy_classes): PLAINLOG's where no toy can be met, FLATLOG's (the
flat universes' toys only) where only theirs, LOG's where one of the shell's toys may be (with
the dump's wh_candMask, which leaves those near the eye out), and LOG's looking for all of them
(wh_candMask -1) where a ray points into a near one's cone.
"""
import json
import os
import re
import sys
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ir3_emu as E

# The estimate, fitted on the headset's speed check (main and three variants of edge-120hz, nine
# poses each; rms 0.19 ms, the variants' means within 5%): per 64 pixels of a frame of both eyes at
# 1728 x 1728, ms = GODOT_MS + MS_ALU x ALU issue cycles + MS_NOP x nop slots + MS_CAT4 x
# transcendental instructions + MS_CAT5 x texture-unit instructions (derivatives, samples). In waves
# of 128 a 32-bit ALU op takes 2 cycles (Mesa's ir3.c) and a nop slot covers 128 pixels; a cat4 or
# cat5 instruction's work is per pixel whatever the wave. The fit says transcendentals and
# derivatives cost far more than their issue slots (16 and ~90 ALU cycles' worth).
GODOT_MS = 0.8
MS_ALU = 1.61e-3
MS_NOP = 1.05e-3
MS_CAT4 = 0.0258
MS_CAT5 = 0.146
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
SCENE = json.load(open(os.path.join(ROOT, 'godot', 'scene.json')))


def ray_program(log, mark=False):
    """The specialised ray tracer from an ir3 log: of the two big fragment programs, the smaller.
    A shader with more than 100 vec4 of constants also gets a variant /2 that reads them from
    memory ("safe constlen"); Turnip runs it only when the pipeline's stages need more than 512 in
    all (ir3_trim_constlen), and ours need ~200, so the /1 runs. mark: a stencil mark compiled alone
    (tools/adreno_stats.sh --alone): of the two programs that discard and read flat inputs (its
    generic and its specialised one; Godot's own passes do neither), the smaller."""
    text = open(log, errors='replace').read().replace('MESA: info: ', '')
    progs = {}
    for m in re.finditer(r'; FRAG prog (\d+/1): (\d+) instr', text):
        if mark:
            end = m.start()
            body = text[text.rfind('Native code for', 0, end):end]
            if 'kill' not in body or body.count('flat.b') < 3:
                continue
        progs[m.group(1)] = int(m.group(2))
    big = max(progs.values())
    cands = sorted((n, p) for p, n in progs.items() if n >= 0.5 * big or mark)
    p = cands[0][1]
    end = text.index('; FRAG prog %s:' % p)
    start = text.rfind('Native code for', 0, end)
    body = text[start:end]
    # Godot compiles in threads: another shader's "NIR (final form) for ..." header can land
    # inside this program's listing
    lines = [x for x in body.split('\n') if not x.startswith('NIR (')]
    hdr = body[body.rfind('; FRAG: outputs'):]
    # the program's instructions: from the first line after the @in/@out declarations
    first = 0
    while first < len(lines) and (not lines[first].strip() or lines[first].startswith(('@', ';', 'Native', 'SIMD'))):
        first += 1
    return lines[first:], hdr, p, progs[p]


# The material's uniforms in declaration order (wormhole_view.gdshaderinc), with the defines that
# keep each: (name, type, array length). Godot lays them out std140-like: a scalar takes 4 bytes on
# a 4-byte boundary, a vec3 12 bytes on a 16-byte one, a vec4 and every array element 16 bytes.
UNIFORMS = [('wh_rho0', 'f', 0, None), ('wh_h', 'f', 0, None), ('wh_fillet', 'f', 0, None),
            ('wh_sph', 'v4', 6, None), ('wh_pil', 'v4', 4, None), ('wh_box', 'v4', 4, None),
            ('wh_ball', 'v4', 12, None), ('wh_ballCol', 'v4', 12, None), ('wh_nBall', 'i', 0, None),
            ('head_l', 'f', 0, None), ('head_n', 'v3', 0, None), ('head_f', 'v4', 3, None), ('head_pos', 'v3', 0, None),
            ('wh_tabLo', 'v4', 0, 'WH_TABLE'), ('wh_tabInv', 'v4', 0, 'WH_TABLE'), ('wh_tabReg', 'v4', 0, 'WH_TABLE'),
            ('grav_cyl', 'v4', 0, 'WH_GRAVITY'), ('grav_g', 'v4', 2, 'WH_GRAVITY'), ('grav_d', 'v4', 2, 'WH_GRAVITY'),
            ('wh_pix', 'f', 0, 'WH_PIX'),
            ('wh_cube', 'v4', 6, 'BALLS'), ('wh_cubeE', 'v4', 30, 'BALLS'), ('wh_cubeCol', 'v4', 6, 'BALLS'),
            ('wh_nCube', 'i', 0, 'BALLS'), ('wh_bound', 'v4', 4, 'BALLS'), ('wh_bIdx', 'iv4', 0, 'BALLS'),
            ('wh_cIdx', 'iv4', 0, 'BALLS'), ('wh_fball', 'v4', 12, 'BALLS'), ('wh_candMask', 'i', 0, 'CURVED'),
            ('wh_mkX', 'v4', 5, 'WH_MARK'), ('wh_mkY', 'v4', 5, 'WH_MARK'), ('wh_mkZ', 'v4', 5, 'WH_MARK'),
            ('wh_mkR2', 'v4', 5, 'WH_MARK'), ('wh_mkLo', 'v4', 5, 'WH_MARK'), ('wh_mkHi', 'v4', 5, 'WH_MARK'),
            ('wh_mkGroups', 'i', 0, 'WH_MARK'), ('wh_near', 'v4', 4, 'WH_MARK'), ('wh_nearBox', 'v4', 12, 'WH_MARK_NEAR'),
            ('wh_nearA', 'v4', 24, 'WH_NEAR_CULL'), ('wh_nearQ', 'v4', 8, 'WH_NEAR_CULL'), ('wh_nearO', 'v4', 8, 'WH_NEAR_CULL'),
            ('wh_nearEye', 'v4', 2, 'WH_NEAR_CULL'),
            ('wh_nearH', 'v4', 0, 'WH_NEAR_CULL'), ('wh_nearBit', 'iv4', 0, 'WH_NEAR_CULL'),
            ('wh_nearAll', 'i', 0, 'WH_NEAR_CULL')]


def shader_defines(path):
    """The WH_* defines of a ray tracer's .gdshader (res:// path or file), as the view include sees them."""
    f = path.replace('res://', os.path.join(ROOT, 'godot') + '/') if path.startswith('res://') else path
    d = set(re.findall(r'^#define (WH_\w+)', open(f).read(), re.M))
    if 'WH_NO_BALLS' not in d:
        d.add('BALLS')
        if 'WH_FLAT_TOYS' not in d:
            d.add('CURVED')
    if 'BALLS' in d or 'WH_ARROWS' in d:
        d.add('WH_PIX')
    return d


def ubo_layout(defines):
    """Byte offset of each uniform the shader with these defines declares."""
    out, off = {}, 0
    for name, typ, n, need in UNIFORMS:
        if need and need not in defines:
            continue
        size, align = {'f': (4, 4), 'i': (4, 4), 'v3': (12, 16), 'v4': (16, 16), 'iv4': (16, 16)}[typ]
        if n:
            size, align = 16 * n, 16
        off = (off + align - 1) // align * align
        out[name] = (off, typ, n)
        off += size
    return out


def material_ubo(defines, values):
    """Godot's material uniform block for a shader with these defines; values: name -> number or
    list (tests/emu_dump.gd's "uniforms"); the scene's static objects and the fillet table by default."""
    u = np.zeros(4 * 256, np.float32)
    ui = u.view(np.uint32)
    tab, lo, inv, reg = fillet_table()
    vals = {'wh_rho0': 3.0, 'wh_h': 5.0, 'wh_fillet': 1.0, 'wh_candMask': -1, 'wh_sph': SCENE['spheres_A'] + SCENE['spheres_B'],
            'wh_pil': SCENE['pillars_A'], 'wh_box': SCENE['boxes_B'], 'wh_tabLo': lo, 'wh_tabInv': inv, 'wh_tabReg': reg}
    vals.update(values or {})
    for name, (off, typ, n) in ubo_layout(defines).items():
        if name not in vals:
            continue
        v = np.ravel(np.asarray(vals[name], np.float64))
        k = off // 4
        if typ == 'i':
            ui[k] = np.uint32(int(v[0]) & 0xffffffff)
        elif typ == 'iv4':
            m = 4 * max(n, 1)
            ui[k:k + min(len(v), m)] = (v.astype(np.int64)[:m] & 0xffffffff).astype(np.uint32)
        else:
            u[k:k + len(v)] = v
    return ui


def fillet_table():
    """WormholeSpace.fillet_table, from the float64 reference (ref/wh.py)."""
    sys.path.insert(0, os.path.join(ROOT, 'ref'))
    from wh import Wormhole
    return Wormhole(3.0, 5.0, 1.0).fillet_table()


class _Ubos(dict):
    """Uniform blocks by binding: the material's, zeros for any other (the marks drawn over a mesh
    read the scene's matrices too: their cost does not depend on them)."""
    def __missing__(self, key):
        return np.zeros(4096, np.uint32)


class Shader:
    def set_uniforms(self, uniforms):
        """The material's uniforms (a pose's own, when they differ between poses: --held)."""
        self.ubos = _Ubos({3: material_ubo(self.defines, uniforms)})   # the main program loads from it too (ldc at a computed index)
        self.consts = E.run_preamble(self.instrs, self.ps, self.pe + 1, np.zeros(8192, np.uint32), self.ubos)

    def __init__(self, log, defines, uniforms=None, mark=False):
        lines, self.hdr, self.name, self.ninstr = ray_program(log, mark)
        self.instrs, self.labels = E.parse_program(lines)
        self.ps = next(i for i, x in enumerate(self.instrs) if x.op == 'shps')
        self.pe = next(i for i, x in enumerate(self.instrs) if x.op == 'shpe')
        self.start = self.instrs[self.ps].target
        self.defines = defines
        self.tex = fillet_table()[0]
        self.set_uniforms(uniforms)
        # the inputs: smooth (bary.f) and flat (flat.b) varying slots, in slot order
        self.smooth, self.flat = [], []
        for x in self.instrs:
            if x.op in ('bary.f', 'flat.b'):
                for k in range(x.rpt + 1):
                    loc = x.srcs[0].imm + (k if x.srcs[0].rpt else 0)
                    (self.smooth if x.op == 'bary.f' else self.flat).append(loc)
        self.smooth = sorted(set(self.smooth))
        self.flat = sorted(set(self.flat))
        self.flat_order = None
        self.wave128 = bool(re.search(r'; FRAG prog %s: \d+ max_waves, 1 double_threadsize' % re.escape(self.name),
                                      open(log, errors='replace').read().replace('MESA: info: ', '')))
        m = re.search(r'outputs: (h?)r(\d+)\.([xyzw])', self.hdr)
        self.out_half = m.group(1) == 'h'
        self.out = int(m.group(2)) * 4 + E.COMP[m.group(3)]

    def run(self, varyings, profile=None):
        L = varyings.shape[1]
        w = E.Wave(L, self.consts, self.ubos, varyings)
        w.tex = self.tex
        st = E.Stats()
        st.pc = profile
        E.run_wave(self.instrs, self.start, w, st)
        if self.out_half:
            col = np.stack([w.H[self.out + k].view(np.float16).astype(np.float32) for k in range(3)], 1)
        else:
            col = np.stack([w.R[self.out + k].view(np.float32) for k in range(3)], 1)
        return col, st


def tile_lanes(x0, y0, wide=False):
    """Pixel (x, y) of each lane of an 8x8 tile at (x0, y0) (16x8 for a wave of 128): quads in
    rows, each 2x2."""
    xs, ys = [], []
    nq = 8 if wide else 4
    for q in range(2 * nq * 2 if wide else 16):
        qx, qy = q % nq, q // nq
        for k in range(4):
            xs.append(x0 + 2 * qx + (k & 1))
            ys.append(y0 + 2 * qy + (k >> 1))
    return np.array(xs), np.array(ys)


def wh_eye(l, rho0=3.0, h=5.0, R=1.0):
    """wormhole_core's wh_eye: (r, r - rmin) of a start point."""
    Lc = max(h - R, 0.0)
    th0 = np.arcsin(max(1.0 - h / R, 0.0))
    L = Lc + R * (0.5 * np.pi - th0)
    al = abs(l)
    if al >= L:
        r = al - L + rho0 + R
    elif al <= Lc:
        r = rho0
    else:
        r = rho0 + R * (1.0 - np.cos(th0 + (al - Lc) / R))
    ths = th0 + max(al - Lc, 0.0) / R
    return [r, 2.0 * R * np.sin(0.5 * (ths + th0)) * np.sin(0.5 * (ths - th0))]


def varyings_for(entry, xs, ys, W, H, tan_x, tan_y, sh=None):
    """The shader's inputs per lane: v_ray (the pixel's unnormalised ray, as (U_l, u)) and the flat
    v_l, v_n and (where the shader has it) v_eye, packed into the slots in the order declared."""
    B = np.array(entry['cam_basis'], float).T    # columns: camera axes in play space
    f = np.array(entry['head_f'], float)
    vx = (2.0 * (xs + 0.5) / W - 1.0) * tan_x
    vy = (1.0 - 2.0 * (ys + 0.5) / H) * tan_y
    dv = np.stack([vx, vy, -np.ones_like(vx)], 0)          # view space
    pd = B @ dv                                            # play space
    ray = pd[0][None] * f[0][:, None] + pd[1][None] * f[1][:, None] + pd[2][None] * f[2][:, None]
    L = len(xs)
    smooth = sh.smooth if sh else [0, 1, 2, 3]
    flat = sh.flat if sh else [4, 5, 6, 7]
    v = np.zeros((max(smooth + flat) + 1, L), np.float32)
    for k, loc in enumerate(smooth):
        v[loc] = ray[k]
    groups = {'l': [entry['head_l']], 'n': list(entry['head_n']), 'eye': wh_eye(entry['head_l'])}
    order = sh.flat_order if sh and sh.flat_order else ['l', 'n', 'eye']
    fv = sum((groups[g] for g in order), [])
    for k, loc in enumerate(flat):
        v[loc] = fv[k]
    return v


def find_flat_order(sh, entries, robust=False):
    """Which way Mesa packed the flat inputs (v_l, v_n, v_eye): the order whose emulated colours are
    Godot's picture on a few tiles. robust: for a ray tracer that is not the one the picture shows
    everywhere (the split's others: the picture's toys are not theirs), the order whose tiles match
    best in the median."""
    import itertools
    from PIL import Image
    names = ['l', 'n', 'eye'] if len(sh.flat) == 6 else ['l', 'n']
    e = entries[0]
    img = np.asarray(Image.open(e['png']).convert('RGB'), np.float32) / 255.0
    H, W = img.shape[:2]
    P = np.array(e['proj'])
    best = None
    for order in itertools.permutations(names):
        sh.flat_order = list(order)
        rng = np.random.default_rng(7)
        errs = []
        for t in range(16 if robust else 6):
            xs, ys = tile_lanes(8 * rng.integers(0, W // 8), 8 * rng.integers(0, H // 8))
            col, _ = sh.run(varyings_for(e, xs, ys, W, H, 1.0 / P[0][0], 1.0 / P[1][1], sh))
            err = np.nan_to_num(np.abs(srgb(2.0 * col) - img[ys, xs]), nan=1.0).max(1)
            errs.append(np.median(err) if robust else err.max())
        worst = np.median(errs) if robust else max(errs)
        if best is None or worst < best[0]:
            best = (worst, list(order))
    sh.flat_order = best[1]
    if best[0] > 4.0 / 255 and not robust:
        print('warning: no packing of the flat inputs reproduces the picture (%.1f/255)' % (255 * best[0]))
    return best[1]


def share_of(e, size, fov, step=16):
    """The share of the view the stencil marks (a grid of pixels)."""
    tan = np.tan(np.radians(fov) / 2.0)
    g = np.arange(step // 2, size, step)
    xs, ys = np.meshgrid(g, g)
    return float(proxy_marked(e, xs.ravel(), ys.ravel(), size, tan, tan).mean())


def srgb(c):
    c = np.clip(c, 0.0, 1.0)
    return np.where(c <= 0.0031308, 12.92 * c, 1.055 * np.power(c, 1.0 / 2.4) - 0.055)


def check(sh, entries, ntiles, rng, unis=None):
    from PIL import Image
    worst = 0.0
    for k, e in enumerate(entries):
        if unis:
            sh.set_uniforms(unis[k])
        img = np.asarray(Image.open(e['png']).convert('RGB'), np.float32) / 255.0
        H, W = img.shape[:2]
        P = np.array(e['proj'])          # columns
        tan_x = 1.0 / P[0][0]
        tan_y = 1.0 / P[1][1]
        errs = []
        for t in range(ntiles):
            x0 = 8 * rng.integers(0, W // 8)
            y0 = 8 * rng.integers(0, H // 8)
            xs, ys = tile_lanes(x0, y0)
            col, st = sh.run(varyings_for(e, xs, ys, W, H, tan_x, tan_y, sh))
            got = srgb(2.0 * col)
            want = img[ys, xs]
            errs.append(np.abs(got - want).max(1))
        errs = np.concatenate(errs)
        bad = (errs > 4.0 / 255).mean()
        print('pose %s: %d pixels, max error %.1f/255, %.2f%% above 4/255, median %.2f/255'
              % (e['pose'], errs.size, errs.max() * 255, 100 * bad, np.median(errs) * 255))
        worst = max(worst, bad)
    return worst


def proxy_marked(e, xs, ys, size, tan_x, tan_y):
    """Per lane: whether the stencil marks its pixel (main.gd, _update_proxies): its straight ray
    from the head, in the chart of the head's universe, meets a proxy sphere (or starts in one).
    No proxies: the whole view is marked."""
    P = np.array(e.get('proxies') or [], float).reshape(-1, 4)
    if len(P) == 0:
        return np.ones(len(xs), bool)
    B = np.array(e['cam_basis'], float).T
    f = np.array(e['head_f'], float)
    vx = (2.0 * (xs + 0.5) / size - 1.0) * tan_x
    vy = (1.0 - 2.0 * (ys + 0.5) / size) * tan_y
    pd = B @ np.stack([vx, vy, -np.ones_like(vx)], 0)
    V = pd[0][None] * f[0][:, None] + pd[1][None] * f[1][:, None] + pd[2][None] * f[2][:, None]
    l, n = e['head_l'], np.array(e['head_n'], float)
    side = 1.0 if l > 0 else -1.0
    M = np.array([side, 1.0, 1.0])
    x = M * wh_eye(l)[0] * n
    d = M[:, None] * (side * V[0][None] * n[:, None] + V[1:])
    d /= np.linalg.norm(d, axis=0)
    hit = np.zeros(len(xs), bool)
    for c in P:
        oc = (x - c[:3])[:, None]
        b = (oc * d).sum(0)
        cq = float((oc * oc).sum()) - c[3] * c[3]
        hit |= (cq <= 0.0) | ((b < 0.0) & (b * b >= cq))
    return hit


def near_cone(q, reach, rho0=3.0):
    """wormhole_core.gdshaderinc's wh_nearCone: cos of the cone's half angle, or -2 (none)."""
    D = float(np.linalg.norm(q))
    rr = 1.02 * reach
    S = np.sin(rr / rho0) / np.sin(min(D, 1.5 * rho0) / rho0)
    return float(np.cos(np.arcsin(S) + 0.005)) if reach > 0.0 and D > rr and S < 1.0 else -2.0


def mark_tests(e, V, n, mk, cone=None):
    """Per lane, whether a mark (wormhole_view.gdshaderinc, WH_MARK) with these uniforms (the dump's
    "marks" entry) passes: some packed toy's plane within reach and its l range met (and with cone,
    per slot, inside that cone, and its box)."""
    e3 = np.cross(n[:, None], V[1:], axis=0)
    s2 = (e3 * e3).sum(0)
    rho0, hh, R = 3.0, 5.0, 1.0
    Lc, Ls = hh - R, hh - R + R * np.pi / 2.0
    le = e['head_l']
    sd = 1.0 if le >= 0.0 else -1.0
    outside = abs(le) >= Ls
    x0 = Ls if outside else abs(le)
    b = (rho0 + R if outside else wh_eye(le)[0]) * np.linalg.norm(V[1:], axis=0)
    inward = np.ones(V.shape[1], bool) if outside else V[0] * sd < 0.0
    turn = (b > rho0) & (x0 > Lc)
    lt = np.maximum(Lc + R * np.sqrt(np.maximum(2.0 * (b - rho0) / R, 0.0)), Lc)
    xlo = np.where(inward, np.where(turn, np.minimum(lt, x0), -Ls), x0)
    xhi = np.where(inward & ~turn, x0, Ls)
    llo = xlo if sd > 0 else -xhi
    lhi = xhi if sd > 0 else -xlo
    hit = np.zeros(V.shape[1], bool)
    for g in range(int(mk.get('wh_mkGroups', 0))):
        for k in range(4):
            X, Y, Z = mk['wh_mkX'][g][k], mk['wh_mkY'][g][k], mk['wh_mkZ'][g][k]
            d = X * e3[0] + Y * e3[1] + Z * e3[2]
            m = (d * d < mk['wh_mkR2'][g][k] * s2 + 1e-12) & (mk['wh_mkLo'][g][k] <= lhi) & (mk['wh_mkHi'][g][k] >= llo)
            if cone is not None:
                m &= cone[k]
            hit |= m
    return hit


def mark_cost(marks, e, size, fov):
    """ms of the stencil's marks 2 and 3 at a pose (main._update_proxies): over the whole view with
    the head in the shell or the band of the shell sphere's margins, else over that sphere; the
    mark 3 only with near toys, its full test only where a ray is in a cone (the rest of its waves
    branch off early). marks: {'quad': (far, near), 'mesh': (far, near)} Shaders; each emulated on a
    tile, its cost not depending on the pixel (but the cones' branch)."""
    if not marks:
        return 0.0
    far_u, near_u = e.get('marks', [{}, {}])
    l = e['head_l']
    Ls = 4.0 + np.pi / 2.0
    quads = abs(l) <= Ls or wh_eye(l)[0] < (4.0 + 0.08) * 1.02 + 0.1
    tan = np.tan(np.radians(fov) / 2.0)
    g = np.arange(8, size, 16)
    gx, gy = np.meshgrid(g, g)
    xs, ys = gx.ravel(), gy.ravel()
    if quads:
        cover = 1.0
    else:
        prox = np.array(e['proxies'], float).reshape(-1, 4)
        cover = float(proxy_marked(dict(e, proxies=prox[:1].tolist()), xs, ys, size, tan, tan).mean())
    far, near = marks['quad' if quads else 'mesh']
    def run(sh, u, ray0, flat):
        sh.set_uniforms(u)
        txs, tys = tile_lanes(0, 0, sh.wave128)
        v = np.zeros((max(sh.smooth + sh.flat) + 1, len(txs)), np.float32)
        for k, loc in enumerate(sh.smooth):
            v[loc] = ray0 if k == 0 else 0.0
        for loc in sh.flat:
            v[loc] = flat
        _, st = sh.run(v)
        a, n_, c4, c5 = per64(sh, st, 1)
        return MS_ALU * a + MS_NOP * n_ + MS_CAT4 * c4 + MS_CAT5 * c5
    ms = cover * run(far, far_u, 1.0, 0.0)
    if any(w[3] > 0 for w in near_u.get('wh_near', [])):
        # in no cone: dot(V, v_near) = -1 below v_nearCos 1; in all: 1 above -1
        early = run(near, near_u, -1.0, 1.0)
        full = run(near, near_u, -1.0, -1.0)
        in_cone = near_cone_share(e, xs, ys, size, tan)
        # over the whole view only the quad over the cones' bounding box is drawn
        ncover = cone_rect_share(e, tan) if quads else cover
        ms += ncover * early + cover * in_cone * (full - early)
    return ms


def cone_rect_share(e, tan):
    """The share of the view the mark 3's quad covers (wormhole_view.gdshaderinc's vertex(): the
    bounding box of an octagon round each near cone's circle), the eye at the head."""
    B = np.array(e['cam_basis'], float)      # rows: the camera's axes in play space
    hp = np.array(e['head_pos'], float)
    lo, hi = np.array([1.0, 1.0]), np.array([-1.0, -1.0])
    for P in e.get('marks', [{}, {}])[1].get('wh_near', []):
        P = np.array(P, float)
        if P[3] <= 0:
            continue
        q = P[:3] - hp
        c = near_cone(q, P[3])
        if c < 0.2:
            return 1.0
        qv = B @ (q / np.linalg.norm(q))
        t = np.sqrt(1.0 - c * c) / c / np.cos(np.pi / 8)
        a1 = np.cross(qv, [0.0, 1.0, 0.0] if abs(qv[1]) < 0.9 else [1.0, 0.0, 0.0])
        a1 /= np.linalg.norm(a1)
        a2 = np.cross(qv, a1)
        for j in range(8):
            d = qv + t * (np.cos(j * np.pi / 4) * a1 + np.sin(j * np.pi / 4) * a2)
            if -d[2] < 1e-3:
                return 1.0
            ndc = d[:2] / (-d[2]) / tan
            lo, hi = np.minimum(lo, ndc), np.maximum(hi, ndc)
    if lo[0] > hi[0]:
        return 0.0
    lo, hi = np.clip(lo, -1, 1), np.clip(hi, -1, 1)
    return float(np.prod(np.maximum(hi - lo, 0.0)) / 4.0)


def near_cone_share(e, xs, ys, size, tan):
    """The share of the view whose rays point into a near toy's cone (the mark 3's full test)."""
    B = np.array(e['cam_basis'], float).T
    vx = (2.0 * (xs + 0.5) / size - 1.0) * tan
    vy = (1.0 - 2.0 * (ys + 0.5) / size) * tan
    pd = B @ np.stack([vx, vy, -np.ones_like(vx)], 0)
    pd /= np.linalg.norm(pd, axis=0)
    hp = np.array(e['head_pos'], float)
    hit = np.zeros(len(xs), bool)
    for P in e.get('marks', [{}, {}])[1].get('wh_near', []):
        P = np.array(P, float)
        if P[3] <= 0:
            continue
        q = P[:3] - hp
        hit |= (q / max(np.linalg.norm(q), 1e-6)) @ pd >= near_cone(q, P[3]) - 1e-4
    return float(hit.mean())


def near_box(o, axes, H, pd):
    """wormhole_view.gdshaderinc's near cube box (main._near_box): per ray pd (3, m) from o (the eye
    against the box's centre, in the room), whether it passes the box of these axes, half size H."""
    with np.errstate(divide='ignore', invalid='ignore'):
        rd = axes @ pd
        ro = (axes @ o)[:, None]
        ta = (-H - ro) / rd
        tb = (H - ro) / rd
        t0 = np.maximum(np.fmax.reduce(np.fmin(ta, tb), 0), 0.0)
        t1 = np.fmin.reduce(np.fmax(ta, tb), 0)
    return t1 >= t0


def toy_classes(e, xs, ys, size, tan_x, tan_y):
    """Per lane, which ray tracer main.gd's stencil gives its pixel (_update_proxies): 0 the plain
    one, 1 the flat universes' toys only, 2 the shell's too but those near the eye, 3 all; the
    marks' tests (wormhole_view.gdshaderinc, WH_MARK) on the dump's uniforms, the eye at the head."""
    B = np.array(e['cam_basis'], float).T
    f = np.array(e['head_f'], float)
    vx = (2.0 * (xs + 0.5) / size - 1.0) * tan_x
    vy = (1.0 - 2.0 * (ys + 0.5) / size) * tan_y
    pd = B @ np.stack([vx, vy, -np.ones_like(vx)], 0)
    pd /= np.linalg.norm(pd, axis=0)
    V = pd[0][None] * f[0][:, None] + pd[1][None] * f[1][:, None] + pd[2][None] * f[2][:, None]
    n = np.array(e['head_n'], float)
    far, nearu = e.get('marks', [{}, {}])
    hp = np.array(e['head_pos'], float)
    cone = []
    boxes = np.array(nearu.get('wh_nearBox', [[0, 0, 0, 0]] * 12), float).reshape(4, 3, 4)
    for k in range(4):
        P = np.array(nearu.get('wh_near', [[0, 0, 0, 0]] * 4)[k], float)
        q = P[:3] - hp
        c = near_cone(q, P[3]) if P[3] > 0 else 2.0
        m = (q / max(np.linalg.norm(q), 1e-6)) @ pd >= c - 1e-4
        H = boxes[k, 0, 3]
        if H > 0:
            m &= near_box(hp - P[:3], boxes[k, :, :3], H, pd)
        cone.append(m)
    c2 = mark_tests(e, V, n, far)
    c3 = mark_tests(e, V, n, nearu, cone)
    if e.get('proxies'):
        prox = np.array(e['proxies'], float).reshape(-1, 4)
        c1 = proxy_marked(e, xs, ys, size, tan_x, tan_y)
        shell = proxy_marked(dict(e, proxies=prox[:1].tolist()), xs, ys, size, tan_x, tan_y)
        c2 &= shell
        c3 &= shell
    else:
        c1 = np.ones(len(xs), bool)
    return np.where(c3, 3, np.where(c2, 2, np.where(c1, 1, 0)))


def cost(sh, entries, ntiles, size, fov, seed, profile=None, share=None, unis=None):
    """share(e, xs, ys, tan): the share of a tile's pixels this ray tracer runs (--split); unis:
    each pose's own uniforms (toys that move with the viewer: --held)."""
    tan_y = np.tan(np.radians(fov) / 2.0)
    tan_x = tan_y
    res = []
    for k, e in enumerate(entries):
        if unis:
            sh.set_uniforms(unis[k])
        rng = np.random.default_rng(seed)
        tot = E.Stats()
        for t in range(ntiles):
            x0 = 8 * rng.integers(0, size // 8)
            y0 = 8 * rng.integers(0, size // 8)
            if sh.wave128:
                x0 = 16 * (x0 // 16)
            xs, ys = tile_lanes(x0, y0, sh.wave128)
            w = 1.0 if share is None else share(e, xs, ys, tan_x)
            if w <= 0.0:
                continue
            col, st = sh.run(varyings_for(e, xs, ys, size, size, tan_x, tan_y, sh), profile)
            for k in ('cycles', 'instr', 'cat4', 'cat5', 'lane_instr', 'nops', 'half'):
                setattr(tot, k, getattr(tot, k) + w * getattr(st, k))
        res.append((e['pose'], tot))
    return res


def per64(sh, st, n):
    """A pose's totals over n tiles as (ALU cycles, nop slots, transcendentals, texture-unit
    instructions) per 64 pixels."""
    lanes = 128 if sh.wave128 else 64
    alu = (st.cycles - st.nops - st.half) * (2 if sh.wave128 else 1) / n * 64 / lanes + st.half / n * 64 / lanes
    return alu, st.nops / n * 64 / lanes, st.cat4 / n, st.cat5 / n


def main():
    args = sys.argv[1:]
    opt = {'--tiles': 300, '--size': 1728, '--fov': 104.0, '--seed': 1, '--split': '', '--flat': '', '--profile-class': 2,
           '--marks': '', '--near': ''}
    flags = set()
    pos = []
    i = 0
    while i < len(args):
        if args[i] in opt:
            opt[args[i]] = type(opt[args[i]])(args[i + 1]); i += 2
        elif args[i].startswith('--'):
            flags.add(args[i]); i += 1
        else:
            pos.append(args[i]); i += 1
    log, dump = pos
    entries = json.load(open(dump))
    defines = shader_defines(entries[0]['shader'])
    def eye_pix(u):
        u = dict(u)
        if 'wh_pix' in u and '--check' not in flags:
            # soft edges: a pixel of the headset's eye, not of the dump's picture
            u['wh_pix'] = 2.0 * np.tan(np.radians(opt['--fov']) / 2.0) / opt['--size']
        return u
    uniforms = eye_pix(entries[0].get('uniforms', {}))
    # toys held in the hand move with the viewer: then each pose's own
    unis = [eye_pix(e.get('uniforms', {})) for e in entries]
    if all(u == unis[0] for u in unis):
        unis = None
    # the packing of the flat inputs: found against Godot's picture, with its uniforms
    order = find_flat_order(Shader(log, defines, dict(entries[0].get('uniforms', {}))), entries)
    sh = Shader(log, defines, uniforms)
    sh.flat_order = order
    print('%s: prog %s, %d instr; flat inputs %s' % (os.path.basename(log), sh.name, sh.ninstr, ', '.join(order)))
    if '--check' in flags:
        # the picture is the split's (stencil 3 draws the toys near the eye that the material of
        # stencil 2, dumped here, leaves out): emulated with all of them, as stencil 3 has them
        cu = [dict(u, wh_candMask=-1) for u in (unis or [uniforms] * len(entries))]
        sh.set_uniforms(cu[0])
        bad = check(sh, entries, opt['--tiles'], np.random.default_rng(opt['--seed']), cu)
        sys.exit(0 if bad < 0.002 else 1)
    prof = np.zeros(len(sh.instrs)) if '--profile' in flags else None
    n = opt['--tiles']
    tot = []
    lanes = 128 if sh.wave128 else 64
    size = opt['--size']
    share = None
    plain = None
    extra = []        # (shader, its share of a tile, its uniforms per pose) of the split's other ray tracers
    classes = bool(opt['--flat'])
    if opt['--split']:
        # the plain ray tracer: its own uniforms are the same material's
        pdefs = {d for d in defines if d not in ('BALLS', 'WH_PIX', 'CURVED')} | {'WH_NO_BALLS'}
        if 'WH_ARROWS' in pdefs:
            pdefs.add('WH_PIX')
        plain = Shader(opt['--split'], pdefs, uniforms)
        # its own packing of the flat inputs (another program: not necessarily LOG's)
        find_flat_order(plain, entries, robust=True)
        if classes:
            fdefs = {d for d in defines if d != 'CURVED'} | {'WH_FLAT_TOYS'}
            flat = Shader(opt['--flat'], fdefs, uniforms)
            find_flat_order(flat, entries, robust=True)
            # stencil 3's: the material that looks for all the shell's toys, and with --near its own
            # program (WH_NEAR_CULL: each ray leaves out the near toys it misses) and uniforms
            base = unis or [uniforms] * len(entries)
            allu = [dict(u, wh_candMask=-1, **e.get('near_uniforms', {})) for u, e in zip(base, entries)]
            if opt['--near']:
                nearsh = Shader(opt['--near'], shader_defines(entries[0]['shader'].replace('.gdshader', '_near.gdshader')), allu[0])
                find_flat_order(nearsh, entries, robust=True)
            else:
                nearsh = Shader(log, defines, dict(uniforms, wh_candMask=-1))
                nearsh.flat_order = order
            cls = lambda e, xs, ys, tan: toy_classes(e, xs, ys, size, tan, tan)
            share = lambda e, xs, ys, tan: float((cls(e, xs, ys, tan) == 2).mean())
            extra = [(plain, lambda e, xs, ys, tan: float((cls(e, xs, ys, tan) == 0).mean()), unis),
                     (flat, lambda e, xs, ys, tan: float((cls(e, xs, ys, tan) == 1).mean()), unis),
                     (nearsh, lambda e, xs, ys, tan: float((cls(e, xs, ys, tan) == 3).mean()), allu)]
        else:
            share = lambda e, xs, ys, tan: float(proxy_marked(e, xs, ys, size, tan, tan).mean())
            extra = [(plain, lambda e, xs, ys, tan: 1.0 - share(e, xs, ys, tan), unis)]
    marks = None
    if opt['--marks']:
        # the marks 2 and 3 over the whole view and over the shell's sphere (their compiler logs, in
        # that order: stencil_toys, _near, _shell, _shell_near)
        names = ['stencil_toys', 'stencil_toys_near', 'stencil_toys_shell', 'stencil_toys_shell_near']
        ms_ = [Shader(lg, shader_defines('res://shaders/%s.gdshader' % nm), mark=True) for lg, nm in zip(opt['--marks'].split(','), names)]
        marks = {'quad': (ms_[0], ms_[1]), 'mesh': (ms_[2], ms_[3])}
    if opt['--split']:
        print('the split: the plain one\'s flat inputs %s%s%s' % (', '.join(plain.flat_order),
              (', the flat toys\' %s' % ', '.join(flat.flat_order)) if opt['--flat'] else '',
              (', the near ones\' %s' % ', '.join(nearsh.flat_order)) if opt['--near'] and classes else ''))
    # --profile-class C: the profile of the pixels of stencil C (with --flat; extra: 0, 1, 3)
    pc = opt['--profile-class'] if classes else 2
    psh = sh if pc == 2 else extra[{0: 0, 1: 1, 3: 2}[pc]][0]
    if prof is not None:
        prof = np.zeros(len(psh.instrs))
    res = cost(sh, entries, n, size, opt['--fov'], opt['--seed'], prof if pc == 2 else None, share, unis)
    resx = [cost(x, entries, n, size, opt['--fov'], opt['--seed'], prof if x is psh else None, w, xu)
            for x, w, xu in extra]
    for k, (pose, st) in enumerate(res):
        alu, nop, c4, c5 = per64(sh, st, n)
        busy = 100.0 * st.lane_instr / max(st.instr * lanes, 1)
        part = lambda a, b, c, d: MS_ALU * a + MS_NOP * b + MS_CAT4 * c + MS_CAT5 * d
        parts = [part(alu, nop, c4, c5)]       # each ray tracer's ms: LOG's first, then the others'
        for (x, w, xu), rx in zip(extra, resx):
            a2, n2, c42, c52 = per64(x, rx[k][1], n)
            parts.append(part(a2, n2, c42, c52))
            alu, nop, c4, c5 = alu + a2, nop + n2, c4 + c42, c5 + c52
        mk = mark_cost(marks, entries[k], size, opt['--fov']) if marks else 0.0
        ms = GODOT_MS + MS_ALU * alu + MS_NOP * nop + MS_CAT4 * c4 + MS_CAT5 * c5 + mk
        tot.append(ms)
        note = ''
        if classes:
            g = np.arange(8, size, 16)
            gx, gy = np.meshgrid(g, g)
            tan = np.tan(np.radians(opt['--fov']) / 2.0)
            cl = toy_classes(entries[k], gx.ravel(), gy.ravel(), size, tan, tan)
            sh_ = [(cl == c).mean() for c in range(4)]
            note = '; plain %.0f%% %.2f ms, flat toys %.0f%% %.2f, shell toys %.0f%% %.2f, near ones %.0f%% %.2f' % (
                100 * sh_[0], parts[1], 100 * sh_[1], parts[2], 100 * sh_[2], parts[0], 100 * sh_[3], parts[3])
            if marks:
                note += ', the marks 2 and 3 %.2f' % mk
        elif plain:
            note = '; marked %.0f%%' % (100.0 * share_of(entries[k], size, opt['--fov']))
        what = (' ' + pose[3]) if len(pose) > 3 and pose[3] != 'none' else ''
        print('pose l %5.1f yaw %4.0f pitch %4.0f%s: %5.2f ms; per 64 pixels %5.0f ALU cycles, %4.0f nops, %4.1f transcendental, %3.1f texture unit; lanes busy %3.0f%%%s'
              % (pose[0], pose[1], pose[2], what, ms, alu, nop, c4, c5, busy, note))
    print('mean %.2f ms (%s, waves of %d%s)' % (np.mean(tot), sh.name, lanes, ', split by the stencil' if plain else ''))
    if prof is not None:
        report(psh, prof)


def report(sh, prof):
    """Cycles per stretch of code between labels and branches, the biggest first."""
    starts = sorted(set([0] + list(sh.labels.values()) + [i + 1 for i, x in enumerate(sh.instrs)
                                                         if x.op in ('br', 'brao', 'braa', 'jump', 'predt', 'predf', 'prede')]))
    tot = prof.sum()
    rows = []
    for a, b in zip(starts, starts[1:] + [len(sh.instrs)]):
        c = prof[a:b].sum()
        if c > 0:
            rows.append((c, a, b))
    rows.sort(reverse=True)
    inv = {v: k for k, v in sh.labels.items()}
    for c, a, b in rows[:40]:
        lab = ('l%d' % inv[a]) if a in inv else ''
        ops = [x.op for x in sh.instrs[a:b] if x.op != 'nop']
        sig = ' '.join(o for o in ops if o in E.CAT4 or o in E.CAT5 or o.startswith(('br', 'jump', 'pred')))
        print('%5.1f%%  [%4d..%4d) %-6s %3d instr  %s' % (100 * c / tot, a, b, lab, b - a, sig[:90]))


if __name__ == '__main__':
    main()
