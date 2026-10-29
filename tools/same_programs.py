"""Does a change leave the compiled ray tracer as it was? Compares the big fragment programs in two
ir3 logs from tools/adreno_stats.sh (KEEP_LOG=file): the ubershader, the specialised program and
their "safe constlen" /2 variants (tools/adreno_stats.sh says when those run). Programs are matched
by their code, both ways: every program of each log must be in the other, instruction for
instruction.
   python3 tools/same_programs.py before.log after.log
Make the logs with a scene without toys (tools/adreno_stats.sh plain --shader res://shaders/X):
with toys, Tracer.set_objects swaps in the toys' shader and the plain one after the first frame,
and the log holds their programs too.
Exit status 0: the same programs; 1: different; 2: a log can't be compared (no programs, or another
program's listing or NIR printed into one: Godot compiles in threads; compile again)."""
import hashlib
import re
import sys

PREFIX = 'MESA: info: '
STATS = re.compile(r'; (\w+) prog (\d+/\d+): (\d+) instr')     # every stage's: each ends a listing
NIR = re.compile(r'%\d+ = |\bblock b\d+:|^\s*decl_|^impl |^shader: ')   # NIR, never in a listing


def programs(log):
    """{hash of the instructions: 'number, instructions'} for the big fragment programs: those of
    half the biggest one's size or more, as tools/adreno_stats.sh takes them."""
    # only the compiler's lines: anything else Godot prints can land inside a listing
    lines = [x[len(PREFIX):] for x in open(log, errors='replace').read().split('\n') if x.startswith(PREFIX)]
    frags = []              # (instructions, number, the listing's lines, headers before it)
    start = None            # the line of the listing's header
    headers = 0             # headers since the last statistics: one, or listings interleaved
    for i, x in enumerate(lines):
        if x.startswith('Native code for'):
            start = i
            headers += 1
            continue
        m = STATS.match(x)
        if not m:
            continue
        if m.group(1) == 'FRAG':
            frags.append((int(m.group(3)), m.group(2), lines[start + 1:i] if start is not None else [], headers))
        headers = 0
    if not frags:
        print('%s: no fragment programs' % log)
        sys.exit(2)
    big = max(f[0] for f in frags)
    out = {}
    for n, number, listing, headers in frags:
        if n < 0.5 * big:
            continue
        if headers != 1:
            print('%s: program %s: %d listings interleaved before its statistics; compile again'
                  % (log, number, headers))
            sys.exit(2)
        body = [y for y in listing if not y.startswith('NIR (')]
        if any(NIR.search(y) for y in body):
            print('%s: program %s: another program\'s NIR printed into its listing; compile again'
                  % (log, number))
            sys.exit(2)
        code = [y for y in body if y.strip() and not y.startswith(('@', ';', 'SIMD'))]
        out[hashlib.sha1('\n'.join(code).encode()).hexdigest()] = '%s, %d instr' % (number, n)
    return out


a, b = programs(sys.argv[1]), programs(sys.argv[2])
for h in sorted(set(a) | set(b), key=lambda h: (a.get(h) or b.get(h))):
    where = 'same' if h in a and h in b else ('only in the first' if h in a else 'only in the second')
    print('%-18s %s  %s' % (a.get(h) or b.get(h), h[:12], where))
print('SAME' if set(a) == set(b) else 'DIFFERENT')
sys.exit(0 if set(a) == set(b) else 1)
