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
OUTS=$REPO/.wt/.out
mkdir -p "$OUTS"
# runs' folders a day old go: nothing else deletes them (a run takes less than an hour)
find "$OUTS" -mindepth 1 -maxdepth 1 -type d -mmin +1440 -exec rm -rf {} + 2>/dev/null || true
# A Godot run with -s knows the project's script classes (WormholeSpace...) only from an import:
# import when there was none or a script changed since.
import_scripts() {
	local stamp=$ROOT/godot/.godot/scripts_imported     # a file: Godot's own imported/ is a folder
	[ -f "$stamp" ] && [ -z "$(find "$ROOT/godot" -name '*.gd' -newer "$stamp" -print -quit)" ] && return 0
	"$GODOT" --headless --path "$ROOT/godot" --import >/dev/null 2>&1 && touch "$stamp"
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
