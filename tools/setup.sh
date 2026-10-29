#!/bin/bash
# Everything the tests and exports need on a Linux machine (or a fresh cloud session):
# Godot 4.7.2 into tools/.bin, its export templates, and the Python packages of ref/ and tools/.
# Software Vulkan (lavapipe) and xvfb are needed to render without a GPU or a display, EGL for
# ref/'s GPU checks, Monado to run the app through a real OpenXR runtime without a headset.
# The four steps don't depend on each other and run at once; each line of output starts with
# its step's name. Then, as a fifth, the Steam Frame's Vulkan driver (Mesa's Turnip for Adreno 750)
# is built from source with Mesa's "noop" drm-shim, for tools/adreno_stats.sh: what the headset's
# shader compiler makes of the ray tracer. No package has the drm-shim (built once).
# On the Steam Frame all of it goes into tools/box.sh's container, where the tools run (tools/env.sh).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
# not there when a cloud environment's setup script, a copy of this one alone, runs it (below)
[ ! -f "$ROOT/tools/env.sh" ] || . "$ROOT/tools/env.sh"
V=4.7.2
BIN=$ROOT/tools/.bin
REL=https://github.com/godotengine/godot/releases/download/$V-stable
GODOT=Godot_v$V-stable_linux.$(uname -m | sed 's/^aarch64$/arm64/')   # x86_64 in the cloud, arm64 on the Frame
TPL=${XDG_DATA_HOME:-$HOME/.local/share}/godot/export_templates/$V.stable
mkdir -p "$BIN"

# GitHub's release storage gives one connection a fraction of the line: eight pieces (-r) at once.
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
	[ ! -x "$BIN/$GODOT" ] || { ln -sfn "$GODOT" "$BIN/godot"; return 0; }
	echo "downloading Godot $V"
	fetch "$REL/$GODOT.zip" "$BIN/godot.zip"
	(cd "$BIN" && unzip -oq godot.zip && rm godot.zip && chmod +x "$GODOT")
	ln -sfn "$GODOT" "$BIN/godot"   # the name the tools use, whatever the machine
}

get_templates() {
	[ ! -f "$TPL/linux_release.arm64" ] || return 0
	echo "downloading export templates (1.3 GB: the release file's size)"
	fetch "$REL/Godot_v$V-stable_export_templates.tpz" "$BIN/templates.tpz"
	# one unzip per core, into a side folder: an interrupted run leaves no half-filled $TPL
	rm -rf "$TPL.part"
	mkdir -p "$TPL.part" "$TPL"
	# only what the one export preset (Linux arm64) takes
	unzip -Z1 "$BIN/templates.tpz" | grep -E '/(linux_(debug|release)\.arm64|version\.txt|icudt[^/]*)$' \
		| xargs -P "$(nproc)" -n 1 unzip -ojq "$BIN/templates.tpz" -d "$TPL.part"
	mv -f "$TPL.part"/* "$TPL/"
	rmdir "$TPL.part"
	rm "$BIN/templates.tpz"
}

# One pip for all four: PyPI through the cloud session's proxy is slow per connection.
get_pip() {
	pip install --quiet --break-system-packages numpy scipy pillow moderngl 2>/dev/null \
		|| pip install --quiet numpy scipy pillow moderngl
}

# what Mesa's build needs (Turnip, X11 for Godot's window, the drm-shim)
MESA_V=25.2.8
MESA_DEBS="ninja-build python3-mako python3-yaml python3-pycparser flex bison pkg-config glslang-tools
	libdrm-dev libexpat1-dev zlib1g-dev libzstd-dev libelf-dev libx11-dev libxext-dev libxfixes-dev
	libx11-xcb-dev libxcb1-dev libxcb-dri2-0-dev libxcb-dri3-dev libxcb-present-dev libxcb-randr0-dev
	libxcb-sync-dev libxcb-shm0-dev libxcb-xfixes0-dev libxshmfence-dev libxxf86vm-dev libxrandr-dev"
MESA_OUT=$BIN/mesa-fd
SHIM=$MESA_OUT/lib/$(uname -m)-linux-gnu/libfreedreno_noop_drm_shim.so

check_apt() {   # sets $missing to the apt packages still needed
	missing=""
	local p
	if [ ! -f "$SHIM" ]; then
		for p in $MESA_DEBS; do
			dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q "ok installed" || missing="$missing $p"
		done
	fi
	command -v xvfb-run >/dev/null || missing="$missing xvfb"
	ls /usr/share/vulkan/icd.d/lvp_icd*.json >/dev/null 2>&1 || missing="$missing mesa-vulkan-drivers"
	command -v monado-service >/dev/null || missing="$missing monado-service"
	[ -f /usr/share/openxr/1/openxr_monado.json ] || missing="$missing libopenxr1-monado"
	local libs   # EGL, for ref/'s GPU checks
	libs=$(ldconfig -p 2>/dev/null) || true
	{ grep -q "libEGL.so.1 " <<<"$libs" && grep -q libEGL_mesa <<<"$libs"; } || missing="$missing libegl1 libegl-mesa0"
}
get_apt() {
	check_apt
	if [ -n "$missing" ] && command -v apt-get >/dev/null; then
		echo "installing:$missing"
		# a fresh container has empty package lists: without update, install finds nothing; dpkg
		# first finishes an install a stopped run left
		{ dpkg --configure -a && apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $missing; } || true
		check_apt
	fi
	[ -z "$missing" ] || { echo "still missing:$missing (lavapipe = mesa-vulkan-drivers)"; return 1; }
}

# Turnip (Mesa's Vulkan driver for Adreno) and the noop drm-shim, built into tools/.bin/mesa-fd.
# The source comes from mesa3d.org, or from Ubuntu's archive where mesa3d.org is unreachable.
get_adreno() {
	[ ! -f "$SHIM" ] || return 0
	# Mesa wants meson 1.4 or newer; Ubuntu 24.04 has 1.3
	python3 -c "import mesonbuild.coredata as c, sys; sys.exit(tuple(map(int, c.version.split('.')[:2])) < (1, 4))" 2>/dev/null \
		|| pip install --quiet --break-system-packages "meson>=1.4,<1.9" 2>/dev/null || pip install --quiet "meson>=1.4,<1.9"
	local src=$BIN/mesa-src tar=$BIN/mesa.tar.xz u
	rm -rf "$src" "$BIN/mesa-build"
	for u in https://archive.mesa3d.org/mesa-$MESA_V.tar.xz \
			http://archive.ubuntu.com/ubuntu/pool/main/m/mesa/mesa_$MESA_V.orig.tar.xz; do
		echo "downloading $u"
		curl -fsSL --retry 2 --connect-timeout 20 -o "$tar" "$u" && break
		rm -f "$tar"
	done
	[ -f "$tar" ] || { echo "no Mesa $MESA_V source"; return 1; }
	mkdir -p "$src"
	tar -xJf "$tar" -C "$src" --strip-components=1
	rm "$tar"
	echo "building Turnip (Mesa $MESA_V)"
	(cd "$src" && meson setup "$BIN/mesa-build" --prefix="$MESA_OUT" -Dbuildtype=release \
		-Dgallium-drivers= -Dvulkan-drivers=freedreno -Dfreedreno-kmds=msm -Dtools=drm-shim \
		-Dplatforms=x11 -Dglx=disabled -Degl=disabled -Dgbm=disabled -Dopengl=false -Dgles1=disabled \
		-Dgles2=disabled -Dllvm=disabled -Dvalgrind=disabled -Dlibunwind=disabled -Dvideo-codecs= \
		>"$BIN/mesa-setup.log" 2>&1) || { tail -20 "$BIN/mesa-setup.log"; return 1; }
	ninja -C "$BIN/mesa-build" install >"$BIN/mesa-build.log" 2>&1 || { tail -20 "$BIN/mesa-build.log"; return 1; }
	rm -rf "$src" "$BIN/mesa-build" "$BIN/mesa-setup.log" "$BIN/mesa-build.log"
}

# A cloud environment's setup script is a copy of this one, run outside the repo (ROOT is then
# not the repo: `/`, so its BIN is /tools/.bin); the cloud keeps what it installed and
# clones the repo afresh for each session. Take that install, found through the godot it put on
# PATH, instead of downloading Godot and building Turnip again.
reuse() {
	local g d
	g=$(readlink -f "$(command -v godot)" 2>/dev/null) || return 0
	d=$(dirname "$g")
	[ "$d" != "$BIN" ] || return 0
	if [ ! -x "$BIN/$GODOT" ] && [ "$(basename "$g")" = "$GODOT" ]; then
		ln -sfn "$g" "$BIN/$GODOT"
		echo "reuse: $g"
	fi
	if [ ! -f "$SHIM" ] && [ -f "$d/mesa-fd/${SHIM#"$MESA_OUT"/}" ]; then
		rm -rf "$MESA_OUT"
		ln -sfn "$d/mesa-fd" "$MESA_OUT"
		echo "reuse: $d/mesa-fd"
	fi
}
reuse

prefix() {   # name: puts it in front of every line
	local l
	while IFS= read -r l || [ -n "$l" ]; do printf '%s: %s\n' "$1" "$l"; done
}
steps=(godot templates pip apt)
adreno=1
if [ $# != 0 ]; then   # or only the steps named: tools/setup.sh godot templates
	steps=()
	adreno=0
	for s; do if [ "$s" = adreno ]; then adreno=1; else steps+=("$s"); fi; done
fi
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
# after apt: it needs the packages that step installs
[ $adreno = 0 ] || get_adreno 2>&1 | prefix adreno

# also on PATH: the tests fall back to it when this script ran outside the repo (a cloud
# environment's copy: reuse above)
ln -sf "$(readlink -f "$BIN/$GODOT")" /usr/local/bin/godot 2>/dev/null || true
echo "ok: $BIN/$GODOT, $MESA_OUT"
