#!/usr/bin/env python3
"""What a frame costs on the Steam Frame's GPU, by the issue model of tools/ir3_emu.py.

The Frame's compiler (Mesa's ir3 in Turnip, Adreno 750) compiles the shaders (tools/adreno_stats.sh
keeps its log with KEEP_LOG); this runs the specialised programs it made on waves of pixels at given
poses, and sums what the waves issue. Divergent branches cost a wave both sides, as on the GPU. It is
a model: no timings, no waits on transcendental or texture-unit results (counted apart: cat4, cat5),
no memory.

  python3 tools/adreno_cost.py WORLD.log DUMP.json [--toys FLAT.log SHELL.log] [--tiles N] [--size S]
                               [--fov F] [--seed K] [--check] [--profile]
WORLD.log: the world's ray tracer's compiler log; DUMP.json: tests/emu_dump.gd's output (the poses).
--toys: the frame as the app draws it with toys (main.gd, README «Мячи и кубы»): first the toys'
passes, the flat one (toys_flat*.gdshader) over each of its proxy spheres and the shell's
(toys_shell*.gdshader) over its sphere or the whole view, each pixel's hit or discard emulated; then
the world's ray tracer where no toy was drawn (the GPU skips it under the toys' depth). The GPU runs a
pass's pixels in waves of its own, so a toy pass runs on the pixels it covers, packed; the world's
ray tracer runs on whole tiles (its screen derivatives need the 2x2 quads) and each tile's cost is
weighted by the share of its pixels it draws.
--check compares the emulated colours with the dumped pictures (each pose is then emulated at the
picture's size and FOV); otherwise each pose is emulated as one eye of the headset, S x S pixels
(default 1728) and F degrees of vertical field of view (default 104), on N random tiles of 16 x 8
pixels (default 150; the same tiles for every LOG with the same seed). --profile: cycles per
stretch of code of the world's ray tracer, or with --toys of the shell's pass.
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


def ray_program(log, kind='world'):
    """A pass's specialised program from an ir3 log (kind: world, flat or shell). The log holds every
    shader Godot compiled (Godot's own materials, the other passes'): the pass's are those whose
    smooth and flat inputs are as many as its varyings (PASSES), with the colour (Godot also makes a
    variant that writes the depth alone) and, for a toys' pass, the depth; of its two (a generic
    ubershader, then the one specialised for the scene) the smaller. A shader with more than 100
    vec4 of constants also gets a variant /2 that reads them from memory ("safe constlen"); Turnip
    runs it only when the pipeline's stages need more than 512 in all (ir3_trim_constlen), and ours
    need ~200, so the /1 runs."""
    text = open(log, errors='replace').read().replace('MESA: info: ', '')
    want = tuple(sum(GROUP_SIZE[g] for g in gs) for gs in PASSES[kind])
    progs = {}
    for m in re.finditer(r'; FRAG prog (\d+/1): (\d+) instr', text):
        outs = text.rfind('; FRAG: outputs:', 0, m.start())
        line = text[outs:text.index('\n', outs)]
        if 'FRAG_RESULT_DATA0' not in line or ('FRAG_RESULT_DEPTH' in line) != (kind != 'world'):
            continue
        body = text[text.rfind('Native code for', 0, m.start()):m.start()]
        locs = {'bary.f': set(), 'flat.b': set()}
        for rpt, op, rel, loc in re.findall(r'(?:\(rpt(\d)\))?(bary\.f|flat\.b) [^,]+, (\(r\))?(\d+)', body):
            for k in range(int(rpt or 0) + 1):
                locs[op].add(int(loc) + (k if rel else 0))
        if (len(locs['bary.f']), len(locs['flat.b'])) == want:
            progs[m.group(1)] = int(m.group(2))
    if not progs:
        raise ValueError('%s: no %s pass program (%d smooth, %d flat inputs)' % (log, kind, want[0], want[1]))
    big = max(progs.values())
    cands = sorted((n, p) for p, n in progs.items() if n >= 0.5 * big)
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


# The material's uniforms in declaration order (wormhole_uniforms.gdshaderinc, then toys_view's), with
# the defines that keep each: (name, type, array length). Godot lays them out std140-like: a scalar
# takes 4 bytes on a 4-byte boundary, a vec3 12 bytes on a 16-byte one, a vec4 and every array
# element 16 bytes, a mat4 64.
UNIFORMS = [('wh_rho0', 'f', 0, None), ('wh_h', 'f', 0, None), ('wh_fillet', 'f', 0, None),
            ('wh_sph', 'v4', 6, None), ('wh_pil', 'v4', 4, None), ('wh_box', 'v4', 4, None),
            ('head_l', 'f', 0, None), ('head_n', 'v3', 0, None), ('head_f', 'v4', 3, None), ('head_pos', 'v3', 0, None),
            ('wh_tabLo', 'v4', 0, 'WH_TABLE'), ('wh_tabInv', 'v4', 0, 'WH_TABLE'), ('wh_tabReg', 'v4', 0, 'WH_TABLE'),
            ('grav_cyl', 'v4', 0, 'WH_GRAVITY'), ('grav_g', 'v4', 2, 'WH_GRAVITY'), ('grav_d', 'v4', 2, 'WH_GRAVITY'),
            ('wh_pix', 'f', 0, 'WH_PIX'),
            ('wh_ball', 'v4', 12, 'WH_TOYS'), ('wh_ballCol', 'v4', 12, 'WH_TOYS'), ('wh_nBall', 'i', 0, 'WH_TOYS'),
            ('wh_fball', 'v4', 12, 'WH_TOYS'), ('wh_cube', 'v4', 6, 'WH_TOYS'), ('wh_cubeE', 'v4', 30, 'WH_TOYS'),
            ('wh_cubeCol', 'v4', 6, 'WH_TOYS'), ('wh_nCube', 'i', 0, 'WH_TOYS'),
            ('wht_toChart', 'm4', 0, 'WHT_FLAT'), ('wht_side', 'f', 0, 'WHT_FLAT'),
            ('wht_cx', 'v4', 5, 'WHT_SHELL'), ('wht_cy', 'v4', 5, 'WHT_SHELL'), ('wht_cz', 'v4', 5, 'WHT_SHELL'),
            ('wht_r2', 'v4', 5, 'WHT_SHELL'), ('wht_lo', 'v4', 5, 'WHT_SHELL'), ('wht_hi', 'v4', 5, 'WHT_SHELL'),
            ('wht_fs', 'v4', 5, 'WHT_SHELL'), ('wht_bit', 'iv4', 5, 'WHT_SHELL'),
            ('wht_t1', 'v3', 0, 'WHT_SHELL'), ('wht_t2', 'v3', 0, 'WHT_SHELL'), ('wht_phiBin', 'iv4', 8, 'WHT_SHELL'),
            ('wht_bBin', 'iv4', 16, 'WHT_SHELL'), ('wht_bStep', 'f', 0, 'WHT_SHELL'),
            ('wht_coneIdx', 'iv4', 0, 'WHT_SHELL')]


def shader_defines(path):
    """The WH_* defines of a shader's .gdshader (res:// path or file), as its includes see them."""
    f = path.replace('res://', os.path.join(ROOT, 'godot') + '/') if path.startswith('res://') else path
    src = open(f).read()
    d = set(re.findall(r'^#define (WH\w+)', src, re.M))
    if 'toys_view' in src:
        d.add('WH_TOYS')
        if 'WHT_FLAT' not in d:
            d.add('WHT_SHELL')
    if 'WH_TOYS' in d or 'WH_ARROWS' in d:
        d.add('WH_PIX')
    return d


def ubo_layout(defines):
    """Byte offset of each uniform the shader with these defines declares."""
    out, off = {}, 0
    for name, typ, n, need in UNIFORMS:
        if need and need not in defines:
            continue
        size, align = {'f': (4, 4), 'i': (4, 4), 'v3': (12, 16), 'v4': (16, 16), 'iv4': (16, 16), 'm4': (64, 16)}[typ]
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
    vals = {'wh_rho0': 3.0, 'wh_h': 5.0, 'wh_fillet': 1.0, 'wh_sph': SCENE['spheres_A'] + SCENE['spheres_B'],
            'wh_pil': SCENE['pillars_A'], 'wh_box': SCENE['boxes_B'], 'wh_tabLo': lo, 'wh_tabInv': inv, 'wh_tabReg': reg,
            'wht_coneIdx': [-1, -1, -1, -1]}
    vals.update(values or {})
    for name, (off, typ, n) in ubo_layout(defines).items():
        if name not in vals:
            continue
        v = np.ravel(np.asarray(vals[name], np.float64))
        k = off // 4
        if typ == 'i':
            ui[k] = int(v[0])
        elif typ == 'iv4':
            ui[k:k + len(v)] = v.astype(np.int64)
        else:
            u[k:k + len(v)] = v
    return ui


def fillet_table():
    """WormholeSpace.fillet_table, from the float64 reference (ref/wh.py)."""
    sys.path.insert(0, os.path.join(ROOT, 'ref'))
    from wh import Wormhole
    return Wormhole(3.0, 5.0, 1.0).fillet_table()


# The shaders' inputs (varyings), by group: how many components each takes. The world's ray tracer
# reads the pixel's ray (as (U_l, u)) and per eye l, n and wh_eye(l); the shell's pass also the ray in
# view space; the flat pass the ray in view space and in the chart, the eye in the chart and the
# toy's bit (toys_view.gdshaderinc).
GROUP_SIZE = {'ray': 4, 'view': 3, 'd': 3, 'l': 1, 'n': 3, 'eye': 2, 'x': 3, 'toy': 1, 'cone': 20}
PASSES = {'world': (['ray'], ['l', 'n', 'eye']), 'shell': (['view', 'ray'], ['l', 'n', 'eye', 'cone']),
          'flat': (['view', 'd'], ['toy', 'x'])}


class Zeros(dict):
    """Uniform buffers by descriptor set; one the model does not have reads as zeros"""
    def __missing__(self, key):
        return np.zeros(4096, np.uint32)


class Shader:
    def set_uniforms(self, uniforms, proj=None):
        """The material's uniforms (a pose's own, when they differ between poses: --held), and the
        view's projection (columns), which the toys' passes read for their depth."""
        key = json.dumps([uniforms, proj], sort_keys=True)
        if key == getattr(self, '_ukey', None):
            return
        self._ukey = key
        # the material's (base 3); Godot's scene data (base 7): its first member the projection
        # matrix, the rest zeros. The camera's projection has OpenGL's depth (-1 near, 1 far); the
        # shaders' has Godot's reversed one, z' = (w - z) / 2 (Projection.create_depth_correction):
        # with the camera's, the farther of two toys won the depth test
        scene = np.zeros(4096, np.uint32)
        if proj is not None:
            P = np.array(proj, np.float64)          # columns
            P[:, 2] = 0.5 * (P[:, 3] - P[:, 2])
            scene[:16] = P.astype(np.float32).ravel().view(np.uint32)
        self.ubos = Zeros({3: material_ubo(self.defines, uniforms), 7: scene})
        self.consts = E.run_preamble(self.instrs, self.ps, self.pe + 1, np.zeros(8192, np.uint32), self.ubos)

    def __init__(self, log, defines, uniforms=None, kind='world'):
        lines, self.hdr, self.name, self.ninstr = ray_program(log, kind)
        self.instrs, self.labels = E.parse_program(lines)
        self.ps = next(i for i, x in enumerate(self.instrs) if x.op == 'shps')
        self.pe = next(i for i, x in enumerate(self.instrs) if x.op == 'shpe')
        self.start = self.instrs[self.ps].target
        self.defines = defines
        self.kind = kind
        self.tex = fillet_table()[0]
        self.set_uniforms(uniforms)
        # the inputs: smooth (bary.f) and flat (flat.b) varying slots, in slot order, and the groups
        # in them in the order Mesa packed them (find_packing)
        self.smooth, self.flat = [], []
        for x in self.instrs:
            if x.op in ('bary.f', 'flat.b'):
                for k in range(x.rpt + 1):
                    loc = x.srcs[0].imm + (k if x.srcs[0].rpt else 0)
                    (self.smooth if x.op == 'bary.f' else self.flat).append(loc)
        self.smooth = sorted(set(self.smooth))
        self.flat = sorted(set(self.flat))
        self.smooth_groups, self.flat_groups = [list(g) for g in PASSES[kind]]
        text = open(log, errors='replace').read().replace('MESA: info: ', '')
        self.wave128 = bool(re.search(r'; FRAG prog %s: \d+ max_waves, 1 double_threadsize' % re.escape(self.name), text))
        self.regs = int(re.search(r'; FRAG prog %s: .*?(\d+) full' % re.escape(self.name), text).group(1))
        outs = dict((n, (h, int(r), c)) for h, r, c, n in re.findall(r'(h?)r(\d+)\.([xyzw]) \(FRAG_RESULT_(\w+)\)', self.hdr.split('\n')[0]))
        h, r, c = outs['DATA0']
        self.out_half = h == 'h'
        self.out = r * 4 + E.COMP[c]
        self.depth = outs['DEPTH'][1] * 4 + E.COMP[outs['DEPTH'][2]] if 'DEPTH' in outs else None

    @property
    def width(self):
        return 128 if self.wave128 else 64

    def pack(self, inputs, L):
        """The varyings array: each group's components in its slots, in the packing order"""
        v = np.zeros((max(self.smooth + self.flat + [0]) + 1, L), np.float32)
        for slots, groups in ((self.smooth, self.smooth_groups), (self.flat, self.flat_groups)):
            vals = np.concatenate([np.asarray(inputs[g], np.float32).reshape(GROUP_SIZE[g], -1) for g in groups], 0)
            for k, loc in enumerate(slots[:len(vals)]):
                v[loc] = np.broadcast_to(vals[k], (L,))
        return v

    def run(self, inputs, L, profile=None):
        """Colours, depths (or None), which lanes discarded, and the issue statistics"""
        w = E.Wave(L, self.consts, self.ubos, self.pack(inputs, L))
        w.tex = self.tex
        st = E.Stats()
        st.pc = profile
        E.run_wave(self.instrs, self.start, w, st)
        if self.out_half:
            col = np.stack([w.H[self.out + k].view(np.float16).astype(np.float32) for k in range(3)], 1)
        else:
            col = np.stack([w.R[self.out + k].view(np.float32) for k in range(3)], 1)
        dep = w.R[self.depth].view(np.float32).copy() if self.depth is not None else None
        return col, dep, w.killed.copy(), st


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


L_SHELL = 4.0 + 0.5 * np.pi     # the shell's half length L for (3, 5, 1)
R_OUT = 4.0


def inputs_for(e, xs, ys, W, H, tan_x, tan_y):
    """Every group's values per lane at pixels (xs, ys) of pose e: the view-space ray (the eye is the
    view's origin in the dump), the ray as (U_l, u), the per-eye values, and, with the head in a flat
    universe, the eye and the ray in its chart."""
    B = np.array(e['cam_basis'], float).T    # columns: camera axes in play space
    f = np.array(e['head_f'], float)
    vx = (2.0 * (xs + 0.5) / W - 1.0) * tan_x
    vy = (1.0 - 2.0 * (ys + 0.5) / H) * tan_y
    dv = np.stack([vx, vy, -np.ones_like(vx)], 0)
    pd = B @ dv
    ray = pd[0][None] * f[0][:, None] + pd[1][None] * f[1][:, None] + pd[2][None] * f[2][:, None]
    l, n = e['head_l'], np.array(e['head_n'], float)
    side = 1.0 if l > 0 else -1.0
    M = np.array([side, 1.0, 1.0])
    x = M * (abs(l) - L_SHELL + R_OUT) * n
    d = M[:, None] * (side * ray[0][None] * n[:, None] + ray[1:])
    return {'ray': ray, 'view': dv, 'd': d, 'l': [l], 'n': n, 'eye': wh_eye(l), 'x': x,
            'toy': None, 'chart': (x, d / np.linalg.norm(d, axis=0)), 'cone': cones(e)}


_CONES = {}


def cones(e):
    """The near toys' cones (eye_data.gd, wh_coneAt) at the eye (the head: the dump has one view): four
    axes, then the cos of their half angles (-2: none)"""
    u = e.get('toys_shell', {})
    key = json.dumps([e['head_l'], e['head_n'], u.get('wht_cone'), u.get('wht_coneR'), u.get('wht_coneIdx')])
    if key not in _CONES:
        sys.path.insert(0, os.path.join(ROOT, 'ref'))
        import cull
        from wh import Wormhole
        W = Wormhole(3.0, 5.0, 1.0)
        out = np.zeros(20)
        out[16:] = -2.0
        idx = u.get('wht_coneIdx', [-1] * 4)
        for j in range(4):
            if idx[j] >= 0:
                c = u['wht_cone'][j]
                axis, cth = cull.cone(W, e['head_l'], np.array(e['head_n'], float), c[3], np.array(c[:3], float), u['wht_coneR'][j])
                out[4 * j:4 * j + 4] = axis
                out[16 + j] = cth
        _CONES[key] = out
    return _CONES[key]


def _ivec(u, name, n):
    return np.array(u.get(name, [[0, 0, 0, 0]] * (n // 4)), np.int64).reshape(-1)[:n]


def cell_cover(e, inp):
    """Per lane: whether the shell's pass is drawn there, over the cells of the view that can hold a
    toy (toys_view.gdshaderinc, wht_cellDir, at the eye: the head here): the pixel's cell (its ray
    plane's normal's azimuth bin and its b bin) has a toy in both bins, and not only near toys whose
    cones miss the whole cell. The chords' slivers beyond a cell's outer circle are left out."""
    u = e.get('toys_shell', {})
    V = inp['ray'] / np.linalg.norm(inp['ray'], axis=0)
    l = e['head_l']
    n = np.array(e['head_n'], float)
    rho = wh_eye(l)[0]
    t1 = np.array(u.get('wht_t1', [1, 0, 0]), float)
    t2 = np.array(u.get('wht_t2', [0, 1, 0]), float)
    phi_bin = _ivec(u, 'wht_phiBin', 32)
    b_bin = _ivec(u, 'wht_bBin', 64)
    step = float(u.get('wht_bStep', 1.0))
    idx = list(u.get('wht_coneIdx', [-1] * 4))
    cone = inp['cone']
    w = V[1:]
    N = np.cross(n[:, None], w, axis=0)
    pb = np.clip(((np.arctan2(t2 @ N, t1 @ N) + np.pi) * (16.0 / np.pi)).astype(np.int64), 0, 31)
    outside = abs(l) >= L_SHELL
    side = 1.0 if l > 0 else -1.0
    sig = np.where(V[0] > 0.0, 1.0, -1.0)
    b = rho * np.linalg.norm(w, axis=0)
    q = np.clip((b / step).astype(np.int64), 0, 31)
    bb = q + np.where(sig > 0.0, 0, 32)
    cand = phi_bin[pb] & b_bin[bb]
    if outside:
        cand = np.where((sig != side) & (b < R_OUT), cand, 0)
    # the cell's directions: th in [th0, th1], azimuths a of N in [a0, a1] (the eye's frame round n)
    e1 = t1 - (t1 @ n) * n
    e1 /= np.linalg.norm(e1)
    e2 = np.cross(n, e1)
    Mi = np.linalg.inv(np.array([[e1 @ t1, e2 @ t1], [e1 @ t2, e2 @ t2]]))
    p0 = pb * (np.pi / 16.0) - np.pi
    q0 = Mi @ np.stack([np.cos(p0), np.sin(p0)])
    q1 = Mi @ np.stack([np.cos(p0 + np.pi / 16.0), np.sin(p0 + np.pi / 16.0)])
    a0 = np.arctan2(q0[1], q0[0])
    a1 = np.arctan2(q1[1], q1[0])
    a1 = np.where(a1 < a0, a1 + 2.0 * np.pi, a1)
    w1 = np.minimum((q + 1.0) * step / rho, 1.0)
    if outside:
        w1 = np.minimum(w1, R_OUT / rho)
    th0 = np.arcsin(np.minimum(q * step / rho, 1.0))
    th1 = np.arcsin(w1)
    for j in range(4):
        k = idx[j]
        ct = cone[16 + j]
        if k < 0 or ct <= -1.5:
            continue
        U = cone[4 * j:4 * j + 4]
        ut = np.array([U[1:] @ e1, U[1:] @ e2])
        au = np.arctan2(ut[1], ut[0]) + 0.5 * np.pi
        d0 = np.mod(au - a0, 2.0 * np.pi)
        ca = np.where(d0 <= a1 - a0, 1.0, np.maximum(np.cos(d0), np.cos(d0 - (a1 - a0))))
        A = sig * U[0]
        B = np.linalg.norm(ut) * ca
        ts = np.arctan2(B, A)
        mx = np.where((ts >= th0) & (ts <= th1), np.sqrt(A * A + B * B),
                      np.maximum(A * np.cos(th0) + B * np.sin(th0), A * np.cos(th1) + B * np.sin(th1)))
        cand = np.where(((cand >> k) & 1 != 0) & (mx < ct - 1e-3), cand & ~(1 << k), cand)
    return cand != 0


def sphere_cover(chart, c, r):
    """Per lane: whether the straight ray from the eye meets the sphere's back face (centre c,
    radius r, in the chart): it is drawn there"""
    x, d = chart
    oc = (x - np.asarray(c, float))[:, None]
    b = (oc * d).sum(0)
    cq = float((oc * oc).sum()) - r * r
    disc = b * b - cq
    return (disc >= 0.0) & (-b + np.sqrt(np.maximum(disc, 0.0)) > 0.0)


def bits(v):
    return np.array([v], np.int32).view(np.float32)


class Acc:
    """A pass's issue totals over its waves, each weighted by the share of a wave of pixels it is"""

    def __init__(self, sh):
        self.sh = sh
        self.alu = self.nop = self.cat4 = self.cat5 = self.lanes = self.instr = self.lane_instr = 0.0

    def add(self, st, k):
        w = k / self.sh.width
        self.alu += w * ((st.cycles - st.nops - st.half) * (2 if self.sh.wave128 else 1) + st.half)
        self.nop += w * st.nops
        self.cat4 += st.cat4 * k
        self.cat5 += st.cat5 * k
        self.lanes += k
        self.instr += w * st.instr
        self.lane_instr += w * st.lane_instr

    def per64(self, pixels):
        """(ALU cycles, nop slots, transcendentals, texture-unit instructions) per 64 pixels of the view"""
        return (64.0 * self.alu / pixels, 64.0 * self.nop / pixels, self.cat4 / pixels, self.cat5 / pixels)

    def ms(self, pixels):
        a, n, c4, c5 = self.per64(pixels)
        return MS_ALU * a + MS_NOP * n + MS_CAT4 * c4 + MS_CAT5 * c5


def frame(passes, e, W, H, tan_x, tan_y, tiles, profile=None, colours=False):
    """One pose's frame on the given tiles ((x0, y0) of 16 x 8 pixels): the toys' passes where they
    are drawn, then the world's ray tracer where no toy was. Returns the passes' Acc and, with colours,
    per tile (xs, ys, colour)."""
    acc = {k: Acc(sh) for k, sh in passes.items()}
    toys = 'shell' in passes and any(e.get('toys_shell', {}).get('wht_phiBin', [0]))
    for k, sh in passes.items():
        sh.set_uniforms(e.get({'world': 'uniforms', 'shell': 'toys_shell', 'flat': 'toys_flat'}[k], {}), e.get('proj'))
    pics = []
    for (x0, y0) in tiles:
        xs, ys = tile_lanes(x0, y0, True)
        inp = inputs_for(e, xs, ys, W, H, tan_x, tan_y)
        n = len(xs)
        drawn = np.zeros(n, bool)
        zbuf = np.full(n, -np.inf, np.float32)      # reverse Z: the nearest is the largest
        col = np.zeros((n, 3), np.float32)
        if toys:
            prox = e.get('proxies') or {}
            runs = [('flat', p[0], sphere_cover(inp['chart'], p[1], p[2])) for p in prox.get('toys', []) if 'flat' in passes]
            runs.append(('shell', None, cell_cover(e, inp)))
            for kind, bit, cover in runs:
                sh = passes[kind]
                idx = np.nonzero(cover)[0]
                for j in range(0, len(idx), sh.width):
                    lanes = idx[j:j + sh.width]
                    sub = {g: (np.asarray(v)[..., lanes] if g in ('ray', 'view', 'd') else v) for g, v in inp.items()}
                    if kind == 'flat':
                        sub['toy'] = bits(bit)
                    c, z, killed, st = sh.run(sub, len(lanes), profile if kind == 'shell' else None)
                    acc[kind].add(st, len(lanes))
                    # without Godot's projection the depths are NaN: then the first toy drawn stays
                    win = ~killed & ((z > zbuf[lanes]) if np.isfinite(z[~killed]).all() else ~drawn[lanes])
                    zbuf[lanes[win]] = z[win]
                    col[lanes[win]] = c[win]
                    drawn[lanes[win]] = True
        sh = passes['world']
        share = 1.0 - drawn.mean()
        if share > 0.0 or colours:
            for j in range(0, n, sh.width):
                c, _, _, st = sh.run({g: (np.asarray(v)[..., j:j + sh.width] if g == 'ray' else v) for g, v in inp.items()},
                                     sh.width, None if toys else profile)
                acc['world'].add(st, (~drawn[j:j + sh.width]).sum())
                keep = ~drawn[j:j + sh.width]
                col[j:j + sh.width][keep] = c[keep]
        if colours:
            pics.append((xs, ys, col))
    return acc, pics


def srgb(c):
    c = np.clip(c, 0.0, 1.0)
    return np.where(c <= 0.0031308, 12.92 * c, 1.055 * np.power(c, 1.0 / 2.4) - 0.055)


def picture_tiles(e, ntiles, rng):
    from PIL import Image
    img = np.asarray(Image.open(e['png']).convert('RGB'), np.float32) / 255.0
    H, W = img.shape[:2]
    tiles = [(16 * rng.integers(0, W // 16), 8 * rng.integers(0, H // 8)) for _ in range(ntiles)] if rng else []
    P = np.array(e['proj'])                  # columns
    return img, W, H, 1.0 / P[0][0], 1.0 / P[1][1], tiles


def errors(passes, e, ntiles, rng, tiles=None):
    img, W, H, tx, ty, rnd = picture_tiles(e, ntiles, rng)
    _, pics = frame(passes, e, W, H, tx, ty, tiles or rnd, colours=True)
    return np.concatenate([np.nan_to_num(np.abs(srgb(2.0 * c) - img[ys, xs]), nan=1.0).max(1) for xs, ys, c in pics])


def find_packing(passes, entries):
    """Which way Mesa packed each pass's inputs: the orders of the groups whose emulated colours are
    Godot's picture. The world's on random tiles of the first pose (toys there are off whatever the
    order); the shell's pass's at the poses with the head in the shell, where it is the only toys'
    pass, then the flat one's at the others; each on the tiles where the frame without it is
    furthest off: there its toys are."""
    import itertools
    rng = np.random.default_rng(7)

    def tiles_of(e, n):
        img, W, H, tx, ty, _ = picture_tiles(e, 1, None)
        return [(16 * rng.integers(0, W // 16), 8 * rng.integers(0, H // 8)) for _ in range(n)]

    def score(some, sets):
        bad = 0.0
        for e, tiles in sets:
            err = errors(some, e, 0, None, tiles)
            bad += (err > 4.0 / 255).mean() + 0.01 * err.mean()
        return bad / max(len(sets), 1)

    def fit(k, some, sets):
        sh = passes[k]
        best = None
        for sg in itertools.permutations(PASSES[k][0]):
            for fg in itertools.permutations(PASSES[k][1]):
                sh.smooth_groups, sh.flat_groups = list(sg), list(fg)
                try:
                    bad = score(some, sets)
                except Exception:
                    if os.environ.get('COST_DEBUG'):
                        import traceback; traceback.print_exc()
                    bad = 2.0
                if best is None or bad < best[0]:
                    best = (bad, list(sg), list(fg))
        sh.smooth_groups, sh.flat_groups = best[1], best[2]

    def worst(some, e, n):
        """the tiles where the passes some are furthest from the picture"""
        off = []
        for t in tiles_of(e, 120):
            err = errors(some, e, 0, None, [t])
            off.append(((err > 4.0 / 255).mean(), t))
        off.sort(key=lambda x: -x[0])
        return [t for f, t in off[:n] if f > 0]

    world = {'world': passes['world']}
    fit('world', world, [(entries[0], tiles_of(entries[0], 10))])
    done = dict(world)
    for k, here in (('shell', lambda e: not e.get('proxies')), ('flat', lambda e: bool(e.get('proxies')))):
        if k not in passes:
            continue
        sets = [(e, worst(done, e, 4)) for e in entries if here(e)]
        sets = [x for x in sets if x[1]]
        done[k] = passes[k]
        if sets:
            fit(k, done, sets)


def check(passes, entries, ntiles, rng):
    worst = 0.0
    for e in entries:
        err = errors(passes, e, ntiles, rng)
        bad = (err > 4.0 / 255).mean()
        print('pose %s: %d pixels, max error %.1f/255, %.2f%% above 4/255, median %.2f/255'
              % (e['pose'], err.size, err.max() * 255, 100 * bad, np.median(err) * 255))
        worst = max(worst, bad)
    return worst


def main():
    args = sys.argv[1:]
    opt = {'--tiles': 150, '--size': 1728, '--fov': 104.0, '--seed': 1}
    flags = set()
    pos = []
    toys = None
    i = 0
    while i < len(args):
        if args[i] in opt:
            opt[args[i]] = type(opt[args[i]])(args[i + 1]); i += 2
        elif args[i] == '--toys':
            toys = (args[i + 1], args[i + 2]); i += 3
        elif args[i].startswith('--'):
            flags.add(args[i]); i += 1
        else:
            pos.append(args[i]); i += 1
    log, dump = pos
    entries = json.load(open(dump))
    e0 = entries[0]
    passes = {'world': Shader(log, shader_defines(e0['shader']), e0.get('uniforms', {}), 'world')}
    if toys:
        g = 2 if e0['shader'].endswith('arrows.gdshader') else 0
        for k, lg in zip(('flat', 'shell'), toys):
            path = 'res://shaders/toys_%s%s.gdshader' % (k, '_arrows' if g else '')
            passes[k] = Shader(lg, shader_defines(path), e0.get('toys_' + k, {}), k)
    find_packing(passes, entries)
    desc = '; '.join('%s prog %s, %d instr, %d regs' % (k, sh.name, sh.ninstr, sh.regs) for k, sh in passes.items())
    print('%s; inputs %s' % (desc, '; '.join('%s %s' % (k, '/'.join(sh.smooth_groups + sh.flat_groups)) for k, sh in passes.items())))
    if '--check' in flags:
        bad = check(passes, entries, 40, np.random.default_rng(opt['--seed']))
        sys.exit(0 if bad < 0.002 else 1)
    # the headset's eye: its pixel for the soft edges
    pix = 2.0 * np.tan(np.radians(opt['--fov']) / 2.0) / opt['--size']
    for e in entries:
        for k in ('uniforms', 'toys_flat', 'toys_shell'):
            if 'wh_pix' in e.get(k, {}):
                e[k]['wh_pix'] = pix
    prof_sh = passes['shell'] if toys else passes['world']
    prof = np.zeros(len(prof_sh.instrs)) if '--profile' in flags else None
    size = opt['--size']
    tan = np.tan(np.radians(opt['--fov']) / 2.0)
    rng = np.random.default_rng(opt['--seed'])
    tiles = [(16 * rng.integers(0, size // 16), 8 * rng.integers(0, size // 8)) for _ in range(opt['--tiles'])]
    pixels = 128.0 * len(tiles)
    tot = []
    for e in entries:
        acc, _ = frame(passes, e, size, size, tan, tan, tiles, prof)
        parts = {k: a.ms(pixels) for k, a in acc.items()}
        ms = GODOT_MS + sum(parts.values())
        tot.append(ms)
        a = acc['world']
        alu, nop, c4, c5 = a.per64(pixels)
        line = 'pose l %5.1f yaw %4.0f pitch %4.0f: %5.2f ms; world %.2f ms on %3.0f%% (%4.0f ALU, %4.0f nops, %4.1f cat4, %3.1f tex per 64 px)' % (
            e['pose'][0], e['pose'][1], e['pose'][2], ms, parts['world'], 100.0 * a.lanes / pixels, alu, nop, c4, c5)
        for k in ('flat', 'shell'):
            if k in acc:
                line += '; %s %.2f ms on %.0f%%' % (k, parts[k], 100.0 * acc[k].lanes / pixels)
        print(line)
    print('mean %.2f ms (%s)' % (np.mean(tot), ', '.join('%s %s, waves of %d' % (k, sh.name, sh.width) for k, sh in passes.items())))
    if prof is not None:
        report(prof_sh, prof)


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
