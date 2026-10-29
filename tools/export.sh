#!/bin/bash
# The headset's build: Godot exports the Steam Frame preset into godot/build/wormhole_vr.arm64
# (where the tools run: tools/box.sh), then it goes where the headset takes it from:
#   on the Frame itself: ~/wormhole-vr/wormhole_vr.arm64, the Steam library's entry, at once
#     (a running build keeps its old file); the owner starts it from the library
#   elsewhere (a cloud session): godot/build/wormhole_vr_<label>_steam_frame.zip with the one
#     .arm64, to attach to the chat; tools/deploy_frame.bat on the PC puts it on the Frame
#   tools/export.sh [--check] [label]      (label: the branch's name by default)
# --check: the build for the one-eye check, with the stereo check scene on (its own export preset,
# whose feature "check" main.show_check reads).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tools/repo.sh"
BUILD=$ROOT/godot/build/wormhole_vr.arm64
if [ "${1:-}" = --godot ]; then   # the export itself (the preset's name), in the container on the Frame
	. "$ROOT/tools/env.sh"
	[ -x "$GODOT" ] || { echo "no Godot: run tools/setup.sh"; exit 2; }
	import_scripts
	cd "$ROOT/godot"
	mkdir -p build
	exec "$GODOT" --headless --path . --export-release "$2" build/wormhole_vr.arm64
fi
CHECK=""
[ "${1:-}" = --check ] && { CHECK=1; shift; }
# the label: the branch checked out, else the task's (its worktree, .wt/<branch>, is detached)
LABEL=${1:-$(git -C "$ROOT" symbolic-ref --short -q HEAD || true)}
case $ROOT in "$REPO"/.wt/*) [ -n "$LABEL" ] || LABEL=${ROOT#"$REPO"/.wt/} ;; esac
[ -n "$LABEL" ] || LABEL=$(git -C "$ROOT" rev-parse --short HEAD)
LABEL=$(tr '/' '-' <<<"$LABEL")${CHECK:+_check}
PRESET="Steam Frame${CHECK:+, the one-eye check} (Linux arm64)"
rm -f "$BUILD"
log=$(mktemp)
"$ROOT/tools/box.sh" "$ROOT/tools/export.sh" --godot "$PRESET" > "$log" 2>&1 || true
if [ ! -s "$BUILD" ] || grep -qE "SCRIPT ERROR|SHADER ERROR|^ERROR" "$log"; then
	grep -E "ERROR" -A3 "$log" || tail -20 "$log"
	rm -f "$log"
	echo "the export failed"
	exit 1
fi
rm -f "$log"
if grep -qsx 'ID=steamos' /etc/os-release; then
	DEST=$HOME/wormhole-vr
	mkdir -p "$DEST"
	cp "$BUILD" "$DEST/wormhole_vr.arm64.new"
	chmod +x "$DEST/wormhole_vr.arm64.new"
	mv -f "$DEST/wormhole_vr.arm64.new" "$DEST/wormhole_vr.arm64"
	echo "$DEST/wormhole_vr.arm64${CHECK:+ (the one-eye check)}: start it from the Steam library"
	grep -aqs "$DEST/wormhole_vr.arm64" "$HOME"/.local/share/Steam/userdata/*/config/shortcuts.vdf \
		|| echo "not in the Steam library yet: steamos-add-to-steam $DEST/wormhole_vr.arm64 adds it (once)"
else
	zip=$ROOT/godot/build/wormhole_vr_${LABEL}_steam_frame.zip
	rm -f "$zip"
	(cd "$ROOT/godot/build" && python3 -c 'import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w", zipfile.ZIP_DEFLATED) as z: z.write("wormhole_vr.arm64")' "$zip")
	echo "$zip: attach it to the chat"
fi
