#!/bin/bash
# Other ray tracers for the speed check (godot/bench.gd): copies the world's ray tracer of each
# source into godot/shaders/ab/1, 2, ... (not in git), where an export picks them up. In the
# headset the menu's speed check then times this build's ray tracer and these at the same places,
# one after the other (the others alone, without the toys' passes); it compares this build's with
# the first.
#   tools/ab_shaders.sh <source>...   a source: a commit, or a directory holding wormhole.gdshader,
#                                     wormhole_view.gdshaderinc, wormhole_core.gdshaderinc
#                                     and wormhole_uniforms.gdshaderinc where its view includes it
#                                     (optionally a file "label" naming it), or one of the cost
#                                     checks made from this tree's ray tracer:
#                                       empty    one colour: what Godot costs without ray tracing
#                                       flat     no wormhole, straight rays, the same shading
#                                       noshade  the same rays, a plain colour per kind of surface
#                                       noderiv  grid lines of a fixed width: no screen derivatives
#                                       nogrid   no grid lines: no atan, asin or derivatives
#                                       nosky    one colour per sky, the grid lines kept
#   tools/ab_shaders.sh --auto <source>...   the same, and the build runs the check by itself
#                                     shortly after it starts (a build for measuring)
#   tools/ab_shaders.sh --remove      a build without them
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
DIR=$ROOT/godot/shaders/ab
rm -rf "$DIR"
[ "${1:-}" = "--remove" ] && exit 0
AUTO=""
[ "${1:-}" = "--auto" ] && { AUTO=1; shift; }
[ $# -ge 1 ] || { echo "usage: tools/ab_shaders.sh <commit or directory>... | --remove"; exit 2; }
n=0
for src in "$@"; do
	n=$((n + 1))
	out=$DIR/$n
	mkdir -p "$out"
	if [[ "$src" =~ ^(empty|flat|noshade|noderiv|nogrid|nosky)$ ]]; then
		tmp=$(mktemp -d)
		cp "$ROOT"/godot/shaders/wormhole.gdshader "$ROOT"/godot/shaders/wormhole_view.gdshaderinc \
			"$ROOT"/godot/shaders/wormhole_core.gdshaderinc "$ROOT"/godot/shaders/wormhole_uniforms.gdshaderinc "$tmp/"
		python3 - "$tmp" "$src" <<'PY' || { rm -rf "$DIR" "$tmp"; exit 1; }
import sys
d, kind = sys.argv[1], sys.argv[2]
def patch(name, old, new, label):
    p = d + '/' + name
    s = open(p).read()
    if old not in s:
        sys.exit('the ray tracer changed: ' + kind + ' does not apply to ' + name)
    open(p, 'w').write(s.replace(old, new))
    open(d + '/label', 'w').write(label + '\n')
if kind == 'empty':
    s = open(d + '/wormhole_view.gdshaderinc').read()
    i = s.index('void fragment() {')
    open(d + '/wormhole_view.gdshaderinc', 'w').write(s[:i] + 'void fragment() {\n\tALBEDO = vec3(0.10, 0.11, 0.13) + 1e-6 * v_ray.xyz;\n}\n')
    open(d + '/label', 'w').write("empty: one colour, Godot's own cost\n")
elif kind == 'flat':
    patch('wormhole_core.gdshaderinc', """    bool inShell = abs(l0) < wh_Lsh();
    bool shellAhead = !inShell;     // a straight ray that has left the shell never re-enters it
    if (!inShell) {
        x = wh_M(side, (abs(l0) - wh_Lsh() + wh_Rout()) * n0);
        d = wh_M(side, side * vl * n0 + w);
    }""", """    bool inShell = false;
    bool shellAhead = false;
    x = wh_M(side, (max(abs(l0) - wh_Lsh(), 0.0) + wh_Rout()) * n0);
    d = wh_M(side, side * vl * n0 + w);""", "flat: no wormhole, straight rays, the same shading")
elif kind in ('noderiv', 'nogrid', 'nosky'):
    core = d + '/wormhole_core.gdshaderinc'
    s = open(core).read()
    def cut(s, start, end, new):
        if start not in s or end not in s[s.index(start):]:
            sys.exit('the ray tracer changed: ' + kind + ' does not apply')
        a = s.index(start)
        b = s.index(end, a) + len(end)
        return s[:a] + new + s[b:]
    if kind in ('noderiv', 'nogrid'):
        s = cut(s, '    float cls = kind == 0 ?', 'max(fw, vec2(1e-4));     // tiny: no line, no circle',
                '    vec2 fw = vec2(%s);' % ('0.02' if kind == 'noderiv' else '1e-4'))
    if kind == 'nogrid':
        s = cut(s, '    vec2 ga = kind == 1 ? fn.xy : dn.xy;', '* (180.0 / WH_PI / 15.0);',
                '    vec2 gq = vec2(0.5) + 1e-6 * vec2(fl, fn.x);')
    if kind == 'nosky':
        s = cut(s, '    float sd = dot(d, wh_sunDir(side));', 'clamp(-el * 8.0, 0.0, 1.0));',
                '    return side > 0.0 ? vec3(0.9, 0.6, 0.4) : vec3(0.5, 0.7, 1.0) + 1e-6 * el;')
    open(core, 'w').write(s)
    open(d + '/label', 'w').write({'noderiv': 'grid lines of a fixed width, no screen derivatives',
                                   'nogrid': 'no grid lines: no atan, asin or derivatives',
                                   'nosky': 'one colour per sky, the grid lines kept'}[kind] + '\n')
else:
    s = open(d + '/wormhole_core.gdshaderinc').read()
    a = s.index('    if (kind == 1) side = fl > 0.0 ? 1.0 : -1.0;')
    end = '    return mix(c, side > 0.0 ? vec3(0.95, 0.60, 0.35) : vec3(0.70, 0.82, 0.95), fog);\n}'
    b = s.index(end, a) + len(end)
    s = s[:a] + """    if (kind == 1) side = fl > 0.0 ? 1.0 : -1.0;
    vec3 tint = side > 0.0 ? vec3(1.0, 0.85, 0.7) : vec3(0.7, 0.85, 1.0);
    if (kind == 0) return 0.8 * tint;
    if (kind == 1) return 0.5 * tint + 0.0001 * vec3(fl, fn.xy) + 0.0001 * dist;
    return col * max(nrm.z, 0.3);
}""" + s[b:]
    open(d + '/wormhole_core.gdshaderinc', 'w').write(s)
    open(d + '/label', 'w').write("no shading: a plain colour per kind (no grid, sky, fog)\n")
PY
		src=$tmp
	fi
	if [ -d "$src" ]; then
		get() { cat "$src/$1"; }
		label=$( [ -f "$src/label" ] && head -1 "$src/label" || basename "$src")
	else
		get() { git -C "$ROOT" show "$src:godot/shaders/$1"; }
		label=$(git -C "$ROOT" log -1 --format='%h, %cs' "$src")
	fi
	get wormhole_core.gdshaderinc > "$out/wormhole_core.gdshaderinc"
	# the world's uniforms in a file of their own, where the source has it
	get wormhole_uniforms.gdshaderinc > "$out/wormhole_uniforms.gdshaderinc" 2>/dev/null || rm -f "$out/wormhole_uniforms.gdshaderinc"
	get wormhole_view.gdshaderinc | sed -e "s#res://shaders/wormhole_core.gdshaderinc#res://shaders/ab/$n/wormhole_core.gdshaderinc#" \
		-e "s#res://shaders/wormhole_uniforms.gdshaderinc#res://shaders/ab/$n/wormhole_uniforms.gdshaderinc#" \
		> "$out/wormhole_view.gdshaderinc"
	# the first line names it: the log shows it
	{ echo "// $label"; get wormhole.gdshader | sed "s#res://shaders/wormhole_view.gdshaderinc#res://shaders/ab/$n/wormhole_view.gdshaderinc#"; } \
		> "$out/wormhole.gdshader"
	grep -q "res://shaders/ab/$n/" "$out/wormhole.gdshader" && grep -q "res://shaders/ab/$n/" "$out/wormhole_view.gdshaderinc" \
		|| { echo "unexpected include paths in $src"; rm -rf "$DIR"; exit 1; }
	echo "godot/shaders/ab/$n: $label"
	[ -n "${tmp:-}" ] && rm -rf "$tmp" && tmp=""
done
[ -n "$AUTO" ] && echo "run by itself" > "$DIR/auto" && echo "godot/shaders/ab/auto: the check runs by itself"
# Godot needs to have seen the new files before a script loads them
GODOT=${GODOT:-$(command -v godot)}
"$GODOT" --headless --path "$ROOT/godot" --import >/dev/null 2>&1 || true
