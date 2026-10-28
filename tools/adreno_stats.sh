#!/bin/bash
# What the Steam Frame's shader compiler (Mesa's ir3 in the Turnip driver, Adreno 750) makes of
# the wormhole shader, without a headset: Godot runs on Turnip over Mesa's "noop" drm-shim (no
# GPU, nothing is drawn), and ir3 prints each fragment shader's statistics. For the ray tracer:
#   instr (nops)     code size; nops are cycles the shader waits for a result
#   full regs        registers per pixel, in vec4: 48 is the most, and then only 4 waves of pixels
#                    run at once on a core; 24 gives 8, 16 gives 12, 12 or fewer 8 of 128
#   waves            how many waves of 64 (128) pixels run at once: more hide waiting better
#   cat4             transcendental instructions (exp, log, sqrt, rcp, sin...)
#   loops            loops left after unrolling
#   tools/adreno_stats.sh [scene] [--full] [--disasm FILE] [--shader res://...]   (scene: as
#   tests/perf.gd, default near; plain, near and away without movable objects, check or balls with
#   them; --shader: another ray tracer, such as res://shaders/ab/1/wormhole.gdshader)
# KEEP_LOG=file keeps the compiler's whole log (tools/adreno_cost.py reads it).
# Needs the driver from tools/setup.sh (tools/.bin/mesa-fd). Timings are not measured: there is
# no GPU, and software Vulkan's timings don't follow the Frame's.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tools/env.sh"
MESA=${MESA:-$ROOT/tools/.bin/mesa-fd}
# setup.sh puts it next to Godot: where the environment ran setup.sh from elsewhere, that is not
# this tree's tools/.bin
[ -d "$MESA" ] || MESA=$(dirname "$(readlink -f "$GODOT")")/mesa-fd
LIB=$MESA/lib/$(uname -m)-linux-gnu
[ -f "$LIB/libfreedreno_noop_drm_shim.so" ] || { echo "no Turnip build in $MESA: run tools/setup.sh"; exit 2; }
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
LOG=$(mktemp)
DATA=$(mktemp -d)    # a fresh user:// each run: Godot's pipeline cache would skip the compiler
# the driver's manifest, pointing at the library where it is now (the installed one has the build's path)
ICD=$DATA/freedreno_icd.json
printf '{"file_format_version": "1.0.1", "ICD": {"library_path": "%s", "api_version": "1.4.318"}}\n' \
	"$LIB/libvulkan_freedreno.so" > "$ICD"
cd "$ROOT/godot"
import_once
XDG_DATA_HOME=$DATA LD_PRELOAD=$LIB/libfreedreno_noop_drm_shim.so FD_GPU_ID=750 MESA_VK_WSI_DEBUG=sw \
VK_ICD_FILENAMES=$ICD \
MESA_SHADER_CACHE_DISABLE=true IR3_SHADER_DEBUG=fs,nocache \
	timeout 300 xvfb-run -a -s "-screen 0 1280x720x24" "$GODOT" --path . \
	--resolution 320x180 -s res://tests/perf.gd -- "$VARIANT" $SHADER > "$LOG" 2>&1
if grep -qE "SCRIPT ERROR|SHADER ERROR" "$LOG"; then grep -E "SCRIPT ERROR|SHADER ERROR" -B8 -A3 "$LOG" | grep -v "MESA: info"; rm -rf "$LOG" "$DATA"; exit 1; fi
grep -q "Turnip Adreno" "$LOG" || { echo "Godot did not run on Turnip:"; tail -20 "$LOG"; rm -rf "$LOG" "$DATA"; exit 1; }
# The ray tracer: the fragment programs of more than half the biggest one's size. Godot compiles
# it twice (a generic "ubershader" first, then the one specialised for the scene, which runs from
# then on); one line each, then ir3's own statistics lines with --full. A shader with more than
# 100 vec4 of constants is compiled once more as prog N/2, reading them from memory; Turnip runs
# that one only if the pipeline's stages need more than 512 vec4 in all (ours: ~200), so it is
# marked "unused".
python3 - "$LOG" "$DISASM" "$FULL" <<'EOF'
import re, sys
text = open(sys.argv[1], errors='replace').read().replace('MESA: info: ', '')
progs = {}
for m in re.finditer(r'; FRAG prog (\d+/\d+): (\d+) instr, (\d+) nops.*\n.*?(\d+) half, (\d+) full.*\n'
                     r'.*?(\d+) cat4.*\n.*?(\d+) loops\n.*?(\d+) max_waves, (\d+) double', text):
    progs[m.group(1)] = [int(v) for v in m.groups()[1:]]
big = max(v[0] for v in progs.values())
for p, (n, nops, half, full, cat4, loops, waves, dbl) in progs.items():
    if n < 0.5 * big:
        continue
    safe = '' if p.endswith('/1') else ' (the safe-constlen variant: unused)'
    print(f"prog {p}: {n} instr ({nops} nops), {full} full regs, {waves} waves of {128 if dbl else 64}, {cat4} cat4, {loops} loops{safe}")
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
[ -n "${KEEP_LOG:-}" ] && cp "$LOG" "$KEEP_LOG"
rm -rf "$LOG" "$DATA"
