#!/usr/bin/env python3
"""Where a shader's registers go: live register components at every instruction of the program
Mesa's compiler made for the Frame (tools/adreno_stats.sh's log, KEEP_LOG=...).

The compiler reserves a shader's registers for its heaviest point, whatever the other pixels run
(CLAUDE.md, «Registers are taken by code no pixel runs»), so the point with the most values alive
at once decides the waves. This finds it: backward liveness over the program's branches and loops,
on the components the register allocator assigned. The register file is shared: a half register
hrN.c is half of the full component (4N + c) / 2, so the half registers (flags, small ints) count
too, two per full component; the shared registers r48-r55 (values the same in every lane) and r63
do not. It prints the peak, the instructions around it, and the uniform loads nearby (which tell
where in the source it is).

  python3 tools/ir3_live.py LOG [--around N] [--top K]
"""
import os
import re
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'ref'))
import in_box  # noqa: F401,E402 (first: on the Frame, into tools/box.sh's container)
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ir3_emu as E  # noqa: E402
import adreno_cost as A

BRANCH = ('br', 'brao', 'braa', 'bany', 'ball', 'getone')


HALF = 256      # half components are bits HALF + 4N + c


def components(o, reps, advance):
    """The register components an operand covers over the instruction's repeats: full ones as
    4N + c, half ones as HALF + 4N + c; none for shared registers (r48-r55) and r63."""
    if o is None or o.kind != 'r':
        return []
    out = []
    for k in range(reps):
        c = o.num + (k if advance else 0)
        if o.half:
            out.append(HALF + c)
        elif c < 192:
            out.append(c)
    return out


def pressure(mask):
    """Full components taken: the full ones, and the half ones two to a full one."""
    full = mask & ((1 << HALF) - 1)
    half = mask >> HALF
    merged = set(c for c in range(HALF) if full >> c & 1) | set(h // 2 for h in range(512) if half >> h & 1)
    return len(merged)


def analyse(instrs):
    n = len(instrs)
    uses, defs, succ = [], [], []
    for i, ins in enumerate(instrs):
        reps = ins.rpt + 1
        u = 0
        for s in ins.srcs:
            for c in components(s, reps, s.rpt):
                u |= 1 << c
        d = 0
        if ins.dst is not None and ins.op not in E.NO_DST:
            width = max(ins.wrmask, 1) if ins.wrmask > 1 else reps
            for c in components(ins.dst, width, True):
                d |= 1 << c
        uses.append(u)
        defs.append(d)
        nxt = [i + 1] if i + 1 < n else []
        if ins.op == 'end':
            nxt = []
        elif ins.op == 'jump':
            nxt = [ins.target]
        elif ins.op in BRANCH and ins.target is not None:
            nxt = nxt + [ins.target]
        succ.append(nxt)
    live_in = [0] * n
    changed = True
    while changed:
        changed = False
        for i in range(n - 1, -1, -1):
            out = 0
            for j in succ[i]:
                out |= live_in[j]
            new = uses[i] | (out & ~defs[i])
            if new != live_in[i]:
                live_in[i] = new
                changed = True
    return [pressure(live_in[i] | defs[i]) for i in range(n)], live_in


def main():
    args = sys.argv[1:]
    around = 25
    top = 3
    if '--around' in args:
        around = int(args[args.index('--around') + 1])
    if '--top' in args:
        top = int(args[args.index('--top') + 1])
    lines, hdr, name, ninstr = A.ray_program(args[0])
    instrs, labels = E.parse_program(lines)
    press, live = analyse(instrs)
    peak = max(press)
    print('%s: prog %s, %d instructions, peak %d live components (%.1f registers)'
          % (os.path.basename(args[0]), name, len(instrs), peak, peak / 4.0))
    # the peaks: separate stretches of instructions at the highest pressure
    order = sorted(range(len(press)), key=lambda i: -press[i])
    shown = []
    for i in order:
        if len(shown) >= top:
            break
        if any(abs(i - j) < 2 * around for j in shown):
            continue
        shown.append(i)
        print('\n--- %d live at instruction %d' % (press[i], i))
        for j in range(max(0, i - around), min(len(instrs), i + around)):
            mark = '>' if j == i else ' '
            print('%s %5d %3d  %s' % (mark, j, press[j], instrs[j].text))


if __name__ == '__main__':
    main()
