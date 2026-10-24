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

missing=""
command -v xvfb-run >/dev/null || missing="$missing xvfb"
ls /usr/share/vulkan/icd.d/lvp_icd*.json >/dev/null 2>&1 || missing="$missing mesa-vulkan-drivers(lavapipe)"
ldconfig -p | grep -q "libEGL.so.1 " && ldconfig -p | grep -q libEGL_mesa || missing="$missing libegl1 libegl-mesa0(ref/test_gpu.py)"
if [ -n "$missing" ]; then
	echo "also needed (apt):$missing"
	command -v apt-get >/dev/null && { apt-get install -y xvfb mesa-vulkan-drivers libegl1 libegl-mesa0 || true; }
fi
echo "ok: $BIN/Godot_v$V-stable_linux.x86_64"
