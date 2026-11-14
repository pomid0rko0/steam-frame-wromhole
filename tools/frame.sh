#!/usr/bin/env bash
# The Steam Frame from here (the PC, or the Frame itself): puts a headset build where its Steam
# library entry runs it, starts and stops it the way the library's button does, runs the speed
# check (bench.gd) with nobody in the headset, and reads its log. Only while the owner said in the
# chat that the headset is not on them, or let it run (CLAUDE.md).
#   tools/frame.sh put [--check] <build>     a build: tools/export.sh's zip for the headset, or a
#                                            commit or branch, whose CI build it downloads
#   tools/frame.sh run [--bench] [<build>]   (puts <build> first) starts it; --bench: the speed check,
#                                            the app quitting after it; prints its result's lines
#   tools/frame.sh stop                      stops it; the headset stands by again unworn
#   tools/frame.sh log [lines]               the last start's log (the running one's)
# Stereo before headset (CLAUDE.md, the hard rule): a build goes on only when every share of CI's
# stereo test (one per line of tools/stereo_parts.txt: «…стерео-тест n») passed on exactly its
# commit; put waits for CI while they run. A build of a tree that differs from its commit ("+" after
# the commit in its name) never goes on. No older build is kept: the library's entry is the one.
# Nobody wearing it, the Frame stands by after 5 s (vrserver.txt: "entering standby"): SteamVR
# pauses its compositor, the session never gets visible and Godot draws nothing (the log's
# "refresh:" lines: gpu 0.00 ms, no "XR session visible"). run sets power.pauseCompositorOnStandby
# off and power.turnOffScreensTimeout to an hour through vrcmd, which SteamVR takes at once; stop
# and the end of --bench set SteamVR's defaults back (true, 5 s).
# Where: WH_FRAME (default steamos@frame.local; .local names through avahi where the system's
# resolver has no mDNS), by an SSH key (ssh-copy-id once); on the Frame itself, right here.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
APP=wormhole-vr/wormhole_vr.arm64     # under the Frame's $HOME: the Steam library's entry
DATA=".local/share/godot/app_userdata/Wormhole VR"   # the app's user data there

# --- on the Frame ------------------------------------------------------------------------------
if [ "${1:-}" = --here ]; then
	shift
	EXE=$HOME/$APP
	LOGS=$HOME/$DATA/logs
	VRCMD=/opt/steamvr/bin/linuxarm64/vrcmd
	vrcmd() { env LD_PRELOAD= LD_LIBRARY_PATH="${VRCMD%/*}" "$VRCMD" "$@"; }
	running() { pgrep -f "^$EXE" >/dev/null; }
	awake() {   # on: the headset draws unworn; off: SteamVR's defaults
		if [ "$1" = on ]; then
			vrcmd --set-settings-bool power.pauseCompositorOnStandby false
			vrcmd --set-settings-float power.turnOffScreensTimeout 3600
		else
			vrcmd --set-settings-bool power.pauseCompositorOnStandby true
			vrcmd --set-settings-float power.turnOffScreensTimeout 5
		fi
		vrcmd --handlewakeup >/dev/null 2>&1 &   # it stays running: it waits for SteamVR's events
		sleep 1
		kill $! 2>/dev/null || true
	}
	stop() {
		pkill -f "^$EXE" 2>/dev/null || true
		for _ in $(seq 20); do running || break; sleep 0.5; done
		pkill -9 -f "^$EXE" 2>/dev/null || true
	}
	game_id() {   # the library's id of the shortcut that runs $EXE: steam://rungameid/<it>
		python3 - "$EXE" <<'EOF'
import glob, os, struct, sys
exe = sys.argv[1].encode()
for f in glob.glob(os.path.expanduser("~/.local/share/Steam/userdata/*/config/shortcuts.vdf")):
    d = open(f, "rb").read()
    i = d.find(b'"' + exe + b'"')
    j = d.rfind(b"\x02appid\x00", 0, i) if i >= 0 else -1
    if j >= 0:
        app = struct.unpack("<I", d[j + 7:j + 11])[0]
        print(app << 32 | 0x02000000)
        break
EOF
	}
	case $1 in
		put)
			stop
			mkdir -p "${EXE%/*}"
			chmod +x "$HOME/$2"
			mv -f "$HOME/$2" "$EXE"
			[ -n "$(game_id)" ] || echo "not in the Steam library yet: steamos-add-to-steam $EXE adds it (once)"
			;;
		run)
			id=$(game_id)
			[ -n "$id" ] || { echo "$EXE is not in the Steam library: steamos-add-to-steam $EXE adds it (once)"; exit 1; }
			stop
			awake on
			ASK=$HOME/$DATA/bench_at_start   # bench.gd's ASKED
			[ "${2:-}" != --bench ] || : > "$ASK"
			t0=$(date +%s)
			steam "steam://rungameid/$id" >/dev/null 2>&1 &
			for _ in $(seq 60); do
				[ "$(stat -c %Y "$LOGS/godot.log" 2>/dev/null || echo 0)" -lt "$t0" ] \
					|| ! grep -q '^build:' "$LOGS/godot.log" || break
				sleep 1
			done
			grep -m1 '^build:' "$LOGS/godot.log" 2>/dev/null || { echo "it did not start within a minute"; rm -f "$ASK"; awake off; exit 1; }
			[ "${2:-}" = --bench ] || exit 0
			# the check takes minutes; the app quits after it (bench.gd, start_if_asked)
			for _ in $(seq 3600); do running || break; sleep 1; done
			running && { echo "the speed check did not end within an hour"; stop; }
			awake off
			grep -q '^bench: done' "$LOGS/godot.log" || { echo "the speed check did not finish:"; tail -5 "$LOGS/godot.log"; exit 1; }
			grep -E '^(bench: (start|compared)|tour: (start|done|.*without a new frame))' "$LOGS/godot.log"
			;;
		stop) stop; rm -f "$HOME/$DATA/bench_at_start"; awake off ;;
		log) tail -n "${2:-60}" "$LOGS/godot.log" ;;
		cat) cat "$LOGS/godot.log" ;;
	esac
	exit 0
fi

# --- here, on the PC ---------------------------------------------------------------------------
. "$ROOT/tools/repo.sh"
. "$ROOT/tools/env.sh"
cd "$ROOT"   # gh's {owner}/{repo}: this repository's
HOST=${WH_FRAME:-steamos@frame.local}
if grep -qsx 'ID=steamos' /etc/os-release; then
	frame() { bash "$ROOT/tools/frame.sh" --here "$@"; }
	copy() { cp "$1" "$HOME/$2"; }
else
	if [[ $HOST == *.local ]] && ! getent hosts "${HOST#*@}" >/dev/null; then
		ip=$(avahi-resolve -4 -n "${HOST#*@}" 2>/dev/null | cut -f2) || true
		[ -n "$ip" ] || { echo "the Frame (${HOST#*@}) is not on this network: is it on?"; exit 2; }
		HOST=${HOST%@*}@$ip
	fi
	SSH=(ssh -o BatchMode=yes -o ConnectTimeout=5 "$HOST")
	frame() { "${SSH[@]}" bash -s -- --here "$@" < "$ROOT/tools/frame.sh"; }
	copy() { scp -q -o BatchMode=yes "$1" "$HOST:$2"; }
	"${SSH[@]}" true 2>/dev/null || { echo "no SSH into $HOST by key: ssh-copy-id $HOST (once)"; exit 2; }
fi

# Is every share of CI's stereo test passed on commit $1? 0 yes, 1 no (it says why), 3 not yet.
stereo_passed() {
	local n runs
	n=$(git -C "$ROOT" show "$1:tools/stereo_parts.txt" | grep -vc '^#')
	runs=$(gh api "repos/{owner}/{repo}/commits/$1/check-runs" --paginate \
		--jq '.check_runs[] | select(.name | test("(^Стерео-тест|, стерео-тест) [0-9]+$")) | "\(.name | sub(".* "; "")) \(.status) \(.conclusion)"')
	local i line
	for i in $(seq "$n"); do
		line=$(grep -m1 "^$i " <<<"$runs" || true)
		case $line in
			"$i completed success") ;;
			"$i completed "*) echo "CI's stereo test, part $i, did not pass on $1: this build must not go on"; return 1 ;;
			*) return 3 ;;
		esac
	done
}

put() {
	local check="" build=$1 commit file tmp
	[ "$build" != --check ] || { check=_check; build=$2; }
	tmp=$(mktemp -d)
	trap 'rm -rf "$tmp"' RETURN
	if [ -f "$build" ]; then
		[[ $build =~ _([0-9a-f]{7,})(\+?)_steam_frame\.zip$ ]] || { echo "$build: not tools/export.sh's zip for the headset"; return 1; }
		[ -z "${BASH_REMATCH[2]}" ] || { echo "$build: godot/ differed from its commit: commit and export again"; return 1; }
		commit=$(git -C "$ROOT" rev-parse "${BASH_REMATCH[1]}^{commit}")
		python3 -c 'import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extract("wormhole_vr.arm64", sys.argv[2])' "$build" "$tmp"
	else
		git -C "$ROOT" fetch -q origin 2>/dev/null || true
		commit=$(git -C "$ROOT" rev-parse "origin/$build^{commit}" 2>/dev/null || git -C "$ROOT" rev-parse "$build^{commit}")
	fi
	local s=0 waited=0
	while :; do
		stereo_passed "$commit" && break || s=$?
		[ $s = 3 ] || return 1
		[ $waited -lt 3600 ] || { echo "CI's stereo test on $commit has not ended in an hour"; return 1; }
		[ $waited -gt 0 ] || echo "CI's stereo test on ${commit:0:7} still runs: waiting for it"
		sleep 30
		waited=$((waited + 30))
	done
	if [ ! -f "$build" ]; then
		local run name
		run=$(gh run list --commit "$commit" --workflow ci.yml --json databaseId,event \
			--jq '[.[] | select(.event == "push")][0].databaseId')
		[ -n "$run" ] || { echo "no CI run of $commit"; return 1; }
		name=$(gh api "repos/{owner}/{repo}/actions/runs/$run/artifacts" --jq '.artifacts[].name' \
			| grep -E "_${commit:0:7}_steam_frame\.zip$" | grep $([ -n "$check" ] || echo -v) _check_ | head -1)
		[ -n "$name" ] || { echo "CI's run $run has no headset build${check:+ for the one-eye check}"; return 1; }
		gh run download "$run" -n "$name" -D "$tmp"
		[ -f "$tmp/wormhole_vr.arm64" ] || python3 -c 'import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extract("wormhole_vr.arm64", sys.argv[2])' "$tmp/$name" "$tmp"
	fi
	copy "$tmp/wormhole_vr.arm64" "$APP.new"
	frame put "$APP.new"
	echo "on the Frame: ${commit:0:7}$check (stereo test passed in CI)"
}

case ${1:-} in
	put) shift; put "$@" ;;
	run)
		shift
		bench=""
		[ "${1:-}" != --bench ] || { bench=--bench; shift; }
		[ $# = 0 ] || put "$@"
		frame run $bench
		if [ -n "$bench" ]; then
			mkdir -p "$OUTS"
			log=$OUTS/frame_bench_$(date +%Y%m%d_%H%M%S).log
			frame cat > "$log"
			echo "the whole log: $log"
		fi
		;;
	stop) frame stop ;;
	log) frame log "${2:-60}" ;;
	*) sed -n '6,12p' "$0"; exit 2 ;;
esac
