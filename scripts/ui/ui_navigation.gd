extends RefCounted
## Controller-first UI navigation: classifies raw joypad events into the
## fixed menu semantics (D-pad/left stick navigates, A confirms, B backs).
## These are independent of every gameplay binding profile, so remapping
## buttons can never strand a player inside a menu. Keyboard handling
## (ui_accept minus Space, ui_up/down/left/right, ui_cancel) stays with
## each screen; this helper only adds the controller layer.
##
## D-pad buttons are edge-based by nature. Left-stick motion events arrive
## continuously while the stick is held, so per-device engagement state
## provides the edge protection: a direction fires once when the stick
## crosses the dead zone and re-arms only after returning to neutral.

const AXIS_DEADZONE := 0.5

const DIR_ACCEPT := "accept"
const DIR_BACK := "back"
const DIR_UP := "up"
const DIR_DOWN := "down"
const DIR_LEFT := "left"
const DIR_RIGHT := "right"

## device -> Vector2i engaged stick direction.
var _engaged := {}


## Returns one of DIR_* for a raw input event, or "" when the event is not
## a recognized controller UI navigation input.
func classify(event: InputEvent) -> String:
	if event is InputEventJoypadButton:
		var b := event as InputEventJoypadButton
		if not b.pressed:
			return ""
		match b.button_index:
			JOY_BUTTON_A:
				return DIR_ACCEPT
			JOY_BUTTON_B:
				return DIR_BACK
			JOY_BUTTON_DPAD_UP:
				return DIR_UP
			JOY_BUTTON_DPAD_DOWN:
				return DIR_DOWN
			JOY_BUTTON_DPAD_LEFT:
				return DIR_LEFT
			JOY_BUTTON_DPAD_RIGHT:
				return DIR_RIGHT
		return ""
	if event is InputEventJoypadMotion:
		var m := event as InputEventJoypadMotion
		if m.axis != JOY_AXIS_LEFT_X and m.axis != JOY_AXIS_LEFT_Y:
			return ""
		var state: Dictionary = _engaged.get_or_add(m.device, {"x": 0.0, "y": 0.0, "dir": Vector2i.ZERO})
		if m.axis == JOY_AXIS_LEFT_X:
			state["x"] = m.axis_value
		else:
			state["y"] = m.axis_value
		var current := Vector2i(
			1 if float(state["x"]) >= AXIS_DEADZONE else (-1 if float(state["x"]) <= -AXIS_DEADZONE else 0),
			1 if float(state["y"]) >= AXIS_DEADZONE else (-1 if float(state["y"]) <= -AXIS_DEADZONE else 0)
		)
		var previous: Vector2i = state["dir"]
		state["dir"] = current
		if current == previous:
			return ""
		if current.x == -1 and previous.x != -1:
			return DIR_LEFT
		if current.x == 1 and previous.x != 1:
			return DIR_RIGHT
		if current.y == -1 and previous.y != -1:
			return DIR_UP
		if current.y == 1 and previous.y != 1:
			return DIR_DOWN
		return ""
	return ""


## Forgets stick engagement state (used when a screen closes so a held
## stick re-arms for the next open).
func reset() -> void:
	_engaged = {}
