#!/bin/bash
# What the speed check's poses cost on the Steam Frame's GPU, by a model: Mesa's compiler for the
# Frame (tools/adreno_stats.sh) compiles each ray tracer, and tools/adreno_cost.py runs the program
# it made on waves of pixels (tools/ir3_emu.py), counting what they issue, divergent branches
# included. Its constants: tools/adreno_cost.py; a model, not a timing.
#   tools/adreno_cost.sh [--tiles N] [--check] [--toys [--hands|--held]] [--gravity 1|2] [--poses P] [--profile] [--split] [source]...
# A source is what tools/ab_shaders.sh takes (a commit, a directory, a cost check); none or
# "this": the tree's own ray tracer. --check: also checks the emulated colours against Godot's
# (lavapipe) picture on 256 random tiles a pose (under 0.2% of pixels off by more than 4/255).
# --toys: the demo's balls and cubes, after the throw and the drop, at rest (the shader with balls;
# other sources' shader with balls too, as tools/ab_shaders.sh copies it). --hands: with them both
# hands' balls where hands are at every pose; --held: and a ball held in the right one (emu_dump.gd).
# --gravity: "this" is the gravity view's ray tracer (main.set_gravity_view: 1 the floor, 2 also the
# arrows); other sources stay as they are. --poses: other poses than the speed check's, as
# "l,yaw,pitch;..." (place_on_axis); --profile: cycles per stretch of code (adreno_cost.py).
# --split: "this" with toys as the app draws it, split by the stencil: the ray tracer with toys
# where they may be seen, the plain one elsewhere (adreno_cost.py --split); other sources are
# timed over the whole view, as the speed check times them.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tools/env.sh"
TILES=150
CHECK=""
TOYS=""
GRAV=""
POSES=""
PROF=""
SPLIT=""
HELD=""
srcs=()
while [ $# -gt 0 ]; do
	case $1 in
		--tiles) TILES=$2; shift 2 ;;
		--check) CHECK=1; shift ;;
		--toys) TOYS=1; shift ;;
		--gravity) GRAV=$2; shift 2 ;;
		--poses) POSES=$2; shift 2 ;;
		--profile) PROF=--profile; shift ;;
		--split) SPLIT=1; shift ;;
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
others=()
for s in "${srcs[@]}"; do [ "$s" = this ] || others+=("$s"); done
if [ ${#others[@]} -gt 0 ]; then "$ROOT/tools/ab_shaders.sh" "${others[@]}" >/dev/null || exit 1; fi
# the speed check's poses, bench.gd's PLACES
[ -n "$POSES" ] || POSES=$(sed -n '/^const PLACES/,/^]/p' "$ROOT/godot/bench.gd" | grep -o '\[[-0-9., ]*\]' | tr -d '[] ' | paste -sd ';')
scene=$([ -n "$TOYS" ] && echo toys$HELD || echo plain)
n=0
for s in "${srcs[@]}"; do
	if [ "$s" = this ]; then sh=""; else n=$((n + 1)); sh=res://shaders/ab/$n/wormhole.gdshader; fi
	sc=$scene
	stsh=$sh
	if [ "$s" = this ] && [ -n "$TOYS" ]; then stsh=res://shaders/wormhole_balls.gdshader; fi
	if [ "$s" = this ] && [ -n "$GRAV" ]; then
		sc=$scene+gravity$GRAV
		stsh=res://shaders/$([ -n "$TOYS" ] && echo wormhole_balls_ || echo wormhole_)$([ "$GRAV" = 2 ] && echo arrows || echo gravity).gdshader
	fi
	[ -n "$TOYS" ] && [ -n "$sh" ] && sh=${sh%wormhole.gdshader}wormhole_balls.gdshader
	[ -n "$sh" ] && stsh=$sh
	log=$WORK/$n.log
	# Godot compiles the ubershader and the specialised program on two threads, and their listings
	# can come out interleaved in the log: compile again until the program parses
	for try in 1 2 3; do
		# of its two programs, the one that runs: the smaller (as adreno_cost.py picks it)
		stats=$(KEEP_LOG=$log "$ROOT/tools/adreno_stats.sh" plain ${stsh:+--shader $stsh} \
			| grep '^prog ' | sort -n -k3 | head -1)
		python3 -W ignore -c "import sys; sys.path.insert(0, '$ROOT/tools'); import adreno_cost as A; A.Shader('$log', set())" 2>/dev/null && break
		echo "$s: the compiler's log did not parse (interleaved listings?), compiling again"
	done
	echo "$s: $stats"
	# the poses' inputs (and pictures, for --check), from Godot itself
	d=$(x_display 970)
	(cd "$ROOT/godot" && XDG_DATA_HOME=$WORK/data timeout 300 xvfb-run -n $d -s "-screen 0 1280x720x24" "$GODOT" --path . \
		--resolution 128x128 -s res://tests/emu_dump.gd -- "$WORK/d$n.json" "$POSES" 90 $sc "$sh" \
		> "$WORK/dump.log" 2>&1) || { free_display $d; echo "emu_dump failed"; tail "$WORK/dump.log"; exit 1; }
	free_display $d
	[ -n "$CHECK" ] && { python3 -W ignore "$ROOT/tools/adreno_cost.py" "$log" "$WORK/d$n.json" --check --tiles 256 || echo "$s: emulated colours differ from Godot's"; }
	plog=""
	if [ -n "$SPLIT" ] && [ "$s" = this ] && [ -n "$TOYS" ]; then
		plog=$WORK/$n.plain.log
		psh=res://shaders/wormhole$([ "$GRAV" = 2 ] && echo _arrows)$([ "$GRAV" = 1 ] && echo _gravity).gdshader
		KEEP_LOG=$plog "$ROOT/tools/adreno_stats.sh" plain --shader $psh | grep '^prog ' | sort -n -k3 | head -1 | sed "s#^#$s, the plain part: #"
	fi
	python3 -W ignore "$ROOT/tools/adreno_cost.py" "$log" "$WORK/d$n.json" --tiles "$TILES" $PROF ${plog:+--split $plog} | tail -n +2 | sed "s#^#$s: #"
done
