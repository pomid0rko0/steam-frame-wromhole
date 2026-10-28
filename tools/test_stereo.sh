#!/bin/bash
# Stereo correctness through Godot's real multiview path (the one OpenXR uses), no headset:
# in each eye, what our ray tracer draws must coincide with what Godot's standard renderer
# draws at the same place. Run it on every headset build's source; it must pass before the build
# is worn: broken stereo physically hurts in a headset.
#   tools/test_stereo.sh            (GODOT=path/to/godot to override the binary, OUT=dir for images,
#                                    JOBS=n renders at once)
# Exit status 0 only if every check passes.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tools/env.sh"
[ -x "$GODOT" ] || { echo "no Godot 4.7.2: run tools/setup.sh or set GODOT"; exit 2; }
OUT=${OUT:-/tmp/wormhole-stereo}; mkdir -p "$OUT"
rm -f "$OUT"/*.png      # a render that fails must not leave the last run's picture to be judged
CMP=$ROOT/tools/compare
cd "$ROOT/godot"
failed=0
import_once

# The renders are independent Godot runs: they go in parallel, JOBS at a time (default: one per
# core), each with its own X display and its own user data (Godot's shader cache), then the
# comparisons run in order. A render that does not exit 0 within 10 minutes fails the suite.
JOBS=${JOBS:-$(nproc)}
LOGS=$(mktemp -d)
n=0
render() {   # a Godot test script, in the background
	n=$((n + 1))
	while [ "$(jobs -rp | wc -l)" -ge "$JOBS" ]; do wait -n; done
	local i=$n
	mkdir -p "$LOGS/data$i"
	# its own X display; one some other X server holds (say, a stray Xvfb) would fail this render: then 1000 further on, where no other render of this run is
	local d=$((90 + i))
	while [ -e /tmp/.X$d-lock ] || [ -e /tmp/.X11-unix/X$d ]; do d=$((d + 1000)); done
	( XDG_DATA_HOME=$LOGS/data$i timeout 600 xvfb-run -n $d -s "-screen 0 1280x720x24" \
		"$GODOT" --path . "$@" > "$LOGS/$i.log" 2>&1
	  echo "$? $*" > "$LOGS/$i.status" ) &
}
verdict() {   # name, comparison command...
	local name=$1; shift
	local res; res=$("$@")
	echo "--- $name"; echo "$res" | sed 's/^/    /'
	grep -q "^PASS$" <<<"$res" || failed=1
}

for m in ray mesh; do render --resolution 960x1080 -s res://tests/desktop_sphere.gd -- "$OUT/dsk" $m; done
for m in ray mesh; do render --resolution 1280x720 -s res://tests/multiview_sphere.gd -- "$OUT/sph" $m; done
# five balls and five turned cubes (the toys' kinds) drawn by the ray tracer against Godot's own
for c in 0 1; do
	for m in ray mesh; do
		render --resolution 640x360 -s res://tests/multiview_hmd.gd -- "$OUT/hmd$c" $m $c balls
		render --resolution 640x360 -s res://tests/multiview_hmd.gd -- "$OUT/cub$c" $m $c cubes
	done
done
# the stereo check scene; case 3 walks and turns with the sticks' keys: --fixed-fps 60, so every
# mode moves the same
for c in 0 1 2 3; do
	for m in ray floor domain balls cube both; do render --resolution 640x360 --fixed-fps 60 -s res://tests/multiview_check.gd -- "$OUT/chk$c" $m $c; done
done
# the same floor lines with the shader the normal scene runs: the one without movable balls
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
# foveated rendering on (Foveation.set_level): the 3D scene in a render pass of its own
for c in 0 1 2 3; do
	for m in ray floor domain balls cube both; do render --resolution 640x360 --fixed-fps 60 -s res://tests/multiview_check.gd -- "$OUT/fov$c" $m $c fov; done
done
for c in 0 1 2 3; do
	for m in ray floor domain; do render --resolution 640x360 --fixed-fps 60 -s res://tests/multiview_check.gd -- "$OUT/fpl$c" $m $c plain fov; done
done
wait
# any script or shader error, or a render that did not exit 0, fails the suite
if cat "$LOGS"/*.log | grep -qE "SCRIPT ERROR|SHADER ERROR"; then
	cat "$LOGS"/*.log | grep -E "SCRIPT ERROR|SHADER ERROR" -A3; failed=1
fi
for f in "$LOGS"/*.status; do
	read -r code args < "$f"
	[ "$code" = 0 ] || { echo "render exit status $code: $args"; tail -3 "${f%.status}.log"; failed=1; }
done
rm -rf "$LOGS"

verdict "desktop: ray-traced ball vs Godot ball" python3 "$CMP/one_ball.py" "$OUT/dsk_ray.png" "$OUT/dsk_mesh.png"
verdict "Godot 'Native mobile' stereo: one ball, each eye" python3 "$CMP/one_ball.py" \
	"$OUT/sph_ray_left.png" "$OUT/sph_mesh_left.png" "$OUT/sph_ray_right.png" "$OUT/sph_mesh_right.png"
for c in 0 1; do
	verdict "simulated headset, case $c: five balls, each eye" python3 "$CMP/five_balls.py" "$OUT/hmd$c"
	verdict "simulated headset, case $c: five turned cubes, each eye" python3 "$CMP/five_balls.py" "$OUT/cub$c"
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
# the split pass changes nothing in the picture: each image with foveation on against the same off
verdict "foveation on: the same pictures as off" python3 "$CMP/same_images.py" "$OUT" chk:fov pln:fpl

echo
if [ $failed -eq 0 ]; then echo "ALL PASS"; else echo "FAILED"; fi
exit $failed
