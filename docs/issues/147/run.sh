#!/bin/bash
# #147's scenes on the checkout this is run in (any commit with tools/env.sh): the pictures of the
# four broken ones (seed 22: scenes 7, 25, 112; seed 33: scene 81), or of any count and seed.
#   docs/issues/147/run.sh out_dir                    the four
#   docs/issues/147/run.sh out_dir count seed [only]  scenes 0 to count - 1 of the seed (or only i,j,...)
# Apply faces.patch first (git apply docs/issues/147/faces.patch) for each face its own pure colour,
# which streaks.py reads.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../../.." && pwd)
OUT=$(mkdir -p "$1" && cd "$1" && pwd)
. "$ROOT/tools/env.sh"
cp "$HERE/repro.gd" "$ROOT/godot/tests/repro147_tmp.gd"
cd "$ROOT/godot"
import_scripts
run() {   # out_prefix count seed [only]
	local d
	d=$(x_display 160)
	XDG_DATA_HOME=$(mktemp -d) godot_x $d "$1.log" 3000 --path . -s res://tests/repro147_tmp.gd -- "$@"
	free_display $d
}
if [ $# -ge 3 ]; then
	run "$OUT/s$3" "$2" "$3" ${4:-}
else
	run "$OUT/s22" 113 22 7,25,112
	run "$OUT/s33" 82 33 81
fi
rm -f "$ROOT/godot/tests/repro147_tmp.gd" "$ROOT/godot/tests/repro147_tmp.gd.uid"
grep -h '^cube\|^conf' "$OUT"/*.log
