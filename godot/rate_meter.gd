extends RefCounted
## Frame pacing as the headset sees it, from the display times that OpenXR's xrWaitFrame
## predicts for our frames: the display's refresh period, whatever the runtime reports through
## XR_FB_display_refresh_rate, and every refresh that passes without a new frame from us is a
## missed frame.
##
## xrWaitFrame's predictedDisplayPeriod is the time until the next frame the runtime expects to
## show; a runtime that paces a slow app at every 2nd refresh reports twice the refresh period
## (Monado does). So the refresh period is the shortest period seen, kept while the predicted
## one is a whole multiple of it. And if the predicted period is a whole multiple of the one an
## expected rate gives, the display runs at the expected rate (and the app at every 2nd, 3rd...
## refresh if the multiple is 2, 3...). An expected rate that does not fit is ignored.
##
## Fed once per frame with (predicted display time, predicted period) in nanoseconds and the
## rate the display is expected to run at (0 if unknown); the window counters are read and
## reset by the caller.

const PAUSE_NS := 500_000_000  # a longer gap is a pause (session not running), not missed frames
const WHOLE := 0.03            # how close to a whole number a ratio of periods must be
const MAX_PACE := 4            # the slowest pacing believed: every 4th refresh

var period := 0          # the display's refresh period, ns
var paced := 0           # the period the runtime last predicted, ns
var frames := 0          # new frames in the window
var refreshes := 0       # display refreshes those frames took
var last_time := 0


func add(display_time: int, predicted_period: int, expected_hz := 0.0) -> void:
	if display_time <= 0 or predicted_period <= 0 or display_time == last_time:
		return
	paced = predicted_period
	period = refresh_period(period, predicted_period, expected_hz)
	var gap := display_time - last_time
	if last_time > 0 and gap > 0 and gap < PAUSE_NS:
		frames += 1
		refreshes += maxi(roundi(float(gap) / float(period)), 1)
	last_time = display_time


## The display's refresh period, from the one known so far, the predicted one and the expected rate.
static func refresh_period(known: int, predicted: int, expected_hz: float) -> int:
	if expected_hz > 0.0:
		var expected := roundi(1e9 / expected_hz)
		var k := float(predicted) / expected
		if absf(k - roundi(k)) < WHOLE and roundi(k) >= 1 and roundi(k) <= MAX_PACE:
			return expected         # paced at every refresh, or at every 2nd, 3rd...
	if known <= 0:
		return predicted
	var ratio := float(predicted) / known
	if ratio < 1.0 - WHOLE:
		return predicted            # the display got faster
	if absf(ratio - roundi(ratio)) < WHOLE:
		return known                # the same, or the app paced at every 2nd, 3rd... refresh
	return predicted                # the display changed to another, slower rate


func missed() -> int:
	return refreshes - frames


func rate() -> float:
	return 1e9 / period if period > 0 else 0.0


func paced_rate() -> float:
	return 1e9 / paced if paced > 0 else 0.0


func reset_window() -> void:
	frames = 0
	refreshes = 0
