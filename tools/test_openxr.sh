#!/bin/bash
# main through the real OpenXR path, no headset: Monado's simulated headset with its null
# compositor (one refresh rate, 20 Hz, 128x128 per eye), then tests/openxr_smoke.gd.
#   tools/test_openxr.sh            (GODOT=path/to/godot to override the binary)
# Exit status 0 only if the smoke test passes and no script error was printed.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
GODOT=${GODOT:-$ROOT/tools/.bin/Godot_v4.7.2-stable_linux.x86_64}
[ -x "$GODOT" ] || GODOT=$(command -v godot || true)
[ -x "$GODOT" ] || { echo "no Godot 4.7.2: run tools/setup.sh or set GODOT"; exit 2; }
command -v monado-service >/dev/null || { echo "no monado-service: apt install monado-service"; exit 2; }
cd "$ROOT/godot"
[ -d .godot ] || "$GODOT" --headless --path . --import >/dev/null 2>&1

export XRT_COMPOSITOR_NULL=1 SIMULATED_ENABLE=1
pkill -x monado-service 2>/dev/null; sleep 0.5
rm -f /tmp/monado_comp_ipc
# monado-service epolls its stdin and quits at once if stdin is /dev/null or a file: give it a
# FIFO whose write end this shell holds (fd 3) until it exits
fifo=$(mktemp -u /tmp/monado-stdin.XXXXXX); mkfifo "$fifo"
monado-service <"$fifo" >/tmp/monado-service.log 2>&1 &
monado=$!
exec 3>"$fifo"
rm -f "$fifo"
trap 'kill $monado 2>/dev/null' EXIT
for i in $(seq 40); do [ -S /tmp/monado_comp_ipc ] && break; sleep 0.5; done
[ -S /tmp/monado_comp_ipc ] || { echo "monado-service did not start:"; tail -5 /tmp/monado-service.log; exit 2; }
sleep 2

log=$(timeout 600 xvfb-run -a -s "-screen 0 1280x720x24" "$GODOT" --path . --rendering-method mobile \
	-s res://tests/openxr_smoke.gd 2>&1)
code=$?
kill $monado 2>/dev/null
echo "$log" > /tmp/wormhole-openxr.log
grep -E "^(in_xr|runtime|measured|panel|refresh|window|bench)| (ok|WRONG)$" <<<"$log"
failed=0
if grep -qE "SCRIPT ERROR|SHADER ERROR" <<<"$log"; then grep -E "SCRIPT ERROR|SHADER ERROR" -A3 <<<"$log"; failed=1; fi
grep -q "^PASS$" <<<"$log" || failed=1
# a crash on the way out (it happened once: a lambda connected to the OpenXR interface)
[ $code -eq 0 ] || { echo "Godot exited with $code (full log: /tmp/wormhole-openxr.log)"; tail -3 <<<"$log"; failed=1; }
if [ $failed -eq 0 ]; then echo "PASS"; else echo "FAILED"; fi
exit $failed
