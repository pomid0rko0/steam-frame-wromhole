#!/usr/bin/env python3
"""What a frame of the ray tracer costs on the Steam Frame's GPU, by the issue model of tools/ir3_emu.py.

The Frame's compiler (Mesa's ir3 in Turnip, Adreno 750) compiles the shader (tools/adreno_stats.sh
keeps its log with KEEP_LOG); this runs the specialised program it made on waves of 64 pixels
(8x8 tiles of 2x2 quads) at given poses, and sums what the waves issue. Divergent branches cost
a wave both sides, as on the GPU. It is a model: no timings, no waits on transcendental or
texture-unit results (counted apart: cat4, cat5), no memory.

  python3 tools/adreno_cost.py LOG DUMP.json [--tiles N] [--size S] [--fov F] [--check]
LOG: the compiler log (KEEP_LOG=... tools/adreno_stats.sh plain); DUMP.json: tests/emu_dump.gd's
output (the poses). --check compares the emulated colours with the dumped pictures (the pose is
then emulated at the picture's size and FOV); otherwise each pose is emulated as one eye of the
headset, S x S pixels (default 1728) and F degrees of vertical field of view (default 104),
on N random tiles (default 300; the same tiles for every LOG with the same seed).
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


def ray_program(log):
    """The specialised ray tracer from an ir3 log: of the two big fragment programs, the smaller.
    A shader with more than 100 vec4 of constants also gets a variant /2 that reads them from
    memory ("safe constlen"); Turnip runs it only when the pipeline's stages need more than 512 in
    all (ir3_trim_constlen), and ours need ~200, so the /1 runs."""
    text = open(log, errors='replace').read().replace('MESA: info: ', '')
    progs = {}
    for m in re.finditer(r'; FRAG prog (\d+/1): (\d+) instr', text):
        progs[m.group(1)] = int(m.group(2))
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
            ('wh_cIdx', 'iv4', 0, 'BALLS'), ('wh_fball', 'v4', 12, 'BALLS')]


def shader_defines(path):
    """The WH_* defines of a ray tracer's .gdshader (res:// path or file), as the view include sees them."""
    f = path.replace('res://', os.path.join(ROOT, 'godot') + '/') if path.startswith('res://') else path
    d = set(re.findall(r'^#define (WH_\w+)', open(f).read(), re.M))
    if 'WH_NO_BALLS' not in d:
        d.add('BALLS')
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
    u = np.zeros(4 * 160, np.float32)
    ui = u.view(np.uint32)
    tab, lo, inv, reg = fillet_table()
    vals = {'wh_rho0': 3.0, 'wh_h': 5.0, 'wh_fillet': 1.0, 'wh_sph': SCENE['spheres_A'] + SCENE['spheres_B'],
            'wh_pil': SCENE['pillars_A'], 'wh_box': SCENE['boxes_B'], 'wh_tabLo': lo, 'wh_tabInv': inv, 'wh_tabReg': reg}
    vals.update(values or {})
    for name, (off, typ, n) in ubo_layout(defines).items():
        if name not in vals:
            continue
        v = np.ravel(np.asarray(vals[name], np.float64))
        k = off // 4
        if typ == 'i':
            ui[k] = int(v[0])
        elif typ == 'iv4':
            ui[k:k + 4] = v.astype(np.int64)[:4]
        else:
            u[k:k + len(v)] = v
    return ui


def fillet_table():
    """WormholeSpace.fillet_table, from the float64 reference (ref/wh.py)."""
    sys.path.insert(0, os.path.join(ROOT, 'ref'))
    from wh import Wormhole
    return Wormhole(3.0, 5.0, 1.0).fillet_table()


class Shader:
    def __init__(self, log, defines, uniforms=None):
        lines, self.hdr, self.name, self.ninstr = ray_program(log)
        self.instrs, self.labels = E.parse_program(lines)
        ps = next(i for i, x in enumerate(self.instrs) if x.op == 'shps')
        pe = next(i for i, x in enumerate(self.instrs) if x.op == 'shpe')
        self.start = self.instrs[ps].target
        self.consts = np.zeros(8192, np.uint32)
        self.tex = fillet_table()[0]
        ubo = material_ubo(defines, uniforms)
        self.ubos = {3: ubo}            # the main program loads from it too (ldc at a computed index)
        self.consts = E.run_preamble(self.instrs, ps, pe + 1, self.consts, self.ubos)
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


def find_flat_order(sh, entries):
    """Which way Mesa packed the flat inputs (v_l, v_n, v_eye): the order whose emulated colours are
    Godot's picture on a few tiles."""
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
        worst = 0.0
        for t in range(6):
            xs, ys = tile_lanes(8 * rng.integers(0, W // 8), 8 * rng.integers(0, H // 8))
            col, _ = sh.run(varyings_for(e, xs, ys, W, H, 1.0 / P[0][0], 1.0 / P[1][1], sh))
            err = np.nan_to_num(np.abs(srgb(2.0 * col) - img[ys, xs]), nan=1.0).max()
            worst = max(worst, err)
        if best is None or worst < best[0]:
            best = (worst, list(order))
    sh.flat_order = best[1]
    if best[0] > 4.0 / 255:
        print('warning: no packing of the flat inputs reproduces the picture (%.1f/255)' % (255 * best[0]))
    return best[1]


def srgb(c):
    c = np.clip(c, 0.0, 1.0)
    return np.where(c <= 0.0031308, 12.92 * c, 1.055 * np.power(c, 1.0 / 2.4) - 0.055)


def check(sh, entries, ntiles, rng):
    from PIL import Image
    worst = 0.0
    for e in entries:
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


def cost(sh, entries, ntiles, size, fov, seed, profile=None):
    tan_y = np.tan(np.radians(fov) / 2.0)
    tan_x = tan_y
    res = []
    for e in entries:
        rng = np.random.default_rng(seed)
        tot = E.Stats()
        for t in range(ntiles):
            x0 = 8 * rng.integers(0, size // 8)
            y0 = 8 * rng.integers(0, size // 8)
            if sh.wave128:
                x0 = 16 * (x0 // 16)
            xs, ys = tile_lanes(x0, y0, sh.wave128)
            col, st = sh.run(varyings_for(e, xs, ys, size, size, tan_x, tan_y, sh), profile)
            for k in ('cycles', 'instr', 'cat4', 'cat5', 'lane_instr', 'nops', 'half'):
                setattr(tot, k, getattr(tot, k) + getattr(st, k))
        res.append((e['pose'], tot))
    return res


def main():
    args = sys.argv[1:]
    opt = {'--tiles': 300, '--size': 1728, '--fov': 104.0, '--seed': 1}
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
    uniforms = dict(entries[0].get('uniforms', {}))
    if 'wh_pix' in uniforms and '--check' not in flags:
        # soft edges: a pixel of the headset's eye, not of the dump's picture
        uniforms['wh_pix'] = 2.0 * np.tan(np.radians(opt['--fov']) / 2.0) / opt['--size']
    # the packing of the flat inputs: found against Godot's picture, with its uniforms
    order = find_flat_order(Shader(log, defines, dict(entries[0].get('uniforms', {}))), entries)
    sh = Shader(log, defines, uniforms)
    sh.flat_order = order
    print('%s: prog %s, %d instr; flat inputs %s' % (os.path.basename(log), sh.name, sh.ninstr, ', '.join(order)))
    if '--check' in flags:
        bad = check(sh, entries, opt['--tiles'], np.random.default_rng(opt['--seed']))
        sys.exit(0 if bad < 0.002 else 1)
    prof = np.zeros(len(sh.instrs)) if '--profile' in flags else None
    n = opt['--tiles']
    tot = []
    tot = []
    lanes = 128 if sh.wave128 else 64
    for pose, st in cost(sh, entries, n, opt['--size'], opt['--fov'], opt['--seed'], prof):
        alu = (st.cycles - st.nops - st.half) * (2 if sh.wave128 else 1) / n * 64 / lanes + st.half / n * 64 / lanes
        nop = st.nops / n * 64 / lanes
        c4 = st.cat4 / n           # per pixel: each issue covers the wave's pixels
        c5 = st.cat5 / n
        ms = GODOT_MS + MS_ALU * alu + MS_NOP * nop + MS_CAT4 * c4 + MS_CAT5 * c5
        tot.append(ms)
        print('pose l %5.1f yaw %4.0f pitch %4.0f: %5.2f ms; per 64 pixels %5.0f ALU cycles, %4.0f nops, %4.1f transcendental, %3.1f texture unit; lanes busy %3.0f%%'
              % (pose[0], pose[1], pose[2], ms, alu, nop, c4, c5, 100.0 * st.lane_instr / max(st.instr * lanes, 1)))
    print('mean %.2f ms (%s, waves of %d)' % (np.mean(tot), sh.name, lanes))
    if prof is not None:
        report(sh, prof)


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
