extends SceneTree
##   godot --headless --path . -s res://tests/next_rate_test.gd

func _initialize() -> void:
	var M = load("res://main.gd")
	var r := [90.0, 72.0, 144.0, 80.0, 120.0]
	var cases := [[72.0, 80.0], [80.0, 90.0], [90.0, 120.0], [120.0, 144.0], [144.0, 72.0], [0.0, 72.0], [89.9, 120.0]]
	var ok := true
	for c in cases:
		var got: float = M.next_rate(r, c[0])
		ok = ok and is_equal_approx(got, c[1])
		print("%5.1f -> %5.1f (expected %5.1f)" % [c[0], got, c[1]])
	print("PASS" if ok else "FAIL")
	quit()
