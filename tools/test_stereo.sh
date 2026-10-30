#!/bin/bash
# Stereo correctness through Godot's real multiview path (the one OpenXR uses), no headset:
# in each eye, what our ray tracer draws must coincide with what Godot's standard renderer
# draws at the same place. Run it on every headset build's source (CLAUDE.md, the hard rule).
#   tools/test_stereo.sh            (GODOT=path/to/godot to override the binary, OUT=dir for images:
#                                    default a new one under .wt/.out each run, printed at the end;
#                                    JOBS=n renders at once)
# Exit status 0 only if every check passes.
# Below 100% render scale the bilinear upscale shifts where tools/compare's one-colour threshold
# falls: test such a scale with SCALING_3D_MODE_NEAREST.
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
# LIMIT seconds fails the suite.
JOBS=${JOBS:-$(nproc)}
LIMIT=600
LOGS=$(mktemp -d)
trap 'rm -rf "$LOGS"' EXIT
n=0
render() {   # a Godot test script, in the background
	n=$((n + 1))
	while [ "$(jobs -rp | wc -l)" -ge "$JOBS" ]; do wait -n; done
	local i=$n
	mkdir -p "$LOGS/data$i"
	local d
	d=$(x_display 90)   # its own X display
	( XDG_DATA_HOME=$LOGS/data$i timeout $LIMIT xvfb-run -n $d -s "-screen 0 1280x720x24" \
		"$GODOT" --path . "$@" > "$LOGS/$i.log" 2>&1
	  echo "$? $*" > "$LOGS/$i.status"
	  free_display $d ) &
}
verdict() {   # name, comparison command...
	local name=$1; shift
	local res; res=$("$@")
	echo "--- $name"; echo "$res" | sed 's/^/    /'
	grep -q "^PASS$" <<<"$res" || failed=1
}

for m in ray mesh; do render --resolution 960x1080 -s res://tests/desktop_sphere.gd -- "$OUT/dsk" $m; done
for m in ray mesh; do render --resolution 1280x720 -s res://tests/multiview_sphere.gd -- "$OUT/sph" $m; done
# balls and turned cubes (the toys' kinds; multiview_hmd.gd's PLACES) drawn by the ray tracer
# against Godot's own
for c in 0 1; do
	for m in ray mesh; do
		render --resolution 640x360 -s res://tests/multiview_hmd.gd -- "$OUT/hmd$c" $m $c balls
		render --resolution 640x360 -s res://tests/multiview_hmd.gd -- "$OUT/cub$c" $m $c cubes
	done
done
# the stereo check scene
for c in 0 1 2 3; do
	for m in ray floor domain balls cube both; do render --resolution 640x360 --fixed-fps 60 -s res://tests/multiview_check.gd -- "$OUT/chk$c" $m $c; done
done
# the same floor lines with the plain shader: the normal scene's where no toy can be seen
for c in 0 1 2 3; do
	for m in ray floor domain; do render --resolution 640x360 --fixed-fps 60 -s res://tests/multiview_check.gd -- "$OUT/pln$c" $m $c plain; done
done
# the gravity view (main.set_gravity_view): the floor coloured by gravity, then also the arrows;
# ray tracers of their own, with the balls and the cube, and without them (plain)
for v in gravity arrows; do
	for c in 0 1 2 3; do
		for m in ray floor domain balls cube; do render --resolution 640x360 --fixed-fps 60 -s res://tests/multiview_check.gd -- "$OUT/${v:0:3}$c" $m $c $v; done
		for m in ray floor domain; do render --resolution 640x360 --fixed-fps 60 -s res://tests/multiview_check.gd -- "$OUT/${v:0:2}p$c" $m $c $v plain; done
	done
done
# foveated rendering on (Foveation.set_level): the ray tracer's cells coarser away from the middle
# (ray_pass.gd); what Godot draws over them must still lie on them
for c in 0 1 2 3; do
	for m in ray floor domain balls cube both; do render --resolution 640x360 --fixed-fps 60 -s res://tests/multiview_check.gd -- "$OUT/fov$c" $m $c fov; done
done
for c in 0 1 2 3; do
	for m in ray floor domain; do render --resolution 640x360 --fixed-fps 60 -s res://tests/multiview_check.gd -- "$OUT/fpl$c" $m $c plain fov; done
done
# this build's toys (the search along the per-eye path tables) against main's fragment ray tracer
render --resolution 640x360 -s res://tests/toys_check.gd -- "$OUT/toys"
wait
# any script or shader error, or a render that did not exit 0, fails the suite
if cat "$LOGS"/*.log | grep -qE "SCRIPT ERROR|SHADER ERROR"; then
	cat "$LOGS"/*.log | grep -E "SCRIPT ERROR|SHADER ERROR" -A3; failed=1
fi
for f in "$LOGS"/*.status; do
	read -r code args < "$f"
	[ "$code" = 0 ] || { echo "render exit status $code: $args"; tail -3 "${f%.status}.log"; failed=1; }
done

verdict "desktop: ray-traced ball vs Godot ball" python3 "$CMP/one_ball.py" "$OUT/dsk_ray.png" "$OUT/dsk_mesh.png"
verdict "Godot 'Native mobile' stereo: one ball, each eye" python3 "$CMP/one_ball.py" \
	"$OUT/sph_ray_left.png" "$OUT/sph_mesh_left.png" "$OUT/sph_ray_right.png" "$OUT/sph_mesh_right.png"
for c in 0 1; do
	verdict "simulated headset, case $c: balls, each eye" python3 "$CMP/silhouettes.py" "$OUT/hmd$c"
	verdict "simulated headset, case $c: turned cubes, each eye" python3 "$CMP/silhouettes.py" "$OUT/cub$c"
done
for c in 0 1 2 3; do
	verdict "simulated headset, case $c: stereo check scene (green on white, red and magenta)" python3 "$CMP/check_scene.py" "$OUT/chk$c"
done
for c in 0 1 2 3; do
	verdict "simulated headset, case $c: floor lines, shader without balls" python3 "$CMP/check_scene.py" "$OUT/pln$c" --floor-only
done
for c in 0 1 2 3; do
	verdict "simulated headset, case $c: gravity view: the floor, with the balls and the cube" python3 "$CMP/check_scene.py" "$OUT/gra$c"
done
for c in 0 1 2 3; do
	verdict "simulated headset, case $c: gravity view: the arrows, with the balls and the cube" python3 "$CMP/check_scene.py" "$OUT/arr$c"
done
for c in 0 1 2 3; do
	verdict "simulated headset, case $c: floor lines, gravity view: the floor, shader without balls" python3 "$CMP/check_scene.py" "$OUT/grp$c" --floor-only
done
for c in 0 1 2 3; do
	verdict "simulated headset, case $c: floor lines, gravity view: the arrows, shader without balls" python3 "$CMP/check_scene.py" "$OUT/arp$c" --floor-only
done
for c in 0 1 2 3; do
	verdict "simulated headset, case $c: stereo check scene, foveation on" python3 "$CMP/check_scene.py" "$OUT/fov$c"
done
for c in 0 1 2 3; do
	verdict "simulated headset, case $c: floor lines, shader without balls, foveation on" python3 "$CMP/check_scene.py" "$OUT/fpl$c" --floor-only
done

verdict "simulated headset: the demo's toys and a held ball, this build against main's ray tracer" python3 "$CMP/same_toys.py" "$OUT/toys"

echo
echo "images: $OUT"
if [ $failed -eq 0 ]; then echo "ALL PASS"; else echo "FAILED"; fi
exit $failed
