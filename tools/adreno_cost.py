#!/usr/bin/env python3
"""What a frame of the ray tracer costs on the Steam Frame's GPU, by the issue model of tools/ir3_emu.py.

The Frame's compiler (Mesa's ir3 in Turnip, Adreno 750) compiles the shader (tools/adreno_stats.sh
keeps its log with KEEP_LOG); this runs the specialised program it made on waves of 64 pixels
(8x8 tiles of 2x2 quads), or 128 (16x8) where the program runs double width, at given poses, and
sums what the waves issue. Divergent branches cost a wave both sides, as on the GPU. What the model
leaves out: tools/ir3_emu.py.

  python3 tools/adreno_cost.py LOG DUMP.json [--tiles N] [--size S] [--fov F] [--seed K] [--check] [--profile]
                               [--split WORLDLOG]
LOG: the compiler log (KEEP_LOG=... tools/adreno_stats.sh plain); DUMP.json: tests/emu_dump.gd's
output (the poses). --check compares the emulated colours with the dumped pictures (the pose is
then emulated at the picture's size and FOV); otherwise each pose is emulated as one eye of the
headset, S x S pixels (tools/adreno_cost.sh passes tools/env.sh's HEADSET_EYE) and F degrees of vertical field of view
(default 104, a guess at the Frame's: the headset log's per-second "refresh:" line gives the frustum
the runtime hands Godot), on N random tiles (default 300; the same tiles for every LOG of the same
wave width with the same seed K). --profile: cycles per stretch of code.
--split: the frame as the app draws it with toys (tracer.gd, «The split»): WORLDLOG's ray tracer (the
world's) over the whole view, LOG's (with the toys) also where the world's leaves the pixel to it
(may_meet, wormhole_core.gdshaderinc's wh_mayMeet); LOG's cost in a tile is weighted by the share of
its pixels it runs (the GPU packs the pixels it runs into waves, whole 2x2 groups, the others of a
group as helpers: that share is a little short of the lanes it takes).
"""
import json
import os
import re
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'ref'))
import in_box  # noqa: F401,E402 (first: on the Frame, into tools/box.sh's container)
import numpy as np  # noqa: E402

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ir3_emu as E  # noqa: E402

# The estimate, fitted on speed checks in the headset of other ray tracers than this tree's, at
# other poses than godot/bench.gd's PLACES; the measurements are not in the repository, so nothing
# here checks the constants. A model to compare variants, not a timing: GODOT_MS + MS_ALU x ALU
# issue cycles + MS_NOP x nop slots + MS_CAT4 x transcendental instructions + MS_CAT5 x texture-unit
# instructions, each per 64 pixels averaged over the tiles (per64). No pixel count is in it: it
# stands for the speed check's GPU ms only at the eye size the fit ran at, which is not recorded.
# By the constants transcendentals and texture-unit instructions cost far more than their issue
# slots (MS_CAT4 / MS_ALU and MS_CAT5 / MS_ALU ALU cycles' worth).
GODOT_MS = 0.8
MS_ALU = 1.61e-3
MS_NOP = 1.05e-3
MS_CAT4 = 0.0258
MS_CAT5 = 0.146
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
_CORE = open(os.path.join(ROOT, 'godot', 'shaders', 'wormhole_core.gdshaderinc')).read()
MAY_MARGIN = float(re.search(r'const float WH_MAY_MARGIN = ([0-9.e-]+);', _CORE).group(1))
WH_STEP = float(re.search(r'const float WH_STEP = ([0-9.e-]+);', _CORE).group(1))
SCENE = json.load(open(os.path.join(ROOT, 'godot', 'scene.json')))
from wh import Wormhole, app_profile  # noqa: E402 (ref/, on the path above)
PROFILE = app_profile()
WH = Wormhole(*PROFILE)


def ray_program(log):
    """The specialised ray tracer from an ir3 log: of the two big fragment programs, the smaller;
    its /1 (the /2 runs only past 512 vec4 of constants in all stages: tools/adreno_stats.sh prints
    each program's constlen)."""
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
    # another shader's "NIR (final form) for ..." header can land inside this program's listing
    # (tools/same_programs.py says why)
    lines = [x for x in body.split('\n') if not x.startswith('NIR (')]
    hdr = body[body.rfind('; FRAG: outputs'):]
    # the program's instructions: from the first line after the @in/@out declarations
    first = 0
    while first < len(lines) and (not lines[first].strip() or lines[first].startswith(('@', ';', 'Native', 'SIMD'))):
        first += 1
    return lines[first:], hdr, p, progs[p]


def res_file(path):
    """A res:// path (or a file) as a file."""
    return path.replace('res://', os.path.join(ROOT, 'godot') + '/') if path.startswith('res://') else path


def shader_defines(path):
    """A ray tracer's .gdshader (res:// path or file): (its WH_* defines, the view include's file)."""
    src = open(res_file(path)).read()
    return (frozenset(re.findall(r'^#define (WH_\w+)', src, re.M)),
            res_file(re.search(r'^#include "([^"]+)"', src, re.M).group(1)))


def view_uniforms(spec):
    """The material's uniforms the view include declares for a shader (shader_defines), in order:
    (name, type, array length). Its #ifdef, #ifndef, #else, #endif and #define are followed."""
    defines, view = set(spec[0]), spec[1]
    on, out = [], []
    for line in open(view).read().split('\n'):
        s = line.strip()
        m = re.match(r'#(ifdef|ifndef)\s+(\w+)', s)
        if m:
            on.append((m.group(2) in defines) == (m.group(1) == 'ifdef'))
        elif s.startswith('#else'):
            on[-1] = not on[-1]
        elif s.startswith('#endif'):
            on.pop()
        elif all(on):
            m = re.match(r'#define\s+(\w+)', s)
            if m:
                defines.add(m.group(1))
            m = re.match(r'uniform\s+(float|int|vec3|vec4|ivec4)\s+(\w+)(?:\[(\d+)\])?', s)
            if m:
                typ = {'float': 'f', 'int': 'i', 'vec3': 'v3', 'vec4': 'v4', 'ivec4': 'iv4'}[m.group(1)]
                out.append((m.group(2), typ, int(m.group(3) or 0)))
    return out


def ubo_layout(spec):
    """Byte offset of each uniform of the shader's material block. Godot lays them out std140-like: a
    scalar takes 4 bytes on a 4-byte boundary, a vec3 12 bytes on a 16-byte one, a vec4 and every
    array element 16 bytes."""
    out, off = {}, 0
    for name, typ, n in view_uniforms(spec):
        size, align = {'f': (4, 4), 'i': (4, 4), 'v3': (12, 16), 'v4': (16, 16), 'iv4': (16, 16)}[typ]
        if n:
            size, align = 16 * n, 16
        off = (off + align - 1) // align * align
        out[name] = (off, typ, n)
        off += size
    return out


def material_ubo(spec, values):
    """Godot's material uniform block for a shader (shader_defines); values: name -> number or
    list (tests/emu_dump.gd's "uniforms"); the app's throat, the scene's static objects and the
    fillet table by default."""
    u = np.zeros(4 * 160, np.float32)
    ui = u.view(np.uint32)
    tab, lo, inv, reg = fillet_table()
    vals = {'wh_rho0': PROFILE[0], 'wh_h': PROFILE[1], 'wh_fillet': PROFILE[2], 'wh_sph': SCENE['spheres_A'] + SCENE['spheres_B'],
            'wh_pil': SCENE['pillars_A'], 'wh_box': SCENE['boxes_B'], 'wh_tabLo': lo, 'wh_tabInv': inv, 'wh_tabReg': reg}
    vals.update(values or {})
    for name, (off, typ, n) in ubo_layout(spec).items():
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
    return WH.fillet_table()


class Shader:
    def set_uniforms(self, uniforms):
        """The material's uniforms (a pose's own, when they differ between poses: tools/adreno_cost.sh --hands, --held)."""
        self.ubos = {3: material_ubo(self.spec, uniforms)}   # the main program loads from it too (ldc at a computed index)
        self.consts = E.run_preamble(self.instrs, self.ps, self.pe + 1, np.zeros(8192, np.uint32), self.ubos)

    def __init__(self, log, spec, uniforms=None):
        lines, self.hdr, self.name, self.ninstr = ray_program(log)
        self.instrs, self.labels = E.parse_program(lines)
        self.ps = next(i for i, x in enumerate(self.instrs) if x.op == 'shps')
        self.pe = next(i for i, x in enumerate(self.instrs) if x.op == 'shpe')
        self.start = self.instrs[self.ps].target
        self.spec = spec
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
        self.killed = w.killed           # lanes the program discarded (the world's ray tracer)
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


def varyings_for(entry, xs, ys, W, H, tan_x, tan_y, sh=None):
    """The shader's inputs per lane: v_ray (the pixel's unnormalised ray, as (U_l, u)) and the flat
    v_l, v_n and (where the shader has it) v_eye, packed into the slots in the order Mesa packed them
    (find_flat_order)."""
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
    groups = {'l': [entry['head_l']], 'n': list(entry['head_n']), 'eye': WH.eye(entry['head_l'])}
    order = sh.flat_order if sh and sh.flat_order else ['l', 'n', 'eye']
    fv = sum((groups[g] for g in order), [])
    for k, loc in enumerate(flat):
        v[loc] = fv[k]
    return v


def find_flat_order(sh, entries):
    """Which way Mesa packed the flat inputs (v_l, v_n, v_eye): the order whose emulated colours are
    Godot's pictures, within 4/255, on the most pixels of a few tiles of each pose (the pictures can
    hold what this program leaves to another ray tracer: the toys of the split, or pixels it
    discards)."""
    import itertools
    from PIL import Image
    names = ['l', 'n', 'eye'] if len(sh.flat) == 6 else ['l', 'n']
    pics = [(e, np.asarray(Image.open(e['png']).convert('RGB'), np.float32) / 255.0) for e in entries]
    best = None
    for order in itertools.permutations(names):
        sh.flat_order = list(order)
        good = 0
        for e, img in pics:
            H, W = img.shape[:2]
            P = np.array(e['proj'])
            sh.set_uniforms(e.get('uniforms', {}))
            rng = np.random.default_rng(7)
            for t in range(6):
                xs, ys = tile_lanes(8 * rng.integers(0, W // 8), 8 * rng.integers(0, H // 8))
                col, _ = sh.run(varyings_for(e, xs, ys, W, H, 1.0 / P[0][0], 1.0 / P[1][1], sh))
                err = np.nan_to_num(np.abs(srgb(2.0 * col) - img[ys, xs]), nan=1.0).max(1)
                good += int(((err <= 4.0 / 255) & ~sh.killed).sum())
        if best is None or good > best[0]:
            best = (good, list(order))
    sh.flat_order = best[1]
    sh.set_uniforms(entries[0].get('uniforms', {}))
    if best[0] < 0.5 * len(pics) * 6 * 64:
        print('warning: the best packing of the flat inputs reproduces the pictures on %d of %d pixels'
              % (best[0], len(pics) * 6 * 64))
    return best[1]


def share_of(e, size, fov, step=16):
    """The share of the view where wh_mayMeet holds (a grid of pixels): what the world's ray tracer
    leaves to the one with the toys, but for the pixels it also leaves beside those (may_meet)."""
    tan = np.tan(np.radians(fov) / 2.0)
    g = np.arange(step // 2, size, step)
    xs, ys = np.meshgrid(g, g)
    return float(may_meet(e, xs.ravel(), ys.ravel(), size, tan, tan, quads=False).mean())


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


def may_meet(e, xs, ys, size, tan_x, tan_y, quads=True):
    """Per lane: whether the world's ray tracer leaves its pixel to the one with the toys
    (wormhole_core.gdshaderinc, wh_mayMeet, from the dump's uniforms; its ray from the head), with
    quads (lanes 4k .. 4k + 3, as tile_lanes lays them out) also where the pixel beside it or above
    or below it in its 2x2 group does (wh_renderE's derivatives, fine as tools/ir3_emu.py takes them)."""
    u = e.get('uniforms', {})
    B = np.array(e['cam_basis'], float).T
    f = np.array(e['head_f'], float)
    vx = (2.0 * (xs + 0.5) / size - 1.0) * tan_x
    vy = (1.0 - 2.0 * (ys + 0.5) / size) * tan_y
    pd = B @ np.stack([vx, vy, -np.ones_like(vx)], 0)
    V = pd[0][None] * f[0][:, None] + pd[1][None] * f[1][:, None] + pd[2][None] * f[2][:, None]
    V /= np.linalg.norm(V, axis=0)
    l0, n0 = e['head_l'], np.array(e['head_n'], float)
    vl, w = V[0], V[1:]
    tw = np.array([0.0, n0[2], -n0[1]]) if abs(n0[0]) < 0.9 else np.array([-n0[2], 0.0, n0[0]])
    we = w + 1e-7 * tw[:, None]
    e2 = we / np.linalg.norm(we, axis=0)
    rs = WH.eye(l0)[0]
    b = rs * np.minimum((w * e2).sum(0), 1.0)
    side = 1.0 if l0 >= 0.0 else -1.0
    inward = vl * side < 0.0
    enters = ~((abs(l0) > WH.L) & ((b >= WH.Rout + MAY_MARGIN) | ~inward))
    turn = b > WH.rmin - MAY_MARGIN
    passing = b < WH.rmin + MAY_MARGIN
    rend = np.maximum(b, WH.rmin) - MAY_MARGIN
    fz = np.stack([-e2[2], np.full(len(xs), n0[2])])
    fz2 = (fz * fz).sum(0)
    ct = np.minimum(b / rs, 1.0)
    tn = np.stack([ct, np.where(inward, 1.0, -1.0) * np.sqrt(np.maximum(1.0 - ct * ct, 0.0))])
    psie = np.arccos(np.minimum(b / min(rs, WH.Rout), 1.0))
    stretch = abs(l0) >= WH.Lc
    stretch_f = WH.Rout / WH.rmin * np.sqrt((WH.Rout + WH.R - WH.rmin) / WH.R)

    def inv_slope(r):
        c = np.clip((WH.Rout - r) / WH.R, 0.0, 1.0)
        return 1.0 / np.sqrt(np.maximum(1.0 - c * c, 1e-14))

    may = np.zeros(len(xs), bool)
    bi = u.get('wh_bIdx', [0, 0, 0, 0])
    ci = u.get('wh_cIdx', [0, 0, 0, 0])
    objs = [(u['wh_ball'][i], u['wh_ballCol'][i][3], 1.0) for i in range(int(bi[0]), int(bi[3]))]
    objs += [(u['wh_cube'][i], u['wh_cubeCol'][i][3], 2.0) for i in range(int(ci[0]), int(ci[3]))]
    for C4, sz, k in objs:
        c = np.array(C4[:3], float)
        step = stretch_f * WH_STEP * sz
        reach = k * sz + step * step / (8.0 * min(WH.R, WH.rho0)) + 1e-4 + MAY_MARGIN
        cb = np.stack([np.full(len(xs), float(c @ n0)), (c[:, None] * e2).sum(0)])
        cc = float(c @ c)
        rho2 = (cb * cb).sum(0)
        K = cc - reach * reach
        cf = (cb * fz).sum(0)
        dr = rend - reach
        arc = (n0[2] <= 0.0) | (K <= 0.0) | ((cb[1] >= 0.0) & (cb[0] * fz[1] - cb[1] * fz[0] >= 0.0)) \
            | ((cb[0] > 0.0) & (cb[0] * cb[0] >= K)) | ((cf > 0.0) & (cf * cf >= K * fz2))
        basic = (rho2 > K) & ((dr < 0.0) | (dr * dr < cc)) & arc
        if not stretch:
            may |= basic
            continue
        a = np.sqrt(np.maximum(rho2 - K, 0.0))
        rho = np.sqrt(rho2)
        r1 = np.where(inward, np.maximum(rho - a, rend), np.maximum(rho - a, rs))
        r2 = np.where(inward, np.minimum(rho + a, rs), rho + a)
        psil = np.abs(psie - np.arccos(np.minimum(b / np.where(inward, r1, r2), 1.0)))
        dev = r2 * psil * (inv_slope(np.where(inward, r1, rs)) - 1.0)
        near = (r1 <= r2) & (np.abs((cb * tn).sum(0) - b) <= a + dev)
        tt = np.stack([tn[0], np.abs(tn[1])])
        c2 = (cb * tt).sum(0)
        floor_after = (n0[2] <= 0.0) | (tt[0] * fz[1] - tt[1] * fz[0] >= 0.0)
        after_turn = turn & floor_after & ((n0[2] <= 0.0) | (K <= 0.0)
            | ((cb[0] * tt[1] - cb[1] * tt[0] <= 0.0) & (cb[1] * fz[0] - cb[0] * fz[1] <= 0.0))
            | ((c2 > 0.0) & (c2 * c2 >= K)) | ((cf > 0.0) & (cf * cf >= K * fz2)))
        throat = passing & (((WH.Lc > 0.0) & (np.sqrt(cc) - reach <= WH.rho0) & (abs(C4[3]) - reach <= WH.Lc))
                            | (side * C4[3] < reach))
        may |= basic & (near | (inward & (after_turn | throat)))
    may &= enters
    if quads:
        m = may.reshape(-1, 4)
        may = np.stack([m[:, 0] | m[:, 1] | m[:, 2], m[:, 1] | m[:, 0] | m[:, 3],
                        m[:, 2] | m[:, 3] | m[:, 0], m[:, 3] | m[:, 2] | m[:, 1]], 1).reshape(-1)
    return may


def cost(sh, entries, ntiles, size, fov, seed, profile=None, share=None, unis=None):
    """share(e, xs, ys, tan): the share of a tile's pixels this ray tracer runs (--split); unis:
    each pose's own uniforms (toys that move with the viewer: tools/adreno_cost.sh --hands, --held)."""
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
            prof = None if profile is None else np.zeros_like(profile)
            col, st = sh.run(varyings_for(e, xs, ys, size, size, tan_x, tan_y, sh), prof)
            if profile is not None:
                profile += w * prof
            for name in ('cycles', 'instr', 'cat4', 'cat5', 'lane_instr', 'nops', 'half'):
                setattr(tot, name, getattr(tot, name) + w * getattr(st, name))
        res.append((e['pose'], tot))
    return res


def per64(sh, st, n):
    """A pose's totals over n tiles as (ALU cycles, nop slots, transcendentals, texture-unit
    instructions) per 64 pixels. In a wave of 128 a full-precision instruction issues in two cycles
    and a half-precision one in one, and a nop slot covers 128 pixels; a cat4 or cat5 instruction's
    work is per pixel whatever the wave."""
    lanes = 128 if sh.wave128 else 64
    alu = (st.cycles - st.nops - st.half) * (2 if sh.wave128 else 1) / n * 64 / lanes + st.half / n * 64 / lanes
    return alu, st.nops / n * 64 / lanes, st.cat4 / n, st.cat5 / n


def main():
    args = sys.argv[1:]
    opt = {'--tiles': 300, '--size': 0, '--fov': 104.0, '--seed': 1, '--split': ''}
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
    if not opt['--size'] and '--check' not in flags:
        sys.exit('--size: the eye size (tools/env.sh, HEADSET_EYE)')
    entries = json.load(open(dump))
    spec = shader_defines(entries[0]['shader'])
    def eye_pix(u):
        u = dict(u)
        if 'wh_pix' in u and '--check' not in flags:
            # soft edges: a pixel of the headset's eye, not of the dump's picture
            u['wh_pix'] = 2.0 * np.tan(np.radians(opt['--fov']) / 2.0) / opt['--size']
        return u
    uniforms = eye_pix(entries[0].get('uniforms', {}))
    # the hands and what they hold move with the viewer: then each pose's own
    unis = [eye_pix(e.get('uniforms', {})) for e in entries]
    if all(u == unis[0] for u in unis):
        unis = None
    # the packing of the flat inputs: found against Godot's picture, with its uniforms
    order = find_flat_order(Shader(log, spec, dict(entries[0].get('uniforms', {}))), entries)
    sh = Shader(log, spec, uniforms)
    sh.flat_order = order
    print('%s: prog %s, %d instr; flat inputs %s' % (os.path.basename(log), sh.name, sh.ninstr, ', '.join(order)))
    if '--check' in flags:
        bad = check(sh, entries, opt['--tiles'], np.random.default_rng(opt['--seed']), unis)
        sys.exit(0 if bad < 0.002 else 1)
    prof = np.zeros(len(sh.instrs)) if '--profile' in flags else None
    n = opt['--tiles']
    tot = []
    lanes = 128 if sh.wave128 else 64
    size = opt['--size']
    share = None
    world = None
    if opt['--split']:
        # the world's ray tracer: its uniforms are the same as the one with the toys'
        world = Shader(opt['--split'], (spec[0] | {'WH_WORLD'}, spec[1]), uniforms)
        world.flat_order = find_flat_order(Shader(opt['--split'], (spec[0] | {'WH_WORLD'}, spec[1]),
                                                  dict(entries[0].get('uniforms', {}))), entries)
        share = lambda e, xs, ys, tan: float(may_meet(e, xs, ys, size, tan, tan).mean())
    res = cost(sh, entries, n, size, opt['--fov'], opt['--seed'], prof, share, unis)
    resw = cost(world, entries, n, size, opt['--fov'], opt['--seed'], None, None, unis) if world else None
    for k, (pose, st) in enumerate(res):
        alu, nop, c4, c5 = per64(sh, st, n)
        busy = 100.0 * st.lane_instr / max(st.instr * lanes, 1)
        if world:
            a2, n2, c42, c52 = per64(world, resw[k][1], n)
            alu, nop, c4, c5 = alu + a2, nop + n2, c4 + c42, c5 + c52
        ms = GODOT_MS + MS_ALU * alu + MS_NOP * nop + MS_CAT4 * c4 + MS_CAT5 * c5
        tot.append(ms)
        print('pose l %5.1f yaw %4.0f pitch %4.0f: %5.2f ms; per 64 pixels %5.0f ALU cycles, %4.0f nops, %4.1f transcendental, %3.1f texture unit; lanes busy %3.0f%%%s'
              % (pose[0], pose[1], pose[2], ms, alu, nop, c4, c5, busy,
                 '; with the toys %.0f%%' % (100.0 * share_of(entries[k], size, opt['--fov'])) if world else ''))
    print('mean %.2f ms (%s, waves of %d%s)' % (np.mean(tot), sh.name, lanes, ', split' if world else ''))
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
