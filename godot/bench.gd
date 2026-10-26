extends Node
## The speed check, "замер" on the frame rate panel, in two parts. The eyes are best kept closed
## throughout: the world is turned and moved to the head, and some pictures are no proper ones.
##
## What a frame costs depends only on the pose: how far from the throat one stands (l), where one
## looks (degrees from the throat along the floor, degrees up) and how the head is tilted (roll:
## it changes how pixels fall into the GPU's groups). The world is symmetric about the throat and
## the floor is a plane, so for someone standing on the floor these are all there is; nothing
## carries over from one frame to the next, so moving only changes which poses come.
##
## 1. Comparison, at 72 Hz. The viewer is put at fixed poses (PLACES), with the feet held there,
## and the ray tracer is timed on the GPU (the median frame of each segment). A build can carry
## other ray tracers: tools/ab_shaders.sh copies them from earlier commits, directories or cost
## checks made from the tree into res://shaders/ab/1, 2, ... before the export. Every pose is
## then timed with each of them and this build's own, in a palindrome order (1 2 .. n n .. 2 1:
## a slow drift of heat or clock falls on all alike). 72 Hz: a frame that misses its refresh
## makes SteamVR step in, and the GPU time then grows by half for reasons of its own.
## This build's ray tracer is timed six ways (FOVEATIONS), and with the demo's toys two more: the
## ray tracer with toys over the whole view, not only where the stencil marks a toy may be seen
## (main.set_toy_mode), and with a ball held at the chest and both hands' balls (IN_HAND, as
## tests/emu_dump.gd +held: what holding a toy costs, the near ones' cones). The six: as it always
## ran, with the 3D scene in
## a render pass of its own (what foveation needs, split_pass.gd) but no density map, and with
## foveated rendering: SteamVR's map low and high, our own wide and narrow (main.set_foveation).
## The others run without foveation.
##
## 2. The tour, at 120 Hz with this build's ray tracer: at each of TOUR_L the view sweeps from
## the throat round to the other side, in rows from 60 degrees down to 60 up; then walks through
## the throat and back, turning and nodding on the way; then turns on the spot about each axis
## (yaw, pitch, roll). Every frame gets a "tf" line: the time, the pose, the refreshes it took,
## and the GPU and CPU time; every second a "tour:" line. Before each place the viewer goes back
## to the start for a moment, so that a headset that fell to every 2nd refresh has come back.
##
## The panel's line says whether 120 Hz held (and where it did worst), how this build's ray
## tracer compares with the first of the others, and what the foveation saves. Render
## scale 100% throughout, the tour with the foveation chosen on the panel; afterwards the rate,
## the scale, the shader, the foveation and where one stood come back. A build made for measuring
## (tools/ab_shaders.sh --auto) runs it by itself once the headset has tracked the head for
## AUTO_AFTER seconds: start it, put the headset on, close the eyes, send the log afterwards.

const RateMeter := preload("res://rate_meter.gd")
const AB_DIR := "res://shaders/ab/%d/wormhole.gdshader"
const AB_BALLS := "res://shaders/ab/%d/wormhole_balls.gdshader"   # the same source's, with the toys
const AUTO := "res://shaders/ab/auto"      # present: run by itself
const AUTO_AFTER := 10.0        # s of head tracking before it starts by itself
const PLACES := [   # the comparison's poses: [l, degrees to the right of the throat, degrees up]
	# (place_on_axis: at l < 0 the throat is behind at 0 degrees, ahead at 180)
	[11.6, 0.0, 0.0],   # the start
	[6.2, 0.0, 0.0],    # just outside the curved zone: the wormhole fills the view
	[6.2, 60.0, 0.0],
	[5.0, 0.0, 0.0],    # inside, at the edge
	[5.0, 90.0, 0.0],
	[5.0, 180.0, 0.0],  # facing away: every ray starts in the curved zone
	[5.0, 0.0, -35.0],  # down at the floor
	[5.0, 0.0, 35.0],   # up
	[0.0, 0.0, 0.0],    # in the throat
	[0.0, 90.0, 0.0],   # in the throat, looking sideways round it: the demo's dearest
	[-5.0, 180.0, 0.0], # world B, at the edge, facing the throat: its boxes cost more than A's pillars
	[-5.7, 160.0, -5.0],  # world B at the edge, 20 deg from the throat: where 144 Hz fell to 72
	[-6.2, 180.0, 0.0], # world B, just outside the curved zone, facing the throat
]
# a ball in the right hand and both hands' balls, from the head in the room's axes: [offset, radius]
const IN_HAND := [[Vector3(0.22, -0.35, -0.6), 0.25], [Vector3(0.22, -0.35, -0.3), 0.04],
	[Vector3(-0.22, -0.35, -0.3), 0.04]]
const RATE := 72.0
const RATE_WAIT := 6.0          # s for the headset to follow a rate request
const PREPARE := 2.0            # s each ray tracer runs before the timing (its pipeline is compiled)
const TOUR_RATE := 120.0
const TOUR_L := [11.6, 8.0, 6.2, 5.0, 4.0, 2.5, 0.0, -2.5, -5.0, -6.2]
const TOUR_PITCH := [-60.0, -30.0, 0.0, 30.0, 60.0]
const SWEEP := 2.0              # s for a row: 180 degrees
const TOUR_RECOVER := 1.5       # s at the start before each place, not counted
const MISSED_OK := 0.01         # as the panel: at most 1% of the refreshes without a new frame
# this build's ray tracer: [label, foveation level (main.set_foveation), split]; the first is the
# reference the others are compared with
const FOVEATIONS := [["this build", 0, false], ["this build, passes split", 0, true],
	["this build, SteamVR low", 1, false], ["this build, SteamVR high", 3, false],
	["this build, own wide", 4, false], ["this build, own narrow", 5, false]]

var main: Node                  # main.gd
var panel: Node                 # perf_panel.gd
var warm := 0.3                 # s after each switch, not timed
var time := 0.8                 # s timed per segment
var tour_scale := 1.0           # the tour's durations, scaled (tests)
var with_tour := true
var running := false
var phase := ""                 # rate, prepare, segments, tour
var _next := ""                 # the phase after a rate request
var others: Array = []          # [label, Shader, the Shader with balls or null] from res://shaders/ab/
var variants: Array = []        # this run's [label, Shader, foveation, split, main.toy_mode]:
                                # others (of the kind
                                # this build runs: with movable balls or without), then this
                                # build's (FOVEATIONS)
var own := 0                    # the variant that is this build as it always ran
var own_shader: Shader
var plan: Array = []            # segments: [place index, variant index]
var step := -1                  # the segment or tour step running
var phase_t := 0.0
var gpu_ms: Array = []          # this segment's frames
var clock_lo := 0
var clock_hi := 0
var results: Array = []         # per place: per variant, the segments' GPU ms (the median frame:
                                # a hitch of the system does not move it)
var tour: Array = []            # the tour's steps (_make_tour)
var tour_results: Array = []    # per step: {frames, refreshes, worst: [share, l, yaw, pitch, roll]}
var meter := RateMeter.new()    # fed by the panel each frame
var counting := false
var tour_t := 0.0               # s since the tour began counting (the "tf" lines' time)
var pose := [0.0, 0.0, 0.0, 0.0]     # the tour's pose now: l, degrees right, up, roll
var sec := {}                   # this second's counts
var saved_pose: Array
var saved_rate := 0.0           # the rate to go back to
var saved_scale := 1.0
var preparing := 0              # variants left to run untimed before the first segment
var verdict := ""               # the comparison's line
var auto := false               # start by itself (once)
var auto_t := 0.0


func _ready() -> void:
	for i in range(1, 10):
		var path := AB_DIR % i
		if not ResourceLoader.exists(path):
			break
		var sh: Shader = load(path)
		var with_balls: Shader = load(AB_BALLS % i) if ResourceLoader.exists(AB_BALLS % i) else null
		others.append([sh.code.get_slice("\n", 0).trim_prefix("//").strip_edges(), sh, with_balls])
	auto = FileAccess.file_exists(AUTO)


func has_ab() -> bool:
	return not others.is_empty()


## The tour's steps: {l: [from, to], yaw: [from, to], pitch, nod: the amplitude of a nod about
## the pitch (degrees, a 3 s period), roll: the amplitude of a tilt (a 2 s period), secs,
## recover: back to the start first, what}
func _make_tour() -> Array:
	var t := []
	for l in TOUR_L:
		for i in TOUR_PITCH.size():
			var y0 := 0.0 if i % 2 == 0 else 180.0
			t.append(_st(l, l, y0, 180.0 - y0, TOUR_PITCH[i], SWEEP,
					"l %.1f m, %.0f deg up, sweeping round" % [l, TOUR_PITCH[i]], i == 0))
	t.append(_st(11.6, -6.2, 0.0, 720.0, 0.0, 15.0, "walking from the start through the throat, turning and nodding", true, 30.0))
	t.append(_st(-6.2, 11.6, 180.0, -540.0, 0.0, 15.0, "walking back, turning, nodding and tilting", true, 30.0, 20.0))
	for l in [6.2, 5.0, 0.0]:
		t.append(_st(l, l, 0.0, 360.0, 0.0, 4.0, "l %.1f m, turning round (yaw)" % l, true))
		t.append(_st(l, l, 0.0, 0.0, 0.0, 6.0, "l %.1f m, nodding 60 deg (pitch)" % l, false, 60.0))
		t.append(_st(l, l, 0.0, 0.0, 0.0, 4.0, "l %.1f m, tilting 30 deg (roll)" % l, false, 0.0, 30.0))
	return t


func _st(l0: float, l1: float, y0: float, y1: float, p: float, secs: float, what: String,
		recover := false, nod := 0.0, roll := 0.0) -> Dictionary:
	return {"l": [l0, l1], "yaw": [y0, y1], "pitch": p, "nod": nod, "roll": roll,
			"secs": secs * tour_scale, "recover": recover, "what": what}


func start() -> void:
	if running:
		return
	running = true
	own_shader = main.material.shader
	variants = []
	# others compared with the same kind: without movable balls, or with them (the demo's toys)
	# (theirs without the stencil: they have no stencil test)
	for o in others:
		if own_shader == main.SHADER_PLAIN:
			variants.append([o[0], o[1], 0, false, main.TOYS_BARE])
		elif own_shader == main.SHADER_BALLS and o[2] != null:
			variants.append([o[0], o[2], 0, false, main.TOYS_BARE])
	own = variants.size()
	for f in FOVEATIONS:
		variants.append([f[0], own_shader, f[1], f[2], main.TOYS_SPLIT])
	if main.balls > 0:
		variants.append(["this build, toys over the whole view", own_shader, 0, false, main.TOYS_WHOLE])
		variants.append(["this build, a ball in the hand", own_shader, 0, false, main.TOYS_SPLIT, true])
	saved_pose = main.get_pose()
	main.hold = true
	saved_scale = panel.render_scale
	panel._set_scale(1.0)
	# back to this app's own setting where there is one, else to what the display ran at
	saved_rate = panel.stored if panel.steam_key != "" and panel.stored > 0.0 else panel.rate
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
		for v in order:
			plan.append([i, v])
	step = -1
	preparing = variants.size()
	var names := []
	for i in variants.size():
		names.append("%d = %s" % [i + 1, variants[i][0]])
	print("bench: start, %s; %d places, %.1f s timed per segment; own maps coarsen the %s first; gravity view %s"
			% [", ".join(names), PLACES.size(), time, "width" if main.own_order == 0 else "height",
			main.GRAVITY_VIEWS[main.gravity_view]])
	var tour_s := 0.0
	for s in tour:
		tour_s += s.secs + (TOUR_RECOVER * tour_scale if s.recover else 0.0)
	var total := plan.size() * (warm + time) + preparing * PREPARE + (tour_s if with_tour and panel.xr != null else 0.0)
	_show("замер: закрой глаза, не двигай головой, ~%d мин" % ceili(total / 60.0))
	_rate(RATE, "prepare")


## Ask for a rate (the headset only), then go on to the next phase.
func _rate(hz: float, next: String) -> void:
	phase_t = 0.0
	if panel.xr != null and absf(panel.rate - hz) > 0.5:
		panel.choose_rate(hz)
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
		print("tour: start at %.0f Hz, foveation %d (own maps %s first), %d steps; \"tf\" lines: s, l m, deg right, deg up, deg roll, refreshes the frame took, gpu ms, cpu ms render, cpu ms process"
				% [panel.rate, main.foveation, "width" if main.own_order == 0 else "height", tour.size()])
		tour_t = 0.0
		_tour_step(0)


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
				start()
		return
	if not running:
		return
	phase_t += delta
	match phase:
		"rate":
			if absf(panel.rate - (TOUR_RATE if _next == "tour" else RATE)) < 0.5 or phase_t > RATE_WAIT:
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
	main.place_on_axis(PLACES[0][0], PLACES[0][1], PLACES[0][2])
	_use(variants[variants.size() - preparing])


## A variant's ray tracer and foveation (and a ball in the hand: after place_on_axis, from there).
func _use(v: Array) -> void:
	main.material.shader = v[1]
	main.set_toy_mode(v[4])
	_in_hand(v.size() > 5 and v[5])
	if main.foveation != v[2] or main.split_pass.enabled != (v[2] > 0 or v[3]):
		main.set_foveation(v[2], v[3])


func _segment() -> void:
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
			_compared()


## The ball in the hand and the hands' balls (IN_HAND) where the head is now, or none. Not held:
## the hands are off while the speed check holds the viewer, and so is the physics, so they stay.
func _in_hand(on: bool) -> void:
	var w = main.world
	if w == null:
		return
	var had := false
	for b in w.balls:
		had = had or b.has("bench")
	if had:
		w.balls = w.balls.filter(func(b: Dictionary) -> bool: return not b.has("bench"))
	if on:
		var sp: WormholeSpace = main.space
		var head: Vector3 = main.camera.transform.origin
		var hp: Array = sp.geodesic(main.foot_l, main.foot_n, main.frame[1], maxf(head.y, 0.05), main.frame,
				WormholeSpace.STEP_FRAME)
		for t in IN_HAND:
			var dir := WormholeSpace.combine(hp[2], t[0])
			var at: Array = sp.geodesic(hp[0], hp[1], dir / dir.length(), dir.length(), hp[2], WormholeSpace.STEP_FRAME)
			var b: Dictionary = w.add(at[0], at[1], Vector4.ZERO, t[1], Color(0.95, 0.95, 0.97))
			b["bench"] = true
	if on or had:
		main._upload_toys()


## The GPU's clock now (read twice a segment: a kernel file each frame is not free).
func _clock() -> void:
	var mhz: int = panel._gpu_mhz()
	if mhz > 0:
		clock_lo = mhz if clock_lo == 0 else mini(clock_lo, mhz)
		clock_hi = maxi(clock_hi, mhz)


func _begin(i: int) -> void:
	step = i
	var place: Array = PLACES[plan[i][0]]
	main.place_on_axis(place[0], place[1], place[2])
	_use(variants[plan[i][1]])
	phase_t = 0.0
	gpu_ms.clear()
	if i == 0 or plan[i][0] != plan[i - 1][0]:
		clock_lo = 0
		clock_hi = 0
		_show("замер: место %d из %d, глаза закрыты" % [plan[i][0] + 1, PLACES.size()])


func _end_segment() -> void:
	var r: Array = results[plan[step][0]]
	gpu_ms.sort()
	r[plan[step][1]].append(gpu_ms[gpu_ms.size() / 2] if not gpu_ms.is_empty() else 0.0)
	var last: bool = step + 1 >= plan.size() or plan[step + 1][0] != plan[step][0]
	if not last:
		return
	var place: Array = PLACES[plan[step][0]]
	var parts := []
	var segs := []
	for v in variants.size():
		var s := "%d: %.2f ms" % [v + 1, _mean(r[v])]
		if v > 0:
			s += " (%.3f)" % (_mean(r[v]) / _mean(r[0]))
		parts.append(s)
		segs.append(_list(r[v]))
	print("bench: l %.1f m, %.0f deg right, %.0f deg up: %s; %.0f Hz, gpu clock %d..%d MHz, segments %s"
			% [place[0], place[1], place[2], ", ".join(parts), panel.rate, clock_lo, clock_hi, " ".join(segs)])


func _compared() -> void:
	main.material.shader = own_shader
	main.set_toy_mode(main.TOYS_SPLIT)
	_in_hand(false)
	main.set_foveation(panel.foveation)     # the tour runs with the foveation chosen on the panel
	if variants.size() > 1:
		# each variant against the first, averaged over the places (geometric mean)
		var summary := []
		for v in range(1, variants.size()):
			summary.append("%d/1 %.3f" % [v + 1, _ratio(v, 0)])
		print("bench: compared, on average over the places %s (1 = %s)" % [", ".join(summary), variants[0][0]])
		var parts := []
		if own > 0:
			var m := _ratio(own, 0)
			var pct := roundi(absf(1.0 - m) * 100.0)
			parts.append("новый и прежний одинаковы" if absf(1.0 - m) <= 0.02 else
					("новый %s прежнего на %d%%" % ["быстрее" if m < 1.0 else "медленнее", pct]))
		# the foveation against this build as it always ran
		summary.clear()
		for v in range(own + 1, variants.size()):
			summary.append("%s %.3f" % [variants[v][0].trim_prefix("this build, "), _ratio(v, own)])
		print("bench: foveation (and the toys over the whole view), on average over the places against this build as it ran: %s" % ", ".join(summary))
		# on the panel, what each foveation saves: SteamVR low, high, own wide, narrow
		var pcts := []
		for v in range(own + 2, own + FOVEATIONS.size()):
			pcts.append("%+d" % roundi(100.0 * (_ratio(v, own) - 1.0)))
		parts.append("фовеация %s%%" % "/".join(pcts))
		# and what the stencil saves: the toys' ray tracer over the whole view against split; and
		# what a ball in the hand costs
		if variants.size() > own + FOVEATIONS.size():
			parts.append("трафарет %+d%%" % roundi(100.0 * (1.0 / _ratio(own + FOVEATIONS.size(), own) - 1.0)))
		if variants.size() > own + FOVEATIONS.size() + 1:
			parts.append("мяч в руке %+d%%" % roundi(100.0 * (_ratio(own + FOVEATIONS.size() + 1, own) - 1.0)))
		verdict = " · ".join(parts)
	if with_tour and panel.xr != null:
		_show("замер: теперь 120 Гц, глаза закрыты")
		_rate(TOUR_RATE, "tour")
	else:
		_finish("")


# ---------------------------------------------------------------- the tour

## The panel's frame timing, every frame: while counting, a "tf" line for the frame.
func frame_timing(display_time: int, period: int, expected_hz: float) -> void:
	var refreshes_before := meter.refreshes
	var frames_before := meter.frames
	meter.add(display_time, period, expected_hz)
	if not counting or meter.frames == frames_before:
		return
	var vp: RID = panel.target.get_viewport_rid()
	var g := RenderingServer.viewport_get_measured_render_time_gpu(vp)
	print("tf %.3f %.2f %.0f %.0f %.0f %d %.2f %.2f %.2f" % [tour_t, pose[0], pose[1], pose[2], pose[3],
			meter.refreshes - refreshes_before, g, RenderingServer.viewport_get_measured_render_time_cpu(vp),
			Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0])
	sec.f += 1
	sec.r += meter.refreshes - refreshes_before
	sec.g += g
	sec.gmax = maxf(sec.gmax, g)


func _tour_step(i: int) -> void:
	step = i
	phase_t = 0.0
	counting = false
	tour_results.append({"frames": 0, "refreshes": 0, "worst": [0.0, 0.0, 0.0, 0.0, 0.0]})
	if tour[i].recover:
		main.place_on_axis(PLACES[0][0], PLACES[0][1], PLACES[0][2])     # recover at the start
	_show("замер 120 Гц: шаг %d из %d, глаза закрыты" % [i + 1, tour.size()])


func _tour(delta: float) -> void:
	var s: Dictionary = tour[step]
	var recover: float = TOUR_RECOVER * tour_scale if s.recover else 0.0
	if phase_t < recover:
		return
	var t := phase_t - recover
	var k := clampf(t / s.secs, 0.0, 1.0)
	pose = [lerpf(s.l[0], s.l[1], k), lerpf(s.yaw[0], s.yaw[1], k),
			s.pitch + s.nod * sin(TAU * t / (3.0 * tour_scale)), s.roll * sin(TAU * t / (2.0 * tour_scale))]
	main.place_on_axis(pose[0], pose[1], pose[2], pose[3])
	if not counting:
		counting = true
		_new_second()
		return
	tour_t += delta
	sec.t += delta
	var r: Dictionary = tour_results[step]
	if sec.t >= 1.0 or k >= 1.0:
		print("tour: step %d, l %.2f m, %.0f deg right, %.0f deg up, %.0f deg roll: %d frames of %d refreshes, gpu %.2f ms avg %.2f max"
				% [step + 1, pose[0], pose[1], pose[2], pose[3], sec.f, sec.r, sec.g / maxi(sec.f, 1), sec.gmax])
		r.frames += sec.f
		r.refreshes += sec.r
		var share: float = float(sec.r - sec.f) / sec.r if sec.r > 0 else 0.0
		if share > r.worst[0]:
			r.worst = [share, pose[0], pose[1], pose[2], pose[3]]
		_new_second()
	if k >= 1.0:
		counting = false
		print("tour: %s: %d of %d refreshes without a new frame (%.1f%%), worst second %.0f%% at l %.1f m, %.0f deg right, %.0f deg up"
				% [s.what, r.refreshes - r.frames, r.refreshes, 100.0 * _missed(r), 100.0 * r.worst[0],
				r.worst[1], r.worst[2], r.worst[3]])
		if step + 1 < tour.size():
			_tour_step(step + 1)
		else:
			_toured()


func _new_second() -> void:
	sec = {"t": 0.0, "f": 0, "r": 0, "g": 0.0, "gmax": 0.0}


static func _missed(r: Dictionary) -> float:
	return float(r.refreshes - r.frames) / r.refreshes if r.refreshes > 0 else 0.0


func _toured() -> void:
	var worst := -1
	var total_f := 0
	var total_r := 0
	for i in tour_results.size():
		var r: Dictionary = tour_results[i]
		total_f += r.frames
		total_r += r.refreshes
		if r.worst[0] > MISSED_OK and (worst < 0 or r.worst[0] > tour_results[worst].worst[0]):
			worst = i
	var line := "%.0f Гц держится везде" % panel.rate
	if worst >= 0:
		var w: Array = tour_results[worst].worst
		line = "%.0f Гц: пропуски, хуже всего %s (%d%%)" % [panel.rate, _ru(w[1], w[2], w[3]), roundi(100.0 * w[0])]
	print("tour: done at %.0f Hz: %d of %d refreshes without a new frame (%.1f%%), %s"
			% [panel.rate, total_r - total_f, total_r, 100.0 * (total_r - total_f) / maxi(total_r, 1),
			"no second above 1%" if worst < 0 else "worst: " + tour[worst].what])
	_finish(line)


## A pose in words for the panel.
func _ru(l: float, yaw: float, pitch: float) -> String:
	var a := absf(l)
	var where := "старт" if a >= 10.0 else ("снаружи у края" if a >= main.space.L else ("край зоны" if a >= main.space.Lc else "горло"))
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
	main.material.shader = own_shader
	main.set_toy_mode(main.TOYS_SPLIT)
	_in_hand(false)
	main.set_foveation(panel.foveation)
	main.hold = false
	main.set_pose(saved_pose)
	panel._set_scale(saved_scale)
	if panel.xr != null and saved_rate > 0.0 and absf(saved_rate - panel.rate) > 0.5:
		panel.choose_rate(saved_rate)
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


func _show(s: String) -> void:
	panel.bench_status(s)
