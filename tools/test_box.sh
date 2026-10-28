#!/bin/bash
# What tools/box.sh promises, run on the Steam Frame (elsewhere there is no container): the
# container's limits are box.sh's; a stopped run leaves nothing running in it; two runs at once keep
# their files apart; test_openxr.sh's Monado is where no other run's Godot finds it; a fresh
# worktree under .wt/ runs the tests, with its files where the host sees them and git's status
# clean; the container is set up by one box.sh at a time. Run it after a change to box.sh, env.sh
# or the tools that use them; its worktree is made from HEAD, so commit first.
#   tools/test_box.sh        (exit status 0 only if every check passes; ~3 min)
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
if command -v apt-get >/dev/null || ! command -v podman >/dev/null; then
	echo "tools/test_box.sh: only where box.sh uses its container (the Frame)"; exit 2
fi
NAME=wormhole-box
TMP=$(mktemp -d)
failed=0
check() {   # name, condition (bash)
	if eval "$2"; then echo "PASS $1"; else echo "FAIL $1"; failed=1; fi
}
inside() {   # how many of the container's processes have a command line matching $1
	podman exec $NAME sh -c 'for c in /proc/[0-9]*/cmdline; do tr "\0" " " < "$c" 2>/dev/null; echo; done' \
		| grep -c -- "$1"
}

"$ROOT/tools/box.sh" true || { echo "FAIL box.sh"; exit 1; }
cg=/sys/fs/cgroup$(podman inspect -f '{{.State.CgroupPath}}' $NAME)
mem=$(numfmt --from=iec "$(sed -n 's/^MEM=\([0-9]*\)\([a-z]\).*/\1\U\2/p' "$ROOT/tools/box.sh")")
cpus=$(sed -n 's/^CPUS=\([0-9]*\).*/\1/p' "$ROOT/tools/box.sh")
check "the container's limits are box.sh's (MEM, no swap, CPUS)" \
	'[ "$(cat $cg/memory.max)" = "$mem" ] && [ "$(cat $cg/memory.swap.max)" = 0 ] && [ "$(cat $cg/cpu.max)" = "$((cpus * 100000)) 100000" ]'

"$ROOT/tools/box.sh" sh -c 'timeout 60 sleep 61 & timeout 60 sleep 62; wait' &
p=$!
sleep 4
started=$(inside '^sleep 6[12]')
kill -TERM $p
wait $p
sleep 1
check "a stopped run leaves nothing running (also what timeout started)" '[ "$started" = 2 ] && [ "$(inside "^sleep 6[12]")" = 0 ]'

"$ROOT/tools/test.sh" refresh_rate > "$TMP/a.txt" 2>&1 &
pa=$!
"$ROOT/tools/test.sh" refresh_rate > "$TMP/b.txt" 2>&1 &
pb=$!
wait $pa; ra=$?
wait $pb; rb=$?
oa=$(sed -n 's/^logs: //p' "$TMP/a.txt")
ob=$(sed -n 's/^logs: //p' "$TMP/b.txt")
check "two runs at once pass, each with files of its own the host sees" \
	'[ $ra = 0 ] && [ $rb = 0 ] && [ -n "$oa" ] && [ "$oa" != "$ob" ] && [ -f "$oa/refresh_rate.log" ] && [ -f "$ob/refresh_rate.log" ]'

"$ROOT/tools/test_openxr.sh" > "$TMP/openxr.txt" 2>&1 &
po=$!
for i in $(seq 120); do
	sock=$(find "$ROOT/.wt/.out" -maxdepth 2 -name monado_comp_ipc -newer "$TMP/a.txt" 2>/dev/null | head -1)
	[ -n "$sock" ] && break
	sleep 1
done
check "test_openxr.sh's Monado is in its own directory, not where any Godot looks" \
	'[ -n "$sock" ] && [ "$(podman exec $NAME sh -c "ls /tmp/monado_comp_ipc \${XDG_RUNTIME_DIR:-/nonexistent}/monado_comp_ipc 2>/dev/null" | wc -l)" = 0 ]'
wait $po

w=$ROOT/.wt/test-box-$$
git -C "$ROOT" worktree add -q --detach "$w" HEAD
"$w/tools/test.sh" refresh_rate > "$TMP/w.txt" 2>&1
rw=$?
ow=$(sed -n 's/^logs: //p' "$TMP/w.txt")
check "a fresh worktree runs the tests, its files where the host sees them" '[ $rw = 0 ] && [ -f "$ow/refresh_rate.log" ]'
check "the worktree's git status is clean" '[ -z "$(git -C "$w" status --porcelain)" ]'
git -C "$ROOT" worktree remove --force "$w"

podman exec $NAME sh -c 'echo 0 > /box-ready'
"$ROOT/tools/box.sh" true > "$TMP/s1.txt" 2>&1 &
p1=$!
"$ROOT/tools/box.sh" true > "$TMP/s2.txt" 2>&1 &
p2=$!
wait $p1; r1=$?
wait $p2; r2=$?
check "two box.sh at once set the container up once" \
	'[ $r1 = 0 ] && [ $r2 = 0 ] && [ "$(cat "$TMP/s1.txt" "$TMP/s2.txt" | grep -c "setting up")" = 1 ]'

rm -rf "$TMP"
if [ $failed = 0 ]; then echo "ALL PASS"; else echo "FAILED"; fi
exit $failed
