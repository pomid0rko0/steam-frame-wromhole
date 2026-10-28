"""Does a change leave the compiled ray tracer as it was? Compares the fragment programs in two ir3
logs from tools/adreno_stats.sh (KEEP_LOG=file): every big program in the first log (the ubershader,
the specialised program and their unused "safe constlen" /2 variants) must be found, instruction
for instruction, in the second. A log holds the programs of every shader the scene compiled (with
toys also the plain one), so programs are matched by their code, not by their number or order.
   python3 tools/same_programs.py before.log after.log
Exit status 0 when all are found."""
import hashlib
import re
import sys

MIN_INSTR = 2000        # the ray tracers' programs; Godot's own shaders are far smaller


def programs(log):
    """{(program number, instructions): hash of its instructions} for the big fragment programs."""
    text = open(log, errors='replace').read().replace('MESA: info: ', '')
    out = {}
    for m in re.finditer(r'; FRAG prog (\d+/\d+): (\d+) instr', text):
        if int(m.group(2)) < MIN_INSTR:
            continue
        start = text.rfind('Native code for', 0, m.start())
        # Godot compiles in threads: another shader's "NIR (final form) for ..." header can land
        # inside a listing
        lines = [x for x in text[start:m.start()].split('\n') if not x.startswith(('NIR (', 'Native code for'))]
        code = [x for x in lines if x.strip() and not x.startswith(('@', ';', 'SIMD'))]
        out[(m.group(1), int(m.group(2)))] = hashlib.sha1('\n'.join(code).encode()).hexdigest()
    return out


before, after = programs(sys.argv[1]), programs(sys.argv[2])
found = set(after.values())
missing = 0
for (num, n), h in sorted(before.items(), key=lambda kv: kv[0][1]):
    ok = h in found
    missing += not ok
    print('%-6s %5d instr %s  %s' % (num, n, h[:12], 'same' if ok else 'NOT FOUND in the second log'))
print('SAME' if before and not missing else 'DIFFERENT')
sys.exit(0 if before and not missing else 1)
