#!/bin/bash
# Runs a command where the tests run: on the Steam Frame (SteamOS: no apt, a read-only root, no
# lavapipe, no Monado) in an Ubuntu container (podman), set up with setup.sh's apt and pip steps:
# lavapipe, xvfb, Monado, EGL, the Python packages. It sees only this repository, at the same
# path: no GPU, no display, no SteamVR, so a test can't reach the headset the owner is wearing, and
# its renders run on the CPU cores Steam gives desktop apps (they inherit the editor's affinity).
# On the Frame's host Godot takes SteamVR as its OpenXR runtime unless XR_RUNTIME_JSON points
# elsewhere, and gamescope's Vulkan layer puts its swapchains on the owner's screen even under
# xvfb-run; without the layer Turnip finds no queue that presents to Xvfb, and there is no lavapipe.
# Anywhere with apt (a cloud session, the container itself) it runs the command right here.
#   tools/box.sh python3 ref/test_gpu.py       (any command, in the same directory there)
# The tools go there by themselves (tools/env.sh), so this is for commands of one's own.
# Made on first use (~5 min) and kept, stopped or not; `podman rm -f wormhole-box` throws it away.
set -euo pipefail
if command -v apt-get >/dev/null || ! command -v podman >/dev/null; then exec "$@"; fi
ROOT=$(cd "$(dirname "$0")/.." && pwd)
NAME=wormhole-box
IMAGE=docker.io/library/ubuntu:24.04
SETUP=2   # what the setup below makes; a container set up by an older one is set up again
if ! podman container exists $NAME; then
	podman run -d --name $NAME --init -v "$ROOT:$ROOT" -w "$ROOT" $IMAGE sleep infinity >/dev/null
fi
[ "$(podman inspect -f '{{.State.Running}}' $NAME)" = true ] || podman start $NAME >/dev/null
# a setup that stopped halfway runs again
if [ "$(podman exec $NAME cat /box-ready 2>/dev/null)" != $SETUP ]; then
	echo "setting up the $NAME container"
	podman exec $NAME sh -c 'apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
		curl unzip xauth python3-pip git >/dev/null'
	podman exec -w "$ROOT" $NAME tools/setup.sh apt pip
	podman exec $NAME sh -c "echo $SETUP > /box-ready"
fi
# the tools' own settings go along (JOBS=3 tools/test_stereo.sh), nothing else of this machine's
# environment: Steam's and the session's would point Godot at SteamVR and the owner's screen
envs=()
for v in $(compgen -e); do
	case $v in JOBS|OUT|GODOT|MESA|KEEP_LOG|WH_*) envs+=(-e "$v=${!v}") ;; esac
done
case $PWD/ in "$ROOT"/*) dir=$PWD ;; *) dir=$ROOT ;; esac
# A command stopped here (a timeout, Ctrl-C, a background task stopped) would go on running in the
# container: podman exec does not pass the signal on. So it runs there as a process group of its
# own, its id in a file, and a signal here stops that group.
tag=/tmp/box-$$-$RANDOM
podman exec -i "${envs[@]}" -w "$dir" $NAME setsid -w sh -c \
	'echo $$ > "$0"; "$@"; s=$?; rm -f "$0"; exit $s' "$tag" "$@" <&0 &
run=$!
stop() {
	podman exec $NAME sh -c 'for i in 1 2 3 4 5 6 7 8 9 10; do [ -s "$0" ] && break; sleep 0.2; done
		g=$(cat "$0") && /bin/kill -TERM -- -"$g" && sleep 2 && /bin/kill -KILL -- -"$g" 2>/dev/null; rm -f "$0"' "$tag" 2>/dev/null
	wait $run
	exit "$1"
}
trap 'stop 130' INT
trap 'stop 143' TERM
trap 'stop 129' HUP
wait $run
