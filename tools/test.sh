#!/bin/bash
# The Godot tests, godot/tests/<name>_test.gd, each with the flags its header gives (its line
# "##   godot <flags> -s res://tests/<name>_test.gd"), JOBS at a time (default: one per core; on the
# Frame tools/box.sh sets it), each with its own X display and user data; then a line per test,
# with what failed.
#   tools/test.sh                  all of them
#   tools/test.sh grab walking_xr  those named
# Exit status 0 only if each one exits 0 with no script or shader error. Whole logs in
# $OUT/<name>.log (OUT default: a new directory under .wt/.out each run, printed at the end; env.sh
# deletes it a day later). The stereo and OpenXR tests are tools/test_stereo.sh and
# tools/test_openxr.sh.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tools/env.sh"
[ -x "$GODOT" ] || { echo "no Godot: run tools/setup.sh"; exit 2; }
cd "$ROOT/godot"
import_scripts
names=("$@")
[ ${#names[@]} -gt 0 ] || names=($(ls tests/*_test.gd | sed 's#^tests/##; s#_test\.gd$##'))
LIMIT=900    # s a test may run
# every test's flags before any starts: a name that is wrong stops the run with none left running
declare -A flags_of
for t in "${names[@]}"; do
	f=tests/${t}_test.gd
	[ -f "$f" ] || { echo "no godot/$f"; exit 2; }
	line=$(grep -m1 -E "^##\s+godot .*-s res://$f" "$f") || { echo "godot/$f: no run line in its header"; exit 2; }
	flags=${line#*godot }
	flags=${flags%%-s res://*}
	flags_of[$t]=${flags//--path . /}
done
OUT=${OUT:-$(mktemp -d "$OUTS/tests.XXXXXX")}; mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd)
JOBS=${JOBS:-$(nproc)}
DATA=$(mktemp -d)
i=0
for t in "${names[@]}"; do
	f=tests/${t}_test.gd
	flags=${flags_of[$t]}
	while [ "$(jobs -rp | wc -l)" -ge "$JOBS" ]; do wait -n; done
	i=$((i + 1))
	d=$(x_display 500)   # its own X display (xvfb-run -a races when several start at once)
	(
		start=$SECONDS
		XDG_DATA_HOME=$DATA/$t timeout $LIMIT xvfb-run -n $d -s "-screen 0 1280x720x24" \
			"$GODOT" --path . $flags -s "res://$f" > "$OUT/$t.log" 2>&1
		echo "$? $((SECONDS - start))" > "$DATA/$t.status"
		free_display $d
	) &
done
wait
failed=0
for t in "${names[@]}"; do
	read -r code secs < "$DATA/$t.status"
	errors=$(grep -E "SCRIPT ERROR|SHADER ERROR" -A3 "$OUT/$t.log")
	if [ "$code" = 0 ] && [ -z "$errors" ]; then
		echo "PASS $t (${secs} s)"
		continue
	fi
	failed=1
	case $code in
		0) echo "FAIL $t: script or shader errors (${secs} s)" ;;
		124) echo "FAIL $t: still running after $LIMIT s" ;;
		*) echo "FAIL $t: exit status $code (${secs} s)" ;;
	esac
	{ grep -E "^FAIL|^FAILURES" "$OUT/$t.log"; echo "$errors"; [ "$code" = 0 ] || tail -3 "$OUT/$t.log"; } \
		| grep -v '^$' | head -20 | sed 's/^/    /'
done
rm -rf "$DATA"
echo "logs: $OUT"
exit $failed
