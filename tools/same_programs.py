"""Does a change leave the compiled ray tracer as it was? Compares the big fragment programs in two
ir3 logs from tools/adreno_stats.sh (KEEP_LOG=file): the ubershader, the specialised program and
their unused "safe constlen" /2 variants. Programs are matched by their code, both ways: every
program of each log must be in the other, instruction for instruction.
   python3 tools/same_programs.py before.log after.log
Make the logs with a scene without toys (tools/adreno_stats.sh plain --shader res://shaders/X):
with toys, Tracer.set_objects swaps in the toys' shader and the plain one after the first frame,
and the log holds their programs too.
Exit status 0: the same programs; 1: different; 2: a log can't be compared (no programs, or another
program's listing or NIR printed into one: Godot compiles in threads; compile again)."""
import hashlib
import re
import sys

MIN_INSTR = 2000        # the ray tracers' programs; Godot's own shaders are far smaller
PREFIX = 'MESA: info: '
STATS = re.compile(r'; (\w+) prog (\d+/\d+): (\d+) instr')     # every stage's: each ends a listing
NIR = re.compile(r'%\d+ = |\bblock b\d+:|^\s*decl_|^impl |^shader: ')   # NIR, never in a listing


def programs(log):
    """{hash of the instructions: 'number, instructions'} for the big fragment programs."""
    # only the compiler's lines: anything else Godot prints can land inside a listing
    lines = [x[len(PREFIX):] for x in open(log, errors='replace').read().split('\n') if x.startswith(PREFIX)]
    out = {}
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
        if m.group(1) == 'FRAG' and int(m.group(3)) >= MIN_INSTR:
            if headers != 1:
                print('%s: program %s: %d listings interleaved before its statistics; compile again'
                      % (log, m.group(2), headers))
                sys.exit(2)
            body = [y for y in lines[start + 1:i] if not y.startswith('NIR (')]
            if any(NIR.search(y) for y in body):
                print('%s: program %s: another program\'s NIR printed into its listing; compile again'
                      % (log, m.group(2)))
                sys.exit(2)
            code = [y for y in body if y.strip() and not y.startswith(('@', ';', 'SIMD'))]
            out[hashlib.sha1('\n'.join(code).encode()).hexdigest()] = '%s, %s instr' % (m.group(2), m.group(3))
        headers = 0
    if not out:
        print('%s: no ray-tracer programs (%d instructions or more)' % (log, MIN_INSTR))
        sys.exit(2)
    return out


a, b = programs(sys.argv[1]), programs(sys.argv[2])
for h in sorted(set(a) | set(b), key=lambda h: (a.get(h) or b.get(h))):
    where = 'same' if h in a and h in b else ('only in the first' if h in a else 'only in the second')
    print('%-18s %s  %s' % (a.get(h) or b.get(h), h[:12], where))
print('SAME' if set(a) == set(b) else 'DIFFERENT')
sys.exit(0 if set(a) == set(b) else 1)
