#!/bin/bash
# What the Steam Frame's shader compiler (Mesa's ir3 in the Turnip driver, Adreno 750) makes of the
# shaders, without a headset: Godot runs on Turnip over the drm-shim (tools/env.sh, turnip), and
# ir3 prints each vertex and fragment program's statistics. A line per program of more than MIN
# instructions (below); Godot compiles a generic "ubershader" first, then one specialised for the
# scene, which runs from then on. The floor and sky's fragment program (sky_floor.gdshader) is the
# biggest fragment one, the bodies' vertex program (body.gdshader) the biggest vertex one.
#   instr (nops)     code size; nops are cycles the shader waits for a result
#   full regs        registers per pixel or vertex, in vec4: the fewer, the more waves
#   waves            how many waves of 64 (128) a core keeps at once (ir3's max_waves for those
#                    registers): more hide waiting better
#   cat4             transcendental instructions (exp, log, sqrt, rcp, sin...)
#   loops            loops left after unrolling
#   tools/adreno_stats.sh [scene] [--full] [--disasm FILE]   (scene: one of tests/perf.gd's,
#   default cube; --disasm: the biggest fragment program)
# KEEP_LOG=file keeps the compiler's whole log (tools/ir3_live.py reads it; on the Frame a file in
# the repository, which the host sees too). A program's size and registers are not the frame's
# time: the speed check in the headset (bench.gd) is.
# Needs the driver from tools/setup.sh (tools/.bin/mesa-fd).
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tools/env.sh"
VARIANT=cube
DISASM=""
FULL=""
while [ $# -gt 0 ]; do
	case $1 in
		--disasm) DISASM=$2; shift 2 ;;
		--full) FULL=1; shift ;;
		*) VARIANT=$1; shift ;;
	esac
done
# files given relative to where it was called (on the Frame, from inside the repository:
# tools/box.sh), before the cd into godot/
[ -z "${KEEP_LOG:-}" ] || KEEP_LOG=$(realpath -m "$KEEP_LOG")
[ -z "$DISASM" ] || DISASM=$(realpath -m "$DISASM")
LOG=$(mktemp)
DATA=$(mktemp -d)    # a fresh user:// each run: Godot's pipeline cache would skip the compiler
trap 'rm -rf "$LOG" "$DATA"' EXIT
turnip "$DATA" || exit 2
cd "$ROOT/godot"
import_scripts
d=$(x_display 950)
XDG_DATA_HOME=$DATA env "${TURNIP[@]}" \
MESA_SHADER_CACHE_DISABLE=true IR3_SHADER_DEBUG=vs,fs,nocache \
	timeout 300 xvfb-run -n $d -s "-screen 0 1280x720x24" "$GODOT" --path . \
	--resolution 320x180 -s res://tests/perf.gd -- "$VARIANT" > "$LOG" 2>&1
free_display $d
if grep -qE "SCRIPT ERROR|SHADER ERROR" "$LOG"; then grep -E "SCRIPT ERROR|SHADER ERROR" -B8 -A3 "$LOG" | grep -v "MESA: info"; exit 1; fi
grep -q "Turnip Adreno" "$LOG" || { echo "Godot did not run on Turnip:"; tail -20 "$LOG"; exit 1; }
# A shader with more than 100 vec4 of constants is compiled once more as prog N/2, reading them
# from memory; Turnip runs that one only if the pipeline's stages need more than 512 vec4 in all
# (Mesa's ir3_compiler.c, max_const_safe and max_const_pipeline): each line gives its own constlen.
python3 - "$LOG" "$DISASM" "$FULL" <<'PY'
import re, sys
MIN = 400
text = open(sys.argv[1], errors='replace').read().replace('MESA: info: ', '')
progs = {}
for m in re.finditer(r'; (VERT|FRAG) prog (\d+/\d+): (\d+) instr, (\d+) nops.*\n.*?(\d+) half, (\d+) full, (\d+) constlen.*\n'
                     r'.*?(\d+) cat4.*\n.*?(\d+) loops\n.*?(\d+) max_waves, (\d+) double', text):
    progs[(m.group(1), m.group(2))] = [int(v) for v in m.groups()[2:]]
if not progs:
    sys.exit('no program statistics in the log')
for (st, p), (n, nops, half, full, constlen, cat4, loops, waves, dbl) in sorted(progs.items(), key=lambda kv: (kv[0][0], -kv[1][0])):
    if n < MIN:
        continue
    print(f"{'vertex' if st == 'VERT' else 'fragment'} prog {p}: {n} instr ({nops} nops), {full} full regs, "
          f"{waves} waves of {128 if dbl else 64}, {cat4} cat4, {loops} loops, constlen {constlen}")
    if sys.argv[3]:
        for line in re.findall(r'; %s prog %s: .*' % (st, p), text):
            print("    " + line)
if sys.argv[2]:
    p = max((k for k in progs if k[0] == 'FRAG'), key=lambda k: progs[k][0])[1]
    end = text.index('; FRAG prog %s:' % p)
    start = text.rfind('Native code for', 0, end)
    open(sys.argv[2], 'w').write(text[start:end])
PY
code=$?
[ -z "${KEEP_LOG:-}" ] || cp "$LOG" "$KEEP_LOG"
exit $code
