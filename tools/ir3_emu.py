"""An emulator of Adreno fragment shader code (Mesa's ir3 disassembly), for cost estimates.

It runs the program that Mesa's Turnip compiler made for the Steam Frame's GPU (Adreno 750), as
printed by IR3_SHADER_DEBUG=fs (tools/adreno_stats.sh), on waves of pixels whose inputs we supply,
and counts what each wave issues: instructions, with their repeats (rptN) and the nops the
compiler put in for latency (nopN). Divergence follows the hardware's model (Mesa's
ir3_reconvergence.c): a wave runs the lowest program counter any of its pixels is at; pixels that
branched further ahead wait there and rejoin. Predicated regions (predt/predf/prede) run for the
whole wave. So a wave pays once for every piece of code any of its pixels needs.

This is a model, not a timing: it does not know the cost of waits on transcendental (cat4) and
texture-unit (cat5: dsx, dsy, samples) results, or of memory; cat4 and cat5 instructions are counted
apart.

Only what the wormhole's ray tracer uses is implemented; anything else stops with an error.
"""
import re
import numpy as np

F32 = np.float32
U32 = np.uint32


IMM_NAMED = {'log2(e)': 1.4426950408889634, '1/log2(e)': 0.6931471805599453,
             'pi': 3.141592653589793, '1/pi': 0.3183098861837907, '2/pi': 0.6366197723675814}


class Operand:
    __slots__ = ('kind', 'num', 'half', 'neg', 'abs', 'rpt', 'imm', 'immhalf', 'immint', 'rel', 'inv')

    def __init__(self):
        self.kind = None      # 'r' (register), 'c' (const), 'i' (immediate), 'p' (predicate), 'l' (label),
        self.num = 0          # 'a' (address reg), 'cr' (const relative c<a0.x + n>), 'cmem' (c[n] dword),
                              # 'cmem_a1' (c[a1.x]), 'rt' (render target), 'tex' (texture)
        self.half = False
        self.neg = False
        self.abs = False
        self.rpt = False      # (r): advances with each repeat
        self.imm = None
        self.immhalf = False
        self.immint = False
        self.rel = None
        self.inv = False      # !p0.x


COMP = {'x': 0, 'y': 1, 'z': 2, 'w': 3}


def parse_operand(s):
    o = Operand()
    s = s.strip()
    while True:
        m = re.match(r'\((neg|abs|r|last|ei|absneg|f32|f16|u32|s32|u16|s16|x|y|z|w|xy|xyz|xyzw|xz|yz|zw|yw|xw|xyw|xzw|yzw)\)', s)
        if not m:
            break
        t = m.group(1)
        if t == 'neg':
            o.neg = True
        elif t == 'abs':
            o.abs = True
        elif t == 'absneg':
            o.abs = True; o.neg = True
        elif t == 'r':
            o.rpt = True
        s = s[m.end():]
    if s.startswith('!p'):
        o.inv = True
        s = s[1:]
    m = re.fullmatch(r'(h?)r(\d+)\.([xyzw])', s)
    if m:
        o.kind = 'r'; o.half = m.group(1) == 'h'; o.num = int(m.group(2)) * 4 + COMP[m.group(3)]
        return o
    m = re.fullmatch(r'(h?)c(\d+)\.([xyzw])', s)
    if m:
        o.kind = 'c'; o.half = m.group(1) == 'h'; o.num = int(m.group(2)) * 4 + COMP[m.group(3)]
        return o
    m = re.fullmatch(r'rt(\d+)\.([xyzw])', s)
    if m:
        o.kind = 'rt'; o.num = int(m.group(1)) * 4 + COMP[m.group(2)]
        return o
    m = re.fullmatch(r'p0\.([xyzw])', s)
    if m:
        o.kind = 'p'; o.num = COMP[m.group(1)]
        return o
    m = re.fullmatch(r'a([01])\.x', s)
    if m:
        o.kind = 'a'; o.num = int(m.group(1))
        return o
    m = re.fullmatch(r'c\[(\d+)\]', s)
    if m:
        o.kind = 'cmem'; o.num = int(m.group(1))
        return o
    m = re.fullmatch(r'c\[a1\.x(?:\+(\d+))?\]', s)
    if m:
        o.kind = 'cmem_a1'
        o.num = int(m.group(1) or 0)
        return o
    m = re.fullmatch(r'(h?)c<a0\.x \+ (\d+)>', s)
    if m:
        o.kind = 'cr'; o.half = m.group(1) == 'h'; o.num = int(m.group(2))
        return o
    m = re.fullmatch(r't#(\d+)', s)
    if m:
        o.kind = 'tex'; o.num = int(m.group(1))
        return o
    m = re.fullmatch(r'#l(\d+)', s)
    if m:
        o.kind = 'l'; o.num = int(m.group(1))
        return o
    m = re.fullmatch(r'h\((.*)\)', s)
    if m:
        o.kind = 'i'; o.immhalf = True
        v = m.group(1)
        if re.fullmatch(r'-?\d+', v):
            o.immint = True; o.imm = int(v)
        else:
            o.imm = float(IMM_NAMED.get(v, v))
        return o
    m = re.fullmatch(r'\((.*)\)', s)
    if m:
        o.kind = 'i'
        v = m.group(1)
        if v.startswith('0x'):
            o.immint = True; o.imm = int(v, 16)
        elif v in IMM_NAMED:
            o.imm = IMM_NAMED[v]
        elif re.fullmatch(r'-?\d+', v):
            o.immint = True; o.imm = int(v)
        else:
            o.imm = float(v)
        return o
    if re.fullmatch(r'0x[0-9a-f]+', s):
        o.kind = 'i'; o.immint = True; o.imm = int(s, 16)
        return o
    if re.fullmatch(r'-?\d+', s):
        o.kind = 'i'; o.immint = True; o.imm = int(s)
        return o
    raise ValueError('operand ' + s)


class Instr:
    __slots__ = ('op', 'dst', 'srcs', 'rpt', 'nop', 'sat', 'jp', 'ss', 'sy', 'text', 'cat', 'target', 'dtype', 'wrmask', 'half16')

    def __init__(self, text):
        self.text = text
        self.rpt = 0
        self.nop = 0
        self.sat = False
        self.jp = self.ss = self.sy = False
        self.target = None
        self.dtype = None
        self.wrmask = 1
        self.half16 = False


def parse_program(lines):
    """lines: the disassembly from shps (or the first instruction) to end. Returns (instrs, labels)."""
    instrs = []
    labels = {}
    for raw in lines:
        L = raw.strip()
        if not L or L.startswith(';') or L.startswith('@'):
            continue
        m = re.fullmatch(r'l(\d+):', L)
        if m:
            labels[int(m.group(1))] = len(instrs)
            continue
        ins = Instr(L)
        while True:
            m = re.match(r'\((sy|ss|jp|sat|eq|ul|rpt\d+|nop\d+)\)\s*', L)
            if not m:
                break
            f = m.group(1)
            if f == 'sy': ins.sy = True
            elif f == 'ss': ins.ss = True
            elif f == 'jp': ins.jp = True
            elif f == 'sat': ins.sat = True
            elif f.startswith('rpt'): ins.rpt = int(f[3:])
            elif f.startswith('nop'): ins.nop = int(f[3:])
            L = L[m.end():]
        parts = L.split(None, 1)
        ins.op = parts[0]
        rest = parts[1] if len(parts) > 1 else ''
        ops = [x for x in (p.strip() for p in split_operands(rest)) if x]
        if ins.op in ('dsx', 'dsy', 'dsxpp.1', 'dsypp.1') or ins.op.startswith(('sam', 'isam')):
            m = re.match(r'\((f32|f16)\)\((\w+)\)(.*)', ops[0])
            ins.dtype = m.group(1)
            ins.wrmask = len(m.group(2))
            ops[0] = m.group(3)
        parsed = [parse_operand(o) for o in ops]
        if ins.op in NO_DST:
            ins.dst = None
            ins.srcs = parsed
        else:
            ins.dst = parsed[0] if parsed else None
            ins.srcs = parsed[1:]
        instrs.append(ins)
    for ins in instrs:
        for s in ins.srcs:
            if s.kind == 'l':
                ins.target = labels[s.num]
        # a 16-bit ALU op (Mesa's uses_significant_16bit_alu): half destination and a half source
        # (in waves of 128 these issue at double rate: adreno_cost.per64)
        alu = ins.op.split('.')[0] in ('add', 'mul', 'mad', 'min', 'max', 'absneg', 'floor', 'ceil', 'sign',
                                         'rndne', 'trunc', 'cmps', 'sel', 'and', 'or', 'xor', 'not', 'sub',
                                         'shl', 'shr', 'cov', 'mov') or ins.op in CAT4
        ins.half16 = bool(alu and ins.dst is not None and ins.dst.kind == 'r' and ins.dst.half
                          and any(x.kind == 'r' and x.half or x.kind == 'i' and x.immhalf for x in ins.srcs))
    return instrs, labels


def split_operands(rest):
    out, depth, cur = [], 0, ''
    for ch in rest:
        if ch in '(<[':
            depth += 1
        elif ch in ')>]':
            depth -= 1
        if ch == ',' and depth == 0:
            out.append(cur); cur = ''
        else:
            cur += ch
    out.append(cur)
    return out


NO_DST = {'br', 'brao', 'braa', 'jump', 'end', 'nop', 'predt', 'predf', 'prede', 'shps', 'shpe', 'getone',
          'kill', 'demote', 'bany', 'ball', 'chmask', 'chsh'}
CAT4 = {'rcp', 'rsq', 'sqrt', 'log2', 'exp2', 'sin', 'cos', 'hrsq', 'hlog2', 'hexp2'}
CAT5 = {'dsx', 'dsy', 'dsxpp.1', 'dsypp.1', 'sam.base3', 'saml.base3', 'sam', 'saml'}


class Wave:
    """One wave: L lanes, laid out as 2x2 quads (lane 4q + 0..3: left top, right top, left bottom, right bottom)."""

    def __init__(self, L, consts, ubos, varyings):
        self.L = L
        self.R = np.zeros((64 * 4, L), U32)
        self.H = np.zeros((64 * 4, L), np.uint16)
        self.C = consts            # U32 array, dwords (shared)
        self.ubos = ubos           # base -> U32 array of dwords
        self.P = np.zeros((4, L), bool)
        self.A0 = np.zeros(L, np.int64)
        self.A1 = 0
        self.var = varyings        # (8 or more, L) float32: per inloc
        self.pred_mode = 0         # 0 none, 1 true, 2 false
        self.pred_mask = np.ones(L, bool)
        self.out = None
        self.tex = None            # the one texture the program samples (H, W, 4)
        self.alias = {}            # alias.tex: register -> operand, for the next texture instruction

    # ---- reading operands
    def read(self, o, k, kind, lanes_half=False):
        """Value of operand o at repeat k as kind 'f' (float32 array), 'h' (float, from half), 'u'/'s' (int64 arrays),
        or 'b' (raw bits: U32 for full, uint16 for half)."""
        L = self.L
        if o.kind == 'r':
            n = o.num + (k if o.rpt else 0)
            if o.half:
                bits = self.H[n]
                if kind in ('f', 'h'):
                    v = bits.view(np.float16).astype(F32)
                elif kind == 's':
                    v = bits.view(np.int16).astype(np.int64)
                elif kind == 'u':
                    v = bits.astype(np.int64)
                else:
                    v = bits.copy()
            else:
                bits = self.R[n]
                if kind in ('f', 'h'):
                    v = bits.view(F32).copy()
                elif kind == 's':
                    v = bits.view(np.int32).astype(np.int64)
                elif kind == 'u':
                    v = bits.astype(np.int64)
                else:
                    v = bits.copy()
        elif o.kind in ('c', 'cr'):
            n = o.num + (k if o.rpt else 0)
            if o.kind == 'cr':
                # a0.x counts components: Mesa multiplies the array index by the stride in code
                # (shl.b ..., 2 for vec4s) before mova
                idx = self.A0 + n
                bits = self.C[idx]
            else:
                bits = np.full(L, self.C[n], U32)
            if o.half:
                # a half const: the low 16 bits of the 32-bit slot
                hb = (bits & 0xffff).astype(np.uint16)
                if kind in ('f', 'h'):
                    v = hb.view(np.float16).astype(F32)
                elif kind == 's':
                    v = hb.view(np.int16).astype(np.int64)
                elif kind == 'u':
                    v = hb.astype(np.int64)
                else:
                    v = hb.copy()
            elif kind in ('f', 'h'):
                v = bits.view(F32).copy()
            elif kind == 's':
                v = bits.view(np.int32).astype(np.int64)
            elif kind == 'u':
                v = bits.astype(np.int64)
            else:
                v = bits.copy()
        elif o.kind == 'i':
            if kind in ('f', 'h'):
                if o.immint and not o.immhalf:
                    v = np.full(L, np.uint32(o.imm & 0xffffffff), U32).view(F32).copy()
                elif o.immint and o.immhalf:
                    v = np.full(L, np.uint16(o.imm & 0xffff), np.uint16).view(np.float16).astype(F32)
                else:
                    v = np.full(L, o.imm, F32)
            elif kind in ('u', 's'):
                if not o.immint:
                    if o.immhalf:
                        v = np.full(L, np.float16(o.imm), np.float16).view(np.uint16).astype(np.int64)
                    else:
                        v = np.full(L, F32(o.imm), F32).view(U32).astype(np.int64)
                else:
                    v = np.full(L, o.imm, np.int64)
            else:  # bits
                if o.immint:
                    v = np.full(L, o.imm & 0xffffffff, np.int64)
                else:
                    v = (np.full(L, np.float16(o.imm), np.float16).view(np.uint16).astype(np.int64) if o.immhalf
                         else np.full(L, F32(o.imm), F32).view(U32).astype(np.int64))
                return v
        elif o.kind == 'p':
            v = self.P[o.num].copy()
            return ~v if o.inv else v
        else:
            raise NotImplementedError('read ' + o.kind)
        if kind in ('f', 'h'):
            if o.abs:
                v = np.abs(v)
            if o.neg:
                v = -v
        elif kind in ('u', 's'):
            if o.abs:
                v = np.abs(v)
            if o.neg:
                v = -v
        else:
            if o.neg:
                v = ~v
        return v

    def write(self, o, k, val, kind, mask):
        """Write val (float32 for 'f', ints for 'u'/'s', bits for 'b', bools for 'p') to operand o at repeat k."""
        if o.kind == 'p':
            n = o.num + k
            self.P[n][mask] = np.asarray(val).astype(bool)[mask] if np.ndim(val) else bool(val)
            return
        if o.kind == 'a':
            if o.num == 0:
                self.A0[mask] = np.asarray(val, np.int64)[mask]
            else:
                self.A1 = int(np.asarray(val).ravel()[0])
            return
        n = o.num + k
        if o.half:
            if kind == 'f':
                bits = np.asarray(val, F32).astype(np.float16).view(np.uint16)
            elif kind in ('u', 's'):
                bits = (np.asarray(val, np.int64) & 0xffff).astype(np.uint16)
            else:
                bits = (np.asarray(val).astype(np.int64) & 0xffff).astype(np.uint16)
            self.H[n][mask] = bits[mask]
        else:
            if kind == 'f':
                bits = np.asarray(val, F32).view(U32)
            elif kind in ('u', 's'):
                bits = (np.asarray(val, np.int64) & 0xffffffff).astype(U32)
            else:
                bits = (np.asarray(val).astype(np.int64) & 0xffffffff).astype(U32)
            self.R[n][mask] = bits[mask]


def quad_dx(v):
    q = v.reshape(-1, 4)
    d0 = q[:, 1] - q[:, 0]
    d1 = q[:, 3] - q[:, 2]
    return np.stack([d0, d0, d1, d1], 1).reshape(-1)


def quad_dy(v):
    q = v.reshape(-1, 4)
    d0 = q[:, 2] - q[:, 0]
    d1 = q[:, 3] - q[:, 1]
    return np.stack([d0, d1, d0, d1], 1).reshape(-1)


def fsat(v, sat):
    return np.clip(v, 0.0, 1.0).astype(F32) if sat else v


def is_half_op(ins):
    for s in ins.srcs:
        if s.kind == 'r' and s.half:
            return True
        if s.kind == 'i' and s.immhalf:
            return True
    return False


def round_half(v, half):
    return np.asarray(v, F32).astype(np.float16).astype(F32) if half else np.asarray(v, F32)


CMP = {'lt': np.less, 'le': np.less_equal, 'gt': np.greater, 'ge': np.greater_equal, 'eq': np.equal, 'ne': np.not_equal}


class Stats:
    def __init__(self):
        self.cycles = 0          # issue slots: instructions (with repeats) + nops
        self.instr = 0           # instructions issued (with repeats), without nops
        self.cat4 = 0            # transcendental instructions issued (with repeats)
        self.cat5 = 0            # texture-unit instructions: a sample one, a derivative one per component
        self.lane_instr = 0      # instructions times active lanes (useful work)
        self.pc = None           # optional: cycles per instruction index (a numpy array)
        self.nops = 0            # issue slots of nops (nop instructions, nopN flags, their repeats)
        self.half = 0            # 16-bit ALU instructions issued (a half destination and a half source)


def run_wave(prog, start, wave, stats, max_steps=200000):
    instrs = prog
    L = wave.L
    pc = np.full(L, start, np.int64)
    done = np.zeros(L, bool)
    steps = 0
    while not done.all():
        steps += 1
        if steps > max_steps:
            raise RuntimeError('runaway')
        cur = int(pc[~done].min())
        at = (pc == cur) & ~done
        ins = instrs[cur]
        if wave.pred_mode == 1:
            ex = at & wave.pred_mask
        elif wave.pred_mode == 2:
            ex = at & ~wave.pred_mask
        else:
            ex = at
        reps = ins.rpt + 1
        stats.cycles += reps + ins.nop
        stats.nops += ins.nop + (reps if ins.op == 'nop' else 0)
        if ins.half16:
            stats.half += reps
        if stats.pc is not None:
            stats.pc[cur] += reps + ins.nop
        if ins.op != 'nop':
            stats.instr += reps
            stats.lane_instr += reps * int(ex.sum())
        if ins.op in CAT4:
            stats.cat4 += reps
        if ins.op in CAT5:
            # derivatives: one per component; a sample: one
            stats.cat5 += reps * (1 if ins.op.startswith('sam') else ins.wrmask)
        nxt = np.where(at, cur + 1, pc)
        op = ins.op
        if op == 'end':
            wave.out_mask = at
            done |= at
            pc = nxt
            continue
        if op == 'jump':
            pc = np.where(at, ins.target, pc)
            continue
        if op in ('br', 'brao', 'braa', 'bany', 'ball'):
            c1 = wave.read(ins.srcs[0], 0, 'b')
            if op == 'br':
                cond = c1
            elif op == 'brao':
                cond = c1 | wave.read(ins.srcs[1], 0, 'b')
            elif op == 'braa':
                cond = c1 & wave.read(ins.srcs[1], 0, 'b')
            elif op == 'bany':
                cond = np.full(L, bool((c1 & at).any()))
            else:
                cond = np.full(L, bool((c1 | ~at).all()))
            cond = cond.astype(bool)
            pc = np.where(at & cond, ins.target, nxt)
            continue
        if op == 'predt' or op == 'predf':
            wave.pred_mask = wave.P[0].copy()
            wave.pred_mode = 1 if op == 'predt' else 2
            pc = nxt
            continue
        if op == 'prede':
            wave.pred_mode = 0
            pc = nxt
            continue
        if op in ('nop', 'shpe'):
            pc = nxt
            continue
        if op in ('shps', 'getone'):
            # the preamble ran separately: skip it
            pc = np.where(at, ins.target, pc)
            continue
        if op in ('kill', 'demote'):
            raise NotImplementedError(op)
        execute(ins, wave, ex)
        pc = nxt
    return wave


def execute(ins, w, ex):
    op = ins.op
    reps = ins.rpt + 1
    base = op.split('.')[0]
    for k in range(reps):
        d = ins.dst
        if base in ('add', 'mul', 'min', 'max', 'mad', 'absneg', 'floor', 'ceil', 'sign', 'rndne', 'trunc') and op.endswith(('.f', '.f32', '.f16')) or op in ('mad.f32', 'mad.f16'):
            half = is_half_op(ins)
            a = w.read(ins.srcs[0], k, 'f')
            if base == 'add':
                v = a + w.read(ins.srcs[1], k, 'f')
            elif base == 'mul':
                v = a * w.read(ins.srcs[1], k, 'f')
            elif base == 'min':
                # IEEE minNum / maxNum, as the GPU: a NaN operand gives the other one
                v = np.fmin(a, w.read(ins.srcs[1], k, 'f'))
            elif base == 'max':
                v = np.fmax(a, w.read(ins.srcs[1], k, 'f'))
            elif base == 'mad':
                v = a * w.read(ins.srcs[1], k, 'f') + w.read(ins.srcs[2], k, 'f')
            elif base == 'absneg':
                v = a
            elif base == 'floor':
                v = np.floor(a)
            elif base == 'ceil':
                v = np.ceil(a)
            elif base == 'sign':
                v = np.sign(a)
            elif base == 'rndne':
                v = np.rint(a)
            elif base == 'trunc':
                v = np.trunc(a)
            v = round_half(v, half)
            w.write(d, k, fsat(v.astype(F32), ins.sat), 'f', ex)
        elif base == 'cmps':
            t = op.split('.')[1]
            cond = op.split('.')[2]
            if t == 'f':
                a = w.read(ins.srcs[0], k, 'f'); b = w.read(ins.srcs[1], k, 'f')
            else:
                kind = 's' if t == 's' else 'u'
                a = w.read(ins.srcs[0], k, kind); b = w.read(ins.srcs[1], k, kind)
            r = CMP[cond](a, b)
            if d.kind == 'p':
                w.write(d, k, r, 'p', ex)
            else:
                w.write(d, k, r.astype(np.int64), 'u', ex)
        elif base == 'sel':
            a = w.read(ins.srcs[0], k, 'b')
            c = w.read(ins.srcs[1], k, 'b')
            b = w.read(ins.srcs[2], k, 'b')
            t = op.split('.')[1]
            if t in ('b16', 'b32'):
                cond = c != 0
            else:
                raise NotImplementedError(op)
            w.write(d, k, np.where(cond, a, b), 'b', ex)
        elif base in ('and', 'or', 'xor', 'not') and op.endswith('.b'):
            a = w.read(ins.srcs[0], k, 'b').astype(np.int64)
            if base == 'not':
                v = ~a
            else:
                b = w.read(ins.srcs[1], k, 'b').astype(np.int64)
                v = a & b if base == 'and' else (a | b if base == 'or' else a ^ b)
            w.write(d, k, v, 'b', ex)
        elif base == 'andg':
            a = w.read(ins.srcs[0], k, 'b').astype(np.int64)
            b = w.read(ins.srcs[1], k, 'b').astype(np.int64)
            c = w.read(ins.srcs[2], k, 'b').astype(np.int64)
            w.write(d, k, (b & a) | c, 'b', ex)
        elif base in ('add', 'sub') and op.endswith(('.u', '.s')):
            kind = 's' if op.endswith('.s') else 'u'
            a = w.read(ins.srcs[0], k, kind); b = w.read(ins.srcs[1], k, kind)
            w.write(d, k, a + b if base == 'add' else a - b, kind, ex)
        elif base in ('min', 'max') and op.endswith(('.u', '.s')):
            kind = 's' if op.endswith('.s') else 'u'
            a = w.read(ins.srcs[0], k, kind); b = w.read(ins.srcs[1], k, kind)
            w.write(d, k, np.minimum(a, b) if base == 'min' else np.maximum(a, b), kind, ex)
        elif op in ('shlm', 'shrm', 'shlg', 'shrg'):
            # a7xx's shift-and-mask family (Mesa isa/ir3-cat3.xml), the shift amount first:
            # shlm s, a, c = (a << s) & c, shrm (a >> s) & c, shlg (a << s) | c, shrg (a >> s) | c
            s_ = w.read(ins.srcs[0], k, 'u'); a = w.read(ins.srcs[1], k, 'u'); c = w.read(ins.srcs[2], k, 'u')
            sh = (a << (s_ & 31)) & 0xffffffff if op.startswith('shl') else a >> (s_ & 31)
            v = sh & c if op.endswith('m') else sh | c
            w.write(d, k, v, 'u', ex)
        elif op in ('bfrev.b', 'clz.b', 'clz.s', 'cbits.b'):
            # bit reverse, count leading zeros (findLSB is clz(bfrev(x)); 0 gives -1 here), set bits
            a = w.read(ins.srcs[0], k, 'u') & 0xffffffff
            if op == 'bfrev.b':
                v = np.zeros_like(a)
                for b in range(32):
                    v |= ((a >> b) & 1) << (31 - b)
            elif op == 'cbits.b':
                v = np.zeros_like(a)
                for b in range(32):
                    v += (a >> b) & 1
            else:
                v = np.full_like(a, -1)
                for b in range(32):
                    v = np.where((v < 0) & (((a >> (31 - b)) & 1) == 1), b, v)
            w.write(d, k, v, 'u' if op != 'clz.s' else 's', ex)
        elif op == 'absneg.s':
            # integer abs / negate: the source's (abs) and (neg) flags do it
            w.write(d, k, w.read(ins.srcs[0], k, 's'), 's', ex)
        elif op == 'mull.u':
            # a 32-bit integer product, as Mesa lowers it: mull.u multiplies the low 16 bits,
            # then madsh.m16 twice adds the cross terms (indexing: 5 * i)
            a = w.read(ins.srcs[0], k, 'u')
            b = w.read(ins.srcs[1], k, 'u')
            w.write(d, k, ((a & 0xffff) * (b & 0xffff)) & 0xffffffff, 'u', ex)
        elif op == 'madsh.m16':
            a = w.read(ins.srcs[0], k, 'u')
            b = w.read(ins.srcs[1], k, 'u')
            c = w.read(ins.srcs[2], k, 'u')
            w.write(d, k, ((((a & 0xffff) * (b >> 16)) << 16) + c) & 0xffffffff, 'u', ex)
        elif base in ('shl', 'shr', 'ashr') and op.endswith('.b'):
            # the shift amount modulo the width; ashr shifts the sign in
            b = w.read(ins.srcs[1], k, 'u') & (15 if d.half else 31)
            a = w.read(ins.srcs[0], k, 's' if base == 'ashr' else 'u')
            v = (a << b) if base == 'shl' else (a >> b)
            w.write(d, k, v, 'u', ex)
        elif base in ('swz', 'gat', 'sct'):
            ops = [d] + list(ins.srcs)
            n = len(ops) // 2
            if base == 'swz':
                vals = [w.read(ops[n + j], 0, 'b') for j in range(n)]
                for j in range(n):
                    w.write(ops[j], 0, vals[j], 'b', ex)
            else:
                raise NotImplementedError(ins.text)
            return
        elif base in ('mov', 'cov'):
            ty = op.split('.', 1)[1]
            m = re.fullmatch(r'([fsu])(16|32)([fsu])(16|32)', ty)
            st, sb, dt, db = m.groups()
            src = ins.srcs[0]
            if st == 'f':
                v = w.read(src, k, 'f')
            else:
                v = w.read(src, k, st)
                if sb == '16' and st == 'u':
                    v = v & 0xffff
                if sb == '16' and st == 's':
                    v = ((v + 0x8000) & 0xffff) - 0x8000
            if op.startswith('mov') and st == dt:
                v = w.read(src, k, 'b')
                w.write(d, k, v, 'b', ex)
                continue
            if dt == 'f':
                v = np.asarray(v, F32)
                if db == '16':
                    v = v.astype(np.float16).astype(F32)
                w.write(d, k, v, 'f', ex)
            else:
                if st == 'f':
                    v = np.trunc(np.nan_to_num(v)).astype(np.int64)
                w.write(d, k, v, dt, ex)
        elif base in ('rcp', 'rsq', 'sqrt', 'log2', 'exp2', 'sin', 'cos', 'hrsq', 'hlog2', 'hexp2'):
            half = is_half_op(ins)
            base = base[1:] if base.startswith('h') else base
            a = w.read(ins.srcs[0], k, 'f').astype(np.float64)
            with np.errstate(all='ignore'):
                if base == 'rcp': v = 1.0 / a
                elif base == 'rsq': v = 1.0 / np.sqrt(a)
                elif base == 'sqrt': v = np.sqrt(a)
                elif base == 'log2': v = np.log2(a)
                elif base == 'exp2': v = np.exp2(a)
                elif base == 'sin': v = np.sin(a)
                elif base == 'cos': v = np.cos(a)
            v = round_half(v.astype(F32), half)
            w.write(d, k, fsat(v, ins.sat), 'f', ex)
        elif op in ('dsx', 'dsy', 'dsxpp.1', 'dsypp.1'):
            for c in range(ins.wrmask):
                a = w.read(ins.srcs[0], c, 'f') if ins.srcs[0].rpt or c == 0 else w.read(_shift(ins.srcs[0], c), 0, 'f')
                v = quad_dx(a) if op.startswith('dsx') else quad_dy(a)
                w.write(d, c, v.astype(F32), 'f', ex)
            return
        elif op.startswith('ldc.'):
            # a load from a uniform buffer (Mesa isa/ir3-cat6.xml): ldc.u.offsetC.N.imm.baseB dst,
            # offset, ubo: N dwords from component C of vec4 `offset` (a register or an immediate)
            # of UBO `ubo` (immediate) in descriptor set B, per lane. Ours: the material's, set 3, UBO 0
            m = re.search(r'offset(\d+)\.(\d+)\..*base(\d+)', op)
            comp, cnt, base_ = int(m.group(1)), int(m.group(2)), int(m.group(3))
            assert ins.srcs[1].kind == 'i' and int(ins.srcs[1].imm) == 0, ins.text
            idx = w.read(ins.srcs[0], 0, 'u')
            buf = w.ubos[base_]
            for c in range(cnt):
                at = np.clip(idx * 4 + comp + c, 0, len(buf) - 1)
                w.write(d, c, buf[at], 'b', ex)
            return
        elif op == 'mova':
            # a0.x for relative constant reads (c<a0.x + n>): Mesa's mov.s16s16 to a0.x, per lane
            v = w.read(ins.srcs[0], k, 's')
            w.write(d, k, ((v + 0x8000) & 0xffff) - 0x8000, 's', ex)
        elif op == 'mova1':
            # the texture's descriptor index: there is one texture
            w.A1 = int(ins.srcs[0].imm) if ins.srcs[0].kind == 'i' else w.A1
        elif op.startswith('alias.tex'):
            w.alias[(d.half, d.num)] = ins.srcs[0]
        elif op.startswith(('sam', 'saml')):
            # a 2D texture, bilinear with clamp to edge, 8-bit filter weights: Wave.tex (H, W, 4).
            # Source registers go through the alias table first (alias.tex)
            tex = w.tex
            H, Wd = tex.shape[:2]
            c0 = ins.srcs[0]
            c1 = _shift(c0, 1)
            src = [w.alias.get((c.half, c.num), c) for c in (c0, c1)]
            w.alias = {}
            # lanes that do not run it can hold anything, NaN too (the GPU samples NaN somewhere)
            u = np.nan_to_num(w.read(src[0], 0, 'f').astype(np.float64), nan=0.0, posinf=1e6, neginf=-1e6)
            v = np.nan_to_num(w.read(src[1], 0, 'f').astype(np.float64), nan=0.0, posinf=1e6, neginf=-1e6)
            x = u * Wd - 0.5
            y = v * H - 0.5
            x0 = np.floor(x); y0 = np.floor(y)
            fx = np.round((x - x0) * 256) / 256; fy = np.round((y - y0) * 256) / 256
            xi0 = np.clip(x0, 0, Wd - 1).astype(int); xi1 = np.clip(x0 + 1, 0, Wd - 1).astype(int)
            yi0 = np.clip(y0, 0, H - 1).astype(int); yi1 = np.clip(y0 + 1, 0, H - 1).astype(int)
            val = ((tex[yi0, xi0] * (1 - fx)[:, None] + tex[yi0, xi1] * fx[:, None]) * (1 - fy)[:, None]
                   + (tex[yi1, xi0] * (1 - fx)[:, None] + tex[yi1, xi1] * fx[:, None]) * fy[:, None])
            for c in range(ins.wrmask):
                w.write(d, c, val[:, c].astype(F32), 'f', ex)
            return
        elif op == 'bary.f':
            loc = ins.srcs[0].imm + (k if ins.srcs[0].rpt else 0)
            w.write(d, k, w.var[loc].astype(F32), 'f', ex)
        elif op == 'flat.b':
            loc = ins.srcs[0].imm + (k if ins.srcs[0].rpt else 0)
            w.write(d, k, w.var[loc].astype(F32), 'f', ex)
        else:
            raise NotImplementedError(ins.text)


def _shift(o, c):
    n = Operand()
    for s in Operand.__slots__:
        setattr(n, s, getattr(o, s))
    n.num = o.num + c
    return n


def run_preamble(instrs, start, end, consts, ubos):
    """Run the preamble (shps .. shpe) once, one lane: it fills the const file."""
    w = Wave(4, consts, ubos, np.zeros((8, 4), F32))
    pc = start
    while pc < end:
        ins = instrs[pc]
        op = ins.op
        if op in ('shps', 'getone', 'nop', 'shpe', 'prede'):
            pc += 1
            continue
        if op == 'jump':
            pc = ins.target
            continue
        if op == 'br':
            c = w.read(ins.srcs[0], 0, 'b')
            pc = ins.target if c[0] else pc + 1
            continue
        if op.startswith('ldc'):
            m = re.fullmatch(r'ldc(?:\.u)?(?:\.offset(\d+))?\.(\d+)(\.k)?\.imm\.base(\d+)', op)
            off, n, isk, base = m.groups()
            ubo = ubos[int(base)]
            if isk:
                cnt = int(n)   # vec4s into the const file at a1.x
                src = int(ins.srcs[0].imm)
                at = w.A1 + ins.dst.num
                consts[at:at + cnt * 4] = ubo[src * 4:(src + cnt) * 4]
            else:
                vec = ins.srcs[0].imm
                comp = int(off or 0)
                for k in range(int(n)):
                    val = ubo[vec * 4 + comp + k]
                    w.write(_shift(ins.dst, k), 0, np.full(4, val, U32), 'b', np.ones(4, bool))
            pc += 1
            continue
        if op == 'stc.u32':
            dst = ins.dst.num + (w.A1 if ins.dst.kind == 'cmem_a1' else 0)
            cnt = int(ins.srcs[1].imm)
            for k in range(cnt):
                consts[dst + k] = w.read(_shift(ins.srcs[0], k), 0, 'b')[0]
            pc += 1
            continue
        if op == 'stsc.u32':
            # a store to the shared consts, another space than this shader's const file
            pc += 1
            continue
        if op == 'mova1':
            w.A1 = int(ins.srcs[0].imm)
            pc += 1
            continue
        if op.startswith(('alias', 'resinfo', 'sam', 'isam')):
            pc += 1
            continue
        execute(ins, w, np.ones(4, bool))
        pc += 1
    return consts
