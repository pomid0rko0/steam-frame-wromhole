#!/bin/bash
# What the speed check's poses cost on the Steam Frame's GPU, by a model: Mesa's compiler for the
# Frame (tools/adreno_stats.sh) compiles each ray tracer, and tools/adreno_cost.py runs the program
# it made on waves of pixels (tools/ir3_emu.py), counting what they issue, divergent branches
# included. Calibrated on the headset's speed check (README, «Что видно в шлеме»); a model, not a
# timing: compare variants with it, then measure the best in the headset (tools/ab_shaders.sh).
#   tools/adreno_cost.sh [--tiles N] [--check] [--balls] [source]...
# A source is what tools/ab_shaders.sh takes (a commit, a directory, a cost check); none or
# "this": the tree's own ray tracer. --check: also checks that the emulated colours are Godot's
# (lavapipe) picture, pixel for pixel. --balls: the shader with movable balls (the stereo check's).
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
GODOT=${GODOT:-$ROOT/tools/.bin/Godot_v4.7.2-stable_linux.x86_64}
[ -x "$GODOT" ] || GODOT=$(command -v godot || true)
TILES=150
CHECK=""
BALLS=""
srcs=()
while [ $# -gt 0 ]; do
	case $1 in
		--tiles) TILES=$2; shift 2 ;;
		--check) CHECK=1; shift ;;
		--balls) BALLS=1; shift ;;
		*) srcs+=("$1"); shift ;;
	esac
done
[ ${#srcs[@]} -gt 0 ] || srcs=(this)
WORK=$(mktemp -d)
AB=$ROOT/godot/shaders/ab
# tools/ab_shaders.sh's directory is the build's: keep what is there
[ -d "$AB" ] && mv "$AB" "$WORK/ab.saved"
restore() { rm -rf "$AB"; [ -d "$WORK/ab.saved" ] && mv "$WORK/ab.saved" "$AB"; "$GODOT" --headless --path "$ROOT/godot" --import >/dev/null 2>&1; rm -rf "$WORK"; }
trap restore EXIT
others=()
for s in "${srcs[@]}"; do [ "$s" = this ] || others+=("$s"); done
if [ ${#others[@]} -gt 0 ]; then "$ROOT/tools/ab_shaders.sh" "${others[@]}" >/dev/null || exit 1; fi
POSES="11.6,0,0;6.2,0,0;6.2,60,0;5.0,0,0;5.0,90,0;5.0,180,0;5.0,0,-35;5.0,0,35;0,0,0"
scene=$([ -n "$BALLS" ] && echo balls || echo plain)
n=0
for s in "${srcs[@]}"; do
	if [ "$s" = this ]; then sh=""; else n=$((n + 1)); sh=res://shaders/ab/$n/wormhole.gdshader; fi
	[ -n "$BALLS" ] && [ -n "$sh" ] && sh=${sh%wormhole.gdshader}wormhole_balls.gdshader
	log=$WORK/$n.log
	KEEP_LOG=$log "$ROOT/tools/adreno_stats.sh" $( [ -n "$BALLS" ] && echo check || echo plain ) ${sh:+--shader $sh} | head -1 | sed "s#^#$s: #"
	# the poses' inputs (and pictures, for --check), from Godot itself
	(cd "$ROOT/godot" && XDG_DATA_HOME=$WORK/data timeout 300 xvfb-run -a -s "-screen 0 1280x720x24" "$GODOT" --path . \
		--rendering-method mobile --resolution 128x128 -s res://tests/emu_dump.gd -- "$WORK/d$n.json" "$POSES" 90 $scene "$sh" \
		> "$WORK/dump.log" 2>&1) || { echo "emu_dump failed"; tail "$WORK/dump.log"; exit 1; }
	[ -n "$CHECK" ] && { python3 -W ignore "$ROOT/tools/adreno_cost.py" "$log" "$WORK/d$n.json" --check --tiles 256 || echo "$s: emulated colours differ from Godot's"; }
	python3 -W ignore "$ROOT/tools/adreno_cost.py" "$log" "$WORK/d$n.json" --tiles "$TILES" | tail -n +2 | sed "s#^#$s: #"
done
