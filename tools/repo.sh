# Sourced by the tools after they set ROOT (the tree they are in), before anything else.
# On NixOS a tool runs in flake.nix's shell, the tools' environment there (what it gives and why:
# its top): outside it, the tool runs again, with its arguments, inside it, the flake of its own tree.
if [ -z "${WORMHOLE_SHELL:-}" ] && [ -f /etc/NIXOS ]; then
	exec nix develop --option warn-dirty false "$ROOT" --command "$(readlink -f "$0")" "$@"
fi
# REPO, the repository's own folder, which holds .wt/, also when the tool runs from a task's
# worktree (.wt/<branch>, tools/box.sh).
REPO=$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) && REPO=$(cd "$REPO/.." && pwd) || REPO=$ROOT
