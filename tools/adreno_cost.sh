#!/bin/bash
# What the speed check's poses cost on the Steam Frame's GPU, by a model: Mesa's compiler for the
# Frame (tools/adreno_stats.sh) compiles each ray tracer, and tools/adreno_cost.py runs the program
# it made on waves of pixels (tools/ir3_emu.py), counting what they issue, divergent branches
# included (what the model is: tools/adreno_cost.py).
#   tools/adreno_cost.sh [--tiles N] [--check] [--toys [--hands|--held|--cube] [--split]] [--gravity 1|2]
#                        [--poses P] [--profile] [source]...
# A source is what tools/ab_shaders.sh takes (a commit, a directory, a cost check); none or
# "this": the tree's own ray tracer. --check: also checks the emulated colours against Godot's
# (lavapipe) picture on 256 random tiles a pose (the bound: tools/adreno_cost.py, --check).
# --toys: tests/emu_dump.gd's scene toys, with --hands, --held or --cube its toys+hands, toys+held
# or toys+cube (a cube held at the eyes, the worst case) (the
# shader with balls, of every source: one without it stops the run).
# --gravity: "this" is the gravity view's ray tracer (main.set_gravity_view: 1 the floor, 2 also the
# arrows); other sources stay as they are. --poses: other poses than the speed check's, as
# "l,yaw,pitch;..." (place_on_axis); --profile: cycles per stretch of code (adreno_cost.py).
# --split: "this" with toys as the app draws it, split by the stencil: the ray tracer with toys
# where they may be seen, the plain one elsewhere, and the mark's own pass (adreno_cost.py --split,
# --mark); other sources are
# costed over the whole view, as the speed check times them.
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
		--cube) HELD=+cube; shift ;;
		*) srcs+=("$1"); shift ;;
	esac
done
[ ${#srcs[@]} -gt 0 ] || srcs=(this)
[ -z "$HELD$SPLIT" ] || [ -n "$TOYS" ] || { echo "--hands, --held, --cube and --split go with --toys"; exit 2; }
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
[ -n "$POSES" ] || POSES=$(sed -n '/^const PLACES/,/^]/p' "$ROOT/godot/bench.gd" | grep -o '\[[-0-9.START, ]*\]' | tr -d '[] ' | paste -sd ';')
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
	if [ -n "$sh" ] && [ ! -f "$ROOT/godot/${sh#res://}" ]; then
		echo "$s: no ray tracer with balls (--toys needs one; a cost check has none)"; exit 1
	fi
	[ -n "$sh" ] && stsh=$sh
	log=$WORK/$n.log
	# compiled up to three times, until adreno_cost.py can parse the log (listings can come out
	# interleaved)
	parsed=""
	for try in 1 2 3; do
		out=$(KEEP_LOG=$log "$ROOT/tools/adreno_stats.sh" plain ${stsh:+--shader $stsh} 2>&1)
		# of its two programs, the one that runs: the smaller /1 (as adreno_cost.py picks it)
		stats=$(grep '^prog [0-9]*/1' <<<"$out" | sort -n -k3 | head -1)
		python3 -W ignore -c "import sys; sys.path.insert(0, '$ROOT/tools'); import adreno_cost as A; A.Shader('$log', A.shader_defines('${stsh:-res://shaders/wormhole.gdshader}'))" 2>/dev/null && { parsed=1; break; }
		[ $try = 3 ] || echo "$s: the compiler's log did not parse, compiling again"
	done
	[ -n "$parsed" ] || { echo "$s: the compiler's log did not parse three times:"; tail -5 <<<"$out"; exit 1; }
	echo "$s: $stats"
	# the poses' inputs (and pictures, for --check), from Godot itself
	d=$(x_display 970)
	(cd "$ROOT/godot" && XDG_DATA_HOME=$WORK/data timeout 300 xvfb-run -n $d -s "-screen 0 1280x720x24" "$GODOT" --path . \
		--resolution 128x128 -s res://tests/emu_dump.gd -- "$WORK/d$n.json" "$POSES" 90 $sc "$sh" \
		> "$WORK/dump.log" 2>&1) || { free_display $d; echo "emu_dump failed"; tail "$WORK/dump.log"; exit 1; }
	free_display $d
	[ -n "$CHECK" ] && { python3 -W ignore "$ROOT/tools/adreno_cost.py" "$log" "$WORK/d$n.json" --check --tiles 256 || echo "$s: emulated colours differ from Godot's"; }
	plog=""
	mlog=""
	if [ -n "$SPLIT" ] && [ "$s" = this ] && [ -n "$TOYS" ]; then
		plog=$WORK/$n.plain.log
		psh=res://shaders/wormhole$([ "$GRAV" = 2 ] && echo _arrows)$([ "$GRAV" = 1 ] && echo _gravity).gdshader
		KEEP_LOG=$plog "$ROOT/tools/adreno_stats.sh" plain --shader $psh | grep '^prog [0-9]*/1' | sort -n -k3 | head -1 | sed "s#^#$s, the plain part: #"
		mlog=$WORK/$n.mark.log
		KEEP_LOG=$mlog "$ROOT/tools/adreno_stats.sh" plain --shader res://shaders/stencil_mark.gdshader | grep '^prog [0-9]*/1' | sort -n -k3 | head -1 | sed "s#^#$s, the mark: #"
	fi
	python3 -W ignore "$ROOT/tools/adreno_cost.py" "$log" "$WORK/d$n.json" --tiles "$TILES" --size "$HEADSET_EYE" $PROF ${plog:+--split $plog --mark $mlog} | tail -n +2 | sed "s#^#$s: #"
done
