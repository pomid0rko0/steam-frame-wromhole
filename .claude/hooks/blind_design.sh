#!/usr/bin/env bash
# CLAUDE.md's first rule, "a wish starts from a blind design": the blind-designer agent
# (.claude/agents/blind-designer.md) can't read the repository, so its design isn't anchored on
# what is here. Claude Code runs this script (.claude/settings.json), with the hook's JSON on stdin:
#   done: that agent has finished; the current branch is marked as asked;
#   stop: the main agent ends a turn; on a feat/… branch that differs from origin/main (committed
#         or not), isn't marked and has no blind design running, it is sent back to ask for one.
# The mark is git's common dir's blind-design/<branch>, so a clone's worktrees share it and a fresh
# clone (a new cloud session) asks again. A turn already sent back by a stop hook
# (stop_hook_active) ends as it is, so the hook never loops. Only bash, git and grep: it runs as it
# is on the Frame (it opens no GPU, so not through tools/box.sh) and in a cloud session.
set -u
input=$(cat)
dir=${CLAUDE_PROJECT_DIR:-$PWD}
branch=$(git -C "$dir" symbolic-ref --short -q HEAD) || exit 0
common=$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir) || exit 0
mark=$common/blind-design/${branch//\//-}

case ${1:-} in
done)
  mkdir -p "${mark%/*}" && date -u +%FT%TZ >"$mark"
  ;;
stop)
  [[ $branch == feat/* ]] || exit 0
  [ -e "$mark" ] && exit 0
  grep -Eq '"stop_hook_active" *: *true' <<<"$input" && exit 0
  # one running in the background: its end marks the branch
  grep -Eq '"agent_type" *: *"blind-designer"' <<<"$input" && exit 0
  base=$(git -C "$dir" merge-base origin/main HEAD 2>/dev/null) || exit 0
  git -C "$dir" diff --quiet "$base" -- &&
    [ -z "$(git -C "$dir" ls-files --others --exclude-standard)" ] && exit 0
  # the message: no " or \ (it goes into JSON as it is)
  msg="This wish's branch has changes and no blind design yet (CLAUDE.md, the first rule)."
  msg+=" Before you finish, brief the blind-designer agent with only what: what the person in"
  msg+=" the headset sees and can do, the Frame, the checks; nothing of how it is done now."
  msg+=" Weigh its design against the branch, and quote the brief and the design in the PR."
  printf '{"hookSpecificOutput":{"hookEventName":"Stop","additionalContext":"%s"}}\n' "$msg"
  ;;
esac
exit 0
