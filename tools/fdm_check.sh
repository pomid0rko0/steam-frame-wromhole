#!/bin/bash
# Does foveated rendering reach the Steam Frame's GPU driver? Without a headset: Godot runs on
# Turnip over the drm-shim (tools/env.sh, turnip), the XR view through the simulated headset, and
# the driver's trace (u_trace) says for each render pass whether it rendered in tiles and with how
# many attachments (a density map applies only in tiles: split_pass.gd). Four runs of
# tests/fdm_check.gd:
#   off    the XR 3D pass without foveation: one pass with two subpasses, which Turnip renders
#          without tiles (split_pass.gd)
#   split  the 3D scene in a pass of its own: in tiles
#   on     foveation: in tiles, and with one attachment more than split (the density map)
#   own    our own foveation (floor_fov.gd): no density map, and the pass as "off" has it (its
#          compute pass before the bodies splits nothing)
# Each eye at tools/env.sh's HEADSET_EYE; the tiles' size is printed too (a density is per tile).
#   tools/fdm_check.sh           (exit 0 if "split" and "on" render the XR pass in tiles, "on" with one
#                                 attachment more than "split": the density map; and "own" as "off")
# Needs the driver from tools/setup.sh (tools/.bin/mesa-fd).
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tools/env.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
turnip "$TMP" || exit 2
cd "$ROOT/godot"
import_scripts
for m in off split on own; do
	mkdir -p "$TMP/data_$m"
	d=$(x_display 960)
	# TU_DEBUG=gmem: tiles wherever they are possible. Turnip's autotune would pick between tiles
	# and none by the samples the GPU counted in earlier frames, which the drm-shim makes up (here,
	# with no GPU behind it, zeros: "Autotune selected sysmem"); the reasons tiles are impossible
	# come first
	XDG_DATA_HOME=$TMP/data_$m MESA_GPU_TRACES=print MESA_GPU_TRACEFILE=$TMP/trace_$m.txt TU_DEBUG=perf,gmem \
		env "${TURNIP[@]}" timeout 300 xvfb-run -n $d -s "-screen 0 1280x720x24" "$GODOT" --path . \
		--resolution 320x180 -s res://tests/fdm_check.gd -- $m $HEADSET_EYE > "$TMP/log_$m.txt" 2>&1
	free_display $d
	if grep -qE "SCRIPT ERROR|SHADER ERROR" "$TMP/log_$m.txt"; then
		grep -E "SCRIPT ERROR|SHADER ERROR" -A3 "$TMP/log_$m.txt"; exit 1
	fi
	grep -q "Turnip Adreno" "$TMP/log_$m.txt" || { echo "$m: Godot did not run on Turnip:"; tail -20 "$TMP/log_$m.txt"; exit 1; }
	grep "^fdm_check:" "$TMP/log_$m.txt"
	grep "^TU: warning" "$TMP/log_$m.txt" | sort | uniq -c | sed 's/^/    driver: /'
done
python3 - "$TMP" "$HEADSET_EYE" <<'PY'
import re, sys, collections
tmp, eye = sys.argv[1], sys.argv[2]
def passes(m):
    """The XR 3D pass's renders after the switch: (attachments, tiled, why not, tiles)."""
    out, start = [], None
    for line in open(f'{tmp}/trace_{m}.txt', errors='replace'):
        if 'start_render_pass:' in line:
            start = line
        elif 'end_render_pass:' in line and start:
            # the simulated headset's view, with depth: the 3D scene
            if f'width={eye}, height={eye}' in start and 'hasDepth=true' in start:
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
on = set(res['on'])
ok &= all(p[1] for p in on) and {p[0] for p in on} == {p[0] + 1 for p in split}
ok &= set(res['own']) == set(res['off'])
print('PASS: with SteamVR\'s foveation the driver renders the XR pass in tiles, with the density map; '
      'our own leaves the pass as it is without foveation' if ok else 'FAIL')
if res['off'] and all(p[1] for p in res['off']):
    print('note: "off" renders in tiles too: this Godot has the fix godot/split_pass.gd works around')
sys.exit(0 if ok else 1)
PY
exit $?
