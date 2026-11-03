#!/bin/bash
# Stereo correctness through Godot's real multiview path (the one OpenXR uses), no headset:
# in each eye, what the app's renderer draws must coincide with what Godot's standard renderer
# draws at the same place, in the flat universe; in the curved zone, where Godot has nothing to
# compare with, with rays traced independently (tools/compare/curved.py). Run it on every headset
# build's source (CLAUDE.md, the hard rule).
#   tools/test_stereo.sh            (GODOT=path/to/godot to override the binary, OUT=dir for images:
#                                    default a new one under .wt/.out each run, printed at the end;
#                                    JOBS=n renders at once; UNITS="..." only those of the suite's
#                                    parts, ALL_UNITS below; PART=n the parts of tools/stereo_parts.txt's
#                                    line n, CI's share of them among its machines)
# Exit status 0 only if every check passes.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tools/env.sh"
[ -x "$GODOT" ] || { echo "no Godot: run tools/setup.sh or set GODOT"; exit 2; }
OUT=${OUT:-$(mktemp -d "$OUTS/stereo.XXXXXX")}; mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd)
rm -f "$OUT"/*.png      # a render that fails must not leave the last run's picture to be judged
CMP=$ROOT/tools/compare
cd "$ROOT/godot"
failed=0
import_scripts

# The renders are independent Godot runs: they go in parallel, JOBS at a time (default: one per
# core; on the Frame tools/box.sh sets it), each with its own X display and its own user data
# (Godot's shader cache), then the comparisons run in order. A render that does not exit 0 within
# LIMIT seconds fails the suite; one that hangs in Godot's own exit after its verdict ends with that
# verdict (env.sh's godot_x).
JOBS=${JOBS:-$(nproc)}
# the suite's parts, each its renders with their verdicts: Godot's own ball (desktop), the headset's
# balls, cubes and beams (headset), each place where light is bent (crvN; crfN with foveation), each
# case of the stereo check scene with its floor lines and foveation (checkN), each case of the
# gravity view (gravityN)
ALL_UNITS="desktop headset crv0 crv1 crv2 crv3 crv4 crv5 crv6 crv7 crv8 crf0 crf6 check0 check1 check2
check3 check4 check5 gravity0 gravity1 gravity2 gravity3"
if [ -n "${PART:-}" ]; then
	# CI's share: every part on exactly one of its lines, or a part would go unchecked
	parts=$(grep -v '^#' "$ROOT/tools/stereo_parts.txt")
	[ "$(echo $parts | tr ' ' '\n' | sort)" = "$(echo $ALL_UNITS | tr ' ' '\n' | sort)" ] \
		|| { echo "tools/stereo_parts.txt does not hold every part exactly once: $(echo $ALL_UNITS)"; exit 2; }
	UNITS=$(sed -n "${PART}p" <<<"$parts")
	[ -n "$UNITS" ] || { echo "no line $PART in tools/stereo_parts.txt"; exit 2; }
	echo "part $PART: $UNITS"
fi
UNITS=$(echo ${UNITS:-$ALL_UNITS})
for u in $UNITS; do
	[[ " $(echo $ALL_UNITS) " == *" $u "* ]] || { echo "no part $u: $(echo $ALL_UNITS)"; exit 2; }
done
want() { [[ " $UNITS " == *" $1 "* ]]; }
LIMIT=600
LOGS=$(mktemp -d)
trap 'rm -rf "$LOGS"' EXIT
n=0
render() {   # a Godot test script, in the background; with TRACE=name its rays traced after it
	n=$((n + 1))
	while [ "$(jobs -rp | wc -l)" -ge "$JOBS" ]; do wait -n; done
	local i=$n trace=${TRACE:-}
	mkdir -p "$LOGS/data$i"
	local d
	d=$(x_display 90)   # its own X display
	( export XDG_DATA_HOME=$LOGS/data$i
	  godot_x $d "$LOGS/$i.log" $LIMIT --path . "$@"
	  echo "$? $*" > "$LOGS/$i.status"
	  free_display $d
	  [ -z "$trace" ] || {
		# each eye in a process of its own, then their lines and one verdict
		for eye in left right; do python3 "$CMP/curved.py" "$OUT/$trace" $eye > "$LOGS/$trace.$eye" 2>&1 & done
		wait
		grep -vhxE "PASS|FAIL" "$LOGS/$trace.left" "$LOGS/$trace.right"
		grep -qx PASS "$LOGS/$trace.left" && grep -qx PASS "$LOGS/$trace.right" && echo PASS || echo FAIL
	  } > "$LOGS/$trace.cmp" 2>&1 ) &
}
verdict() {   # name, comparison command...
	local name=$1; shift
	local res; res=$("$@")
	echo "--- $name"; echo "$res" | sed 's/^/    /'
	grep -q "^PASS$" <<<"$res" || failed=1
}

# where light is bent: at the start looking up at the lifted throat, level with it, at the curved
# zone's edge, in A's fillet, in the throat along it and sideways, out in B looking back, far off as
# a control, under the mouth looking up (curved_check.gd's PLACES); first, as their rays, traced
# after each (tools/compare/curved.py, each eye on a core of its own), take minutes a place (more in
# the throat, where they go round it), beside the other renders
for p in 0 1 2 3 4 5 6 7 8; do want crv$p && TRACE=crv$p render -s res://tests/curved_check.gd -- "$OUT/crv$p" $p; done
# the same with foveation (foveation.gd), where bodies cross the edge of the zone's disc: at
# the start looking up at the mouth, out in B looking back at it
for p in 0 6; do want crf$p && TRACE=crf$p render -s res://tests/curved_check.gd -- "$OUT/crf$p" $p fov; done
if want desktop; then
	for m in app mesh; do render --resolution 960x1080 -s res://tests/desktop_sphere.gd -- "$OUT/dsk" $m; done
	for m in app mesh; do render --resolution 1280x720 -s res://tests/multiview_sphere.gd -- "$OUT/sph" $m; done
fi
# balls and turned cubes (the toys' kinds; multiview_hmd.gd's PLACES), and the hands' beams, drawn
# by the app against Godot's own where light goes straight (lens: the rest, left out)
for c in 0 1; do
	want headset || break
	for m in app mesh lens; do
		render --resolution 640x360 -s res://tests/multiview_hmd.gd -- "$OUT/hmd$c" $m $c balls
		render --resolution 640x360 -s res://tests/multiview_hmd.gd -- "$OUT/cub$c" $m $c cubes
		render --resolution 640x360 -s res://tests/multiview_hmd.gd -- "$OUT/bea$c" $m $c beams
	done
done
# the stereo check scene, also flying (cases 4 and 5)
for c in 0 1 2 3 4 5; do
	want check$c || continue
	for m in app lens floor domain balls cube both; do render --resolution 640x360 --fixed-fps 60 -s res://tests/multiview_check.gd -- "$OUT/chk$c" $m $c; done
done
# the same floor lines without the balls and the cube
for c in 0 1 2 3 4 5; do
	want check$c || continue
	for m in app floor domain; do render --resolution 640x360 --fixed-fps 60 -s res://tests/multiview_check.gd -- "$OUT/pln$c" $m $c plain; done
done
# the gravity view (main.set_gravity_view): the floor coloured by gravity, then also the arrows;
# with the balls and the cube, and without them (plain)
for v in gravity arrows; do
	for c in 0 1 2 3; do
		want gravity$c || continue
		for m in app lens floor domain balls cube; do render --resolution 640x360 --fixed-fps 60 -s res://tests/multiview_check.gd -- "$OUT/${v:0:3}$c" $m $c $v; done
		for m in app floor domain; do render --resolution 640x360 --fixed-fps 60 -s res://tests/multiview_check.gd -- "$OUT/${v:0:2}p$c" $m $c $v plain; done
	done
done
# foveated rendering on (foveation.gd: the floor coarser away from where the eyes look, the bodies
# as ever), each case at its level, in case 1 with the eyes tracked looking off the middle
# (multiview_check.gd's FOV_LEVELS, FOV_GAZE); case 1 also with the coarse texels tinted, to look at
for c in 0 1 2 3; do
	want check$c || continue
	for m in app floor domain balls cube both; do render --resolution 640x360 --fixed-fps 60 -s res://tests/multiview_check.gd -- "$OUT/fov$c" $m $c fov; done
done
want check1 && render --resolution 640x360 --fixed-fps 60 -s res://tests/multiview_check.gd -- "$OUT/fov1" zones 1 fov
for c in 0 1 2 3; do
	want check$c || continue
	for m in app floor domain probe; do render --resolution 640x360 --fixed-fps 60 -s res://tests/multiview_check.gd -- "$OUT/fpl$c" $m $c plain fov; done
done
wait
# any script or shader error, or a render that did not exit 0, fails the suite
if cat "$LOGS"/*.log | grep -qE "SCRIPT ERROR|SHADER ERROR"; then
	cat "$LOGS"/*.log | grep -E "SCRIPT ERROR|SHADER ERROR" -A3; failed=1
fi
for f in "$LOGS"/*.status; do
	read -r code args < "$f"
	[ "$code" = 0 ] || { echo "render exit status $code: $args"; tail -3 "${f%.status}.log"; failed=1; }
	grep -q "^godot_x: still in Godot's exit" "${f%.status}.log" && echo "render hung in Godot's exit after its verdict, killed: $args"
done

if want desktop; then
	verdict "desktop: the app's ball vs Godot's" python3 "$CMP/one_ball.py" "$OUT/dsk_app.png" "$OUT/dsk_mesh.png"
	verdict "Godot 'Native mobile' stereo: one ball, each eye" python3 "$CMP/one_ball.py" \
		"$OUT/sph_app_left.png" "$OUT/sph_mesh_left.png" "$OUT/sph_app_right.png" "$OUT/sph_mesh_right.png"
fi
for c in 0 1; do
	want headset || break
	verdict "simulated headset, case $c: balls, each eye" python3 "$CMP/silhouettes.py" "$OUT/hmd$c"
	verdict "simulated headset, case $c: turned cubes, each eye" python3 "$CMP/silhouettes.py" "$OUT/cub$c"
	verdict "simulated headset, case $c: the hands' beams, each eye" python3 "$CMP/silhouettes.py" "$OUT/bea$c" 2
done
for p in 0 1 2 3 4 5 6 7 8; do
	want crv$p || continue
	verdict "simulated headset, place $p where light is bent: balls, cubes and the floor against traced rays, every image, each eye" cat "$LOGS/crv$p.cmp"
done
for p in 0 6; do
	want crf$p || continue
	verdict "simulated headset, place $p where light is bent, our own foveation: the same" cat "$LOGS/crf$p.cmp"
done
for c in 0 1 2 3 4 5; do
	want check$c || continue
	verdict "simulated headset, case $c: stereo check scene (green on white, red and magenta)" python3 "$CMP/check_scene.py" "$OUT/chk$c"
done
for c in 0 1 2 3 4 5; do
	want check$c || continue
	verdict "simulated headset, case $c: floor lines, without the balls" python3 "$CMP/check_scene.py" "$OUT/pln$c" --floor-only
done
for c in 0 1 2 3; do
	want gravity$c || continue
	verdict "simulated headset, case $c: gravity view: the floor, with the balls and the cube" python3 "$CMP/check_scene.py" "$OUT/gra$c"
done
for c in 0 1 2 3; do
	want gravity$c || continue
	verdict "simulated headset, case $c: gravity view: the arrows, with the balls and the cube" python3 "$CMP/check_scene.py" "$OUT/arr$c"
done
for c in 0 1 2 3; do
	want gravity$c || continue
	verdict "simulated headset, case $c: floor lines, gravity view: the floor, without the balls" python3 "$CMP/check_scene.py" "$OUT/grp$c" --floor-only
done
for c in 0 1 2 3; do
	want gravity$c || continue
	verdict "simulated headset, case $c: floor lines, gravity view: the arrows, without the balls" python3 "$CMP/check_scene.py" "$OUT/arp$c" --floor-only
done
for c in 0 1 2 3; do
	want check$c || continue
	verdict "simulated headset, case $c: stereo check scene, foveation on (the floor's lines in the fovea)" python3 "$CMP/check_scene.py" "$OUT/fov$c" --fovea
done
for c in 0 1 2 3; do
	want check$c || continue
	verdict "simulated headset, case $c: floor lines in the fovea, without the balls, foveation on" python3 "$CMP/check_scene.py" "$OUT/fpl$c" --floor-only --fovea
done
# foveation moves nothing: where the eyes look the picture is the same as without it, and away
# from there, where the floor is softer, every pixel takes the colour worked out at its place (the
# probe), so the checks above in the fovea hold all over
pairs=""
for c in 0 1 2 3; do want check$c && pairs="$pairs chk$c:fov$c"; done
for c in 0 1 2 3; do want check$c && pairs="$pairs pln$c:fpl$c"; done
[ -z "$pairs" ] || verdict "foveation: the fovea as without it, and every pixel of the floor from its own place, each eye" python3 "$CMP/fovea.py" "$OUT" $pairs

echo
echo "images: $OUT"
if [ $failed -eq 0 ]; then echo "ALL PASS"; else echo "FAILED"; fi
exit $failed
