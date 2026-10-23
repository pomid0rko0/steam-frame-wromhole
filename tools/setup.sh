#!/bin/bash
# Everything the tests and exports need on a Linux machine (or a fresh cloud session):
# Godot 4.7.2 into tools/.bin, its export templates, and the Python packages of ref/ and tools/.
# Software Vulkan (lavapipe) and xvfb are needed to render without a GPU or a display.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
V=4.7.2
BIN=$ROOT/tools/.bin
REL=https://github.com/godotengine/godot/releases/download/$V-stable
TPL=${XDG_DATA_HOME:-$HOME/.local/share}/godot/export_templates/$V.stable
mkdir -p "$BIN"

if [ ! -x "$BIN/Godot_v$V-stable_linux.x86_64" ]; then
	echo "downloading Godot $V"
	curl -fsSL -o "$BIN/godot.zip" "$REL/Godot_v$V-stable_linux.x86_64.zip"
	(cd "$BIN" && unzip -oq godot.zip && rm godot.zip && chmod +x "Godot_v$V-stable_linux.x86_64")
fi

if [ ! -f "$TPL/linux_release.arm64" ]; then
	echo "downloading export templates (about 1 GB)"
	curl -fsSL -o "$BIN/templates.tpz" "$REL/Godot_v$V-stable_export_templates.tpz"
	mkdir -p "$TPL"
	(cd "$BIN" && unzip -oq templates.tpz && cp templates/* "$TPL/" && rm -rf templates templates.tpz)
fi

pip install --quiet --break-system-packages numpy scipy pillow moderngl 2>/dev/null \
	|| pip install --quiet numpy scipy pillow moderngl

check_apt() {   # sets $missing to the apt packages still needed
	missing=""
	command -v xvfb-run >/dev/null || missing="$missing xvfb"
	ls /usr/share/vulkan/icd.d/lvp_icd*.json >/dev/null 2>&1 || missing="$missing mesa-vulkan-drivers"
}
check_apt
if [ -n "$missing" ] && command -v apt-get >/dev/null; then
	echo "installing (apt):$missing"
	# a fresh container has empty package lists: without update, install finds nothing
	{ apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $missing; } || true
	check_apt
fi
[ -z "$missing" ] || { echo "still missing (apt):$missing (lavapipe = mesa-vulkan-drivers)"; exit 1; }

# also on PATH: the tests fall back to it when this script ran outside the repo,
# e.g. piped from curl in an environment setup script (then ROOT is not the repo)
ln -sf "$BIN/Godot_v$V-stable_linux.x86_64" /usr/local/bin/godot 2>/dev/null || true
echo "ok: $BIN/Godot_v$V-stable_linux.x86_64"
