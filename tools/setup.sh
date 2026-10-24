#!/bin/bash
# Everything the tests and exports need on a Linux machine (or a fresh cloud session):
# Godot 4.7.2 into tools/.bin, its export templates, and the Python packages of ref/ and tools/.
# Software Vulkan (lavapipe) and xvfb are needed to render without a GPU or a display, EGL for
# ref/test_gpu.py.
# The four steps don't depend on each other and run at once; each line of output starts with
# its step's name.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
V=4.7.2
BIN=$ROOT/tools/.bin
REL=https://github.com/godotengine/godot/releases/download/$V-stable
TPL=${XDG_DATA_HOME:-$HOME/.local/share}/godot/export_templates/$V.stable
mkdir -p "$BIN"

# One connection to GitHub's release storage gives ~25 MB/s; eight pieces (-r) at once are
# several times faster.
fetch() {   # url file
	local url size i n=8 pids="" ok=1
	url=$(curl -fsSIL -o /dev/null -w '%{url_effective}' "$1")   # the signed link GitHub redirects to
	size=$(curl -fsSI "$url" | tr -d '\r' | awk 'tolower($1) == "content-length:" { n = $2 }
		tolower($1) == "accept-ranges:" && $2 == "bytes" { r = 1 } END { if (r) print n }')
	if [ -z "$size" ]; then curl -fsSL --retry 3 -o "$2" "$1"; return; fi
	for i in $(seq 0 $((n - 1))); do
		curl -fsS --retry 3 -r $((size * i / n))-$((size * (i + 1) / n - 1)) -o "$2.$i" "$url" &
		pids="$pids $!"
	done
	for i in $pids; do wait "$i" || ok=0; done
	[ $ok = 1 ]
	for i in $(seq 0 $((n - 1))); do cat "$2.$i"; done > "$2"
	rm -f "$2".?
	[ "$(stat -c %s "$2")" = "$size" ] || { echo "$2: wrong size"; return 1; }
}

get_godot() {
	[ ! -x "$BIN/Godot_v$V-stable_linux.x86_64" ] || return 0
	echo "downloading Godot $V"
	fetch "$REL/Godot_v$V-stable_linux.x86_64.zip" "$BIN/godot.zip"
	(cd "$BIN" && unzip -oq godot.zip && rm godot.zip && chmod +x "Godot_v$V-stable_linux.x86_64")
}

get_templates() {
	[ ! -f "$TPL/linux_release.arm64" ] || return 0
	echo "downloading export templates (1.3 GB)"
	fetch "$REL/Godot_v$V-stable_export_templates.tpz" "$BIN/templates.tpz"
	# one unzip per core, into a side folder: an interrupted run leaves no half-filled $TPL
	rm -rf "$TPL.part"
	mkdir -p "$TPL.part" "$TPL"
	unzip -Z1 "$BIN/templates.tpz" | grep -v '/$' \
		| xargs -P "$(nproc)" -n 1 unzip -ojq "$BIN/templates.tpz" -d "$TPL.part"
	mv -f "$TPL.part"/* "$TPL/"
	rmdir "$TPL.part"
	rm "$BIN/templates.tpz"
}

# One pip for all four: PyPI through the cloud session's proxy swings between 0.1 and 35 MB/s
# per connection, and four pip downloads at once came out slower than one after another.
get_pip() {
	pip install --quiet --break-system-packages numpy scipy pillow moderngl 2>/dev/null \
		|| pip install --quiet numpy scipy pillow moderngl
}

check_apt() {   # sets $missing to the apt packages still needed
	missing=""
	command -v xvfb-run >/dev/null || missing="$missing xvfb"
	ls /usr/share/vulkan/icd.d/lvp_icd*.json >/dev/null 2>&1 || missing="$missing mesa-vulkan-drivers"
	local libs   # EGL, for ref/test_gpu.py
	libs=$(ldconfig -p 2>/dev/null) || true
	{ grep -q "libEGL.so.1 " <<<"$libs" && grep -q libEGL_mesa <<<"$libs"; } || missing="$missing libegl1 libegl-mesa0"
}
get_apt() {
	check_apt
	if [ -n "$missing" ] && command -v apt-get >/dev/null; then
		echo "installing:$missing"
		# a fresh container has empty package lists: without update, install finds nothing
		{ apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $missing; } || true
		check_apt
	fi
	[ -z "$missing" ] || { echo "still missing:$missing (lavapipe = mesa-vulkan-drivers)"; return 1; }
}

prefix() {   # name: puts it in front of every line
	local l
	while IFS= read -r l || [ -n "$l" ]; do printf '%s: %s\n' "$1" "$l"; done
}
steps=(godot templates pip apt)
pids=()
# Steps in the background don't get Ctrl-C from the terminal: on it, stop them here. `set -m`
# gives each step its own process group, so that its curls, unzips and pip stop with it.
set -m
trap 'kill -- "${pids[@]/#/-}" 2>/dev/null || true; echo "interrupted"; exit 130' INT TERM
for s in "${steps[@]}"; do
	# no `if`/`||` around the step: there bash would ignore `set -e` inside it
	( "get_$s" 2>&1 | prefix "$s"; echo "$s: done" ) </dev/null &
	pids+=($!)
done
failed=""
for i in "${!steps[@]}"; do wait "${pids[$i]}" || failed="$failed ${steps[$i]}"; done
[ -z "$failed" ] || { echo "failed:$failed"; exit 1; }

# also on PATH: the tests fall back to it when this script ran outside the repo,
# e.g. piped from curl in an environment setup script (then ROOT is not the repo)
ln -sf "$BIN/Godot_v$V-stable_linux.x86_64" /usr/local/bin/godot 2>/dev/null || true
echo "ok: $BIN/Godot_v$V-stable_linux.x86_64"
