#!/bin/bash
# What the Steam Frame's shader compiler (Mesa's ir3 in the Turnip driver, Adreno 750) makes of the
# renderer's shaders, without a headset: Godot runs tests/shots.gd on Turnip over the drm-shim
# (tools/env.sh, turnip), and ir3 prints each program's statistics. Per program:
#   instr (nops)     code size; nops are cycles the shader waits for a result
#   full regs        registers per pixel or vertex, in vec4: the fewer, the more waves
#   waves            how many waves of 64 (128) a core keeps at once (ir3's max_waves)
#   cat4             transcendental instructions (exp, log, sqrt, rcp, sin...)
#   cat5             texture-unit instructions (samples, derivatives)
# The fragment programs of more than a third of the biggest one's size: the floor's, the biggest
# (floor.gdshader; Godot compiles it twice, a generic "ubershader" first, then the one specialised
# for the scene, which runs from then on), and the generic programs of Godot's own StandardMaterial3D
# (the menu's and the gaze dot's: two inputs, texture samples, loops); the bodies' are smaller. The
# vertex programs likewise: the bodies' (body.gdshaderinc). Code size is not what runs: a pixel
# runs one way through the floor's branches.
#   tools/adreno_stats.sh [--full]      (--full: ir3's own lines too)
# KEEP_LOG=file keeps the compiler's whole log (on the Frame a file in the repository, which the host
# sees too). Needs the driver from tools/setup.sh (tools/.bin/mesa-fd). Timings are not measured:
# there is no GPU; the speed check in the headset (bench.gd) measures.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tools/env.sh"
FULL=""
[ "${1:-}" = --full ] && FULL=1
[ -z "${KEEP_LOG:-}" ] || KEEP_LOG=$(realpath -m "$KEEP_LOG")
LOG=$(mktemp)
DATA=$(mktemp -d)    # a fresh user:// each run: Godot's pipeline cache would skip the compiler
SHOTS=$(mktemp -d)
trap 'rm -rf "$LOG" "$DATA" "$SHOTS"' EXIT
turnip "$DATA" || exit 2
cd "$ROOT/godot"
import_scripts
d=$(x_display 950)
XDG_DATA_HOME=$DATA env "${TURNIP[@]}" MESA_SHADER_CACHE_DISABLE=true IR3_SHADER_DEBUG=fs,vs,nocache \
	timeout 300 xvfb-run -n $d -s "-screen 0 1280x720x24" "$GODOT" --path . \
	--resolution 320x180 -s res://tests/shots.gd -- "$SHOTS/s" > "$LOG" 2>&1
free_display $d
[ -z "${KEEP_LOG:-}" ] || cp "$LOG" "$KEEP_LOG"
if grep -qE "SCRIPT ERROR|SHADER ERROR" "$LOG"; then grep -E "SCRIPT ERROR|SHADER ERROR" -B8 -A3 "$LOG" | grep -v "MESA: info"; exit 1; fi
grep -q "Turnip Adreno" "$LOG" || { echo "Godot did not run on Turnip:"; tail -20 "$LOG"; exit 1; }
python3 - "$LOG" "$FULL" <<'EOF'
import re, sys
text = open(sys.argv[1], errors='replace').read().replace('MESA: info: ', '')
for stage in ('FRAG', 'VERT'):
    progs = {}
    for m in re.finditer(r'; %s prog (\d+/\d+): (\d+) instr, (\d+) nops.*\n.*?(\d+) half, (\d+) full, (\d+) constlen.*\n'
                         r'.*?(\d+) cat0.*?(\d+) cat4, (\d+) cat5.*\n.*?(\d+) loops\n.*?(\d+) max_waves, (\d+) double' % stage, text):
        progs[m.group(1)] = [int(v) for v in m.groups()[1:]]
    if not progs:
        sys.exit('no %s program statistics in the log' % stage)
    big = max(v[0] for v in progs.values())
    print('fragment programs (the floor, the biggest):' if stage == 'FRAG' else 'vertex programs (the bodies):')
    for p, (n, nops, half, full, constlen, cat0, cat4, cat5, loops, waves, dbl) in progs.items():
        if n < big / 3:
            continue
        print(f"  prog {p}: {n} instr ({nops} nops), {full} full regs, {waves} waves of {128 if dbl else 64}, "
              f"{cat4} cat4, {cat5} cat5, {loops} loops, constlen {constlen}")
        if sys.argv[2]:
            for line in re.findall(r'; %s prog %s: .*' % (stage, p), text):
                print('      ' + line)
EOF
