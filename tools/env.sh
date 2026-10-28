# Sourced first thing by the tools, after they set ROOT: the same commands in a cloud session and
# on the Steam Frame.
# On a machine without apt (the Frame's SteamOS) it runs the calling script again, with its
# arguments, in tools/box.sh's container (box.sh says why; without podman it stops), and the script
# goes on there past this line. Elsewhere (a cloud session, the container) it sets GODOT, the
# Godot the tools run, OUTS, where runs keep their files (in the repository: the host sees them
# too), and import_scripts.
# A task's worktree (.wt/<branch>, tools/box.sh) takes the repository's own tools/.bin, which git
# does not hold.
REPO=$(cd "$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)/.." 2>/dev/null && pwd) || REPO=$ROOT
[ "$REPO" = "$ROOT" ] || [ -e "$ROOT/tools/.bin" ] || ln -s "$REPO/tools/.bin" "$ROOT/tools/.bin"
if ! command -v apt-get >/dev/null; then
	exec "$ROOT/tools/box.sh" "$(readlink -f "$0")" "$@"
fi
GODOT=${GODOT:-$ROOT/tools/.bin/godot}
[ -x "$GODOT" ] || GODOT=$(command -v godot || true)
OUTS=$REPO/.wt/out
mkdir -p "$OUTS"
# A Godot run with -s knows the project's script classes (WormholeSpace...) only from an import:
# import when there was none or a script changed since.
import_scripts() {
	local stamp=$ROOT/godot/.godot/imported
	[ -f "$stamp" ] && [ -z "$(find "$ROOT/godot" -name '*.gd' -newer "$stamp" -print -quit)" ] && return 0
	"$GODOT" --headless --path "$ROOT/godot" --import >/dev/null 2>&1
	touch "$stamp"
}
