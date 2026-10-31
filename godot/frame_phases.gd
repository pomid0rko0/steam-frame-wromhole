class_name FramePhases
extends OpenXRExtensionWrapper
## Where a frame's time goes on the main thread: for the log's lines about late frames
## (frame_rate.gd) and the speed check's tour (bench.gd).
##
## Godot (the version tools/setup.sh installs) renders on the main thread here (project.godot
## leaves rendering/driver/threads/thread_model at Safe), so a frame is one stretch of that thread,
## cut at these points:
##   0. right before xrWaitFrame, where SteamVR holds the thread till the next frame is due (OpenXR
##      calls _set_frame_wait_info_and_get_next_pointer there); also the physics and a SceneTree
##      script's own _process (the tests') come before 1
##   1. the scripts' start (SceneTree.process_frame)
##   2. the drawing's start (RenderingServer.frame_pre_draw)
##   3. the 3D pass's start (picture: an effect before the opaque pass, first on the XR camera's
##      compositor); before it xrLocateViews, xrBeginFrame, the culling, and the wait for the
##      swapchain's image (xrWaitSwapchainImage: SteamVR's compositor still reading it)
##   4. right before xrEndFrame (_set_frame_end_info_and_get_next_pointer); before it the passes'
##      recording, their submission and the wait for the GPU to finish the frame before (Godot's
##      RenderingDevice keeps two frames in flight: frame_queue_size)
##   5. the drawing's end (RenderingServer.frame_post_draw), after xrEndFrame
## and the next frame's 0; PHASES names the stretches between. An effect before the opaque pass
## leaves the Mobile renderer's render passes as they are (it splits them only for effects after
## it: split_pass.gd).
##
## At each point the kernel's /proc/thread-self/schedstat (one system call) says how the thread
## spent the stretch: running, waiting for a core (runnable while other threads had them all), or
## neither: asleep (waiting for SteamVR, the GPU, a file, a lock). The kernel adds the time waiting
## for a core when the thread gets one back, so that is exact per stretch; the time running only at
## its ticks and the thread's switches, so that is given for the whole frame, a tick off at most.
##
## OpenXR takes a frame info extension only while its session is not running (start, from
## FrameRate._ready, before the first frame) and keeps a pointer to it till it shuts down: never
## freed. stop, as the scene goes, lets go of all it holds.

const PHASES := ["SteamVR's wait", "scripts", "to the picture", "drawing and the GPU", "handing over", "between"]
const SCHEDSTAT := "/proc/thread-self/schedstat"
const VALUES := 4                   # per point: us, ns running, ns waiting for a core, times scheduled in

var picture := Mark.new()           # point 3, on the XR camera's compositor (main.gd)
var on := false
var _stat: FileAccess
var _cur := PackedInt64Array()      # this frame's points 0..5, VALUES each; 0 us: not reached
var _last := PackedInt64Array()     # the last whole frame's, and the next frame's point 0
var _have := false


func _init() -> void:
	_cur.resize(PHASES.size() * VALUES)
	_last.resize((PHASES.size() + 1) * VALUES)
	picture.phases = self


## Measure from the next frame on; api's session must not be running yet.
func start(api: OpenXRAPIExtension) -> void:
	if int(ProjectSettings.get_setting("rendering/driver/threads/thread_model", 1)) != 1:
		print("phases: rendering off the main thread, not measured")
		return
	_stat = FileAccess.open(SCHEDSTAT, FileAccess.READ)
	api.register_frame_info_extension(self)
	(Engine.get_main_loop() as SceneTree).process_frame.connect(_scripts)
	RenderingServer.frame_pre_draw.connect(_drawing)
	RenderingServer.frame_post_draw.connect(_drawn)
	on = true
	print("phases: measured; %s %s" % [SCHEDSTAT, "read" if _stat else "missing: no running, waiting, asleep"])


## The scene goes: let go of the signals, the mark and the file; OpenXR still calls in, to no effect.
func stop() -> void:
	if not on:
		return
	on = false
	picture = null
	_stat = null
	(Engine.get_main_loop() as SceneTree).process_frame.disconnect(_scripts)
	RenderingServer.frame_pre_draw.disconnect(_drawing)
	RenderingServer.frame_post_draw.disconnect(_drawn)


func _set_frame_wait_info_and_get_next_pointer(_next_pointer: int) -> int:
	if not on:
		return 0
	var at := PHASES.size() * VALUES
	if _cur[0] > 0:
		for i in at:
			_last[i] = _cur[i]
		_point(_last, PHASES.size())
		_have = true
	_cur.fill(0)
	_point(_cur, 0)
	return 0


func _set_frame_end_info_and_get_next_pointer(_next_pointer: int) -> int:
	if on:
		_point(_cur, 4)
	return 0


func _scripts() -> void:
	_point(_cur, 1)


func _drawing() -> void:
	_point(_cur, 2)


func _drawn() -> void:
	_point(_cur, 5)


func _picture() -> void:
	if on:
		_point(_cur, 3)


func _point(a: PackedInt64Array, i: int) -> void:
	var k := i * VALUES
	a[k] = Time.get_ticks_usec()
	if _stat:
		# a seek within what was read stays in the read buffer: away and back reads the file again
		_stat.seek(1 << 20)
		_stat.seek(0)
		var s := _stat.get_line().split(" ")
		if s.size() >= 3:
			a[k + 1] = s[0].to_int()
			a[k + 2] = s[1].to_int()
			a[k + 3] = s[2].to_int()


## The last whole frame: ms of each of PHASES, then over the frame ms running, waiting for a core
## and asleep, and the times scheduled in (-1 each without schedstat); empty before there is one.
func last_frame() -> PackedFloat32Array:
	var out := PackedFloat32Array()
	if not _have:
		return out
	var n := PHASES.size()
	var t := _times()
	for i in n:
		out.append((t[i + 1] - t[i]) / 1000.0)
	if _stat == null:
		out.append_array([-1, -1, -1, -1])
		return out
	var wall := (t[n] - t[0]) / 1000.0
	var run := (_last[n * VALUES + 1] - _last[1]) / 1e6
	var queue := (_last[n * VALUES + 2] - _last[2]) / 1e6
	out.append_array([run, queue, maxf(wall - run - queue, 0.0), _last[n * VALUES + 3] - _last[3]])
	return out


## The same in words, for the log; scripts: what to say after the scripts' time.
func text(scripts := "") -> String:
	var f := last_frame()
	if f.is_empty():
		return "the frame before: not measured"
	var n := PHASES.size()
	var parts := []
	var waits := _waits()
	var total := 0.0
	for i in n:
		var s := "%s %.2f" % [PHASES[i], f[i]]
		if i == 1 and scripts != "":
			s += " (%s)" % scripts
		if waits.size() > i and waits[i] >= 0.05:
			s += " (waiting for a core %.2f)" % waits[i]
		parts.append(s)
		total += f[i]
	var out := "the frame before on the main thread, ms: %s; %.2f in all" % [", ".join(parts), total]
	if f[n] >= 0.0:
		out += ": running %.2f, waiting for a core %.2f, asleep %.2f, scheduled in %d times" % [f[n], f[n + 1], f[n + 2], int(f[n + 3])]
	return out


## The points' times, us; one not reached takes the time of the point before it.
func _times() -> PackedInt64Array:
	var t := PackedInt64Array()
	for i in PHASES.size() + 1:
		var v := _last[i * VALUES]
		t.append(v if v > 0 else (t[i - 1] if i > 0 else 0))
	return t


## Per stretch: ms waiting for a core (empty without schedstat).
func _waits() -> PackedFloat32Array:
	var out := PackedFloat32Array()
	if _stat == null:
		return out
	var prev := _last[2]
	for i in PHASES.size():
		var v := _last[(i + 1) * VALUES + 2]
		if _last[(i + 1) * VALUES] == 0:
			v = prev            # not reached: nothing in this stretch
		out.append((v - prev) / 1e6)
		prev = v
	return out


## Point 3: an effect that only notes the time (FramePhases' top).
class Mark extends CompositorEffect:
	var phases: FramePhases

	func _init() -> void:
		effect_callback_type = EFFECT_CALLBACK_TYPE_PRE_OPAQUE

	func _render_callback(_type: int, _data: RenderData) -> void:
		if phases:
			phases._picture()
