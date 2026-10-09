extends RefCounted
## Pure "hold any button for N seconds" claim tracker. Callers feed a
## snapshot of currently pressed joypad buttons per device; the tracker
## resets on release or device/button change, completes once the hold
## reaches its duration, and then waits for a release. Headless tests
## drive it with synthetic snapshots.

const DEFAULT_HOLD_SECONDS := 3.0

## idle: no candidate held; held: accumulating; complete: claimed, waiting
## for the button to be released.
const STATE_IDLE := "idle"
const STATE_HELD := "held"
const STATE_COMPLETE := "complete"

var hold_seconds: float = DEFAULT_HOLD_SECONDS

var _device: int = -1
var _button: int = -1
var _time: float = 0.0
var _state: String = STATE_IDLE


func reset() -> void:
	_device = -1
	_button = -1
	_time = 0.0
	_state = STATE_IDLE


func state() -> String:
	return _state


func device() -> int:
	return _device


func progress() -> float:
	## 0..1 fraction of the hold completed (1 while waiting for release).
	if _state == STATE_COMPLETE:
		return 1.0
	return clampf(_time / maxf(hold_seconds, 0.0001), 0.0, 1.0)


## `pressed` maps device ids to the list of currently pressed buttons.
## `excluded` devices are ignored (already claimed by someone else).
## Returns an event dict: {"event": ""|"claimed"|"released", "device": int}.
func update(pressed: Dictionary, excluded: Array, delta: float) -> Dictionary:
	if _state == STATE_COMPLETE:
		var still: Array = pressed.get(_device, [])
		if still.is_empty():
			var released_device := _device
			reset()
			return {"event": "released", "device": released_device}
		return {"event": "", "device": _device}

	# Find the first non-excluded device with any pressed button.
	var candidate_device := -1
	var candidate_button := -1
	for key in pressed:
		var device := int(key)
		if excluded.has(device):
			continue
		var buttons: Array = pressed[key]
		if not buttons.is_empty():
			candidate_device = device
			candidate_button = int(buttons[0])
			break

	if candidate_device < 0:
		if _state != STATE_IDLE:
			reset()
		return {"event": "", "device": -1}

	# Any release, device change, or button change restarts the hold.
	if _state == STATE_IDLE or candidate_device != _device or candidate_button != _button:
		_device = candidate_device
		_button = candidate_button
		_time = 0.0
		_state = STATE_HELD

	_time += delta
	if _time >= hold_seconds:
		_state = STATE_COMPLETE
		return {"event": "claimed", "device": _device}
	return {"event": "", "device": _device}
