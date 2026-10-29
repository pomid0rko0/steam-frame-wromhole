#!/bin/bash
# What the Steam Frame's shader compiler (Mesa's ir3 in the Turnip driver, Adreno 750) makes of
# the wormhole shader, without a headset: Godot runs on Turnip over the drm-shim (tools/env.sh,
# turnip), and ir3 prints each fragment shader's statistics. For the ray tracer:
#   instr (nops)     code size; nops are cycles the shader waits for a result
#   full regs        registers per pixel, in vec4: the fewer, the more waves
#   waves            how many waves of 64 (128) pixels a core keeps at once (ir3's max_waves for
#                    those registers): more hide waiting better
#   cat4             transcendental instructions (exp, log, sqrt, rcp, sin...)
#   loops            loops left after unrolling
#   tools/adreno_stats.sh [scene] [--full] [--disasm FILE] [--shader res://...]   (scene: one of
#   tests/perf.gd's, default near; --shader: another ray tracer, such as
#   res://shaders/ab/1/wormhole.gdshader; --disasm: the biggest program, not the one that runs: the
#   generic ubershader, or the /2 variant of a ray tracer with toys, below)
# KEEP_LOG=file keeps the compiler's whole log (tools/adreno_cost.py reads it; on the Frame a file
# in the repository, which the host sees too).
# Needs the driver from tools/setup.sh (tools/.bin/mesa-fd). Timings are not measured: there is
# no GPU, and software Vulkan's timings don't follow the Frame's.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tools/env.sh"
VARIANT=near
DISASM=""
FULL=""
SHADER=""
while [ $# -gt 0 ]; do
	case $1 in
		--disasm) DISASM=$2; shift 2 ;;
		--full) FULL=1; shift ;;
		--shader) SHADER=$2; shift 2 ;;
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
MESA_SHADER_CACHE_DISABLE=true IR3_SHADER_DEBUG=fs,nocache \
	timeout 300 xvfb-run -n $d -s "-screen 0 1280x720x24" "$GODOT" --path . \
	--resolution 320x180 -s res://tests/perf.gd -- "$VARIANT" $SHADER > "$LOG" 2>&1
free_display $d
if grep -qE "SCRIPT ERROR|SHADER ERROR" "$LOG"; then grep -E "SCRIPT ERROR|SHADER ERROR" -B8 -A3 "$LOG" | grep -v "MESA: info"; exit 1; fi
grep -q "Turnip Adreno" "$LOG" || { echo "Godot did not run on Turnip:"; tail -20 "$LOG"; exit 1; }
# The ray tracer: the fragment programs of more than half the biggest one's size. Godot compiles
# it twice (a generic "ubershader" first, then the one specialised for the scene, which runs from
# then on); one line each, then ir3's own statistics lines with --full. A shader with more than
# 100 vec4 of constants is compiled once more as prog N/2, reading them from memory; Turnip runs
# that one only if the pipeline's stages need more than 512 vec4 in all: each line gives the
# program's own (constlen).
python3 - "$LOG" "$DISASM" "$FULL" <<'EOF'
import re, sys
text = open(sys.argv[1], errors='replace').read().replace('MESA: info: ', '')
progs = {}
for m in re.finditer(r'; FRAG prog (\d+/\d+): (\d+) instr, (\d+) nops.*\n.*?(\d+) half, (\d+) full, (\d+) constlen.*\n'
                     r'.*?(\d+) cat4.*\n.*?(\d+) loops\n.*?(\d+) max_waves, (\d+) double', text):
    progs[m.group(1)] = [int(v) for v in m.groups()[1:]]
if not progs:
    sys.exit('no fragment program statistics in the log')
big = max(v[0] for v in progs.values())
for p, (n, nops, half, full, constlen, cat4, loops, waves, dbl) in progs.items():
    if n < 0.5 * big:
        continue
    safe = '' if p.endswith('/1') else ' (the safe-constlen variant: runs only past 512 vec4 in all stages)'
    print(f"prog {p}: {n} instr ({nops} nops), {full} full regs, {waves} waves of {128 if dbl else 64}, {cat4} cat4, {loops} loops, constlen {constlen}{safe}")
    if sys.argv[3]:
        for line in re.findall(r'; FRAG prog %s: .*' % p, text):
            print("    " + line)
if sys.argv[2]:
    # the disassembly of the biggest program
    p = max(progs, key=lambda k: progs[k][0])
    end = text.index('; FRAG prog %s:' % p)
    start = text.rfind('Native code for', 0, end)
    open(sys.argv[2], 'w').write(text[start:end])
EOF
code=$?
[ -z "${KEEP_LOG:-}" ] || cp "$LOG" "$KEEP_LOG"
exit $code
