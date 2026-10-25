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
    """The specialised ray tracer from an ir3 log: of the two big fragment programs, the smaller."""
    text = open(log, errors='replace').read().replace('MESA: info: ', '')
    progs = {}
    for m in re.finditer(r'; FRAG prog (\d+/\d+): (\d+) instr', text):
        progs[m.group(1)] = int(m.group(2))
    big = max(progs.values())
    cands = sorted((n, p) for p, n in progs.items() if n >= 0.5 * big)
    p = cands[0][1]
    end = text.index('; FRAG prog %s:' % p)
    start = text.rfind('Native code for', 0, end)
    body = text[start:end]
    lines = body.split('\n')
    hdr = body[body.rfind('; FRAG: outputs'):]
    # the program's instructions: from the first line after the @in/@out declarations
    first = 0
    while first < len(lines) and (not lines[first].strip() or lines[first].startswith(('@', ';', 'Native', 'SIMD'))):
        first += 1
    return lines[first:], hdr, p, progs[p]


def material_ubo(balls=None, grav=None):
    """Godot's material uniform block, std140 in declaration order (wormhole_view.gdshaderinc).
    grav: the gravity view's uniforms (tests/emu_dump.gd's "gravity" entry), after wh_tabReg."""
    u = np.zeros(4 * 64, np.float32)
    # (wh_tab* sit after head_pos when the shader has them: set by material_ubo's caller)
    u[0:3] = [3.0, 5.0, 1.0]                    # wh_rho0, wh_h, wh_fillet
    sph = SCENE['spheres_A'] + SCENE['spheres_B']
    for i, s in enumerate(sph):
        u[4 * (1 + i):4 * (2 + i)] = s
    for i, s in enumerate(SCENE['pillars_A']):
        u[4 * (7 + i):4 * (8 + i)] = s
    for i, s in enumerate(SCENE['boxes_B']):
        u[4 * (11 + i):4 * (12 + i)] = s
    # wh_tabLo, wh_tabInv, wh_tabReg (WH_TABLE), after head_l .. head_pos (vec4 39-44)
    tab, lo, inv, reg = fillet_table()
    u[4 * 45:4 * 46] = lo
    u[4 * 46:4 * 47] = inv
    u[4 * 47:4 * 48] = reg
    ui = u.view(np.uint32)
    if grav:
        u[4 * 48:4 * 49] = grav['cyl']
        u[4 * 49:4 * 51] = np.ravel(grav['g'])
        u[4 * 51:4 * 53] = np.ravel(grav['d'])
        u[4 * 53] = grav['pix']             # with WH_ARROWS only
    if balls:
        for i, (c, col) in enumerate(balls):
            u[4 * (15 + i):4 * (16 + i)] = c
            u[4 * (27 + i):4 * (28 + i)] = col
        ui[4 * 39] = len(balls)
    return ui


def fillet_table():
    """WormholeSpace.fillet_table, from the float64 reference (ref/wh.py)."""
    sys.path.insert(0, os.path.join(ROOT, 'ref'))
    from wh import Wormhole
    return Wormhole(3.0, 5.0, 1.0).fillet_table()


def check_balls_scene():
    """The stereo check's movable balls (main.gd CHECK_BALLS) and its emptied static objects."""
    return [([7.5, -0.5, 1.5, 5.0], [0.85, 0.08, 0.06, 0.3]), ([8.0, -1.8, 1.1, 5.0], [0.85, 0.08, 0.06, 0.3]),
            ([8.3, 1.6, 1.9, 5.0], [0.85, 0.08, 0.06, 0.3])]


class Shader:
    def __init__(self, log, balls=None, grav=None):
        lines, self.hdr, self.name, self.ninstr = ray_program(log)
        self.instrs, self.labels = E.parse_program(lines)
        ps = next(i for i, x in enumerate(self.instrs) if x.op == 'shps')
        pe = next(i for i, x in enumerate(self.instrs) if x.op == 'shpe')
        self.start = self.instrs[ps].target
        self.consts = np.zeros(8192, np.uint32)
        self.tex = fillet_table()[0]
        ubo = material_ubo(balls, grav)
        self.consts = E.run_preamble(self.instrs, ps, pe + 1, self.consts, {3: ubo})
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
        w = E.Wave(L, self.consts, None, varyings)
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
    balls = check_balls_scene() if entries[0].get('balls') else None
    grav = entries[0].get('gravity')
    if grav and '--check' not in flags:
        # the arrows' soft edges: a pixel of the headset's eye, not of the dump's picture
        grav = dict(grav, pix=2.0 * np.tan(np.radians(opt['--fov']) / 2.0) / opt['--size'])
    sh = Shader(log, balls, grav)
    order = find_flat_order(sh, entries)
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
