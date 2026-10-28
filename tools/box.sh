#!/bin/bash
# Runs a command where the tests run: on the Steam Frame (SteamOS: no apt, a read-only root, no
# lavapipe, no Monado) in an Ubuntu container (podman), set up once with all of tools/setup.sh. It
# sees only this repository, at the same
# path: no GPU, no display, no SteamVR, so a test can't reach the headset the owner is wearing, and
# its renders run on the CPU cores Steam gives desktop apps (they inherit the editor's affinity).
# On the Frame's host Godot takes SteamVR as its OpenXR runtime unless XR_RUNTIME_JSON points
# elsewhere, and gamescope's Vulkan layer puts its swapchains on the owner's screen even under
# xvfb-run; without the layer Turnip finds no queue that presents to Xvfb, and there is no lavapipe.
# Anywhere with apt (a cloud session, the container itself) it runs the command right here.
#   tools/box.sh python3 ref/test_gpu.py       (any command, in the same directory there)
# The tools go there by themselves (tools/env.sh), so this is for commands of one's own.
# Made on first use and kept, stopped or not; `podman rm -f wormhole-box` throws it away. It
# mounts only the repository's folder, and every task's runs share it: a task's git worktree goes
# under .wt/, one per task (git worktree add --detach .wt/<branch> <branch>), and each run of the
# tests keeps its files and its Monado in a directory of its own (test.sh, test_stereo.sh,
# test_openxr.sh).
set -euo pipefail
if command -v apt-get >/dev/null; then exec "$@"; fi
command -v podman >/dev/null || { echo "tools/box.sh: no apt and no podman: no place to run this off the headset" >&2; exit 2; }
ROOT=$(cd "$(dirname "$0")/.." && pwd)
# the repository's own folder, which holds .wt/, also when this runs from a worktree
REPO=$(cd "$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)/.." 2>/dev/null && pwd) || REPO=$ROOT
NAME=wormhole-box
IMAGE=docker.io/library/ubuntu:24.04
# SteamVR and the owner's view share this machine's memory and cores with the container: a stereo
# test with five renders at once and no memory limit can crash SteamVR; with two at once and the
# limits below it does not (the container's memory.peak after a stereo test, test.sh and
# test_openxr.sh: 2.4 GB). So the container
# gets at most one core's time and MEM of memory, no swap (a run that needs more fails in here, not
# SteamVR), and runs take JOBS renders at once (default 2).
CPUS=1
MEM=4g
MIN_FREE=1500   # MB
SETUP=4   # what the setup below makes; a container set up by an older one is set up again (one
          # set up by a newer box.sh, another branch's, already has all of it)
if ! podman container exists $NAME; then
	podman run -d --name $NAME --init --cpus $CPUS --memory $MEM --memory-swap $MEM \
		-v "$REPO:$REPO" -w "$REPO" $IMAGE sleep infinity >/dev/null
fi
podman update --cpus $CPUS --memory $MEM --memory-swap $MEM $NAME >/dev/null   # a container made without them
[ "$(podman inspect -f '{{.State.Running}}' $NAME)" = true ] || podman start $NAME >/dev/null
# podman update records the swap limit but leaves the cgroup's at max (podman 5.5): the Frame's
# swap is zram, in the same memory
cg=/sys/fs/cgroup$(podman inspect -f '{{.State.CgroupPath}}' $NAME)/memory.swap.max
[ ! -w "$cg" ] || echo 0 > "$cg"
podman inspect -f '{{range .Mounts}}{{.Destination}}{{"\n"}}{{end}}' $NAME | grep -qx "$REPO" \
	|| { echo "the $NAME container does not mount $REPO: podman rm -f $NAME makes it anew" >&2; exit 2; }
# the tools' own settings go along (JOBS=3 tools/test_stereo.sh), nothing else of this machine's
# environment: Steam's and the session's would point Godot at SteamVR and the owner's screen
envs=()
for v in $(compgen -e); do
	case $v in JOBS|OUT|GODOT|MESA|KEEP_LOG|WH_*) envs+=(-e "$v=${!v}") ;; esac
done
[ -n "${JOBS:-}" ] || envs+=(-e JOBS=2)
case $PWD/ in "$ROOT"/*) dir=$PWD ;; *) dir=$ROOT ;; esac
# A command stopped here (a timeout, Ctrl-C, a background task stopped) would go on running in the
# container: podman exec does not pass the signal on. So it runs there in a session of its own
# (timeout gives each Godot a process group of its own), its id in a file, and a signal here stops
# that session.
tag=""
run=""
stop() {
	[ -z "$tag" ] || podman exec $NAME sh -c 'for i in 1 2 3 4 5 6 7 8 9 10; do [ -s "$0" ] && break; sleep 0.2; done
		g=$(cat "$0") && pkill -TERM -s "$g"; sleep 2; pkill -KILL -s "$g"; rm -f "$0"' "$tag" 2>/dev/null
	[ -z "$run" ] || wait $run
	exit "$1"
}
trap 'stop 130' INT
trap 'stop 143' TERM
trap 'stop 129' HUP
inbox() {   # command...: runs it in the container, stopped with this script; its exit status
	tag=/tmp/box-$$-$RANDOM
	podman exec -i "${envs[@]}" -w "$dir" $NAME setsid -w sh -c \
		'echo $$ > "$0"; "$@"; s=$?; rm -f "$0"; exit $s' "$tag" "$@" <&0 &
	run=$!
	# and should the Frame still run low on memory (the owner's programs, other tasks), the run
	# stops before SteamVR does
	( while kill -0 $run 2>/dev/null; do
		a=$(awk '/^MemAvailable/ {print int($2 / 1024)}' /proc/meminfo)
		[ "$a" -ge $MIN_FREE ] || { echo "box.sh: $a MB of memory left on the Frame: stopping the run" >&2; kill -TERM $$; break; }
		sleep 2
	  done ) &
	local s=0
	wait $run || s=$?
	tag=""
	run=""
	return $s
}
# all of setup.sh, once; a setup that stopped halfway runs again; one at a time (another task's
# box.sh waits for it)
mkdir -p "$REPO/.wt"
exec 9>"$REPO/.wt/box-setup.lock"
flock 9
if [ "$(podman exec $NAME cat /box-ready 2>/dev/null || echo 0)" -lt $SETUP ]; then
	echo "setting up the $NAME container"
	inbox sh -c 'apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
		curl unzip xauth python3-pip git procps >/dev/null'
	inbox "$ROOT/tools/setup.sh"
	podman exec $NAME sh -c "echo $SETUP > /box-ready"
fi
exec 9>&-
inbox "$@"
