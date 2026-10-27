extends Node
## The speed check, the menu's last row ("замер"). The eyes are best kept closed throughout: the
## world is turned and moved to the head, and some pictures are no proper ones.
##
## What a frame costs depends only on what is in view from where: the pose (how far from the throat
## one stands, l; where one looks, degrees from the throat along the floor and up) and where the
## toys are. So the check goes through scenes of play where the headset found frames dear
## (play_scenes.gd, SCENES: the demo at rest seen from the start, from the shell's edge and from
## outside it facing the throat, the throat sideways, world B at the edge; the demo's cubes set down
## at the edge and looked at; two big cubes in the hands at the edge; a ball in the hand), the
## viewer and the toys put there and held (main.hold: no physics), and times the frame on the GPU
## (the median of each segment) at 72 Hz: a frame that misses its refresh makes SteamVR step in,
## and the GPU time then grows by half for reasons of its own (a scene dearer than 13.9 ms reads
## more than it costs; its line says so).
##
## Ray tracers: this build's as it runs in play (with the foveation chosen in the menu), the same
## without foveation (what tools/adreno_cost.sh --poses scenes models), and the others a build may
## carry: tools/ab_shaders.sh copies them from earlier commits, directories or cost checks made
## from the tree into res://shaders/ab/1, 2, ... before the export (theirs over the whole view, with
## no stencil). Each scene is timed with each of them in a palindrome order (1 2 .. n n .. 2 1: a
## slow drift of heat or clock falls on all alike).
##
## The line below the menu then gives the dearest scenes as they run in play, with the highest
## refresh rate each leaves room for (a frame within 70% of its budget), and how this build compares
## with the first of the others. Render scale 100% throughout; afterwards the rate, the scale, the
## shader, the foveation, where one stood and the toys come back. A build made for measuring
## (tools/ab_shaders.sh --auto) runs it by itself once the headset has tracked the head for
## AUTO_AFTER seconds: start it, put the headset on, close the eyes, send the log afterwards.

const RateMeter := preload("res://rate_meter.gd")
const AB_DIR := "res://shaders/ab/%d/wormhole.gdshader"
const AB_BALLS := "res://shaders/ab/%d/wormhole_balls.gdshader"   # the same source's, with the toys
const AUTO := "res://shaders/ab/auto"      # present: run by itself
const AUTO_AFTER := 10.0        # s of head tracking before it starts by itself
const RATE := 72.0
const RATE_WAIT := 6.0          # s for the headset to follow a rate request
const PREPARE := 2.0            # s each ray tracer runs before the timing (its pipeline is compiled)
const RATES := [144.0, 120.0, 90.0, 72.0]   # the rates a scene's frame is held against
const ROOM := 0.7               # a rate is left room for when the frame takes at most this of its budget

var main: Node                  # main.gd
var panel: Node                 # perf_panel.gd
var warm := 0.3                 # s after each switch, not timed
var time := 0.8                 # s timed per segment
var running := false
var phase := ""                 # rate, prepare, segments
var others: Array = []          # [label, Shader, the Shader with balls or null] from res://shaders/ab/
var variants: Array = []        # this run's [label, Shader, foveation, main.toy_mode]: others (of the
                                # kind this build runs: with movable balls or without), then this
                                # build's as in play, then without foveation (if that differs)
var own := 0                    # the variant that is this build as in play
var own_shader: Shader
var plan: Array = []            # segments: [scene index, variant index]
var step := -1                  # the segment running
var phase_t := 0.0
var gpu_ms: Array = []          # this segment's frames
var seg_frames := 0             # this segment's frames and refreshes (frame_timing)
var seg_refreshes := 0
var clock_lo := 0
var clock_hi := 0
var results: Array = []         # per scene: per variant, the segments' GPU ms (the median frame:
                                # a hitch of the system does not move it)
var late: Array = []            # per scene: per variant, refreshes without a new frame
var meter := RateMeter.new()    # fed by the panel each frame
var saved_pose: Array
var saved_toys: Array = []      # the toys as they were: [balls, cubes] (deep copies)
var saved_rate := 0.0           # the rate to go back to
var saved_scale := 1.0
var saved_foveation := 0
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


func start() -> void:
	if running:
		return
	running = true
	own_shader = main.material.shader
	saved_foveation = panel.foveation
	variants = []
	# others compared with the same kind: without movable balls, or with them (the demo's toys)
	# (theirs without the stencil: they have no stencil test)
	for o in others:
		if own_shader == main.SHADER_PLAIN:
			variants.append([o[0], o[1], 0, main.TOYS_BARE])
		elif own_shader == main.SHADER_BALLS and o[2] != null:
			variants.append([o[0], o[2], 0, main.TOYS_BARE])
	own = variants.size()
	variants.append(["this build as in play, foveation %d" % saved_foveation, own_shader, saved_foveation, main.TOYS_SPLIT])
	if saved_foveation != 0:
		variants.append(["this build without foveation", own_shader, 0, main.TOYS_SPLIT])
	saved_pose = main.get_pose()
	saved_toys = []
	if main.world:
		saved_toys = [main.world.balls.duplicate(true), main.world.cubes.duplicate(true)]
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
	late.clear()
	verdict = ""
	for i in PlayScenes.SCENES.size():
		var r := []
		var lt := []
		for v in variants:
			r.append([])
			lt.append(0)
		results.append(r)
		late.append(lt)
		for v in order:
			plan.append([i, v])
	step = -1
	preparing = variants.size()
	var names := []
	for i in variants.size():
		names.append("%d = %s" % [i + 1, variants[i][0]])
	print("bench: start, %s; %d scenes, %.1f s timed per segment; own maps coarsen the %s first; gravity view %s"
			% [", ".join(names), PlayScenes.SCENES.size(), time, "width" if main.own_order == 0 else "height",
			main.GRAVITY_VIEWS[main.gravity_view]])
	var total := plan.size() * (warm + time) + preparing * PREPARE
	_show("замер: закрой глаза, не двигай головой, ~%d с" % ceili(total))
	_rate(RATE)


## Ask for the rate (the headset only), then prepare.
func _rate(hz: float) -> void:
	phase_t = 0.0
	if panel.xr != null and absf(panel.rate - hz) > 0.5:
		panel.choose_rate(hz)
		phase = "rate"
	else:
		phase = "prepare"
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
				start()
		return
	if not running:
		return
	phase_t += delta
	match phase:
		"rate":
			if absf(panel.rate - RATE) < 0.5 or phase_t > RATE_WAIT:
				phase = "prepare"
				_prepare()
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


## Run a ray tracer untimed at the dearest scene, so its pipelines are compiled before the timing.
func _prepare() -> void:
	phase_t = 0.0
	_place(PlayScenes.SCENES.size() - 2)
	_use(variants[variants.size() - preparing])


## A scene: the viewer and its toys (play_scenes.gd), the demo's toys as they were otherwise.
func _place(i: int) -> void:
	var s: Array = PlayScenes.SCENES[i]
	_restore_toys()
	PlayScenes.place(main, s[5], s[2], s[3], s[4])


func _restore_toys() -> void:
	if saved_toys.is_empty() or main.world == null:
		return
	main.world.balls = saved_toys[0].duplicate(true)
	main.world.cubes = saved_toys[1].duplicate(true)
	for st in main.hand_state:
		st.erase("held")
	main._upload_toys()


## A variant's ray tracer and foveation.
func _use(v: Array) -> void:
	main.material.shader = v[1]
	main.set_toy_mode(v[3])
	if main.foveation != v[2]:
		main.set_foveation(v[2])


## The panel's frame timing, every frame: the refreshes a segment's frames took.
func frame_timing(display_time: int, period: int, expected_hz: float) -> void:
	var refreshes_before := meter.refreshes
	var frames_before := meter.frames
	meter.add(display_time, period, expected_hz)
	if phase == "segments" and phase_t >= warm and meter.frames != frames_before:
		seg_frames += meter.frames - frames_before
		seg_refreshes += meter.refreshes - refreshes_before


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


## The GPU's clock now (read twice a segment: a kernel file each frame is not free).
func _clock() -> void:
	var mhz: int = panel._gpu_mhz()
	if mhz > 0:
		clock_lo = mhz if clock_lo == 0 else mini(clock_lo, mhz)
		clock_hi = maxi(clock_hi, mhz)


func _begin(i: int) -> void:
	step = i
	if i == 0 or plan[i][0] != plan[i - 1][0]:
		_place(plan[i][0])
		clock_lo = 0
		clock_hi = 0
		_show("замер: сцена %d из %d, глаза закрыты" % [plan[i][0] + 1, PlayScenes.SCENES.size()])
	_use(variants[plan[i][1]])
	phase_t = 0.0
	gpu_ms.clear()
	seg_frames = 0
	seg_refreshes = 0


func _end_segment() -> void:
	var r: Array = results[plan[step][0]]
	gpu_ms.sort()
	r[plan[step][1]].append(gpu_ms[gpu_ms.size() / 2] if not gpu_ms.is_empty() else 0.0)
	late[plan[step][0]][plan[step][1]] += maxi(seg_refreshes - seg_frames, 0)
	var last: bool = step + 1 >= plan.size() or plan[step + 1][0] != plan[step][0]
	if not last:
		return
	var s: Array = PlayScenes.SCENES[plan[step][0]]
	var parts := []
	var segs := []
	for v in variants.size():
		var p := "%d: %.2f ms" % [v + 1, _mean(r[v])]
		if v > 0:
			p += " (%.3f)" % (_mean(r[v]) / maxf(_mean(r[0]), 1e-6))
		if late[plan[step][0]][v] > 0:
			p += " [%d refreshes missed]" % late[plan[step][0]][v]
		parts.append(p)
		segs.append(_list(r[v]))
	print("bench: %s, l %.1f m, %.0f deg right, %.0f deg up, %s: %s; %.0f Hz, gpu clock %d..%d MHz, segments %s"
			% [s[0], s[2], s[3], s[4], s[5], ", ".join(parts), panel.rate, clock_lo, clock_hi, " ".join(segs)])


func _compared() -> void:
	var parts := []
	# the dearest scenes as in play, and the highest rate each leaves room for
	var dear := []
	for i in results.size():
		dear.append([_mean(results[i][own]), i])
	dear.sort_custom(func(a: Array, b: Array) -> bool: return a[0] > b[0])
	var words := []
	for k in mini(3, dear.size()):
		var ms: float = dear[k][0]
		var fits := "не тянет и 72 Гц"
		for hz in RATES:
			if ms <= ROOM * 1000.0 / hz:
				fits = "тянет %.0f Гц" % hz
				break
		words.append("%s %.1f мс (%s)" % [PlayScenes.SCENES[dear[k][1]][1], ms, fits])
	parts.append("дороже всего: " + ", ".join(words))
	var line := []
	for i in results.size():
		line.append("%s %.2f" % [PlayScenes.SCENES[i][0], _mean(results[i][own])])
	print("bench: as in play (foveation %d), ms: %s" % [saved_foveation, ", ".join(line)])
	if variants.size() > 1:
		var summary := []
		for v in range(1, variants.size()):
			summary.append("%d/1 %.3f" % [v + 1, _ratio(v, 0)])
		print("bench: compared, on average over the scenes %s (1 = %s)" % [", ".join(summary), variants[0][0]])
	if own > 0:
		var m := _ratio(own, 0)
		var pct := roundi(absf(1.0 - m) * 100.0)
		parts.append("новый и прежний одинаковы" if absf(1.0 - m) <= 0.02 else
				("новый %s прежнего на %d%%" % ["быстрее" if m < 1.0 else "медленнее", pct]))
	if variants.size() > own + 1:
		parts.append("фовеация %+d%%" % roundi(100.0 * (_ratio(own, own + 1) - 1.0)))
	verdict = " · ".join(parts)
	_finish()


func _finish() -> void:
	running = false
	phase = ""
	main.material.shader = own_shader
	main.set_toy_mode(main.TOYS_SPLIT)
	PlayScenes.take_away(main)
	_restore_toys()
	main.set_foveation(saved_foveation)
	main.hold = false
	main.set_pose(saved_pose)
	panel._set_scale(saved_scale)
	if panel.xr != null and saved_rate > 0.0 and absf(saved_rate - panel.rate) > 0.5:
		panel.choose_rate(saved_rate)
	print("bench: done")
	_show(verdict if verdict != "" else "замер готов, он в логе")


## Variant a's time against b's, averaged over the scenes (geometric mean).
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
