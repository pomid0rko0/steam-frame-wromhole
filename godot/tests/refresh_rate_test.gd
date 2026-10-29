extends SceneTree
## The refresh rate logic without a headset: how display times from OpenXR turn into the
## measured rate and missed frames, the verdict (frame_rate.gd), and reading the GPU clock.
##   godot --headless --xr-mode off --path . -s res://tests/refresh_rate_test.gd

const U := preload("res://tests/util.gd")
const RateMeter := preload("res://rate_meter.gd")


func check(name: String, got: Variant, want: Variant) -> void:
	var same: bool = is_equal_approx(got, want) if got is float else got == want
	U.check(name, same, "%s%s" % [got, "" if same else ", expected %s" % [want]])


func _initialize() -> void:
	# a steady 90 Hz display, a frame for every refresh
	var p90 := 11_111_111
	var m := RateMeter.new()
	var t := 1_000_000_000
	m.add(t, p90)
	for i in 90:
		t += p90
		m.add(t, p90)
	check("90 Hz: measured rate", snappedf(m.rate(), 0.01), 90.0)
	check("90 Hz: frames", m.frames, 90)
	check("90 Hz: missed", m.missed(), 0)

	# every 10th frame late by one refresh, and each frame seen twice (as _process may)
	m.reset_window()
	for i in 90:
		t += p90 * (2 if i % 10 == 9 else 1)
		m.add(t, p90)
		m.add(t, p90)
	check("90 Hz, every 10th late: frames", m.frames, 90)
	check("90 Hz, every 10th late: missed", m.missed(), 9)

	# half rate: every frame takes two refreshes
	m.reset_window()
	for i in 36:
		t += 2 * 13_888_889
		m.add(t, 13_888_889)
	check("72 Hz at half rate: missed", m.missed(), 36)
	check("72 Hz at half rate: measured rate", snappedf(m.rate(), 0.01), 72.0)

	# a runtime that paces a slow app at every 2nd refresh (rate_meter.gd): the display is still
	# 72 Hz, each frame missed one refresh
	m.reset_window()
	for i in 36:
		t += 2 * 13_888_889
		m.add(t, 2 * 13_888_889)
	check("72 Hz, paced at 36: display rate", snappedf(m.rate(), 0.01), 72.0)
	check("72 Hz, paced at 36: paced rate", snappedf(m.paced_rate(), 0.01), 36.0)
	check("72 Hz, paced at 36: missed", m.missed(), 36)

	# slow from the first frame: only the expected rate tells the display's
	var slow := RateMeter.new()
	for i in 11:
		slow.add(t + i * 2 * 13_888_889, 2 * 13_888_889, 72.0)
	check("slow from the start, 72 expected: display rate", snappedf(slow.rate(), 0.01), 72.0)
	check("slow from the start, 72 expected: missed", slow.missed(), 10)

	# an expected rate that does not fit the prediction is ignored
	var wrong := RateMeter.new()
	for i in 11:
		wrong.add(t + i * 13_888_889, 13_888_889, 120.0)
	check("72 Hz, 120 expected: display rate", snappedf(wrong.rate(), 0.01), 72.0)
	check("72 Hz, 120 expected: missed", wrong.missed(), 0)

	# a whole multiple too large to be pacing (100 ms at 90 Hz expected) is not believed
	check("20 Hz paced at 10, 90 expected", RateMeter.refresh_period(50_000_000, 100_000_000, 90.0), 50_000_000)

	# the display really changes rate: 90 -> 72 (not a whole multiple), 72 -> 144 (faster)
	check("display 90 -> 72", RateMeter.refresh_period(11_111_111, 13_888_889, 0.0), 13_888_889)
	check("display 72 -> 144", RateMeter.refresh_period(13_888_889, 6_944_444, 0.0), 6_944_444)
	check("display 144 -> 72, 72 expected", RateMeter.refresh_period(6_944_444, 13_888_889, 72.0), 13_888_889)

	# seen on the Frame while switching: the display passes through other rates; once the
	# runtime says the new one, a period that is a whole multiple of it is pacing
	check("Frame, 96 -> 108 via 72: 108 at half", RateMeter.refresh_period(13_888_889, 18_518_519, 108.0), 9_259_259)
	check("Frame, 144 -> 80: 80 at half, not 120 at a third", RateMeter.refresh_period(6_944_444, 25_000_000, 80.0), 12_500_000)

	# a pause (session not running) is not missed frames; no timing at all is ignored
	m.reset_window()
	m.add(t + 3_000_000_000, p90)
	m.add(0, 0)
	check("pause: frames", m.frames, 0)
	check("pause: missed", m.missed(), 0)

	# the verdict over the last seconds: [frames shown, refreshes] each
	check("verdict: one second is too little", FrameRate.keeps_up(_seconds([[90, 90]])), null)
	check("verdict: all frames", FrameRate.keeps_up(_seconds([[90, 90], [90, 90]])), true)
	check("verdict: 1 missed of 450", FrameRate.keeps_up(_seconds([[90, 90], [90, 90], [89, 90], [90, 90], [90, 90]])), true)
	check("verdict: 9 missed of 180", FrameRate.keeps_up(_seconds([[81, 90], [90, 90]])), false)
	check("verdict: half rate", FrameRate.keeps_up(_seconds([[36, 72], [36, 72]])), false)

	# the GPU's clock as the kernel shows it: /sys/class/devfreq/<address>.gpu, a symlink
	var fake := ProjectSettings.globalize_path("user://fake_devfreq")
	OS.execute("rm", ["-rf", fake])
	for d in ["devices/3d00000.gpu", "devices/soc:qcom,cpu-bw", "class"]:
		DirAccess.make_dir_recursive_absolute(fake + "/" + d)
	for f in [["cur_freq", "680000000"], ["governor", "msm-adreno-tz"], ["min_freq", "220000000"],
			["max_freq", "1100000000"], ["available_frequencies", "220000000 680000000 1100000000"]]:
		var w := FileAccess.open(fake + "/devices/3d00000.gpu/" + f[0], FileAccess.WRITE)
		w.store_string(f[1] + "\n")
		w.close()
	OS.execute("ln", ["-s", fake + "/devices/soc:qcom,cpu-bw", fake + "/class/soc:qcom,cpu-bw"])
	OS.execute("ln", ["-s", fake + "/devices/3d00000.gpu", fake + "/class/3d00000.gpu"])
	var rate := FrameRate.new()
	rate.devfreq = fake + "/class"
	rate._find_gpu_clock()
	check("GPU clock found among devfreq symlinks", rate.gpu_clock, fake + "/class/3d00000.gpu")
	check("GPU clock read in MHz", rate.gpu_mhz(), 680)
	rate.free()

	# a real sysfs file: says 4096 bytes, holds a few
	if FileAccess.file_exists("/sys/devices/system/cpu/online"):
		var v := FrameRate.read_line("/sys/devices/system/cpu/online")
		check("sysfs file read up to its value (%s)" % v, v.is_valid_int() or v.contains("-") or v.contains(","), true)
		check("sysfs value is clean ASCII", v.to_ascii_buffer().size(), v.length())

	U.finish(self)


static func _seconds(counts: Array) -> Array[FrameRate.Second]:
	var out: Array[FrameRate.Second] = []
	for c: Array in counts:
		var s := FrameRate.Second.new()
		s.shown = c[0]
		s.refreshes = c[1]
		out.append(s)
	return out
