#!/bin/bash
# The tests on the Steam Frame itself. SteamOS has a read-only root, no apt, no lavapipe and no
# Monado, so they run in an Ubuntu container (podman), set up as a cloud session is (setup.sh's
# apt and pip steps): lavapipe, xvfb, Monado, EGL, the Python packages, Turnip's drm-shim once
# `tools/box.sh tools/setup.sh adreno` built it. It sees only this repository, at the same path:
# no GPU, no display, no SteamVR, so a test can't reach the headset the owner is wearing, and its
# renders run on the CPU cores Steam gives desktop apps (they inherit the editor's affinity).
#   tools/box.sh tools/test_stereo.sh       (any command, in the same directory there)
#   tools/box.sh env JOBS=3 tools/test_stereo.sh
# Made on first use (~5 min) and kept, stopped or not; `podman rm -f wormhole-box` throws it away.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
NAME=wormhole-box
IMAGE=docker.io/library/ubuntu:24.04
if ! podman container exists $NAME; then
	podman run -d --name $NAME --init -v "$ROOT:$ROOT" -w "$ROOT" $IMAGE sleep infinity >/dev/null
fi
[ "$(podman inspect -f '{{.State.Running}}' $NAME)" = true ] || podman start $NAME >/dev/null
# set up once; a setup that stopped halfway runs again
if ! podman exec $NAME test -f /box-ready; then
	echo "setting up the $NAME container"
	podman exec $NAME sh -c 'apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
		curl unzip xauth python3-pip >/dev/null'
	podman exec -w "$ROOT" $NAME tools/setup.sh apt pip
	podman exec $NAME touch /box-ready
fi
case $PWD/ in "$ROOT"/*) dir=$PWD ;; *) dir=$ROOT ;; esac
exec podman exec -i -w "$dir" $NAME "$@"
