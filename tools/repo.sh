# Sourced by the tools after they set ROOT (the tree they are in): REPO, the repository's own folder,
# which holds .wt/, also when the tool runs from a task's worktree (.wt/<branch>, tools/box.sh).
REPO=$(cd "$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)/.." 2>/dev/null && pwd) || REPO=$ROOT
