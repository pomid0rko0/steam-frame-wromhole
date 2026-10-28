# Sourced first thing by the tools, after they set ROOT: the same commands in a cloud session and
# on the Steam Frame.
# On a machine without apt that has podman (the Frame's SteamOS) it runs the calling script again,
# with its arguments, in tools/box.sh's container (box.sh says why), and the script goes on there
# past this line. Elsewhere (a cloud session, the container) it only sets GODOT,
# the Godot the tools run, and import_once.
if ! command -v apt-get >/dev/null && command -v podman >/dev/null; then
	exec "$ROOT/tools/box.sh" "$(readlink -f "$0")" "$@"
fi
GODOT=${GODOT:-$ROOT/tools/.bin/godot}
[ -x "$GODOT" ] || GODOT=$(command -v godot || true)
# a fresh clone has no godot/.godot yet: import once, or Godot knows none of the project's script
# classes (WormholeSpace...) in a test script
import_once() {
	[ -d "$ROOT/godot/.godot" ] || "$GODOT" --headless --path "$ROOT/godot" --import >/dev/null 2>&1
}
