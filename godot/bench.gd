extends Node
## The speed check, "замер" on the frame rate panel. Where one stands and looks changes the cost
## of a frame several times over, so frame times from walking around do not compare between two
## builds. This puts the viewer at fixed places on the axis through the throat, facing it (and
## once facing away), and times the ray tracer there on the GPU.
##
## A build can carry other ray tracers: tools/ab_shaders.sh copies them from earlier commits (or
## from a directory) into res://shaders/ab/1, 2, ... before the export. Then every place is timed
## with each of them and with this build's own, in a palindrome order (1 2 .. n n .. 2 1: a slow
## drift, of heat or clock, falls on all alike), and the panel says how much faster or slower this
## build's ray tracer is than the first of them. The log gets a line per place.
##
## A build made for measuring (tools/ab_shaders.sh --auto) runs it by itself, twice over, once the
## headset has tracked the head for AUTO_AFTER seconds: start it, put the headset on, close the
## eyes, and send the log afterwards.
##
## The refresh rate is set to 72 Hz meanwhile: a frame that misses its refresh makes SteamVR step
## in, and the GPU time then grows by half for reasons of its own. Render scale 100%. Afterwards
## the rate, the scale, the shader and where one stood come back.

const AB_DIR := "res://shaders/ab/%d/wormhole.gdshader"
const AUTO := "res://shaders/ab/auto"      # present: run by itself
const AUTO_AFTER := 10.0        # s of head tracking before it starts by itself
const AUTO_ROUNDS := 2
const PLACES := [   # [l, facing the throat]
	[11.6, true],   # the start
	[6.2, true],    # just outside the curved zone: the wormhole fills the view
	[5.0, true],    # inside, at the edge
	[5.0, false],   # the same, facing away: every ray starts in the curved zone
	[0.0, true],    # in the throat
]
const RATE := 72.0
const RATE_WAIT := 6.0          # s for the headset to follow the rate request
const PREPARE := 2.0            # s each ray tracer runs before the timing (its pipeline is compiled)

var main: Node                  # main.gd
var panel: Node                 # perf_panel.gd
var warm := 0.4                 # s after each switch, not timed
var time := 1.0                 # s timed per segment
var running := false
var others: Array = []          # [label, Shader] from res://shaders/ab/
var variants: Array = []        # this run's: others (if the scene has no movable balls), then this build's
var plan: Array = []            # segments: [place index, variant index]
var step := -1                  # the segment running
var phase_t := 0.0
var gpu_ms: Array = []          # this segment's frames
var clock_lo := 0
var clock_hi := 0
var results: Array = []         # per place: per variant, the segments' GPU ms (the median frame:
                                # a hitch of the system does not move it)
var saved_pose: Array
var saved_rate := 0.0           # the rate to go back to; 0: it was not changed
var saved_scale := 1.0
var waiting_rate := false
var preparing := 0              # variants left to run untimed before the first segment
var rounds := 1                 # every place this many times over
var auto := false               # start by itself (once)
var auto_t := 0.0


func _ready() -> void:
	for i in range(1, 10):
		var path := AB_DIR % i
		if not ResourceLoader.exists(path):
			break
		var sh: Shader = load(path)
		others.append([sh.code.get_slice("\n", 0).trim_prefix("//").strip_edges(), sh])
	auto = FileAccess.file_exists(AUTO)


func has_ab() -> bool:
	return not others.is_empty()


func start(n_rounds := 1) -> void:
	if running:
		return
	running = true
	rounds = n_rounds
	var own: Shader = main.material.shader
	# others are ray tracers without movable balls: compared only with the same kind
	variants = (others if own == main.SHADER_PLAIN else []) + [["this build", own]]
	saved_pose = main.get_pose()
	saved_scale = panel.render_scale
	panel._set_scale(1.0)
	waiting_rate = panel.xr != null and absf(panel.rate - RATE) > 0.5
	saved_rate = 0.0
	if waiting_rate:
		# back to this app's own setting where there is one, else to what the display ran at
		saved_rate = panel.stored if panel.steam_key != "" and panel.stored > 0.0 else panel.rate
		panel.choose_rate(RATE)
	var order: Array = range(variants.size())
	if variants.size() > 1:
		var back := order.duplicate()
		back.reverse()
		order += back
	plan.clear()
	results.clear()
	for i in PLACES.size():
		var r := []
		for v in variants:
			r.append([])
		results.append(r)
	for k in rounds:
		for i in PLACES.size():
			for v in order:
				plan.append([i, v])
	step = -1
	phase_t = 0.0
	preparing = variants.size()
	var names := []
	for i in variants.size():
		names.append("%d = %s" % [i + 1, variants[i][0]])
	print("bench: start, %s; %d places, %d round(s), %.1f s timed per segment"
			% [", ".join(names), PLACES.size(), rounds, time])
	# the picture changes every second or two, and some of the others are no proper picture at all
	_show("замер: закрой глаза, не двигай головой, ~%d с" % roundi(plan.size() * (warm + time) + preparing * PREPARE))
	if not waiting_rate:
		_prepare()


func _process(delta: float) -> void:
	if auto and not running:
		# by itself, once the headset has tracked the head for a while
		if panel.xr != null and not main.await_pose and panel.rate > 0.0:
			auto_t += delta
			var left := ceili(AUTO_AFTER - auto_t)
			if left != ceili(AUTO_AFTER - auto_t + delta):
				_show("замер начнётся через %d с: закрой глаза" % left)
			if auto_t >= AUTO_AFTER:
				auto = false
				start(AUTO_ROUNDS)
		return
	if not running:
		return
	phase_t += delta
	if waiting_rate:
		if absf(panel.rate - RATE) < 0.5 or phase_t > RATE_WAIT:
			waiting_rate = false
			_prepare()
		return
	if preparing > 0:
		if phase_t >= PREPARE:
			preparing -= 1
			if preparing > 0:
				_prepare()
			else:
				_begin(0)
		return
	if phase_t < warm:
		return
	if gpu_ms.is_empty():
		_clock()
	gpu_ms.append(RenderingServer.viewport_get_measured_render_time_gpu(panel.target.get_viewport_rid()))
	if phase_t >= warm + time:
		_clock()
		_end_segment()
		if step + 1 < plan.size():
			_begin(step + 1)
		else:
			_finish()


## Run a ray tracer untimed at the first place, so its pipeline is compiled before the timing.
func _prepare() -> void:
	phase_t = 0.0
	main.place_on_axis(PLACES[0][0], PLACES[0][1])
	main.material.shader = variants[variants.size() - preparing][1]


## The GPU's clock now (read twice a segment: a kernel file each frame is not free).
func _clock() -> void:
	var mhz: int = panel._gpu_mhz()
	if mhz > 0:
		clock_lo = mhz if clock_lo == 0 else mini(clock_lo, mhz)
		clock_hi = maxi(clock_hi, mhz)


func _begin(i: int) -> void:
	step = i
	var place: Array = PLACES[plan[i][0]]
	main.place_on_axis(place[0], place[1])
	main.material.shader = variants[plan[i][1]][1]
	phase_t = 0.0
	gpu_ms.clear()
	if i == 0 or plan[i][0] != plan[i - 1][0]:
		clock_lo = 0
		clock_hi = 0
		_show("замер: место %d из %d, глаза закрыты" % [(i / (plan.size() / rounds)) * PLACES.size() + plan[i][0] + 1,
				PLACES.size() * rounds])


func _end_segment() -> void:
	var r: Array = results[plan[step][0]]
	gpu_ms.sort()
	r[plan[step][1]].append(gpu_ms[gpu_ms.size() / 2] if not gpu_ms.is_empty() else 0.0)
	var last: bool = step + 1 >= plan.size() or plan[step + 1][0] != plan[step][0]
	if not last:
		return
	var place: Array = PLACES[plan[step][0]]
	var per := 2 if variants.size() > 1 else 1     # segments per variant in a block
	var parts := []
	var segs := []
	for v in variants.size():
		var block: Array = r[v].slice(r[v].size() - per)
		var s := "%d: %.2f ms" % [v + 1, _mean(block)]
		if v > 0:
			s += " (%.3f)" % (_mean(block) / _mean(r[0].slice(r[0].size() - per)))
		parts.append(s)
		segs.append(_list(block))
	print("bench: round %d, l %.1f m %s: %s; %.0f Hz, gpu clock %d..%d MHz, segments %s"
			% [step / (plan.size() / rounds) + 1, place[0], "facing the throat" if place[1] else "facing away",
			", ".join(parts), panel.rate, clock_lo, clock_hi, " ".join(segs)])


func _finish() -> void:
	running = false
	main.material.shader = variants.back()[1]
	main.set_pose(saved_pose)
	panel._set_scale(saved_scale)
	if saved_rate > 0.0:
		panel.choose_rate(saved_rate)
	if variants.size() == 1:
		print("bench: done")
		_show("замер готов, он в логе")
		return
	# each variant against the first, averaged over the places (geometric mean)
	var own := variants.size() - 1
	var summary := []
	var own_mean := 1.0
	for v in range(1, variants.size()):
		var log_sum := 0.0
		for r in results:
			log_sum += log(_mean(r[v]) / _mean(r[0]))
		var m := exp(log_sum / results.size())
		summary.append("%d/1 %.3f" % [v + 1, m])
		if v == own:
			own_mean = m
	print("bench: done, on average over the places %s (1 = %s)" % [", ".join(summary), variants[0][0]])
	var pct := roundi(absf(1.0 - own_mean) * 100.0)
	var verdict := "новый и прежний одинаковы"
	if own_mean < 0.98:
		verdict = "новый быстрее прежнего на %d%%" % pct
	elif own_mean > 1.02:
		verdict = "новый медленнее прежнего на %d%%" % pct
	_show(verdict)


static func _mean(v: Array) -> float:
	var s := 0.0
	for x in v:
		s += x
	return s / v.size() if v.size() > 0 else 0.0


static func _list(v: Array) -> String:
	var parts := []
	for x in v:
		parts.append("%.2f" % x)
	return "[" + ", ".join(parts) + "]"


func _show(s: String) -> void:
	panel.bench_status(s)
