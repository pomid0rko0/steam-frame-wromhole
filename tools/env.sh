# Sourced first thing by the tools, after they set ROOT: the same commands in a cloud session and
# on the Steam Frame.
# On a machine without apt (the Frame's SteamOS) it runs the calling script again, with its
# arguments, in tools/box.sh's container (box.sh says why; without podman it stops), and the script
# goes on there past this line. Elsewhere (a cloud session, the container) it sets GODOT, the
# Godot the tools run (setup.sh's, the godot on PATH), MESA, the Frame's driver setup.sh builds next
# to it, OUTS, where runs keep their files (in the repository: the host sees them too),
# import_scripts and x_display.
. "$ROOT/tools/repo.sh"
if ! command -v apt-get >/dev/null; then
	exec "$ROOT/tools/box.sh" "$(readlink -f "$0")" "$@"
fi
GODOT=${GODOT:-$(command -v godot || true)}
# What a Godot run's log must not have (the tools fail on it): script and shader errors, and calls to
# the RenderingDevice off the render thread (Main.render_thread: they do nothing there). Godot 4.7.2's
# own at exit, finalize's, is left out: it leaks nothing a run looks at.
GODOT_ERRORS='SCRIPT ERROR|SHADER ERROR|This function \(([^f]|f[^i])[a-z_]*\) can only be called from the render thread'
MESA=${MESA:-$(dirname "$(readlink -f "$GODOT")")/mesa-fd}
OUTS=$REPO/.wt/.out
mkdir -p "$OUTS"
# runs' folders a day old go: nothing else deletes them (the tools' timeouts end a run sooner)
find "$OUTS" -mindepth 1 -maxdepth 1 -type d -mmin +1440 -exec rm -rf {} + 2>/dev/null || true
# Godot on Turnip (Mesa's driver for the Frame's Adreno 750) over Mesa's "noop" drm-shim (no GPU,
# nothing is drawn): turnip DIR writes the driver's manifest into DIR, pointing at the library where
# it is now (the installed one has the build's path), and sets TURNIP, the environment to run
# under (env "${TURNIP[@]}" ...); exit status 2 without setup.sh's Turnip.
turnip() {
	local lib=$MESA/lib/$(uname -m)-linux-gnu
	[ -f "$lib/libfreedreno_noop_drm_shim.so" ] || { echo "no Turnip build in $MESA: run tools/setup.sh"; return 2; }
	sed "s#\"library_path\": *\"[^\"]*\"#\"library_path\": \"$lib/libvulkan_freedreno.so\"#" \
		"$MESA"/share/vulkan/icd.d/freedreno_icd.*.json > "$1/icd.json"
	TURNIP=(LD_PRELOAD="$lib/libfreedreno_noop_drm_shim.so" FD_GPU_ID=750 MESA_VK_WSI_DEBUG=sw VK_ICD_FILENAMES="$1/icd.json")
}
# A Godot run with -s knows the project's script classes (WormholeSpace...) only from an import:
# import when there was none or a script changed since (the stamp's time: the import's start), one
# run of this tree at a time.
import_scripts() {
	local stamp=$ROOT/godot/.godot/scripts_imported     # a file: Godot's own imported/ is a folder
	mkdir -p "$ROOT/godot/.godot"
	(
		flock 8
		[ -f "$stamp" ] && [ -z "$(find "$ROOT/godot" -name '*.gd' -newer "$stamp" -print -quit)" ] && exit 0
		touch "$stamp.new"
		"$GODOT" --headless --path "$ROOT/godot" --import >/dev/null 2>&1 && mv "$stamp.new" "$stamp"
	) 8>"$ROOT/godot/.godot/import.lock"
}
# An X display no other run holds, also another task's: from $1 on, the first without an X server
# whose reservation (a directory: mkdir makes it or fails, never both for two runs) this run gets.
# A run stopped before free_display leaves its reservation: one older than an hour goes (the tools'
# timeouts end every run before that).
x_display() {
	local d=$1
	find /tmp -maxdepth 1 -name '.wormhole-X*' -type d -mmin +60 -exec rmdir {} + 2>/dev/null || true
	while [ -e "/tmp/.X$d-lock" ] || [ -e "/tmp/.X11-unix/X$d" ] || ! mkdir "/tmp/.wormhole-X$d" 2>/dev/null; do
		d=$((d + 1))
	done
	echo "$d"
}
free_display() { rmdir "/tmp/.wormhole-X$1" 2>/dev/null || true; }
# Godot's shader cache (its user data's shader_cache: each shader compiled to SPIR-V, a file under a
# hash of its source) is half of what a test's Godot run costs when it starts empty
# (tests/multiview_hmd.gd: 29 s of CPU, 14 s with the cache; the Vulkan pipeline cache saves nothing on
# lavapipe). So a tool's runs share theirs through a folder, $1 below: shaders_in puts a copy of it
# into a run's own user data ($2, the run's XDG_DATA_HOME: its settings and logs stay its own) before
# the run, shaders_out what the run compiled into it after a run that passed (one that failed may have
# been stopped halfway through a file). Godot writes a cache file in place: a run never writes the
# shared folder itself, and a file goes in under a name of its own and is then renamed, so a copy never
# takes half of one.
CACHE_DIR="godot/app_userdata/Wormhole VR/shader_cache"   # project.godot's config/name
shaders_in() {
	mkdir -p "$1" "$2/$CACHE_DIR"
	cp -r "$1/." "$2/$CACHE_DIR/"
}
shaders_out() {
	local c="$2/$CACHE_DIR" f
	( cd "$c" && find . -type f -name '*.cache' ) | while read -r f; do
		[ -e "$1/$f" ] && continue
		mkdir -p "$(dirname "$1/$f")"
		cp "$c/$f" "$1/$f.$BASHPID" && mv -f "$1/$f.$BASHPID" "$1/$f"
	done
}
# A Godot run of a test script on X display $1, its output into the file $2, for at most $3 s; the
# rest are Godot's arguments. Exit status Godot's, 124 past the limit. Godot 4.7.2 can hang in its
# own shutdown after a script has quit: the main thread waits on its worker pool, whose workers all
# wait for work (under the stereo test's load, about one render in two). A run that has printed its
# verdict (tests/util.gd's finish: "FAILURES: n", the line before it quits) and not ended
# EXIT_GRACE s later is killed, ends with that verdict (0 if n = 0, else 1), and says so in its log.
EXIT_GRACE=30
godot_x() {
	local d=$1 log=$2 limit=$3
	shift 3
	xvfb-run -n "$d" -s "-screen 0 1280x720x24" "$GODOT" "$@" > "$log" 2>&1 &
	local pid=$! t=0 seen=-1 c n
	while kill -0 $pid 2>/dev/null; do
		sleep 1
		t=$((t + 1))
		[ $seen -lt 0 ] && grep -qE "^FAILURES: [0-9]+$" "$log" && seen=$t
		if { [ $seen -ge 0 ] && [ $((t - seen)) -ge $EXIT_GRACE ]; } || [ $t -ge "$limit" ]; then
			# Godot: xvfb-run's child next to its X server (xvfb-run then takes that down)
			for c in $(pgrep -P $pid); do
				[ "$(cat /proc/$c/comm 2>/dev/null)" = Xvfb ] || kill -KILL "$c" 2>/dev/null
			done
			wait $pid 2>/dev/null
			if [ $seen -ge 0 ]; then
				n=$(grep -oE "^FAILURES: [0-9]+$" "$log" | tail -1 | grep -oE "[0-9]+$")
				echo "godot_x: still in Godot's exit $EXIT_GRACE s after the verdict (FAILURES: $n): killed, the verdict stands" >> "$log"
				[ "$n" = 0 ]
				return
			fi
			echo "godot_x: still running after $limit s: killed" >> "$log"
			return 124
		fi
	done
	wait $pid
}
