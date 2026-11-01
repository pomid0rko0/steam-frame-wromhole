class_name Placing
extends RefCounted
## Moving the wormhole's mouth in the universe one stands in (the buttons: README.md,
## «Управление»). The right controller's X (P on the desktop) starts it; the right hand points the
## way along the floor (the head on the desktop), the right stick up and down takes the throat
## farther and nearer, left and right turns it; A (Enter) puts it there, B (Backspace), X again or
## the menu leave it where it was. Meanwhile a ring on the floor (Renderer.set_beam's PLACING tube)
## shows where the new curved zone's edge would be, with a tick out along its chart's +x: green
## where the mouth may stand (allowed: within the world's wall, clear of the scene's objects and of
## the viewer), red where not; and the right stick, A and B are this file's (main.gd's top). Main
## moves the mouth (main.move_mouth). Not during the speed check, nor in the one-eye check's build
## (its scene is built for the mouths as they stand at the start: check_scene.gd).
## The ring's points left out are those in the curved zone as it stands now (no place of the world
## there yet): drawn with no thickness.

const HAND_CLEAR := 1.5         # m: the new curved zone's edge at least this far from the hand
const DIST_MAX := 30.0          # m from the hand to the new centre, along the floor
const DIST_SPEED := 6.0         # m/s at full stick
const TURN_SPEED := deg_to_rad(90.0)    # per second at full stick
const CLEAR := 0.3              # m: the scene's objects and the wall this far from the new curved zone
const VIEWER_CLEAR := 1.0       # m: the feet and the head this far from it
const RING_POINTS := 40         # the ring's points (one more closes it; with the tick within Renderer.BEAM_POINTS)
const RING_Z := 0.05            # m over the floor
const RING_RADIUS := 0.04       # m: the tube's
const TICK := 1.2               # m out from the ring along the throat's chart +x
const COLOR_OK := Color(0.3, 0.95, 0.45)
const COLOR_NO := Color(0.95, 0.2, 0.15)

var main: Main
var active := false
var side := 1.0                 # the universe whose mouth moves: the viewer's
var dist := 10.0                # m from the hand to the new centre along the floor
var turn := 0.0                 # rad: the new turn (WormholeSpace.mouths)
var centre := Vector2.ZERO      # the new centre in that world
var ok := false                 # allowed there; why not, for the line below
var why := ""
var aim := Vector2.RIGHT        # the last way along the floor the hand pointed (world)
var pts := PackedVector4Array() # the ring to draw: points of R^4, radii, colour (Renderer.set_beam)
var radii := PackedFloat32Array()
var col := COLOR_OK
var _was := {}


## Each frame, after the menu took its buttons (main._process): the buttons, the sticks, where the
## mouth would go, the ring.
func update(dt: float) -> void:
	var xr := main.in_xr
	var rh := main.right_hand
	var toggle := _pressed("toggle", Input.is_key_pressed(KEY_P) or (xr and rh.is_button_pressed(&"place_button")))
	var put := _pressed("put", Input.is_key_pressed(KEY_ENTER) or (xr and rh.is_button_pressed(&"ax_button")))
	var cancel := _pressed("cancel", Input.is_key_pressed(KEY_BACKSPACE) or (xr and rh.is_button_pressed(&"by_button")))
	if main.menu_active or main.hold or main.show_check:
		if active:
			stop()
		return
	if not active:
		if toggle:
			start()
		return
	if toggle or cancel:
		stop()
		main.menu.notice("червоточина осталась на месте")
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
	if put:
		if ok:
			var m := Vector3(centre.x, centre.y, turn)
			stop()
			main.move_mouth(side, m)
			main.menu.notice("червоточина переставлена")
			if xr:
				Menu._tick(rh)
		else:
			main.menu.notice("сюда нельзя: " + why)


## Start: the viewer's universe (not from the curved zone), the throat as far and as turned as now.
func start() -> void:
	var v := main.viewer
	if absf(v.l) <= main.space.L:
		main.menu.notice("сначала выйди из кривой зоны")
		return
	active = true
	side = signf(v.l)
	turn = main.space.mouths[WormholeSpace.side_index(side)].z
	var hand := _hand()
	var now := main.space.world_from_chart(side, Vector3.ZERO)
	dist = clampf((Vector2(now.x, now.y) - Vector2(hand[0].x, hand[0].y)).length(), main.space.Rout + HAND_CLEAR, DIST_MAX)
	print("placing: start in universe %s" % ("A" if side > 0.0 else "B"))
	main.menu.notice("рука — куда, правый стик — дальше-ближе и поворот, A — поставить, B — отмена")
	_aim()


func stop() -> void:
	active = false
	pts = PackedVector4Array()
	radii = PackedFloat32Array()


## Where the mouth would go and whether it may, and the ring there.
func _aim() -> void:
	var sp := main.space
	pts = PackedVector4Array()
	radii = PackedFloat32Array()
	if main.viewer.l * side <= sp.L:
		ok = false
		why = "сначала выйди из кривой зоны"
		return
	var hand := _hand()
	var d := Vector2(hand[1].x, hand[1].y)
	if d.length() > 0.2:
		aim = d.normalized()
	centre = Vector2(hand[0].x, hand[0].y) + dist * aim
	var a := allowed(side, Vector3(centre.x, centre.y, turn))
	ok = a[0]
	why = a[1]
	col = COLOR_OK if ok else COLOR_NO
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


## The hand that points in the viewer's world (the right one in XR, the head on the desktop):
## [where, which way], world coordinates, worked out from the feet's place and the room's axes there
## (the flat universe: the room's axes are the same everywhere in it).
func _hand() -> Array:
	var sp := main.space
	var v := main.viewer
	var feet := sp.world_position(v.l, v.n)
	var ax := []
	for k in 3:
		ax.append(sp.vector_to_world(side, v.n, v.frame[k]))
	var head := main.camera.transform
	var at: Transform3D = main.right_hand.transform if main.in_xr and main.right_hand.get_has_tracking_data() else head
	var o := at.origin - Vector3(head.origin.x, 0.0, head.origin.z)
	var f := -at.basis.z
	return [feet + o.x * ax[0] + o.y * ax[1] + o.z * ax[2], f.x * ax[0] + f.y * ax[1] + f.z * ax[2]]


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
