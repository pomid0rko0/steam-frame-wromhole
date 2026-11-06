class_name Bench
extends Node
## The speed check (menu.gd's row "bench"), in two parts. The eyes are best kept
## closed throughout: the world is turned and moved to the head, and some pictures are no proper
## ones.
##
## What a frame costs depends on the pose: where the head is (on the floor, at the start or under
## the mouth; flying at the curved zone's edge, in the throat, in universe B), where one looks
## (degrees from the throat, degrees up) and how the head is tilted (roll: it changes how pixels
## fall into the GPU's groups). With the toys still (main.hold stops them) and the viewer put at the
## pose (_put: standing, main.place, or flying on the axis through the throat's centre at its
## height, main.place_on_axis), the pose decides what the renderer does. Besides it a frame's time
## changes with where the eyes look under foveation (its fovea follows them: foveation.gd) and with
## SteamVR's half rate after a late frame (below).
##
## 1. Comparison, at RATE. The viewer is put at fixed poses (PLACES), and held there,
## and the frame is timed on the GPU (the median frame of each segment, and of each of its parts:
## FrameRate.PARTS, and of each pass of the zone's nodes and paths: ZoneSections.TS_PASS), this
## build's renderer each
## way VARIANTS lists: without foveation, at each of its levels, and with a cube held right before
## the eyes (NEAR_CUBE: a body near the eyes with the world round it), and with a ball and a cube
## in the throat's cylinder (THROAT_BODIES: their images past the meshes', the tail, cost pixels
## per body: zone_tail.gdshader), and the same without the tail (what it costs: the difference) and
## with it as one band, without its strips, at foveation's strongest with two balls of a hand's size
## before the chest (HAND_BALLS: what the hands' balls cost); at the long throat's places only (LONG)
## also with the bodies in the throat at foveation's strongest with the tail and without,
## in a palindrome order (1 2 .. n n .. 2 1: a slow drift of heat or clock falls on
## all alike). RATE is low because a frame that misses its refresh sends SteamVR to half rate
## (frame_rate.gd), and the GPU time then grows: a variant over the frame's budget reads dearer than
## it is, and so does the segment after it.
##
## 2. The tour (_make_tour), at TOUR_RATE if the display follows, with the menu's foveation: does
## the rate hold all round, and where not: sweeps round at each place, a flight along the axis
## through the throat into universe B and back, and its last rows with the cube before the eyes.
## Each place starts from a cheap pose (TOUR_RECOVER), which is not enough to undo SteamVR's half rate
## (frame_rate.gd).
##
## Throughout, the toys are at their start (Toys.spawn, without the throw and the drop: the toys
## in the curved zone, their images and tail, cost as much as the bodies timed), so that a check
## times what another session's does. Afterwards what it changed comes back (_restore, _finish).

const RateMeter := preload("res://rate_meter.gd")
# Where a pose is (_put): START, standing at main.START_POS facing the wormhole; Vector3(x, y, side),
# standing on universe side's floor at chart (x, y), facing the point under the throat's centre;
# a float, the head at that l on the axis through the throat's centre (main.place_on_axis: flying,
# main.LIFT over the floor, facing the throat at l > 0 and away from it at l < 0). Degrees to the
# right and up are from there. The values are metres chosen against the video's throat's curved zone
# (edge MOUTH, radius Rout) and main.LIFT, which WormholeSpace.set_profile's list names; on a throat
# of another length (the menu's) a place on the axis off l = 0 is as far from its mouth as there
# (_axis_l).
const MOUTH := 4.0 + PI / 2.0
const START := INF
const UNDER_A := Vector3(2.5, 0.0, 1.0)     # on A's floor under the mouth, the head just below the curved zone
const UNDER_A_IN := Vector3(0.5, 0.0, 1.0)  # right under the throat's centre: the head in the curved zone
const UNDER_B := Vector3(-2.5, 0.0, -1.0)   # on B's floor under its mouth
const LONG := 80.0              # m: a long throat's cylinder (the menu's longest)
const PLACES := [   # the comparison's poses: [where, degrees to the right, degrees up, and the throat's cylinder's length if not the menu's]
	[START, 0.0, 0.0],      # the mouth over the floor ahead
	[UNDER_A, 0.0, 60.0],   # looking up into the mouth
	[UNDER_A_IN, 0.0, 80.0],
	[6.2, 0.0, 0.0],        # flying just outside the curved zone: the wormhole fills the view
	[6.2, 60.0, 0.0],
	[5.0, 0.0, 0.0],        # inside, at the edge: every ray starts in the curved zone
	[5.0, 90.0, 0.0],
	[5.0, 180.0, 0.0],      # facing away
	[5.0, 0.0, -35.0],      # down at the floor
	[0.0, 0.0, 0.0],        # in the throat, looking along it
	[0.0, 90.0, 0.0],       # in the throat, looking sideways round it
	[-5.0, 180.0, 0.0],     # world B, at the edge, facing the throat (boxes where A has pillars)
	[-6.2, 180.0, 0.0],     # world B, just outside the curved zone, facing the throat
	[UNDER_B, 0.0, 60.0],   # on B's floor, looking up into its mouth
	[0.0, 90.0, 0.0, LONG],  # in the middle of a long throat, looking sideways round it
	[-0.5, 90.0, 0.0, LONG], # 5 m in from its mouth B, sideways: the throat's ball 55 m along, its tail across the view
	[0.0, 0.0, 0.0, LONG],   # and along it
	[START, 0.0, 0.0, LONG], # the start, the long throat's mouth ahead
]
const RATE := 72.0
const RATE_WAIT := 6.0          # s for the headset to follow a rate request
const PREPARE := 2.0            # s each variant runs before the timing (its pipelines are compiled)
const TOUR_RATE := 144.0
const TOUR_AT := [START, UNDER_A, 8.0, 6.2, 5.0, 4.0, 2.5, 0.0, -2.5, -5.0, -6.2, UNDER_B]   # sweeping round
const TOUR_FLY := 12.0          # l: the tour's flight from here along the axis, through the throat to -6.2
const TOUR_PITCH := [-60.0, -30.0, 0.0, 30.0, 60.0]
const SWEEP := 2.0              # s for a row: 180 degrees
const TOUR_RECOVER := 1.5       # s at the start before each place, not counted
const NOD_PERIOD := 3.0         # s: the tour's nods
const TILT_PERIOD := 2.0        # s: its tilts (roll)
# the comparison's variants, each what it changes from the first (Setup's defaults: without foveation,
# the tail drawn with its strips, timed at every place): foveation (its level,
# Foveation.set_level), near (the cube before the eyes), throat (the bodies in the throat), hands
# (two balls of a hand's size before the chest: HAND_BALLS), tail (Renderer.tail_shown), strips
# (Renderer.tail_strips: else one band from the first copy past the meshes'), long (at the long
# throat's places only); the first is the reference the others are compared with
const VARIANTS := [{"label": "plain"},
	{"label": "foveation weak", "foveation": 1},
	{"label": "foveation medium", "foveation": 2},
	{"label": "foveation strong", "foveation": 3},
	{"label": "foveation stronger", "foveation": 4},
	{"label": "foveation strongest", "foveation": 5},
	{"label": "the same with the hands' balls", "foveation": 5, "hands": true},
	{"label": "a cube at the eyes", "near": true},
	{"label": "a ball and a cube in the throat", "throat": true},
	{"label": "the same without the tail", "throat": true, "tail": false},
	{"label": "the same, the tail without strips", "throat": true, "strips": false},
	{"label": "a ball and a cube in the throat, foveation strongest", "foveation": 5, "throat": true, "long": true},
	{"label": "the same without the tail, foveation strongest", "foveation": 5, "throat": true, "tail": false, "long": true}]
# the bodies in the throat: [share of the cylinder's half length along l from its middle, angle
# round the throat from the head's way forward, radius or half size]: a ball on A's side, a cube on
# B's, both in view from inside the cylinder looking round it and from out at the mouth
const THROAT_BALL := [0.45, 0.6, 0.3]
const THROAT_CUBE := [-0.7, 1.4, 0.25]
const THROAT_COLOR := Color(0.9, 0.4, 0.3)
# the cube before the eyes: [m ahead of the head, half size]: 20 cm, its near face 30 cm away, as if
# held, the floor and the sky all round it (one filling the view would be the cheapest frame there
# is: its pixels only shade)
const NEAR_CUBE := [0.4, 0.1]
# the hands' balls (the variant's, not the tracked hands', which a run with the eyes closed seldom has
# in view): [m ahead of the head, m to its right (each side), m up, radius], as hands hold out
const HAND_BALLS := [0.35, 0.2, -0.3, 0.04]
const NEAR_COLOR := Color(0.55, 0.6, 0.95)

var main: Main
var menu: Menu                  # the result goes there; the eye's size
var warm := 0.3                 # s after each switch, not timed
var time := 0.8                 # s timed per segment
var tour_scale := 1.0           # the tour's durations, scaled (tests)
var running := false
var phase := ""                 # rate, prepare, segments, tour
var _next := ""                 # the phase after a rate request
var variants: Array[Setup] = []   # this run's (start)
# the cube before the eyes is drawn (extras); set, the toys go to the renderer again at once:
# main drew them before this node's _process, and the frame a variant starts in must have its cube
var near := false:
	set(v):
		near = v
		if main and main.toys.enabled:
			main.draw_toys()
# the hands' balls are drawn (extras), likewise
var hand_balls := false:
	set(v):
		hand_balls = v
		if main and main.toys.enabled:
			main.draw_toys()
# the bodies in the throat are drawn (extras), likewise
var throat := false:
	set(v):
		throat = v
		if main and main.toys.enabled:
			main.draw_toys()
var saved_length := 0.0         # the throat's cylinder's length before (a place sets its own)
var plan: Array[Vector2i] = []  # segments: (place index, variant index)
var step := -1                  # the segment or tour step running
var phase_t := 0.0
var gpu_ms: Array = []          # this segment's frames
var part_ms: Array = []         # and their GPU time by part (FrameRate.PARTS), as read
var part_frame := -1            # the last frame whose parts were taken (FrameRate.parts_frame)
var zone_ms: Array = []         # and their zone's passes' (FrameRate.zone_last), as read
var clock_lo := 0
var clock_hi := 0
var results: Array = []         # per place: per variant, the segments' GPU ms (the median frame:
                                # a hitch of the system does not move it)
var part_results: Array = []    # the same by part: per place, per variant, per segment its medians
var zone_results: Array = []    # the zone's passes': per place, per variant, per segment {pass: median}
var _zone_counts: Array[Vector2i] = []   # per place: the balls and cubes in the zone with the cube there
var tour: Array[Step] = []      # the tour's steps (_make_tour)
var tour_results: Array[Tally] = []   # per step
var meter := RateMeter.new()    # fed by main.rate each frame
var counting := false
var tour_t := 0.0               # s since the tour began counting (the "tf" lines' time)
var pose: Array = [START, 0.0, 0.0, 0.0]     # the tour's pose now: where, degrees right, up, roll
var sec := Tally.new()          # this second's
var saved_pose: Array
var saved_toys: Array = []      # the toys before (start): their balls, cubes, throw's and drop's delays
var saved_rate := 0.0           # the rate to go back to
var preparing := 0              # variants left to run untimed before the first segment
var verdict := ""               # the comparison's line


## What this check draws besides the toys (main.draw_toys, Toys.draw): {"balls": [[centre (R^4),
## (colour, radius)]...], "cubes": [[centre, two axes (R^4), (colour, half size)]...]}: the cube
## before the eyes while near (the comparison's variant, the tour's last rows), the ball and the cube
## in the throat while throat. hp: the head as main has it ([l, n, frame]), basis: the head's in the
## play space.
func extras(hp: Array, basis: Basis) -> Dictionary:
	var out := {"balls": [], "cubes": []}
	if near:
		out.cubes.append(_near_cube(hp, basis))
	if hand_balls:
		var f: Array = hp[2]
		for side in [-1.0, 1.0]:
			var v: Vector3 = basis * Vector3(side * HAND_BALLS[1], HAND_BALLS[2], -HAND_BALLS[0])
			var T: Vector4 = v.x * f[0] + v.y * f[1] + v.z * f[2]
			var g: Array = main.space.geodesic(hp[0], hp[1], T.normalized(), v.length(), [])
			out.balls.append([main.space.embed(g[0], g[1]), Vector4(THROAT_COLOR.r, THROAT_COLOR.g, THROAT_COLOR.b, HAND_BALLS[3])])
	if throat:
		var sp: WormholeSpace = main.space
		var f: Array = hp[2]
		var fwd := -basis.z
		var T: Vector4 = fwd.x * f[0] + fwd.y * f[1] + fwd.z * f[2]
		var n0: Vector3 = hp[1]
		var t := Vector3(T.y, T.z, T.w)
		t -= t.dot(n0) * n0
		if t.length() < 1e-3:
			t = (Vector3(0.0, 0.0, 1.0) if absf(n0.z) < 0.9 else Vector3(1.0, 0.0, 0.0)).cross(n0)
		t = t.normalized()
		var half := maxf(sp.Lc, 0.5)
		for k in 2:
			var d: Array = THROAT_BALL if k == 0 else THROAT_CUBE
			var l: float = d[0] * half
			var n: Vector3 = (cos(d[1]) * n0 + sin(d[1]) * t).normalized()
			var C := sp.embed(l, n)
			if k == 0:
				out.balls.append([C, Vector4(THROAT_COLOR.r, THROAT_COLOR.g, THROAT_COLOR.b, d[2])])
			else:
				var a1 := n.cross(t).normalized()
				var e1 := sp.embed_vector(l, n, Vector4(0.0, a1.x, a1.y, a1.z)).normalized()
				var e2 := sp.embed_vector(l, n, Vector4(0.6, 0.8 * t.x, 0.8 * t.y, 0.8 * t.z)).normalized()
				e2 = (e2 - e2.dot(e1) * e1).normalized()
				out.cubes.append([C, e1, e2, Vector4(NEAR_COLOR.r, NEAR_COLOR.g, NEAR_COLOR.b, d[2])])
	return out


func _near_cube(hp: Array, basis: Basis) -> Array:
	var f: Array = hp[2]
	var fwd := -basis.z
	var T: Vector4 = fwd.x * f[0] + fwd.y * f[1] + fwd.z * f[2]
	var right: Vector4 = basis.x.x * f[0] + basis.x.y * f[1] + basis.x.z * f[2]
	var up: Vector4 = basis.y.x * f[0] + basis.y.y * f[1] + basis.y.z * f[2]
	var sp: WormholeSpace = main.space
	var g := sp.geodesic(hp[0], hp[1], T.normalized(), NEAR_CUBE[0], [right, up])
	var e1: Vector4 = sp.embed_vector(g[0], g[1], g[2][0]).normalized()
	var e2: Vector4 = sp.embed_vector(g[0], g[1], g[2][1])
	e2 = (e2 - e2.dot(e1) * e1).normalized()
	return [sp.embed(g[0], g[1]), e1, e2, Vector4(NEAR_COLOR.r, NEAR_COLOR.g, NEAR_COLOR.b, NEAR_CUBE[1])]



## The tour's steps.
func _make_tour() -> Array[Step]:
	var t: Array[Step] = []
	for at: Variant in TOUR_AT:
		for i in TOUR_PITCH.size():
			var y0 := 0.0 if i % 2 == 0 else 180.0
			t.append(_st(at, at, y0, 180.0 - y0, TOUR_PITCH[i], SWEEP,
					"%s, %.0f deg up, sweeping round" % [_name(at), TOUR_PITCH[i]], i == 0))
	t.append(_st(TOUR_FLY, -6.2, 0.0, 720.0, 0.0, 15.0, "flying along the axis through the throat, turning and nodding", true, 30.0))
	t.append(_st(-6.2, TOUR_FLY, 180.0, -540.0, 0.0, 15.0, "flying back, turning, nodding and tilting", true, 30.0, 20.0))
	for l in [6.2, 5.0, 0.0]:
		t.append(_st(l, l, 0.0, 360.0, 0.0, 4.0, "%s, turning round (yaw)" % _name(l), true))
		t.append(_st(l, l, 0.0, 0.0, 0.0, 6.0, "%s, nodding 60 deg (pitch)" % _name(l), false, 60.0))
		t.append(_st(l, l, 0.0, 0.0, 0.0, 4.0, "%s, tilting 30 deg (roll)" % _name(l), false, 0.0, 30.0))
	# the worst case: a cube right before the eyes, in the throat and at the curved zone's edge
	for l in [6.2, 5.0, 4.0, 0.0, -5.0]:
		var st := _st(l, l, 0.0, 360.0, 0.0, 4.0, "%s, a cube at the eyes, turning round and nodding" % _name(l), true, 40.0)
		st.near = true
		t.append(st)
	return t


## A place of PLACES: the throat its length (its own, or the one before the check), then the viewer.
func _put_place(place: Array) -> void:
	var cyl: float = place[3] if place.size() > 3 else saved_length
	if not is_equal_approx(2.0 * main.space.Lc, cyl):
		main.set_length(cyl)
	_put(place[0], place[1], place[2])


## The viewer at a pose (where: PLACES' top), turned yaw degrees right, the view pitch degrees up
## and roll degrees about the line of sight.
func _put(where: Variant, yaw: float, pitch: float, roll := 0.0) -> void:
	if where is float and not is_inf(where):
		main.place_on_axis(_axis_l(where), yaw, pitch, roll)
		return
	var stand: Vector3 = Vector3(main.START_POS.x, main.START_POS.y, 1.0) if where is float else where
	var xy := Vector2(stand.x, stand.y)
	var fwd: Vector2 = Vector2(main.START_FORWARD.x, main.START_FORWARD.y) if where is float else -xy.normalized()
	fwd = fwd.rotated(-deg_to_rad(yaw))      # to the right: clockwise in either chart (main.place's right)
	main.place(Vector3(xy.x, xy.y, 0.0), Vector3(fwd.x, fwd.y, 0.0), stand.z, pitch, roll)


## A pose's place in words, for the log.
func _name(where: Variant) -> String:
	if where is float:
		return "the start" if is_inf(where) else "on the axis at l %.1f m" % _axis_l(where)
	var v: Vector3 = where
	return "on %s's floor at (%.1f, %.1f)" % ["A" if v.z > 0.0 else "B", v.x, v.y]


## The l of a pose's place: the head's on the axis, the feet's standing (the "tf" lines).
func _l(where: Variant) -> float:
	if where is float and not is_inf(where):
		return _axis_l(where)
	var v: Vector3 = Vector3(main.START_POS.x, main.START_POS.y, 1.0) if where is float else where
	return main.space.point_from_chart(v.z, Vector3(v.x, v.y, 0.0))[0]


## The l of a place on the axis (PLACES' top): as far from the mouth on its side as from the video's.
func _axis_l(p: float) -> float:
	return 0.0 if p == 0.0 else signf(p) * maxf(absf(p) + main.space.L - MOUTH, 0.0)


## Between two places of a step: along the axis if both are on it, else the first.
static func _between(a: Variant, b: Variant, k: float) -> Variant:
	if a is float and b is float and not is_inf(a) and not is_inf(b):
		return lerpf(a, b, k)
	return a


func _st(at0: Variant, at1: Variant, y0: float, y1: float, p: float, secs: float, what: String,
		recover := false, nod := 0.0, roll := 0.0) -> Step:
	var st := Step.new()
	st.at = [at0, at1]
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
	variants.clear()
	for f in VARIANTS:
		variants.append(Setup.new(f))
	saved_pose = main.get_pose()
	var toys: Toys = main.toys
	saved_toys = [toys.world.balls.duplicate(), toys.world.cubes.duplicate(), toys.launch_in, toys.drop_in]
	if toys.enabled:
		toys.spawn()
		toys.launch_in = -1.0
		toys.drop_in = -1.0
	saved_length = 2.0 * main.space.Lc
	main.hold = true
	menu.set_eye(1.0)       # the menu keeps the size chosen (menu.render_scale)
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
	part_results.clear()
	zone_results.clear()
	_zone_counts.clear()
	tour = _make_tour()
	tour_results.clear()
	verdict = ""
	for i in PLACES.size():
		var r := []
		var pr := []
		var zr := []
		for v in variants:
			r.append([])
			pr.append([])
			zr.append([])
		results.append(r)
		part_results.append(pr)
		zone_results.append(zr)
		_zone_counts.append(Vector2i.ZERO)
		for v: int in order:
			if not variants[v].long or _long(PLACES[i]):
				plan.append(Vector2i(i, v))
	step = -1
	preparing = variants.size()
	var names := []
	for i in variants.size():
		names.append("%d = %s" % [i + 1, variants[i].label])
	print("bench: start, %s; %d places, %.1f s timed per segment; gravity view %s"
			% [", ".join(names), PLACES.size(), time, Renderer.GRAVITY_VIEWS[main.renderer.gravity_view]])
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
		print("tour: start at %.0f Hz, foveation %d, %d steps; \"tf\" lines: s, l m (the head's on the axis, the feet's standing), deg right, deg up, deg roll, refreshes the frame took, gpu ms, cpu ms render, cpu ms process, the frame before on the main thread: ms from main's start to drawn, main's script ms, ms waiting after (FrameRate.before_ms)"
				% [main.rate.rate, main.foveation.level, tour.size()])
		tour_t = 0.0
		_tour_step(0)


func _process(delta: float) -> void:
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

## Run a variant untimed at the first place it is timed at, so its pipelines are compiled before
## the timing.
func _prepare() -> void:
	phase_t = 0.0
	var v := variants[variants.size() - preparing]
	for place: Array in PLACES:
		if not v.long or _long(place):
			_put_place(place)
			break
	_use(v)


## A place of the long throat (PLACES' fourth).
static func _long(place: Array) -> bool:
	return place.size() > 3 and place[3] == LONG


## A variant's foveation, cube, hands' balls, bodies in the throat and tail.
func _use(v: Setup) -> void:
	near = v.near
	hand_balls = v.hands
	throat = v.throat
	main.renderer.tail_shown = v.tail
	main.renderer.tail_strips = v.strips
	if main.foveation.level != v.foveation:
		main.foveation.set_level(v.foveation)


func _segment() -> void:
	if phase_t < warm:
		return
	if gpu_ms.is_empty():
		_clock()
	gpu_ms.append(RenderingServer.viewport_get_measured_render_time_gpu(main.rate.target.get_viewport_rid()))
	var rate: FrameRate = main.rate
	if rate.parts_frame != part_frame and rate.parts_last.size() == FrameRate.PARTS.size():
		part_frame = rate.parts_frame
		part_ms.append(rate.parts_last)
		zone_ms.append(rate.zone_last)
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
	_put_place(place)
	_use(variants[plan[i].y])
	phase_t = 0.0
	gpu_ms.clear()
	part_ms.clear()
	zone_ms.clear()
	part_frame = main.rate.parts_frame
	if i == 0 or plan[i].x != plan[i - 1].x:
		clock_lo = 0
		clock_hi = 0
		_show("замер: место %d из %d, глаза закрыты" % [plan[i].x + 1, PLACES.size()])


func _end_segment() -> void:
	var r: Array = results[plan[step].x]
	gpu_ms.sort()
	r[plan[step].y].append(gpu_ms[gpu_ms.size() / 2] if not gpu_ms.is_empty() else 0.0)
	if near:
		_zone_counts[plan[step].x] = main.renderer.zone_count
	var med := PackedFloat32Array()
	for k in FrameRate.PARTS.size():
		var xs := part_ms.map(func(p: PackedFloat32Array) -> float: return p[k])
		xs.sort()
		med.append(xs[xs.size() / 2] if not xs.is_empty() else 0.0)
	part_results[plan[step].x][plan[step].y].append(med)
	var zmed := {}
	for z: Dictionary in zone_ms:
		for k: String in z:
			zmed[k] = []
	for k: String in zmed:
		var xs := zone_ms.map(func(z: Dictionary) -> float: return z.get(k, 0.0))
		xs.sort()
		zmed[k] = xs[xs.size() / 2]
	zone_results[plan[step].x][plan[step].y].append(zmed)
	var last := step + 1 >= plan.size() or plan[step + 1].x != plan[step].x
	if not last:
		return
	var place: Array = PLACES[plan[step].x]
	var parts := []
	var segs := []
	for v in variants.size():
		if r[v].is_empty():
			continue
		var s := "%d: %.2f ms" % [v + 1, _mean(r[v])]
		if v > 0:
			s += " (%.3f)" % (_mean(r[v]) / _mean(r[0]))
		parts.append(s)
		segs.append(_list(r[v]))
	print("bench: %s, %.0f deg right, %.0f deg up, cylinder %.0f m: %s; %.0f Hz, gpu clock %d..%d MHz, segments %s"
			% [_name(place[0]), place[1], place[2], 2.0 * main.space.Lc, ", ".join(parts), main.rate.rate, clock_lo, clock_hi, " ".join(segs)])
	# by part: each variant's mean over its segments of their medians, ms (FrameRate.PARTS)
	var by := []
	for v in variants.size():
		var segs_v: Array = part_results[plan[step].x][v]
		if segs_v.is_empty():
			continue
		var m := []
		for k in FrameRate.PARTS.size():
			m.append("%.2f" % _mean(segs_v.map(func(p: PackedFloat32Array) -> float: return p[k])))
		by.append("%d: %s" % [v + 1, " ".join(m)])
	var zc: Vector2i = _zone_counts[plan[step].x]
	print("bench parts: %s, %.0f deg right, %.0f deg up (%s): %s; with the cube before the eyes, in the curved zone %d balls, %d cubes"
			% [_name(place[0]), place[1], place[2], ", ".join(FrameRate.PARTS), "; ".join(by), zc.x, zc.y])
	# the zone's nodes and paths by pass (ZoneSections.TS_PASS): each variant's mean over its segments
	var zby := []
	for v in variants.size():
		var segs_z: Array = zone_results[plan[step].x][v]
		var sums := {}
		for z: Dictionary in segs_z:
			for k: String in z:
				sums[k] = sums.get(k, 0.0) + z[k]
		if not sums.is_empty():
			zby.append("%d: %s" % [v + 1, FrameRate.zone_text(sums, segs_z.size())])
	if not zby.is_empty():
		print("bench zone passes: %s, %.0f deg right, %.0f deg up: %s" % [_name(place[0]), place[1], place[2], "; ".join(zby)])


func _compared() -> void:
	_restore()      # the tour runs with the foveation chosen in the menu
	# each variant against the first, averaged over the places (geometric mean)
	var summary := []
	var pcts := []
	for v in range(1, variants.size()):
		summary.append("%s %.3f" % [variants[v].label, _ratio(v, 0)])
		var f := variants[v]
		if f.foveation > 0 and not f.near and not f.throat and not f.hands and not f.long:
			pcts.append("%s %+d%%" % [Menu.FOVEATIONS[variants[v].foveation], roundi(100.0 * (_ratio(v, 0) - 1.0))])
	print("bench: compared, on average over the places against %s: %s" % [variants[0].label, ", ".join(summary)])
	# for the menu: the slowest place without and with the cube before the eyes, and the foveation
	# and the tail's cost: the most the bodies in the throat cost more with it than without, at a place
	var cube := _variant(true, false, true)
	var bodies := _variant(false, true, true)
	var bare := _variant(false, true, false)
	var one_band := _variant(false, true, true, false)
	var tail_ms := 0.0
	var band_ms := 0.0
	for r in results:
		tail_ms = maxf(tail_ms, _mean(r[bodies]) - _mean(r[bare]))
		band_ms = maxf(band_ms, _mean(r[one_band]) - _mean(r[bare]))
	# and at foveation's strongest (the long throat's places): the most its tail costs there
	var fov_ms := 0.0
	var fov_tail := -1
	var fov_bare := -1
	for v in variants.size():
		var f := variants[v]
		if f.foveation == 5 and f.throat:
			if f.tail:
				fov_tail = v
			else:
				fov_bare = v
	if fov_tail >= 0 and fov_bare >= 0:
		for r in results:
			if not r[fov_tail].is_empty() and not r[fov_bare].is_empty():
				fov_ms = maxf(fov_ms, _mean(r[fov_tail]) - _mean(r[fov_bare]))
	var with_hands := -1
	var fov5 := -1
	for v in variants.size():
		var f := variants[v]
		if f.hands:
			with_hands = v
		if f.foveation == 5 and not f.near and not f.throat and not f.hands:
			fov5 = v
	# the hands' balls: the most they add at foveation's strongest at a place
	var hands_ms := 0.0
	if with_hands >= 0 and fov5 >= 0:
		for r in results:
			hands_ms = maxf(hands_ms, _mean(r[with_hands]) - _mean(r[fov5]))
	var parts := ["худшее место %.1f мс, с кубом у глаз %.1f мс, с мячом и кубом в горле %.1f мс (хвост — до %.1f мс, при сильнейшей фовеации — до %.1f мс, без полосок — до %.1f мс), мячи рук при сильнейшей фовеации — до %.1f мс"
			% [_worst(0), _worst(cube), _worst(bodies), tail_ms, fov_ms, band_ms, hands_ms]]
	parts.append("фовеация: " + ", ".join(pcts))
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
	var mt: Vector3 = main.rate.before_ms()
	print("tf %.3f %.2f %.0f %.0f %.0f %d %.2f %.2f %.2f %.2f %.2f %.2f" % [tour_t, _l(pose[0]), pose[1], pose[2], pose[3],
			meter.refreshes - refreshes_before, g, RenderingServer.viewport_get_measured_render_time_cpu(vp),
			Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0, mt.x, mt.y, mt.z])
	sec.frames += 1
	sec.refreshes += meter.refreshes - refreshes_before
	sec.gpu += g
	sec.gpu_max = maxf(sec.gpu_max, g)


func _tour_step(i: int) -> void:
	step = i
	phase_t = 0.0
	counting = false
	near = tour[i].near
	tour_results.append(Tally.new())
	if tour[i].recover:
		_put_place(PLACES[0])     # recover at the start
	_show("замер %.0f Гц: шаг %d из %d, глаза закрыты" % [main.rate.rate, i + 1, tour.size()])


func _tour(delta: float) -> void:
	var s := tour[step]
	var recover := TOUR_RECOVER * tour_scale if s.recover else 0.0
	if phase_t < recover:
		return
	var t := phase_t - recover
	var k := clampf(t / s.secs, 0.0, 1.0)
	pose = [_between(s.at[0], s.at[1], k), lerpf(s.yaw.x, s.yaw.y, k),
			s.pitch + s.nod * sin(TAU * t / (NOD_PERIOD * tour_scale)),
			s.roll * sin(TAU * t / (TILT_PERIOD * tour_scale))]
	_put(pose[0], pose[1], pose[2], pose[3])
	if not counting:
		counting = true
		_new_second()
		return
	tour_t += delta
	sec.t += delta
	var r := tour_results[step]
	if sec.t >= 1.0 or k >= 1.0:
		print("tour: step %d, %s, %.0f deg right, %.0f deg up, %.0f deg roll: %d frames of %d refreshes, gpu %.2f ms avg %.2f max"
				% [step + 1, _name(pose[0]), pose[1], pose[2], pose[3], sec.frames, sec.refreshes, sec.gpu / maxi(sec.frames, 1), sec.gpu_max])
		r.frames += sec.frames
		r.refreshes += sec.refreshes
		var share := float(sec.refreshes - sec.frames) / sec.refreshes if sec.refreshes > 0 else 0.0
		if share > r.worst:
			r.worst = share
			r.worst_pose = pose.duplicate()
		_new_second()
	if k >= 1.0:
		counting = false
		print("tour: %s: %d of %d refreshes without a new frame (%.1f%%), worst second %.0f%% %s, %.0f deg right, %.0f deg up"
				% [s.what, r.refreshes - r.frames, r.refreshes, 100.0 * r.missed(), 100.0 * r.worst,
				_name(r.worst_pose[0]), r.worst_pose[1], r.worst_pose[2]])
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
func _ru(at: Variant, yaw: float, pitch: float) -> String:
	var where := "старт"
	var b := false
	var y := fposmod(yaw, 360.0)    # degrees from the throat
	if at is Vector3:
		where = "на полу под горлом"
		b = (at as Vector3).z < 0.0
	elif not is_inf(at):
		var a := absf(at as float)
		where = "в полёте " + ("снаружи у края" if a >= main.space.L else ("на краю зоны" if a >= main.space.Lc else "в горле"))
		b = at < 0.0
		y = fposmod(yaw if at >= 0.0 else 180.0 - yaw, 360.0)
	if b:
		where += " (мир B)"
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
	# the toys as they were: at the length they were at (_restore)
	var toys: Toys = main.toys
	if toys.enabled and not saved_toys.is_empty():
		toys.world.balls.assign(saved_toys[0])
		toys.world.cubes.assign(saved_toys[1])
		toys.launch_in = saved_toys[2]
		toys.drop_in = saved_toys[3]
		main.draw_toys()
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


## As it runs: the foveation chosen in the menu, no cube.
func _restore() -> void:
	near = false
	hand_balls = false
	throat = false
	main.renderer.tail_shown = true
	main.renderer.tail_strips = true
	if not is_equal_approx(2.0 * main.space.Lc, saved_length):
		main.set_length(saved_length)
	main.foveation.set_level(menu.foveation)


## The first variant without foveation, with this build's tail, timed at every place, with the cube before the eyes, the bodies in the throat, the tail and its strips as asked.
func _variant(p_near: bool, p_throat: bool, p_tail: bool, p_strips := true) -> int:
	for v in variants.size():
		var f := variants[v]
		if f.foveation == 0 and not f.long and not f.hands and f.near == p_near and f.throat == p_throat and f.tail == p_tail and f.strips == p_strips:
			return v
	return 0


## Variant v's slowest place, ms.
func _worst(v: int) -> float:
	var w := 0.0
	for r in results:
		w = maxf(w, _mean(r[v]))
	return w


## A headset whose rate can be asked for and measured (not the desktop, not a test's fake one).
func _headset() -> bool:
	return main.rate.xr != null


func _show(s: String) -> void:
	menu.bench_status(s)


## A way the comparison times this build.
class Setup:
	var label: String
	var foveation: int              # Foveation.set_level's level
	var near: bool                  # the cube before the eyes
	var throat: bool                # the ball and the cube in the throat
	var tail: bool                  # the tail drawn (Renderer.tail_shown)
	var strips: bool                # its strips (Renderer.tail_strips)
	var long: bool                  # timed at the long throat's places only
	var hands: bool                 # the two balls of a hand's size before the chest (HAND_BALLS)

	## From a VARIANTS entry (its top: what each key means), the rest as the first's.
	func _init(d: Dictionary) -> void:
		label = d.label
		foveation = d.get("foveation", 0)
		near = d.get("near", false)
		throat = d.get("throat", false)
		tail = d.get("tail", true)
		strips = d.get("strips", true)
		long = d.get("long", false)
		hands = d.get("hands", false)


## A step of the tour: where (PLACES' top; along the axis if both ends are on it) and yaw (degrees
## to the right) from the first to the second over secs, pitch with a nod of that amplitude
## (degrees, NOD_PERIOD), a tilt of roll's (TILT_PERIOD); back to the start first if recover.
class Step:
	var at: Array                   # [from, to]
	var yaw: Vector2
	var pitch: float
	var nod: float
	var roll: float
	var secs: float
	var recover: bool
	var what: String
	var near := false               # the cube before the eyes


## Frames and refreshes counted: over a second, or over a step with its worst second.
class Tally:
	var t := 0.0                    # s counted
	var frames := 0
	var refreshes := 0
	var gpu := 0.0                  # ms, summed
	var gpu_max := 0.0
	var worst := 0.0                # the worst second's share of refreshes without a new frame
	var worst_pose: Array = [START, 0.0, 0.0, 0.0]   # and where: where, degrees right, up, roll

	func missed() -> float:
		return float(refreshes - frames) / refreshes if refreshes > 0 else 0.0
