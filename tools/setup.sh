#!/bin/bash
# Everything the tests and exports need on a Linux machine with apt, as root (a cloud environment's
# setup script is a copy of it; tools/Containerfile's image and tools/box.sh's container run it):
# Godot (V below) into DIR below and onto PATH as godot, where the tools take it from
# (tools/env.sh), its export templates, and the Python packages of ref/ and tools/.
# Software Vulkan (lavapipe) and xvfb are needed to render without a GPU or a display, EGL for
# ref/'s GPU checks, Monado to run the app through a real OpenXR runtime without a headset.
# The steps (steps= below) don't depend on each other and run at once; each line of output starts
# with its step's name. Then, after apt (after= below: they need its compilers and headers), pip,
# which builds from source what has no wheel for this machine (moderngl and glcontext on arm64),
# and last adreno: the Steam Frame's Vulkan driver (Mesa's Turnip for Adreno 750) built from source
# with Mesa's "noop" drm-shim, for tools/adreno_stats.sh (what the headset's shader compiler makes
# of the renderer's shaders).
# No package has the drm-shim (built once).
# On the Steam Frame all of it goes into tools/box.sh's container, where the tools run
# (tools/env.sh).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
# not there when it runs as a copy outside the repository (a cloud environment's, the image's)
[ ! -f "$ROOT/tools/env.sh" ] || . "$ROOT/tools/env.sh"
V=4.7.2
DIR=/opt/wormhole-vr   # the same on every machine, for every checkout and worktree
REL=https://github.com/godotengine/godot/releases/download/$V-stable
GODOT=Godot_v$V-stable_linux.$(uname -m | sed 's/^aarch64$/arm64/')   # x86_64 in the cloud, arm64 on the Frame
TPL=${XDG_DATA_HOME:-$HOME/.local/share}/godot/export_templates/$V.stable
# An install elsewhere (an older image's /tools/.bin, a checkout's tools/.bin: the Frame's container
# keeps its own when setup.sh changes) moves into DIR rather than being downloaded and built again
# (on the Frame, Turnip on one core); what is left of it in the checkout goes.
if [ ! -e "$DIR" ]; then
	for old in /tools/.bin ${REPO:+"$REPO/tools/.bin"}; do
		[ ! -d "$old/mesa-fd" ] || { mv "$old" "$DIR"; rmdir "${old%/.bin}" 2>/dev/null || true; break; }
	done
fi
[ -z "${REPO:-}" ] || rm -rf "$REPO/tools/.bin" "$REPO"/.wt/*/tools/.bin
mkdir -p "$DIR"

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
	if [ ! -x "$DIR/$GODOT" ]; then
		echo "downloading Godot $V"
		fetch "$REL/$GODOT.zip" "$DIR/godot.zip"
		(cd "$DIR" && unzip -oq godot.zip && rm godot.zip && chmod +x "$GODOT")
	fi
	ln -sfn "$DIR/$GODOT" /usr/local/bin/godot   # the name the tools use, whatever the machine
}

get_templates() {
	[ ! -f "$TPL/linux_release.arm64" ] || [ ! -f "$TPL/linux_release.x86_64" ] \
		|| [ ! -f "$TPL/windows_release_x86_64.exe" ] || return 0
	echo "downloading export templates (the release's file for every platform: those of the presets are kept)"
	fetch "$REL/Godot_v$V-stable_export_templates.tpz" "$DIR/templates.tpz"
	# one unzip per core, into a side folder: an interrupted run leaves no half-filled $TPL
	rm -rf "$TPL.part"
	mkdir -p "$TPL.part" "$TPL"
	# only what the export presets take: the Frame's Linux arm64, the PC's Linux and Windows x86_64
	unzip -Z1 "$DIR/templates.tpz" \
		| grep -E '/(linux_(debug|release)\.(arm64|x86_64)|windows_(debug|release)_x86_64\.exe|version\.txt|icudt[^/]*)$' \
		| xargs -P "$(nproc)" -n 1 unzip -ojq "$DIR/templates.tpz" -d "$TPL.part"
	mv -f "$TPL.part"/* "$TPL/"
	rmdir "$TPL.part"
	rm "$DIR/templates.tpz"
}

# pip into the system's Python: Ubuntu from 23.04 refuses that without the flag, which older pip
# does not know (grep reads the whole help: -q's early exit would fail the pipe)
pip_system() {
	if pip install --help | grep -- --break-system-packages >/dev/null; then
		pip install --quiet --break-system-packages "$@"
	else
		pip install --quiet "$@"
	fi
}

# One pip for all four: PyPI through the cloud session's proxy is slow per connection.
get_pip() {
	pip_system numpy scipy pillow moderngl
}

# what Mesa's build needs (Turnip, X11 for Godot's window, the drm-shim)
MESA_V=25.2.8
MESA_DEBS="build-essential xz-utils python3-pip ninja-build python3-mako python3-yaml python3-pycparser flex bison pkg-config glslang-tools
	libdrm-dev libexpat1-dev zlib1g-dev libzstd-dev libelf-dev libx11-dev libxext-dev libxfixes-dev
	libx11-xcb-dev libxcb1-dev libxcb-dri2-0-dev libxcb-dri3-dev libxcb-present-dev libxcb-randr0-dev
	libxcb-sync-dev libxcb-shm0-dev libxcb-xfixes0-dev libxshmfence-dev libxxf86vm-dev libxrandr-dev"
MESA_OUT=$DIR/mesa-fd
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
	command -v xauth >/dev/null || missing="$missing xauth"     # xvfb-run's
	command -v git >/dev/null || missing="$missing git"         # tools that read the repository
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

# Turnip (Mesa's Vulkan driver for Adreno) and the noop drm-shim, built into DIR/mesa-fd: next to
# Godot, where tools/env.sh looks for it.
# The source comes from mesa3d.org, or from Ubuntu's archive where mesa3d.org is unreachable.
get_adreno() {
	[ ! -f "$SHIM" ] || return 0
	# Mesa wants meson 1.4 or newer, which the system may lack
	python3 -c "import mesonbuild.coredata as c, sys; sys.exit(tuple(map(int, c.version.split('.')[:2])) < (1, 4))" 2>/dev/null \
		|| pip_system "meson>=1.4,<1.9"
	local src=$DIR/mesa-src tar=$DIR/mesa.tar.xz u
	rm -rf "$src" "$DIR/mesa-build"
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
	(cd "$src" && meson setup "$DIR/mesa-build" --prefix="$MESA_OUT" -Dbuildtype=release \
		-Dgallium-drivers= -Dvulkan-drivers=freedreno -Dfreedreno-kmds=msm -Dtools=drm-shim \
		-Dplatforms=x11 -Dglx=disabled -Degl=disabled -Dgbm=disabled -Dopengl=false -Dgles1=disabled \
		-Dgles2=disabled -Dllvm=disabled -Dvalgrind=disabled -Dlibunwind=disabled -Dvideo-codecs= \
		>"$DIR/mesa-setup.log" 2>&1) || { tail -20 "$DIR/mesa-setup.log"; return 1; }
	ninja -C "$DIR/mesa-build" install >"$DIR/mesa-build.log" 2>&1 || { tail -20 "$DIR/mesa-build.log"; return 1; }
	rm -rf "$src" "$DIR/mesa-build" "$DIR/mesa-setup.log" "$DIR/mesa-build.log"
}

prefix() {   # name: puts it in front of every line
	local l
	while IFS= read -r l || [ -n "$l" ]; do printf '%s: %s\n' "$1" "$l"; done
}
steps=(godot templates apt)
after=(pip adreno)
if [ $# != 0 ]; then   # or only the steps named: tools/setup.sh godot templates
	steps=()
	after=()
	for s; do case $s in pip|adreno) after+=("$s") ;; *) steps+=("$s") ;; esac; done
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
for s in "${after[@]}"; do get_$s 2>&1 | prefix "$s"; done
echo "ok: $DIR/$GODOT, $MESA_OUT"
