class_name Placing
extends RefCounted
## Moving the wormhole's mouth in the universe one stands in (the buttons: README.md,
## «Управление»). The right controller's X (P on the desktop) takes hold of it where it stands, and
## from then on the throat itself follows: the right hand turning along the floor turns the way to it
## about the hand (the head on the desktop),
## the right stick up and down takes it farther and nearer, left and right turns it; it glides there
## (FOLLOW_TIME), moved as main.move_mouth moves it, so what one does shows at once. A (Enter) or X
## again lets go of it there, B (Backspace) puts it back where it stood, the menu lets go too.
## Where it may not go (allowed: outside the world's wall, onto the scene's objects or the viewer)
## it stays, and a red ring on the floor (Renderer.set_beam's PLACING tube) shows where the hand
## points, the new curved zone's edge with a tick out along its chart's +x, and the line below says
## why. Meanwhile the right stick, A and B are this file's (main.gd's top). Not during the speed
## check, nor in the one-eye check's build (its scene is built for the mouths as they stand at the
## start: check_scene.gd). The log has a line at each start, each place it would not go (once per
## reason) and at the end.
## The ring's points left out are those in the curved zone as it stands now (no place of the world
## there yet): drawn with no thickness.

const HAND_CLEAR := 1.5         # m: the curved zone's edge at least this far from the hand
const DIST_MAX := 30.0          # m from the hand to the centre, along the floor
const DIST_SPEED := 6.0         # m/s at full stick
const TURN_SPEED := deg_to_rad(90.0)    # per second at full stick
const FOLLOW_TIME := 0.12       # s: the throat closes on where it is led as exp(-t / FOLLOW_TIME) (the hand's tremor, far off, is no shaking)
const CLEAR := 0.3              # m: the scene's objects and the wall this far from the curved zone
const VIEWER_CLEAR := 1.0       # m: the feet and the head this far from it
const RING_POINTS := 40         # the ring's points (one more closes it; with the tick within Renderer.BEAM_POINTS)
const RING_Z := 0.05            # m over the floor
const RING_RADIUS := 0.04       # m: the tube's
const TICK := 1.2               # m out from the ring along the throat's chart +x
const COLOR_NO := Color(0.95, 0.2, 0.15)

var main: Main
var active := false
var side := 1.0                 # the universe whose mouth moves: the viewer's
var dist := 10.0                # m from the hand to where the centre is led, along the floor
var turn := 0.0                 # rad: the turn it is led to (WormholeSpace.mouths)
var centre := Vector2.ZERO      # where it is led, in that world
var ok := false                 # allowed there; why not, for the line below
var why := ""
var aim := Vector2.RIGHT        # the way along the floor it is led, from the hand (world)
var aim_off := 0.0              # rad: that way less the hand's (start: the throat where it stands)
var from := Vector3.ZERO        # where the mouth stood at the start (B puts it back)
var pushed := 0                 # toys pushed out of the way since the start
var pts := PackedVector4Array() # the red ring to draw: points of R^4, radii, colour (Renderer.set_beam)
var radii := PackedFloat32Array()
var col := COLOR_NO
var _was := {}
var _said := ""                 # the last reason said (once per reason)


## Each frame, after the menu took its buttons (main._process): the buttons, the sticks, where the
## mouth is led, the throat after it, the ring.
func update(dt: float) -> void:
	var xr := main.in_xr
	var rh := main.right_hand
	var toggle := _pressed("toggle", Input.is_key_pressed(KEY_P) or (xr and rh.is_button_pressed(&"place_button")))
	var put := _pressed("put", Input.is_key_pressed(KEY_ENTER) or (xr and rh.is_button_pressed(&"ax_button")))
	var cancel := _pressed("cancel", Input.is_key_pressed(KEY_BACKSPACE) or (xr and rh.is_button_pressed(&"by_button")))
	if main.menu_active or main.hold or main.show_check:
		if active:
			finish()
		return
	if not active:
		if toggle:
			start()
		return
	if cancel:
		back()
		return
	if toggle or put:
		finish()
		return
	var s := Vector2(float(Input.is_key_pressed(KEY_E)) - float(Input.is_key_pressed(KEY_Q)),
			float(Input.is_key_pressed(KEY_I)) - float(Input.is_key_pressed(KEY_K)))
	if xr:
		s += rh.get_vector2(&"primary")
	s = s.clamp(-Vector2.ONE, Vector2.ONE)
	var a := Vector2(maxf(absf(s.x) - Main.STICK_DEAD_ZONE, 0.0), maxf(absf(s.y) - Main.STICK_DEAD_ZONE, 0.0)) / (1.0 - Main.STICK_DEAD_ZONE)
	dist = clampf(dist + signf(s.y) * a.y * DIST_SPEED * dt, main.space.Rout + HAND_CLEAR, DIST_MAX)
	turn = wrapf(turn - signf(s.x) * a.x * TURN_SPEED * dt, -PI, PI)
	_aim()
	_follow(dt)


## Take hold of the viewer's universe's mouth (not from the curved zone), led from where it stands.
func start() -> void:
	var v := main.viewer
	if absf(v.l) <= main.space.L:
		main.menu.notice("сначала выйди из кривой зоны")
		print("placing: not from the curved zone (l %.2f)" % v.l)
		return
	active = true
	side = signf(v.l)
	from = main.space.mouths[WormholeSpace.side_index(side)]
	turn = from.z
	pushed = 0
	_said = ""
	var hand := _hand()
	var to := Vector2(from.x, from.y) - Vector2(hand[0].x, hand[0].y)
	dist = clampf(to.length(), main.space.Rout + HAND_CLEAR, DIST_MAX)
	var d := Vector2(hand[1].x, hand[1].y)
	aim_off = d.angle_to(to) if d.length() > 0.2 else 0.0
	print("placing: start in universe %s, the mouth at (%.2f, %.2f) turned %.0f deg, %.1f m from the %s"
			% ["A" if side > 0.0 else "B", from.x, from.y, rad_to_deg(from.z), dist, hand[2]])
	main.menu.notice("горло едет за рукой; правый стик — дальше-ближе и поворот; A — оставить, B — вернуть")
	_aim()


## Let go of it: where it is led if it may stand there (it has not quite glided there yet), else where
## it is.
func finish() -> void:
	var to := Vector3(centre.x, centre.y, turn)
	var m: Vector3 = main.space.mouths[WormholeSpace.side_index(side)]
	if ok and m != to:
		pushed += main.move_mouth(side, to, false)
		m = to
	_end("placed")
	if m != from:
		main.menu.notice("червоточина переставлена")
		if main.in_xr:
			Menu._tick(main.right_hand)


## Put it back where it stood at the start (if the viewer has not walked in there since).
func back() -> void:
	var a := allowed(side, from)
	if a[0]:
		pushed += main.move_mouth(side, from, false)
		main.menu.notice("червоточина вернулась на место")
	else:
		main.menu.notice("назад нельзя: " + a[1])
	_end("put back" if a[0] else "left (back: %s)" % a[1])


func _end(how: String) -> void:
	var m: Vector3 = main.space.mouths[WormholeSpace.side_index(side)]
	print("placing: %s, universe %s's mouth from (%.2f, %.2f) turned %.0f deg to (%.2f, %.2f) turned %.0f deg; %d toys pushed out of it"
			% [how, "A" if side > 0.0 else "B", from.x, from.y, rad_to_deg(from.z), m.x, m.y, rad_to_deg(m.z), pushed])
	active = false
	pts = PackedVector4Array()
	radii = PackedFloat32Array()


## The throat a step toward where it is led, if it may stand there (else straight there, past what is
## in the way between); not at all where it may not.
func _follow(dt: float) -> void:
	if not ok:
		return
	var m: Vector3 = main.space.mouths[WormholeSpace.side_index(side)]
	var to := Vector3(centre.x, centre.y, turn)
	var k := 1.0 - exp(-dt / FOLLOW_TIME)
	var next := Vector3(lerpf(m.x, to.x, k), lerpf(m.y, to.y, k), m.z + angle_difference(m.z, to.z) * k)
	if Vector2(next.x - m.x, next.y - m.y).length() < 1e-4 and absf(next.z - m.z) < 1e-5:
		return
	if not allowed(side, next)[0]:
		next = to
	pushed += main.move_mouth(side, next, false)


## Where it is led and whether it may go there; the red ring there where not.
func _aim() -> void:
	var sp := main.space
	pts = PackedVector4Array()
	radii = PackedFloat32Array()
	if main.viewer.l * side <= sp.L:
		_not("сначала выйди из кривой зоны")
		return
	var hand := _hand()
	var d := Vector2(hand[1].x, hand[1].y)
	if d.length() > 0.2:
		aim = d.normalized().rotated(aim_off)
	centre = Vector2(hand[0].x, hand[0].y) + dist * aim
	var a := allowed(side, Vector3(centre.x, centre.y, turn))
	ok = a[0]
	if ok:
		_said = ""
		return
	_not(a[1])
	var ring := []
	var e := Vector2(cos(turn), sin(turn))
	ring.append(centre + (sp.Rout + TICK) * e)
	for k in RING_POINTS + 1:
		var t := turn + TAU * k / RING_POINTS
		ring.append(centre + sp.Rout * Vector2(cos(t), sin(t)))
	for q: Vector2 in ring:
		var c := sp.chart_from_world(side, Vector3(q.x, q.y, RING_Z))
		var r := Vector2(c.x, c.y).length()
		var shown := r >= sp.Rout + 0.02
		if not shown:
			var f := Vector2(c.x, c.y) / maxf(r, 1e-6) * (sp.Rout + 0.02)
			c = Vector3(f.x, f.y, c.z)
		var p := sp.point_from_chart(side, c)
		pts.append(sp.embed(p[0], p[1]))
		radii.append(RING_RADIUS if shown else 0.0)


## Not allowed, for reason w: said on the line below and in the log once while it holds.
func _not(w: String) -> void:
	ok = false
	why = w
	if w != _said:
		_said = w
		main.menu.notice("сюда нельзя: " + w)
		print("placing: not to (%.2f, %.2f): %s" % [centre.x, centre.y, w])


## The hand that points in the viewer's world (the right one in XR, the head on the desktop or with
## the hand not tracked): [where, which way, which: "hand" or "head"], world coordinates, worked out
## from the feet's place and the room's axes there (the flat universe: the room's axes are the same
## everywhere in it).
func _hand() -> Array:
	var sp := main.space
	var v := main.viewer
	var feet := sp.world_position(v.l, v.n)
	var ax := []
	for k in 3:
		ax.append(sp.vector_to_world(side, v.n, v.frame[k]))
	var head := main.camera.transform
	var tracked: bool = main.in_xr and main.right_hand.get_has_tracking_data()
	var at: Transform3D = main.right_hand.transform if tracked else head
	var o := at.origin - Vector3(head.origin.x, 0.0, head.origin.z)
	var f := -at.basis.z
	return [feet + o.x * ax[0] + o.y * ax[1] + o.z * ax[2], f.x * ax[0] + f.y * ax[1] + f.z * ax[2],
			"hand" if tracked else "head"]


## Whether the side's mouth may stand at m (Vector3(x, y, turn) of that world): [true, ""], or
## [false, why] (for the line below).
func allowed(p_side: float, m: Vector3) -> Array:
	var sp := main.space
	var c := Vector3(m.x, m.y, 0.0)
	var reach := sp.Rout + CLEAR
	if Vector2(m.x, m.y).length() + reach > BallWorld.WORLD_RADIUS:
		return [false, "там стена мира"]
	var key := "A" if p_side > 0.0 else "B"
	for s: Array in main.scene.get("spheres_" + key, []):
		if (Vector3(s[0], s[1], s[2]) - c).length() < s[3] + reach:
			return [false, "мешает шар"]
	for p: Array in main.scene.get("pillars_" + key, []):
		if Vector2(p[0] - m.x, p[1] - m.y).length() < p[2] + reach:
			return [false, "мешает столб"]
	for b: Array in main.scene.get("boxes_" + key, []):
		var bc := Vector3(b[0], b[1], b[2])
		var hs := Vector3.ONE * float(b[3])
		if (c.clamp(bc - hs, bc + hs) - c).length() < reach:
			return [false, "мешает ящик"]
	var v := main.viewer
	var hp := v.head(main.camera.transform.origin.y)
	if v.l * p_side <= sp.L or hp[0] * p_side <= sp.L:
		return [false, "сначала выйди из кривой зоны"]
	for q: Vector3 in [sp.world_position(v.l, v.n), sp.world_position(hp[0], hp[1])]:
		if (q - c).length() < sp.Rout + VIEWER_CLEAR:
			return [false, "слишком близко к тебе"]
	return [true, ""]


func _pressed(key: String, down: bool) -> bool:
	var before: bool = _was.get(key, false)
	_was[key] = down
	return down and not before
