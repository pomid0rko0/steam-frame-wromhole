#!/bin/bash
# main through the real OpenXR path, no headset: Monado's simulated headset with its null
# compositor (one refresh rate, 20 Hz, 128x128 per eye), then tests/openxr_smoke.gd.
#   tools/test_openxr.sh            (GODOT=path/to/godot to override the binary)
# Monado's socket goes into XDG_RUNTIME_DIR, here a directory of this run's own (also its logs,
# printed on failure): any Godot that finds the socket takes Monado as its headset, so other runs'
# Godots must not find it; its Godot's user data is there too. Run it alone: beside other runs its
# frames miss the 20 Hz display's refreshes under the load, and the check that frames keep up fails.
# Exit status 0 only if the smoke test passes and no script error was printed.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tools/env.sh"
[ -x "$GODOT" ] || { echo "no Godot 4.7.2: run tools/setup.sh or set GODOT"; exit 2; }
command -v monado-service >/dev/null || { echo "no monado-service: run tools/setup.sh"; exit 2; }
cd "$ROOT/godot"
import_scripts

run=$(mktemp -d "$OUTS/openxr.XXXXXX")
export XRT_COMPOSITOR_NULL=1 SIMULATED_ENABLE=1 XDG_RUNTIME_DIR=$run
# monado-service epolls its stdin and quits at once if stdin is /dev/null or a file: give it a
# FIFO whose write end this shell holds (fd 3) until it exits
fifo=$run/monado-stdin; mkfifo "$fifo"
monado-service <"$fifo" >"$run/monado-service.log" 2>&1 &
monado=$!
exec 3>"$fifo"
rm -f "$fifo"
trap 'kill $monado 2>/dev/null' EXIT
for i in $(seq 40); do [ -S "$run/monado_comp_ipc" ] && break; sleep 0.5; done
[ -S "$run/monado_comp_ipc" ] || { echo "monado-service did not start:"; tail -5 "$run/monado-service.log"; exit 2; }
sleep 2

log=$(XDG_DATA_HOME=$run/data timeout 600 xvfb-run -a -s "-screen 0 1280x720x24" "$GODOT" --path . \
	-s res://tests/openxr_smoke.gd 2>&1)
code=$?
kill $monado 2>/dev/null
echo "$log" > "$run/godot.log"
grep -E "^(in_xr|runtime|measured|menu|refresh|bench|PASS |FAIL )" <<<"$log"
failed=0
if grep -qE "SCRIPT ERROR|SHADER ERROR" <<<"$log"; then grep -E "SCRIPT ERROR|SHADER ERROR" -A3 <<<"$log"; failed=1; fi
grep -q "^FAILURES: 0$" <<<"$log" || failed=1
# a crash on the way out (a lambda connected to the OpenXR interface causes one)
[ $code -eq 0 ] || { echo "Godot exited with $code"; tail -3 <<<"$log"; failed=1; }
if [ $failed -eq 0 ]; then echo "PASS"; else echo "FAILED (logs: $run)"; fi
exit $failed
