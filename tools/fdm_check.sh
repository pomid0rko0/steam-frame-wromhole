#!/bin/bash
# Does foveated rendering reach the Steam Frame's GPU driver? Without a headset: Godot runs on
# Turnip (Mesa's driver for the Frame's Adreno 750) over Mesa's "noop" drm-shim (no GPU, nothing
# is drawn), the XR view through the simulated headset, and the driver's trace (u_trace) says
# for each render pass whether it rendered in tiles and with how many attachments. Turnip only
# applies a density map in tiles. Three runs of tests/fdm_check.gd:
#   off    the XR 3D pass as it always ran: one pass with two subpasses, which Turnip renders
#          without tiles (Godot 4.7.2's subpass dependency lacks BY_REGION, split_pass.gd)
#   split  the 3D scene in a pass of its own: in tiles
#   on     foveation: in tiles, and with one attachment more than split (the density map)
#   own    the same with our own density map (main.OWN_MAPS)
# Each eye at 1728x1728, as SteamVR gives the app on the Frame; the tiles' size is printed too
# (a density is per tile).
#   tools/fdm_check.sh           (exit 0 if "on" and "own" render the XR pass in tiles with the density map)
# Needs the driver from tools/setup.sh (tools/.bin/mesa-fd).
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
GODOT=${GODOT:-$ROOT/tools/.bin/godot}
[ -x "$GODOT" ] || GODOT=$(command -v godot || true)
MESA=${MESA:-$ROOT/tools/.bin/mesa-fd}
# setup.sh puts it next to Godot: where the environment ran setup.sh from elsewhere, that is not
# this tree's tools/.bin
[ -d "$MESA" ] || MESA=$(dirname "$(readlink -f "$GODOT")")/mesa-fd
LIB=$MESA/lib/$(uname -m)-linux-gnu
[ -f "$LIB/libfreedreno_noop_drm_shim.so" ] || { echo "no Turnip build in $MESA: run tools/setup.sh"; exit 2; }
TMP=$(mktemp -d)
printf '{"file_format_version": "1.0.1", "ICD": {"library_path": "%s", "api_version": "1.4.318"}}\n' \
	"$LIB/libvulkan_freedreno.so" > "$TMP/icd.json"
cd "$ROOT/godot"
[ -d .godot ] || "$GODOT" --headless --path . --import >/dev/null 2>&1
for m in off split on own; do
	mkdir -p "$TMP/data_$m"
	XDG_DATA_HOME=$TMP/data_$m LD_PRELOAD=$LIB/libfreedreno_noop_drm_shim.so FD_GPU_ID=750 MESA_VK_WSI_DEBUG=sw \
	VK_ICD_FILENAMES=$TMP/icd.json MESA_GPU_TRACES=print MESA_GPU_TRACEFILE=$TMP/trace_$m.txt TU_DEBUG=perf \
		timeout 300 xvfb-run -a -s "-screen 0 1280x720x24" "$GODOT" --path . --rendering-method mobile \
		--resolution 320x180 -s res://tests/fdm_check.gd -- $m 1728 > "$TMP/log_$m.txt" 2>&1
	if grep -qE "SCRIPT ERROR|SHADER ERROR" "$TMP/log_$m.txt"; then
		grep -E "SCRIPT ERROR|SHADER ERROR" -A3 "$TMP/log_$m.txt"; rm -rf "$TMP"; exit 1
	fi
	grep -q "Turnip Adreno" "$TMP/log_$m.txt" || { echo "$m: Godot did not run on Turnip:"; tail -20 "$TMP/log_$m.txt"; rm -rf "$TMP"; exit 1; }
	grep "^fdm_check:" "$TMP/log_$m.txt"
	grep "^TU: warning" "$TMP/log_$m.txt" | sort | uniq -c | sed 's/^/    driver: /'
done
python3 - "$TMP" <<'PY'
import re, sys, collections
tmp = sys.argv[1]
def passes(m):
    """The XR 3D pass's renders after the switch: (attachments, tiled, why not, tiles)."""
    out, start = [], None
    for line in open(f'{tmp}/trace_{m}.txt', errors='replace'):
        if 'start_render_pass:' in line:
            start = line
        elif 'end_render_pass:' in line and start:
            # the simulated headset's view, with depth: the 3D scene
            if 'width=1728, height=1728' in start and 'hasDepth=true' in start:
                att = int(re.search(r'attachment_count=(\d+)', start).group(1))
                tiled = 'tiledRender=true' in line
                why = re.search(r'tilingDisableReason=([^,]*)', line).group(1)
                b = re.search(r'numberOfBins=(\d+), binWidth=(\d+), binHeight=(\d+)', start).groups()
                out.append((att, tiled, why, f'{b[0]} tiles of {b[1]}x{b[2]}' if tiled else ''))
            start = None
    return out[4:]       # the frames after foveation was set
res = {m: passes(m) for m in ('off', 'split', 'on', 'own')}
for m, p in res.items():
    c = collections.Counter(p)
    print(f'{m:5s}: ' + '; '.join(f'{n}x {a} attachments, {"in " + b if t else "no tiles (" + w + ")"}' for (a, t, w, b), n in c.items()))
ok = bool(res['on']) and bool(res['split']) and bool(res['own'])
split = set(res['split'])
ok &= all(p[1] for p in split)
for m in ('on', 'own'):
    on = set(res[m])
    ok &= all(p[1] for p in on) and {p[0] for p in on} == {p[0] + 1 for p in split}
print('PASS: with foveation on (either map) the driver renders the XR pass in tiles, with the density map' if ok else 'FAIL')
sys.exit(0 if ok else 1)
PY
code=$?
rm -rf "$TMP"
exit $code
