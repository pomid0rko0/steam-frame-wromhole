extends RefCounted
## Frame pacing as the headset sees it, from the display times that OpenXR's xrWaitFrame
## predicts for our frames: the display's refresh period, and every refresh that passes without a
## new frame from us is a missed frame.
##
## The period comes from the gaps between our frames' display times, not from xrWaitFrame's
## predictedDisplayPeriod: SteamVR on the Frame predicts 6.94 ms (144 Hz) at every rate while
## Godot renders on a thread of its own (Main.render_thread; the headset's log of build 5f4189d:
## "paced 144" at a display of 72 and of 120 Hz), and the display times themselves are whole
## refreshes apart. So the refresh period is the shortest gap seen, kept while the gaps are whole
## multiples of it: a frame late by a refresh is a gap of two, and so is every frame of a slow app
## that the runtime paces at every 2nd refresh. And if a gap is a whole multiple of the period an
## expected rate gives, the display runs at the expected rate (and the app at every 2nd, 3rd...
## refresh if the multiple is 2, 3...). An expected rate that does not fit is ignored.
##
## Fed once per frame with the predicted display time in nanoseconds and the rate the display is
## expected to run at (0 if unknown): the runtime's word, which on the Frame matched the display
## once a switch had settled. The window counters are read and reset by the caller.

const PAUSE_NS := 500_000_000  # a longer gap is a pause (session not running), not missed frames
const WHOLE := 0.03            # how close to a whole number a ratio of periods must be
const MAX_PACE := 4            # the slowest pacing an expected rate is matched to: every MAX_PACE-th refresh

var period := 0          # the display's refresh period, ns
var paced := 0           # the last gap between our frames' display times, ns
var frames := 0          # new frames in the window
var refreshes := 0       # display refreshes those frames took
var last_time := 0


func add(display_time: int, expected_hz := 0.0) -> void:
	if display_time <= 0 or display_time == last_time:
		return
	var gap := display_time - last_time
	if last_time > 0 and gap > 0 and gap < PAUSE_NS:
		paced = gap
		period = refresh_period(period, gap, expected_hz)
		frames += 1
		refreshes += maxi(roundi(float(gap) / float(period)), 1)
	last_time = display_time


## The display's refresh period, from the one known so far, a gap between our frames' display
## times and the expected rate.
static func refresh_period(known: int, gap: int, expected_hz: float) -> int:
	if expected_hz > 0.0:
		var expected := roundi(1e9 / expected_hz)
		var k := float(gap) / expected
		if absf(k - roundi(k)) < WHOLE and roundi(k) >= 1 and roundi(k) <= MAX_PACE:
			return expected         # a frame every refresh, or every 2nd, 3rd...
	if known <= 0:
		return gap
	var ratio := float(gap) / known
	if ratio < 1.0 - WHOLE:
		return gap                  # the display got faster
	if absf(ratio - roundi(ratio)) < WHOLE:
		return known                # the same, or the frame took 2, 3... refreshes
	return gap                      # the display changed to another, slower rate


func missed() -> int:
	return refreshes - frames


func rate() -> float:
	return 1e9 / period if period > 0 else 0.0


func paced_rate() -> float:
	return 1e9 / paced if paced > 0 else 0.0


func reset_window() -> void:
	frames = 0
	refreshes = 0
