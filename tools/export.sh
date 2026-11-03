#!/bin/bash
# The headset's build: Godot exports the Steam Frame preset into godot/build/wormhole_vr.arm64
# (where the tools run: tools/box.sh), then it goes where the headset takes it from:
#   on the Frame itself: ~/wormhole-vr/wormhole_vr.arm64, the Steam library's entry, at once
#     (a running build keeps its old file); the owner starts it from the library
#   elsewhere (a cloud session): godot/build/wormhole_vr_<label>_<commit>_steam_frame.zip with the
#     one .arm64, to attach to the chat; tools/deploy_frame.bat on the PC puts it on the Frame. The
#     commit keeps each build's name its own: a browser saves a second file of the same name as
#     "... (1).zip", and the PC's tools would take the first
# The PC's builds, which run on a PC with SteamVR and stream to the headset, always go into a zip:
# godot/build/wormhole_vr_<label>_<commit>_pc_windows.zip with wormhole_vr.exe, ..._pc_linux.zip
# with wormhole_vr.x86_64.
# The build carries its commit (godot/build.json while it exports, "+" after it if godot/ differs
# from it): main.gd prints it at the start, so the log says which build ran.
#   tools/export.sh [--check | --pc-windows | --pc-linux] [label]   (label: the branch's name by default)
# --check: the build for the one-eye check, with the stereo check scene on (its own export preset,
# whose feature "check" main.show_check reads).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tools/repo.sh"
if [ "${1:-}" = --godot ]; then   # the export itself (preset, file), in the container on the Frame
	. "$ROOT/tools/env.sh"
	[ -x "$GODOT" ] || { echo "no Godot: run tools/setup.sh"; exit 2; }
	import_scripts
	cd "$ROOT/godot"
	mkdir -p build
	exec "$GODOT" --headless --path . --export-release "$2" "build/$3"
fi
# the preset, the file it makes, the zip's name after the label (<commit> for the commit), and
# whether it is the headset's own (FRAME; NOTE: what it is, said on the Frame)
FRAME=1
NOTE=""
case ${1:-} in
	--check) PRESET="Steam Frame, the one-eye check (Linux arm64)"; FILE=wormhole_vr.arm64
		KIND=check_"<commit>"_steam_frame; NOTE=" (the one-eye check)"; shift ;;
	--pc-windows) PRESET="PC, streamed to the headset (Windows x86_64)"; FILE=wormhole_vr.exe
		KIND="<commit>"_pc_windows; FRAME=""; shift ;;
	--pc-linux) PRESET="PC, streamed to the headset (Linux x86_64)"; FILE=wormhole_vr.x86_64
		KIND="<commit>"_pc_linux; FRAME=""; shift ;;
	*) PRESET="Steam Frame (Linux arm64)"; FILE=wormhole_vr.arm64
		KIND="<commit>"_steam_frame ;;
esac
BUILD=$ROOT/godot/build/$FILE
# the label: the branch checked out, else the task's (its worktree, .wt/<branch>, is detached)
LABEL=${1:-$(git -C "$ROOT" symbolic-ref --short -q HEAD || true)}
case $ROOT in "$REPO"/.wt/*) [ -n "$LABEL" ] || LABEL=${ROOT#"$REPO"/.wt/} ;; esac
[ -n "$LABEL" ] || LABEL=$(git -C "$ROOT" rev-parse --short HEAD)
LABEL=$(tr '/' '-' <<<"$LABEL")
COMMIT=$(git -C "$ROOT" rev-parse --short HEAD)$(git -C "$ROOT" diff --quiet HEAD -- godot || echo +)
printf '{"commit": "%s"}\n' "$COMMIT" > "$ROOT/godot/build.json"
rm -f "$BUILD"
log=$(mktemp)
"$ROOT/tools/box.sh" "$ROOT/tools/export.sh" --godot "$PRESET" "$FILE" > "$log" 2>&1 || true
rm -f "$ROOT/godot/build.json"
if [ ! -s "$BUILD" ] || grep -qE "SCRIPT ERROR|SHADER ERROR|^ERROR" "$log"; then
	grep -E "ERROR" -A3 "$log" || tail -20 "$log"
	rm -f "$log"
	echo "the export failed"
	exit 1
fi
rm -f "$log"
if [ -n "$FRAME" ] && grep -qsx 'ID=steamos' /etc/os-release; then
	DEST=$HOME/wormhole-vr
	mkdir -p "$DEST"
	cp "$BUILD" "$DEST/wormhole_vr.arm64.new"
	chmod +x "$DEST/wormhole_vr.arm64.new"
	mv -f "$DEST/wormhole_vr.arm64.new" "$DEST/wormhole_vr.arm64"
	echo "$DEST/wormhole_vr.arm64$NOTE: start it from the Steam library"
	grep -aqs "$DEST/wormhole_vr.arm64" "$HOME"/.local/share/Steam/userdata/*/config/shortcuts.vdf \
		|| echo "not in the Steam library yet: steamos-add-to-steam $DEST/wormhole_vr.arm64 adds it (once)"
else
	zip=$ROOT/godot/build/wormhole_vr_${LABEL}_${KIND/<commit>/$COMMIT}.zip
	rm -f "$zip"
	(cd "$ROOT/godot/build" && python3 -c 'import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w", zipfile.ZIP_DEFLATED) as z: z.write(sys.argv[2])' "$zip" "$FILE")
	echo "$zip: attach it to the chat"
fi
