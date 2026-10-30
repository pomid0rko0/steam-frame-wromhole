class_name Bench
extends Node
## The speed check (menu.gd's row "bench"), in two parts. The eyes are best kept
## closed throughout: the world is turned and moved to the head, and some pictures are no proper
## ones.
##
## What a frame costs depends on the pose: how far from the throat one stands (l), where one looks
## (degrees from the throat along the floor, degrees up) and how the head is tilted (roll: it
## changes how pixels fall into the GPU's groups). With the toys still (main.hold stops them) and
## the viewer on the axis through the throat (main.place_on_axis), the pose decides what the ray
## tracer does. Besides it a frame's time changes with where the eyes look under foveation (the
## density map follows them: foveation.gd) and with SteamVR's half rate after a late frame (below).
##
## 1. Comparison, at RATE. The viewer is put at fixed poses (PLACES), with the feet held there,
## and the ray tracer is timed on the GPU (the median frame of each segment): this build's
## (tracer.gd, compute kernels) each way FOVEATIONS lists, and main's fragment ray tracer
## (frag_tracer.gd, in this build for the comparison) each way MAIN_WAYS lists, with the toys also
## over the whole view. A build can carry other fragment ray tracers in res://shaders/ab/1, 2, ...
## (tools/ab_shaders.sh), timed in main's: those of the kind this build runs. Every pose is timed
## with all of them in a palindrome order (1 2 .. n n .. 2 1: a slow drift of heat or clock falls on
## all alike). RATE is low because a frame that misses its refresh sends SteamVR to half rate
## (frame_rate.gd), and the GPU time then grows: a variant over the frame's budget reads dearer than
## it is, and so does the segment after it. Fewer instructions or registers
## (tools/adreno_stats.sh) are not faster by themselves, and frame times from walking around don't
## compare between builds (where one looks changes them): this part decides.
##
## 2. The tour (_make_tour), at TOUR_RATE if the display follows, with this build's ray tracer and
## the menu's foveation: does the rate hold all round, and where not. Each place starts from a cheap pose (TOUR_RECOVER),
## which is not enough to undo SteamVR's half rate (frame_rate.gd).
##
## Afterwards what it changed comes back (_restore, _finish). A build made for measuring
## (tools/ab_shaders.sh --auto) runs it by itself once the headset has tracked the head for
## AUTO_AFTER seconds: start it, put the headset on, close the eyes, send the log afterwards.

const RateMeter := preload("res://rate_meter.gd")
const AB_DIR := "res://shaders/ab/%d/wormhole.gdshader"
const AB_BALLS := "res://shaders/ab/%d/wormhole_balls.gdshader"   # the same source's, with the toys
const AUTO := "res://shaders/ab/auto"      # present: run by itself
const AUTO_AFTER := 10.0        # s of head tracking before it starts by itself
# l, in PLACES and TOUR_L: the start (main.START_POS); the other values are metres of l chosen
# against this throat's curved zone (edge L), which WormholeSpace.set_profile's list names
const START := INF
const PLACES := [   # the comparison's poses: [l, degrees to the right, degrees up] (place_on_axis)
	[START, 0.0, 0.0],
	[6.2, 0.0, 0.0],    # just outside the curved zone: the wormhole fills the view
	[6.2, 60.0, 0.0],
	[5.0, 0.0, 0.0],    # inside, at the edge: every ray starts in the curved zone
	[5.0, 90.0, 0.0],
	[5.0, 180.0, 0.0],  # facing away
	[5.0, 0.0, -35.0],  # down at the floor
	[5.0, 0.0, 35.0],   # up
	[0.0, 0.0, 0.0],    # in the throat
	[0.0, 90.0, 0.0],   # in the throat, looking sideways round it
	[-5.0, 180.0, 0.0], # world B, at the edge, facing the throat (boxes where A has pillars)
	[-5.7, 160.0, -5.0],  # world B at the edge, 20 deg from the throat
	[-6.2, 180.0, 0.0], # world B, just outside the curved zone, facing the throat
]
const RATE := 72.0
const RATE_WAIT := 6.0          # s for the headset to follow a rate request
const PREPARE := 2.0            # s each ray tracer runs before the timing (its pipeline is compiled)
const TOUR_RATE := 120.0
const TOUR_L := [START, 8.0, 6.2, 5.0, 4.0, 2.5, 0.0, -2.5, -5.0, -6.2]
const TOUR_PITCH := [-60.0, -30.0, 0.0, 30.0, 60.0]
const SWEEP := 2.0              # s for a row: 180 degrees
const TOUR_RECOVER := 1.5       # s at the start before each place, not counted
const NOD_PERIOD := 3.0         # s: the tour's nods
const TILT_PERIOD := 2.0        # s: its tilts (roll)
# this build's ray tracer: [label, foveation level (Foveation.set_level)]; the first is the one the
# others of this build are compared with
const FOVEATIONS := [["this build", 0], ["this build, low", 1], ["this build, high", 3],
	["this build, wide", 4], ["this build, narrow", 5]]
# main's fragment ray tracer: [label, foveation level, split]; the first is the reference of the
# whole comparison
const MAIN_WAYS := [["main's", 0, false], ["main's, SteamVR high", 3, false], ["main's, own narrow", 5, false]]

var main: Main
var menu: Menu                  # the result goes there; its render scale
var warm := 0.3                 # s after each switch, not timed
var time := 0.8                 # s timed per segment
var tour_scale := 1.0           # the tour's durations, scaled (tests)
var running := false
var phase := ""                 # rate, prepare, segments, tour
var _next := ""                 # the phase after a rate request
var others: Array[Other] = []   # from res://shaders/ab/
var variants: Array[Setup] = []   # this run's ray tracers (start)
var own := 0                    # the variant that is this build without foveation
var main_shader: Shader         # main's ray tracer as it runs
var plan: Array[Vector2i] = []  # segments: (place index, variant index)
var step := -1                  # the segment or tour step running
var phase_t := 0.0
var gpu_ms: Array = []          # this segment's frames
var clock_lo := 0
var clock_hi := 0
var results: Array = []         # per place: per variant, the segments' GPU ms (the median frame:
                                # a hitch of the system does not move it)
var tour: Array[Step] = []      # the tour's steps (_make_tour)
var tour_results: Array[Tally] = []   # per step
var meter := RateMeter.new()    # fed by main.rate each frame
var counting := false
var tour_t := 0.0               # s since the tour began counting (the "tf" lines' time)
var pose := [0.0, 0.0, 0.0, 0.0]     # the tour's pose now: l, degrees right, up, roll
var sec := Tally.new()          # this second's
var saved_pose: Array
var saved_rate := 0.0           # the rate to go back to
var preparing := 0              # variants left to run untimed before the first segment
var verdict := ""               # the comparison's line
var auto := false               # start by itself (once)
var auto_t := 0.0


func _ready() -> void:
	var i := 1
	while ResourceLoader.exists(AB_DIR % i):
		var sh: Shader = load(AB_DIR % i)
		var with_balls: Shader = load(AB_BALLS % i) if ResourceLoader.exists(AB_BALLS % i) else null
		others.append(Other.new(sh.code.get_slice("\n", 0).trim_prefix("//").strip_edges(), sh, with_balls))
		i += 1
	auto = FileAccess.file_exists(AUTO)


func has_ab() -> bool:
	return not others.is_empty()


## The others as variants of the kind this build runs now, in main's ray tracer: without toys, or
## with them (the demo's), theirs over the whole view: with the stencil test the whole view marked,
## without it no stencil at all; none with the gravity view on (theirs are without it).
func comparable() -> Array[Setup]:
	var out: Array[Setup] = []
	if main.tracer.gravity_view != 0:
		return out
	for o in others:
		if main.tracer.plain():
			out.append(Setup.new(o.label, true, o.shader, 0, false, FragTracer.BARE))
		elif o.balls != null:
			var with_stencil := o.balls.code.contains("stencil_mode")
			out.append(Setup.new(o.label, true, o.balls, 0, false, FragTracer.WHOLE if with_stencil else FragTracer.BARE))
	return out


## The tour's steps.
func _make_tour() -> Array[Step]:
	var t: Array[Step] = []
	var start_l := _l(START)
	for tl in TOUR_L:
		var l := _l(tl)
		for i in TOUR_PITCH.size():
			var y0 := 0.0 if i % 2 == 0 else 180.0
			t.append(_st(l, l, y0, 180.0 - y0, TOUR_PITCH[i], SWEEP,
					"l %.1f m, %.0f deg up, sweeping round" % [l, TOUR_PITCH[i]], i == 0))
	t.append(_st(start_l, -6.2, 0.0, 720.0, 0.0, 15.0, "walking from the start through the throat, turning and nodding", true, 30.0))
	t.append(_st(-6.2, start_l, 180.0, -540.0, 0.0, 15.0, "walking back, turning, nodding and tilting", true, 30.0, 20.0))
	for l in [6.2, 5.0, 0.0]:
		t.append(_st(l, l, 0.0, 360.0, 0.0, 4.0, "l %.1f m, turning round (yaw)" % l, true))
		t.append(_st(l, l, 0.0, 0.0, 0.0, 6.0, "l %.1f m, nodding 60 deg (pitch)" % l, false, 60.0))
		t.append(_st(l, l, 0.0, 0.0, 0.0, 4.0, "l %.1f m, tilting 30 deg (roll)" % l, false, 0.0, 30.0))
	return t


## A pose's l: START as the start's.
func _l(l: float) -> float:
	return main.space.point_from_chart(1.0, main.START_POS)[0] if is_inf(l) else l


func _st(l0: float, l1: float, y0: float, y1: float, p: float, secs: float, what: String,
		recover := false, nod := 0.0, roll := 0.0) -> Step:
	var st := Step.new()
	st.l = Vector2(l0, l1)
	st.yaw = Vector2(y0, y1)
	st.pitch = p
	st.nod = nod
	st.roll = roll
	st.secs = secs * tour_scale
	st.recover = recover
	st.what = what
	return st


func start() -> void:
	if running:
		return
	running = true
	var tracer: Tracer = main.tracer
	main_shader = main.frag.material.shader
	variants.clear()
	for w in MAIN_WAYS:
		variants.append(Setup.new(w[0], true, main_shader, w[1], w[2], FragTracer.SPLIT))
	if not tracer.plain():
		variants.append(Setup.new("main's, toys over the whole view", true, main_shader, 0, false, FragTracer.WHOLE))
	variants.append_array(comparable())
	own = variants.size()
	for f in FOVEATIONS:
		variants.append(Setup.new(f[0], false, null, f[1], false, FragTracer.SPLIT))
	saved_pose = main.get_pose()
	main.hold = true
	menu.target.scaling_3d_scale = 1.0     # the menu keeps the scale chosen (menu.render_scale)
	# back to this app's own setting where there is one, else to what the display ran at
	var rate: FrameRate = main.rate
	saved_rate = rate.stored if rate.steam_key != "" and rate.stored > 0.0 else rate.rate
	var order: Array = range(variants.size())
	if variants.size() > 1:
		var back := order.duplicate()
		back.reverse()
		order += back
	plan.clear()
	results.clear()
	tour = _make_tour()
	tour_results.clear()
	verdict = ""
	for i in PLACES.size():
		var r := []
		for v in variants:
			r.append([])
		results.append(r)
		for v: int in order:
			plan.append(Vector2i(i, v))
	step = -1
	preparing = variants.size()
	var names := []
	for i in variants.size():
		names.append("%d = %s" % [i + 1, variants[i].label])
	print("bench: start, %s; %d places, %.1f s timed per segment; gravity view %s"
			% [", ".join(names), PLACES.size(), time, Tracer.GRAVITY_VIEWS[tracer.gravity_view]])
	var tour_s := 0.0
	for s in tour:
		tour_s += s.secs + (TOUR_RECOVER * tour_scale if s.recover else 0.0)
	var total := plan.size() * (warm + time) + preparing * PREPARE + (tour_s if _headset() else 0.0)
	_show("замер: закрой глаза, не двигай головой, ~%d мин" % ceili(total / 60.0))
	_rate(RATE, "prepare")


## Ask for a rate (the headset only), then go on to the next phase.
func _rate(hz: float, next: String) -> void:
	phase_t = 0.0
	if _headset() and absf(main.rate.rate - hz) > 0.5:
		main.rate.choose(hz)
		phase = "rate"
		_next = next
	else:
		_enter(next)


func _enter(p: String) -> void:
	phase = p
	phase_t = 0.0
	if p == "prepare":
		_prepare()
	elif p == "tour":
		print("tour: start at %.0f Hz, foveation %d, %d steps; \"tf\" lines: s, l m, deg right, deg up, deg roll, refreshes the frame took, gpu ms, cpu ms render, cpu ms process"
				% [main.rate.rate, main.foveation.level, tour.size()])
		tour_t = 0.0
		_tour_step(0)


func _process(delta: float) -> void:
	if auto and not running:
		# by itself, once the headset has tracked the head for a while
		if _headset() and not main.await_pose and main.rate.rate > 0.0:
			auto_t += delta
			var left := ceili(AUTO_AFTER - auto_t)
			if left != ceili(AUTO_AFTER - auto_t + delta):
				_show("замер начнётся через %d с: закрой глаза" % left)
			if auto_t >= AUTO_AFTER:
				auto = false
				start()
		return
	if not running:
		return
	phase_t += delta
	match phase:
		"rate":
			if absf(main.rate.rate - (TOUR_RATE if _next == "tour" else RATE)) < 0.5 or phase_t > RATE_WAIT:
				_enter(_next)
		"prepare":
			if phase_t >= PREPARE:
				preparing -= 1
				if preparing > 0:
					_prepare()
				else:
					phase = "segments"
					_begin(0)
		"segments":
			_segment()
		"tour":
			_tour(delta)


# ---------------------------------------------------------------- the comparison

## Run a ray tracer untimed at the first place, so its pipeline is compiled before the timing.
func _prepare() -> void:
	phase_t = 0.0
	main.place_on_axis(_l(PLACES[0][0]), PLACES[0][1], PLACES[0][2])
	_use(variants[variants.size() - preparing])


## A variant's ray tracer and foveation.
func _use(v: Setup) -> void:
	main.set_frag(v.frag)
	if v.frag:
		main.frag.material.shader = v.shader
		main.frag.toy_mode = v.toy_mode
	var fov: Foveation = main.foveation
	if fov.level != v.foveation or fov.frag != v.frag or fov.split_pass.enabled != (v.frag and (v.foveation > 0 or v.split)):
		fov.set_level(v.foveation, v.split, v.frag)


func _segment() -> void:
	if phase_t < warm:
		return
	if gpu_ms.is_empty():
		_clock()
	gpu_ms.append(RenderingServer.viewport_get_measured_render_time_gpu(main.rate.target.get_viewport_rid()))
	if phase_t >= warm + time:
		_clock()
		_end_segment()
		if step + 1 < plan.size():
			_begin(step + 1)
		else:
			_compared()


## The GPU's clock now (read twice a segment: a kernel file each frame is not free).
func _clock() -> void:
	var mhz: int = main.rate.gpu_mhz()
	if mhz > 0:
		clock_lo = mhz if clock_lo == 0 else mini(clock_lo, mhz)
		clock_hi = maxi(clock_hi, mhz)


func _begin(i: int) -> void:
	step = i
	var place: Array = PLACES[plan[i].x]
	main.place_on_axis(_l(place[0]), place[1], place[2])
	_use(variants[plan[i].y])
	phase_t = 0.0
	gpu_ms.clear()
	if i == 0 or plan[i].x != plan[i - 1].x:
		clock_lo = 0
		clock_hi = 0
		_show("замер: место %d из %d, глаза закрыты" % [plan[i].x + 1, PLACES.size()])


func _end_segment() -> void:
	var r: Array = results[plan[step].x]
	gpu_ms.sort()
	r[plan[step].y].append(gpu_ms[gpu_ms.size() / 2] if not gpu_ms.is_empty() else 0.0)
	var last := step + 1 >= plan.size() or plan[step + 1].x != plan[step].x
	if not last:
		return
	var place: Array = PLACES[plan[step].x]
	var parts := []
	var segs := []
	for v in variants.size():
		var s := "%d: %.2f ms" % [v + 1, _mean(r[v])]
		if v > 0:
			s += " (%.3f)" % (_mean(r[v]) / _mean(r[0]))
		parts.append(s)
		segs.append(_list(r[v]))
	print("bench: l %.1f m, %.0f deg right, %.0f deg up: %s; %.0f Hz, gpu clock %d..%d MHz, segments %s"
			% [_l(place[0]), place[1], place[2], ", ".join(parts), main.rate.rate, clock_lo, clock_hi, " ".join(segs)])


func _compared() -> void:
	_restore()      # the tour runs with this build's ray tracer and the foveation chosen in the menu
	if variants.size() > 1:
		# each variant against the first (main's), averaged over the places (geometric mean)
		var summary := []
		for v in range(1, variants.size()):
			summary.append("%d/1 %.3f" % [v + 1, _ratio(v, 0)])
		print("bench: compared, on average over the places %s (1 = %s)" % [", ".join(summary), variants[0].label])
		var parts := []
		var m := _ratio(own, 0)
		var pct := roundi(absf(1.0 - m) * 100.0)
		parts.append("этот и main одинаковы" if absf(1.0 - m) <= 0.02 else
				"этот %s, чем main, на %d%%" % ["быстрее" if m < 1.0 else "медленнее", pct])
		# with foveation: this build's narrow against main's own narrow, the menu's usual
		var narrow := own + FOVEATIONS.size() - 1
		var m5 := _ratio(narrow, MAIN_WAYS.size() - 1)
		parts.append("с узкой фовеацией %s на %d%%" % ["быстрее" if m5 < 1.0 else "медленнее", roundi(absf(1.0 - m5) * 100.0)])
		# this build's foveation against itself without it
		summary.clear()
		for v in range(own + 1, variants.size()):
			summary.append("%s %.3f" % [variants[v].label.trim_prefix("this build, "), _ratio(v, own)])
		print("bench: this build's foveation, on average over the places against it without: %s" % ", ".join(summary))
		verdict = " · ".join(parts)
	if _headset():
		_show("замер: переключаю на %.0f Гц, глаза закрыты" % TOUR_RATE)
		_rate(TOUR_RATE, "tour")
	else:
		_finish("")


# ---------------------------------------------------------------- the tour

## The frame timing (main.rate), every frame: while counting, a "tf" line for the frame.
func frame_timing(display_time: int, period: int, expected_hz: float) -> void:
	var refreshes_before := meter.refreshes
	var frames_before := meter.frames
	meter.add(display_time, period, expected_hz)
	if not counting or meter.frames == frames_before:
		return
	var vp: RID = main.rate.target.get_viewport_rid()
	var g := RenderingServer.viewport_get_measured_render_time_gpu(vp)
	print("tf %.3f %.2f %.0f %.0f %.0f %d %.2f %.2f %.2f" % [tour_t, pose[0], pose[1], pose[2], pose[3],
			meter.refreshes - refreshes_before, g, RenderingServer.viewport_get_measured_render_time_cpu(vp),
			Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0])
	sec.frames += 1
	sec.refreshes += meter.refreshes - refreshes_before
	sec.gpu += g
	sec.gpu_max = maxf(sec.gpu_max, g)


func _tour_step(i: int) -> void:
	step = i
	phase_t = 0.0
	counting = false
	tour_results.append(Tally.new())
	if tour[i].recover:
		main.place_on_axis(_l(PLACES[0][0]), PLACES[0][1], PLACES[0][2])     # recover at the start
	_show("замер %.0f Гц: шаг %d из %d, глаза закрыты" % [main.rate.rate, i + 1, tour.size()])


func _tour(delta: float) -> void:
	var s := tour[step]
	var recover := TOUR_RECOVER * tour_scale if s.recover else 0.0
	if phase_t < recover:
		return
	var t := phase_t - recover
	var k := clampf(t / s.secs, 0.0, 1.0)
	pose = [lerpf(s.l.x, s.l.y, k), lerpf(s.yaw.x, s.yaw.y, k),
			s.pitch + s.nod * sin(TAU * t / (NOD_PERIOD * tour_scale)),
			s.roll * sin(TAU * t / (TILT_PERIOD * tour_scale))]
	main.place_on_axis(pose[0], pose[1], pose[2], pose[3])
	if not counting:
		counting = true
		_new_second()
		return
	tour_t += delta
	sec.t += delta
	var r := tour_results[step]
	if sec.t >= 1.0 or k >= 1.0:
		print("tour: step %d, l %.2f m, %.0f deg right, %.0f deg up, %.0f deg roll: %d frames of %d refreshes, gpu %.2f ms avg %.2f max"
				% [step + 1, pose[0], pose[1], pose[2], pose[3], sec.frames, sec.refreshes, sec.gpu / maxi(sec.frames, 1), sec.gpu_max])
		r.frames += sec.frames
		r.refreshes += sec.refreshes
		var share := float(sec.refreshes - sec.frames) / sec.refreshes if sec.refreshes > 0 else 0.0
		if share > r.worst:
			r.worst = share
			r.worst_pose = pose.duplicate()
		_new_second()
	if k >= 1.0:
		counting = false
		print("tour: %s: %d of %d refreshes without a new frame (%.1f%%), worst second %.0f%% at l %.1f m, %.0f deg right, %.0f deg up"
				% [s.what, r.refreshes - r.frames, r.refreshes, 100.0 * r.missed(), 100.0 * r.worst,
				r.worst_pose[0], r.worst_pose[1], r.worst_pose[2]])
		if step + 1 < tour.size():
			_tour_step(step + 1)
		else:
			_toured()


func _new_second() -> void:
	sec = Tally.new()


func _toured() -> void:
	var worst := -1
	var total_f := 0
	var total_r := 0
	for i in tour_results.size():
		var r := tour_results[i]
		total_f += r.frames
		total_r += r.refreshes
		if r.worst > FrameRate.MISSED_OK and (worst < 0 or r.worst > tour_results[worst].worst):
			worst = i
	var line := "%.0f Гц держится везде" % main.rate.rate
	if worst >= 0:
		var w := tour_results[worst]
		line = "%.0f Гц: пропуски, хуже всего %s (%d%%)" % [main.rate.rate,
				_ru(w.worst_pose[0], w.worst_pose[1], w.worst_pose[2]), roundi(100.0 * w.worst)]
	print("tour: done at %.0f Hz: %d of %d refreshes without a new frame (%.1f%%), %s"
			% [main.rate.rate, total_r - total_f, total_r, 100.0 * (total_r - total_f) / maxi(total_r, 1),
			("no second above %d%%" % roundi(100.0 * FrameRate.MISSED_OK)) if worst < 0 else "worst: " + tour[worst].what])
	_finish(line)


## A pose in words for the menu.
func _ru(l: float, yaw: float, pitch: float) -> String:
	var a := absf(l)
	var where := "старт" if a >= _l(START) - 0.05 else ("снаружи у края" if a >= main.space.L else ("край зоны" if a >= main.space.Lc else "горло"))
	if l < 0.0:
		where += " (мир B)"
	var y := fposmod(yaw if l >= 0.0 else 180.0 - yaw, 360.0)    # degrees from the throat
	y = minf(y, 360.0 - y)
	var dir := "на горло" if y < 45.0 else ("от горла" if y > 135.0 else "вбок")
	if pitch > 20.0:
		dir += " и вверх"
	elif pitch < -20.0:
		dir += " и вниз"
	return where + ", взгляд " + dir


func _finish(tour_line: String) -> void:
	running = false
	counting = false
	phase = ""
	_restore()
	main.hold = false
	main.set_pose(saved_pose)
	menu.set_render_scale(menu.render_scale)
	# also when the display never followed: SteamVR's setting for the app may hold TOUR_RATE now
	if _headset() and saved_rate > 0.0 and (absf(saved_rate - main.rate.rate) > 0.5
			or absf(saved_rate - main.rate.chosen()) > 0.5):
		main.rate.choose(saved_rate)
	print("bench: done")
	var parts := []
	if tour_line != "":
		parts.append(tour_line)
	if verdict != "":
		parts.append(verdict)
	_show(" · ".join(parts) if not parts.is_empty() else "замер готов, он в логе")


## Variant a's time against b's, averaged over the places (geometric mean).
func _ratio(a: int, b: int) -> float:
	var log_sum := 0.0
	var n := 0
	for r in results:
		if _mean(r[a]) > 0.0 and _mean(r[b]) > 0.0:
			log_sum += log(_mean(r[a]) / _mean(r[b]))
			n += 1
	return exp(log_sum / n) if n > 0 else 1.0


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


## This build's ray tracer as it runs, with the foveation chosen in the menu.
func _restore() -> void:
	main.frag.material.shader = main_shader
	main.frag.toy_mode = FragTracer.SPLIT
	main.set_frag(false)
	main.foveation.set_level(menu.foveation)


## A headset whose rate can be asked for and measured (not the desktop, not a test's fake one).
func _headset() -> bool:
	return main.rate.xr != null


func _show(s: String) -> void:
	menu.bench_status(s)


## A ray tracer the comparison times, and how.
class Setup:
	var label: String
	var frag: bool                  # main's fragment ray tracer (else this build's)
	var shader: Shader              # its shader
	var foveation: int              # Foveation.set_level's level
	var split: bool                 # main's: the split pass without a density map
	var toy_mode: int               # main's: FragTracer.SPLIT, WHOLE or BARE

	func _init(p_label: String, p_frag: bool, p_shader: Shader, p_foveation: int, p_split: bool, p_toy_mode: int) -> void:
		label = p_label
		frag = p_frag
		shader = p_shader
		foveation = p_foveation
		split = p_split
		toy_mode = p_toy_mode


## Another source's ray tracers (tools/ab_shaders.sh).
class Other:
	var label: String               # their first line
	var shader: Shader
	var balls: Shader               # with the toys, or null

	func _init(p_label: String, p_shader: Shader, p_balls: Shader) -> void:
		label = p_label
		shader = p_shader
		balls = p_balls


## A step of the tour: l and yaw (degrees to the right) from x to y over secs, pitch with a nod of
## that amplitude (degrees, NOD_PERIOD), a tilt of roll's (TILT_PERIOD); back to the start first if
## recover.
class Step:
	var l: Vector2
	var yaw: Vector2
	var pitch: float
	var nod: float
	var roll: float
	var secs: float
	var recover: bool
	var what: String


## Frames and refreshes counted: over a second, or over a step with its worst second.
class Tally:
	var t := 0.0                    # s counted
	var frames := 0
	var refreshes := 0
	var gpu := 0.0                  # ms, summed
	var gpu_max := 0.0
	var worst := 0.0                # the worst second's share of refreshes without a new frame
	var worst_pose: Array = [0.0, 0.0, 0.0, 0.0]   # and where: l, degrees right, up, roll

	func missed() -> float:
		return float(refreshes - frames) / refreshes if refreshes > 0 else 0.0
