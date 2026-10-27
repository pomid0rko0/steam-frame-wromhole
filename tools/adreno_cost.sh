#!/bin/bash
# What the speed check's poses cost on the Steam Frame's GPU, by a model: Mesa's compiler for the
# Frame (tools/adreno_stats.sh) compiles each ray tracer, and tools/adreno_cost.py runs the program
# it made on waves of pixels (tools/ir3_emu.py), counting what they issue, divergent branches
# included. Calibrated on the headset's speed check (README, «Что видно в шлеме»); a model, not a
# timing: compare variants with it, then measure the best in the headset (tools/ab_shaders.sh).
#   tools/adreno_cost.sh [--tiles N] [--check] [--balls] [--toys [--hands|--held]] [--gravity 1|2] [--poses P] [--profile] [source]...
# A source is what tools/ab_shaders.sh takes (a commit, a directory, a cost check); none or
# "this": the tree's own. --check: also checks that the emulated colours are Godot's (lavapipe)
# picture, pixel for pixel. --balls: the stereo check's scene (its red balls and magenta cube).
# --toys: the demo's balls and cubes, after the throw and the drop, at rest: "this" is the frame as
# the app draws it, the toys' passes and then the world's ray tracer where no toy is (adreno_cost.py
# --toys); other sources are ray tracers of the world, timed alone. --hands: with both hands' balls
# in front of the chest at every pose; --held: and a ball held in the right one (main.bench_hands,
# as the speed check's last places have them). --gravity: "this" is the gravity view's (main.
# set_gravity_view: 1 the floor, 2 also the arrows); other sources stay as they are. --poses: other
# poses than the speed check's, as "l,yaw,pitch;..." (place_on_axis); --profile: cycles per stretch
# of code (adreno_cost.py).
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
GODOT=${GODOT:-$ROOT/tools/.bin/Godot_v4.7.2-stable_linux.x86_64}
[ -x "$GODOT" ] || GODOT=$(command -v godot || true)
TILES=150
CHECK=""
BALLS=""
TOYS=""
GRAV=""
POSES=""
PROF=""
HELD=""
srcs=()
while [ $# -gt 0 ]; do
	case $1 in
		--tiles) TILES=$2; shift 2 ;;
		--check) CHECK=1; shift ;;
		--balls) BALLS=1; shift ;;
		--toys) TOYS=1; shift ;;
		--gravity) GRAV=$2; shift 2 ;;
		--poses) POSES=$2; shift 2 ;;
		--profile) PROF=--profile; shift ;;
		--held) HELD=+held; shift ;;
		--hands) HELD=+hands; shift ;;
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
[ -n "${KEEP_WORK:-}" ] && trap "cp -r $WORK/. $KEEP_WORK/; restore" EXIT
others=()
for s in "${srcs[@]}"; do [ "$s" = this ] || others+=("$s"); done
if [ ${#others[@]} -gt 0 ]; then "$ROOT/tools/ab_shaders.sh" "${others[@]}" >/dev/null || exit 1; fi
[ -n "$POSES" ] || POSES="11.6,0,0;6.2,0,0;6.2,60,0;5.0,0,0;5.0,90,0;5.0,180,0;5.0,0,-35;5.0,0,35;0,0,0;0,90,0;-5.0,180,0;-5.7,160,-5;-6.2,180,0"   # bench.gd PLACES
scene=$([ -n "$BALLS" ] && echo balls || ([ -n "$TOYS" ] && echo toys$HELD || echo plain))
# compile a shader with Mesa's compiler for the Frame, keeping its log in $1: a toys' pass's in the
# demo's scene, where it is drawn (the flat pass over its MultiMesh, as the app draws it). Godot
# compiles the ubershader and the specialised program on two threads, and their listings can come
# out interleaved in the log: again until the program parses. Prints its line.
compile() {   # log shader kind (world, flat, shell)
	local try
	for try in 1 2 3 4 5; do
		KEEP_LOG=$1 "$ROOT/tools/adreno_stats.sh" $([ "$3" = world ] && echo plain || echo toys) --shader "$2" >/dev/null
		python3 -W ignore -c "import sys; sys.path.insert(0, '$ROOT/tools'); import adreno_cost as A
sh = A.Shader('$1', set(), kind='$3'); print('prog %s: %d instr, %d full regs, waves of %d' % (sh.name, sh.ninstr, sh.regs, sh.width))" 2>/dev/null && return 0
	done
	echo "$2: the compiler's log did not parse" >&2
	return 1
}
grav=$([ "$GRAV" = 2 ] && echo _arrows)$([ "$GRAV" = 1 ] && echo _gravity)
n=0
for s in "${srcs[@]}"; do
	if [ "$s" = this ]; then sh=res://shaders/wormhole$grav.gdshader; dsh=""; else n=$((n + 1)); sh=res://shaders/ab/$n/wormhole.gdshader; dsh=$sh; fi
	sc=$scene
	[ "$s" = this ] && [ -n "$GRAV" ] && sc=$scene+gravity$GRAV
	log=$WORK/$n.log
	line=$(compile "$log" "$sh" world) || exit 1
	echo "$s: world $line"
	toys=""
	if [ "$s" = this ] && [ -n "$TOYS$BALLS" ]; then
		ta=$([ "$GRAV" = 2 ] && echo _arrows)
		for k in flat shell; do
			line=$(compile "$WORK/$n.$k.log" res://shaders/toys_$k$ta.gdshader $k) || exit 1
			echo "$s: $k toys $line"
		done
		toys="--toys $WORK/$n.flat.log $WORK/$n.shell.log"
	fi
	# the poses' inputs (and pictures, for --check), from Godot itself
	(cd "$ROOT/godot" && XDG_DATA_HOME=$WORK/data timeout 300 xvfb-run -a -s "-screen 0 1280x720x24" "$GODOT" --path . \
		--rendering-method mobile --resolution 128x128 -s res://tests/emu_dump.gd -- "$WORK/d$n.json" "$POSES" 90 $sc "$dsh" \
		> "$WORK/dump.log" 2>&1) || { echo "emu_dump failed"; tail "$WORK/dump.log"; exit 1; }
	[ -n "$CHECK" ] && { python3 -W ignore "$ROOT/tools/adreno_cost.py" "$log" "$WORK/d$n.json" $toys --check || echo "$s: emulated colours differ from Godot's"; }
	python3 -W ignore "$ROOT/tools/adreno_cost.py" "$log" "$WORK/d$n.json" $toys --tiles "$TILES" $PROF | tail -n +2 | sed "s#^#$s: #"
done
