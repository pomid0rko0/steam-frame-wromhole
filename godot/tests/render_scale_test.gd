extends SceneTree
## Dynamic resolution (render_scale.gd) against a simulated headset GPU, 72 Hz: a frame costs
## fixed + per_pixel * scale^2 ms, and the measurement the controller sees is two frames old.
## Exit status 1 on any failure:
##   godot --headless --path . -s res://tests/render_scale_test.gd

const BUDGET := 1000.0 / 72.0
const DT := 1.0 / 72.0

var fails := 0


func _check(name: String, ok: bool, detail: String) -> void:
	print(("PASS " if ok else "FAIL ") + name + "  " + detail)
	if not ok:
		fails += 1


## Runs seconds of frames at a cost (fixed, per_pixel); returns [changes, worst ms after the
## first second, scale at the end].
func _run(rs: RenderScale, seconds: float, fixed: float, per_pixel: float) -> Array:
	var lag: Array[float] = [0.0, 0.0]
	var changes := 0
	var worst := 0.0
	var n := int(seconds / DT)
	for i in n:
		var cost := fixed + per_pixel * rs.scale() * rs.scale()
		lag.append(cost)
		if rs.update(lag.pop_front(), BUDGET, DT):
			changes += 1
		if i * DT > 1.0:
			worst = maxf(worst, cost)
	return [changes, worst, rs.scale()]


func _initialize() -> void:
	var rs := RenderScale.new()
	var r := _run(rs, 10.0, 1.5, 7.9)            # the start: 9.4 ms
	_check("the start view keeps full resolution", r[0] == 0 and r[2] == 1.0, "changes %d, scale %.1f" % [r[0], r[2]])

	r = _run(rs, 10.0, 1.5, 16.5)                # the shell's edge: 18 ms at full resolution
	_check("the edge lowers the resolution", r[2] < 1.0, "scale %.1f" % r[2])
	_check("then every frame fits", r[1] <= BUDGET * RenderScale.HIGH, "worst %.1f ms of %.1f" % [r[1], BUDGET])
	_check("and it settles: no back and forth", r[0] <= 2, "changes %d" % r[0])

	r = _run(rs, 10.0, 1.5, 7.9)                 # back to the start
	_check("back at the start, full resolution again", r[2] == 1.0, "scale %.1f" % r[2])

	r = _run(rs, 5.0, 2.0, 40.0)                 # far too heavy
	_check("a view far too heavy stops at the lowest step", r[2] == RenderScale.STEPS[-1], "scale %.1f" % r[2])

	var rs2 := RenderScale.new()
	var changed := false
	for i in 200:
		changed = rs2.update(0.0, BUDGET, DT) or changed
	_check("no measurement, no change", not changed and rs2.scale() == 1.0, "scale %.1f" % rs2.scale())

	# a single long frame (a hitch) is not a reason to drop the resolution
	var rs3 := RenderScale.new()
	changed = false
	for i in 300:
		changed = rs3.update(30.0 if i == 100 else 9.4, BUDGET, DT) or changed
	_check("one long frame changes nothing", not changed, "scale %.1f" % rs3.scale())

	print("FAILURES: ", fails)
	quit(1 if fails > 0 else 0)
