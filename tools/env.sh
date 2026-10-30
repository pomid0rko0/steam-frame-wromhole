# Sourced first thing by the tools, after they set ROOT: the same commands in a cloud session and
# on the Steam Frame.
# On a machine without apt (the Frame's SteamOS) it runs the calling script again, with its
# arguments, in tools/box.sh's container (box.sh says why; without podman it stops), and the script
# goes on there past this line. Elsewhere (a cloud session, the container) it sets GODOT, the
# Godot the tools run, MESA, the Frame's driver setup.sh builds, OUTS, where runs keep their files
# (in the repository: the host sees them too), import_scripts and x_display.
# A task's worktree (.wt/<branch>, tools/box.sh) takes the repository's own tools/.bin, which git
# does not hold.
. "$ROOT/tools/repo.sh"
if [ "$REPO" != "$ROOT" ] && [ ! -e "$ROOT/tools/.bin" ]; then
	mkdir -p "$REPO/tools/.bin"
	ln -sfn "$REPO/tools/.bin" "$ROOT/tools/.bin"
fi
if ! command -v apt-get >/dev/null; then
	exec "$ROOT/tools/box.sh" "$(readlink -f "$0")" "$@"
fi
GODOT=${GODOT:-$ROOT/tools/.bin/godot}
[ -x "$GODOT" ] || GODOT=$(command -v godot || true)
# setup.sh puts it next to Godot: where the environment ran setup.sh from elsewhere, that is not
# this tree's tools/.bin
MESA=${MESA:-$ROOT/tools/.bin/mesa-fd}
[ -d "$MESA" ] || MESA=$(dirname "$(readlink -f "$GODOT")")/mesa-fd
# Each eye's pixels a side in the headset: the headset log's "refresh:" lines ("eye WxH"; SteamVR's
# resolution setting decides it)
HEADSET_EYE=1728
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
