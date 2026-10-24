#!/bin/bash
# Stereo correctness through Godot's real multiview path (the one OpenXR uses), no headset:
# in each eye, what our ray tracer draws must coincide with what Godot's standard renderer
# draws at the same place. Run this before handing anyone a headset build: broken stereo
# physically hurts in a headset.
#   tools/test_stereo.sh            (GODOT=path/to/godot to override the binary, OUT=dir for images)
# Exit status 0 only if every check passes.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
GODOT=${GODOT:-$ROOT/tools/.bin/Godot_v4.7.2-stable_linux.x86_64}
[ -x "$GODOT" ] || GODOT=$(command -v godot || true)
[ -x "$GODOT" ] || { echo "no Godot 4.7.2: run tools/setup.sh or set GODOT"; exit 2; }
OUT=${OUT:-/tmp/wormhole-stereo}; mkdir -p "$OUT"
CMP=$ROOT/tools/compare
cd "$ROOT/godot"
failed=0
# a fresh clone has no .godot/ yet: import once so Godot knows the project's script classes
[ -d .godot ] || "$GODOT" --headless --path . --import >/dev/null 2>&1

run() {   # a Godot test script; any script or shader error fails the suite
	local log; log=$(xvfb-run -a -s "-screen 0 1280x720x24" "$GODOT" --path . --rendering-method mobile "$@" 2>&1)
	if grep -qE "SCRIPT ERROR|SHADER ERROR" <<<"$log"; then
		grep -E "SCRIPT ERROR|SHADER ERROR" -A3 <<<"$log"; failed=1
	fi
}
verdict() {   # name, comparison command...
	local name=$1; shift
	local res; res=$("$@")
	echo "--- $name"; echo "$res" | sed 's/^/    /'
	grep -q "^PASS$" <<<"$res" || failed=1
}

for m in ray mesh; do run --resolution 960x1080 -s res://tests/desktop_sphere.gd -- "$OUT/dsk" $m; done
verdict "desktop: ray-traced ball vs Godot ball" python3 "$CMP/one_ball.py" "$OUT/dsk_ray.png" "$OUT/dsk_mesh.png"

for m in ray mesh; do run --resolution 1280x720 -s res://tests/multiview_sphere.gd -- "$OUT/sph" $m; done
verdict "Godot 'Native mobile' stereo: one ball, each eye" python3 "$CMP/one_ball.py" \
	"$OUT/sph_ray_left.png" "$OUT/sph_mesh_left.png" "$OUT/sph_ray_right.png" "$OUT/sph_mesh_right.png"

for c in 0 1; do
	for m in ray mesh; do run --resolution 640x360 -s res://tests/multiview_hmd.gd -- "$OUT/hmd$c" $m $c; done
	verdict "simulated headset, case $c: five balls, each eye" python3 "$CMP/five_balls.py" "$OUT/hmd$c"
done

for c in 0 1 2 3 4; do
	for m in ray floor domain balls both; do run --resolution 640x360 --fixed-fps 60 -s res://tests/multiview_check.gd -- "$OUT/chk$c" $m $c; done
	verdict "simulated headset, case $c: stereo check scene (green on white and red)" python3 "$CMP/check_scene.py" "$OUT/chk$c"
done

echo
if [ $failed -eq 0 ]; then echo "ALL PASS"; else echo "FAILED"; fi
exit $failed
