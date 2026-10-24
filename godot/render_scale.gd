class_name RenderScale
extends RefCounted
## Dynamic resolution for the headset. Where many rays cross the curved region (most of all
## near the shell's edge) a frame costs about twice what it costs at the start, more than the
## headset's frame time, and the headset drops frames. Then the eyes are rendered at a lower
## resolution and stretched to full size (bilinear), and back up once there is room again.
## Cost is taken to scale with the pixel count, the square of the scale.

const STEPS: Array[float] = [1.0, 0.9, 0.8, 0.7, 0.6]
const HIGH := 0.85        # GPU time above this part of the frame budget: lower the resolution
const TARGET := 0.75      # what a step aims for; a step up must keep below it
const FRAMES_HIGH := 3    # frames in a row above HIGH before stepping down
const CALM_UP := 1.0      # seconds in a row with room for the next step up before taking it
const HOLD := 0.5         # seconds after a change before the next one: the measurement lags

var level := 0
var over := 0
var calm := 0.0
var hold := 0.0


func scale() -> float:
	return STEPS[level]


## Feed the last measured GPU time of a frame and the time one frame may take (both in ms) and
## the seconds since the last call. Returns true if the scale changed.
func update(gpu_ms: float, budget_ms: float, delta: float) -> bool:
	hold = maxf(hold - delta, 0.0)
	if gpu_ms <= 0.0 or budget_ms <= 0.0 or hold > 0.0:
		return false
	var s := STEPS[level]
	if gpu_ms > HIGH * budget_ms:
		calm = 0.0
		over += 1
		if over < FRAMES_HIGH or level == STEPS.size() - 1:
			return false
		# down at once to the step the cost model says fits, at least one
		var need := s * sqrt(TARGET * budget_ms / gpu_ms)
		var to := level + 1
		while to < STEPS.size() - 1 and STEPS[to] > need:
			to += 1
		return _step_to(to)
	over = 0
	if level > 0 and gpu_ms * pow(STEPS[level - 1] / s, 2.0) < TARGET * budget_ms:
		calm += delta
		if calm >= CALM_UP:
			return _step_to(level - 1)
	else:
		calm = 0.0
	return false


func _step_to(to: int) -> bool:
	level = to
	over = 0
	calm = 0.0
	hold = HOLD
	return true
