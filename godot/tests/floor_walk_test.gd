extends SceneTree
## On foot through the throat: the whole app with the throat's centre at the floor's level
## (space.lift = 0, set before main._ready: the floor runs through the throat, WormholeSpace's top),
## through the desktop keys (the code paths the sticks and triggers drive), run with --fixed-fps 60
## in a small window (nothing here looks at the picture); exit status 1 on any failure:
##   godot --path . --resolution 160x90 --fixed-fps 60 -s res://tests/floor_walk_test.gd
## 1. it starts standing at chart A (10, 0) as ever, and the toys at rest stand on flat floor, out
##    of the 4 m round the axis where the floor bends (Toys.rest_place)
## 2. Shift + W for 3 s runs 12 m: 6 m to the curved zone and 6 m into it, to the throat's cylinder,
##    0.43 m past its middle: on the floor there, up the floor's normal, the head 1.6 m up the
##    throat's wall (1.52 m over the floor)
## 3. without gravity (F), Space for half a second flies 2 m up the wall from there, C comes back
##    down and lands on the floor where it took off
## 4. Shift + W for 3 s more: out into universe B, 24 m from the start along the floor, at chart B
##    (-10.86, 0), facing away from the throat, on the floor
## 5. R goes back to the start in universe A
## Every lift, and what a floor does to balls and cubes: tests/floor_test.gd.

const U := preload("res://tests/util.gd")

var main: Main
var frames := 0
var took_off := Vector4.ZERO


func _initialize() -> void:
	main = load("res://main.tscn").instantiate() as Main
	main.xr_name = "none"
	main.space.lift = 0.0
	root.add_child(main)


func _feet() -> Vector3:
	return main.space.chart_position(main.viewer.l, main.viewer.n)


## How far the body is from standing on the floor: the feet's height, up against the floor's normal.
func _off_floor() -> float:
	var v := main.viewer
	return maxf(absf(v.height()), ((v.frame[1] as Vector4) - main.space.floor_normal(v.l, v.n)).length())


func _process(_delta: float) -> bool:
	frames += 1
	var sp := main.space
	var v := main.viewer
	match frames:
		3:
			var p := _feet()
			U.check("the throat's centre at the floor's level: the start as ever", v.standing and v.l > sp.L and p.distance_to(Vector3(10, 0, 0)) < 1e-4
					and sp.floor_through() and absf(sp.floor_edge() - sp.Rout) < 1e-9, "feet at %s, lift %s" % [p, sp.lift])
			var inner := INF
			var off := 0.0
			for b: BallWorld.Body in main.toys.world.balls + main.toys.world.cubes:
				var cube := b as BallWorld.Cube
				var size: float = cube.half if cube else (b as BallWorld.Ball).radius
				var x := sp.chart_position(b.l, b.n)
				inner = minf(inner, Vector2(x.x, x.y).length() - (sqrt(2.0) * size if cube else size))
				off = maxf(off, absf(x.z - size))
			U.check("the toys at rest stand on flat floor", main.toys.world.balls.size() == 4 and main.toys.world.cubes.size() == 4
					and inner > sp.floor_edge() + Toys.REST_CLEAR - 1e-4 and off < 2e-3,
					"the nearest %.3f m from the axis (the floor bends within %.1f m), centres within %.6f m of their size up" % [inner, sp.floor_edge(), off])
			U.key(KEY_SHIFT, true)
			U.key(KEY_W, true)
		183:
			U.key(KEY_W, false)
			U.key(KEY_SHIFT, false)
		185:
			var hp := v.head(main.camera.transform.origin.y)
			var H := sp.height(hp[0], hp[1])
			var want := sp.rho0 * sin(Main.DESKTOP_HEAD_HEIGHT / sp.rho0)
			U.check("Shift + W for 3 s: 12 m, into the throat's cylinder", v.standing and absf(v.l - (sp.L - 6.0)) < 0.03 and absf(v.l) < sp.Lc
					and v.n.distance_to(Vector3(1, 0, 0)) < 1e-5, "l %.3f (expected %.3f), n %s" % [v.l, sp.L - 6.0, v.n])
			U.check("... on the floor, up its normal, the head up the throat's wall", _off_floor() < 1e-5 and absf(H - want) < 1e-4,
					"off by %s, the head %.4f m over the floor (expected %.4f)" % [_off_floor(), H, want])
			took_off = sp.embed(v.l, v.n)
			U.key(KEY_F, true)              # no gravity: it goes up and comes down by the keys alone
		187:
			U.key(KEY_F, false)
			U.key(KEY_SPACE, true)
		217:
			U.key(KEY_SPACE, false)
		218:
			var want := sp.rho0 * sin(2.0 / sp.rho0)
			U.check("Space for half a second flies 2 m up the throat's wall", not v.standing and absf(v.height() - want) < 2e-3,
					"standing %s, the feet %.4f m over the floor (expected %.4f)" % [v.standing, v.height(), want])
			U.key(KEY_C, true)
		260:
			U.key(KEY_C, false)
		262:
			var d := (sp.embed(v.l, v.n) - took_off).length()
			U.check("C comes back down and lands where it took off", v.standing and _off_floor() < 1e-5 and d < 2e-3,
					"standing %s, off the floor by %s, %.5f m from there" % [v.standing, _off_floor(), d])
			U.key(KEY_SHIFT, true)
			U.key(KEY_W, true)
		442:
			U.key(KEY_W, false)
			U.key(KEY_SHIFT, false)
		444:
			var p := _feet()
			var want := -(sp.Rout + 24.0 - (10.0 - sp.Rout) - 2.0 * sp.L)
			var fwd := WormholeSpace.vector_to_chart(-1.0, v.n, -v.frame[2])
			U.check("Shift + W for 3 s more: out into universe B, 24 m from the start", v.standing and v.l < -sp.L
					and absf(p.x - want) < 0.05 and absf(p.y) < 0.01, "l %.3f, chart B (%.3f, %.3f), expected (%.3f, 0)" % [v.l, p.x, p.y, want])
			U.check("... on B's floor, facing away from the throat", _off_floor() < 1e-5 and fwd.distance_to(Vector3(-1, 0, 0)) < 1e-4,
					"off by %s, forward %s" % [_off_floor(), fwd])
			U.key(KEY_R, true)
		446:
			U.key(KEY_R, false)
		448:
			var p := _feet()
			U.check("R goes back to the start in universe A", v.standing and v.l > sp.L and p.distance_to(Vector3(10, 0, 0)) < 1e-4, "feet at %s" % p)
			U.finish(self)
	return false
