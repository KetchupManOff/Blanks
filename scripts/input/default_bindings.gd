extends RefCounted
## Canonical logical action list, default binding profile as plain records,
## record<->InputEvent conversion, conflict detection, and InputMap profile
## application. Pure data helpers with no scene tree dependency so headless
## tests can exercise remapping and persistence.
##
## Bindings are stored and serialized as plain dictionaries, never as
## InputEvent objects: keyboard = {device, code, ctrl, alt, shift},
## controller button = {device, index}, controller axis = {device, axis,
## value} with value normalized to +/-1.0.

const DEVICE_KEYBOARD := "keyboard"
const DEVICE_JOY_BUTTON := "joy_button"
const DEVICE_JOY_AXIS := "joy_axis"

const ACTION_NAMES := [
	"move_left",
	"move_right",
	"soft_drop",
	"hard_drop",
	"rotate_cw",
	"rotate_ccw",
	"hold",
	"pause",
	"restart",
]


# ------------------------------------------------------------ default profile

static func default_profile() -> Dictionary:
	return {
		"move_left": [key_record(KEY_LEFT), key_record(KEY_A), joy_button_record(13), joy_axis_record(0, -1.0)],
		"move_right": [key_record(KEY_RIGHT), key_record(KEY_D), joy_button_record(14), joy_axis_record(0, 1.0)],
		"soft_drop": [key_record(KEY_DOWN), key_record(KEY_S), joy_button_record(12), joy_axis_record(1, 1.0)],
		"hard_drop": [key_record(KEY_SPACE), joy_button_record(1)],
		"rotate_cw": [key_record(KEY_UP), key_record(KEY_X), joy_button_record(0)],
		"rotate_ccw": [key_record(KEY_Z), joy_button_record(2)],
		"hold": [key_record(KEY_C), key_record(KEY_SHIFT), joy_button_record(3)],
		"pause": [key_record(KEY_ESCAPE), key_record(KEY_P), joy_button_record(6)],
		"restart": [key_record(KEY_R)],
	}


static func key_record(code: int, ctrl: bool = false, alt: bool = false, shift: bool = false) -> Dictionary:
	return {"device": DEVICE_KEYBOARD, "code": code, "ctrl": ctrl, "alt": alt, "shift": shift}


static func joy_button_record(index: int) -> Dictionary:
	return {"device": DEVICE_JOY_BUTTON, "index": index}


static func joy_axis_record(axis: int, direction: float) -> Dictionary:
	return {"device": DEVICE_JOY_AXIS, "axis": axis, "value": -1.0 if direction < 0.0 else 1.0}


# ------------------------------------------------------------------- records

static func record_from_event(event: InputEvent) -> Dictionary:
	## Converts a raw pressed input event into a plain record. Returns an
	## empty dictionary for unsupported or unpressed events (mouse, echoes,
	## released buttons, etc.).
	if event is InputEventKey:
		var k := event as InputEventKey
		if not k.pressed or k.is_echo() or k.physical_keycode == KEY_NONE:
			return {}
		return key_record(k.physical_keycode, k.ctrl_pressed, k.alt_pressed, k.shift_pressed)
	if event is InputEventJoypadButton:
		var b := event as InputEventJoypadButton
		if not b.pressed:
			return {}
		return joy_button_record(b.button_index)
	if event is InputEventJoypadMotion:
		var m := event as InputEventJoypadMotion
		return joy_axis_record(m.axis, m.axis_value)
	return {}


static func event_from_record(record) -> InputEvent:
	## Rebuilds an InputMap-compatible event from a record, or null when the
	## record is invalid.
	var sanitized := sanitize_record(record)
	if sanitized.is_empty():
		return null
	match sanitized["device"]:
		DEVICE_KEYBOARD:
			var ev := InputEventKey.new()
			ev.physical_keycode = sanitized["code"] as Key
			ev.ctrl_pressed = sanitized["ctrl"]
			ev.alt_pressed = sanitized["alt"]
			ev.shift_pressed = sanitized["shift"]
			return ev
		DEVICE_JOY_BUTTON:
			var ev := InputEventJoypadButton.new()
			ev.button_index = sanitized["index"] as JoyButton
			return ev
		DEVICE_JOY_AXIS:
			var ev := InputEventJoypadMotion.new()
			ev.axis = sanitized["axis"] as JoyAxis
			ev.axis_value = sanitized["value"]
			return ev
	return null


static func sanitize_record(record) -> Dictionary:
	## Validates one record; returns a canonical record or {} when invalid.
	## Accepts ints and integral floats for numeric fields (JSON round trips
	## large keycodes as floats).
	if not (record is Dictionary):
		return {}
	var device = record.get("device")
	match device:
		DEVICE_KEYBOARD:
			var code := _as_int(record.get("code"))
			if code <= 0:
				return {}
			return key_record(code, _as_bool(record.get("ctrl")), _as_bool(record.get("alt")), _as_bool(record.get("shift")))
		DEVICE_JOY_BUTTON:
			var index := _as_int(record.get("index"))
			if index < 0:
				return {}
			return joy_button_record(index)
		DEVICE_JOY_AXIS:
			var axis := _as_int(record.get("axis"))
			var value = record.get("value")
			if axis < 0 or not (value is int or value is float) or float(value) == 0.0:
				return {}
			return joy_axis_record(axis, float(value))
	return {}


static func sanitize_profile(profile) -> Dictionary:
	## Validates a whole profile. Unknown actions and invalid records are
	## dropped; actions left without any valid record fall back to their
	## defaults. Returns a complete profile covering every known action.
	var defaults := default_profile()
	if not (profile is Dictionary):
		return defaults
	var result := {}
	for action in ACTION_NAMES:
		var list = profile.get(action)
		var records: Array = []
		if list is Array:
			for raw in list:
				var record := sanitize_record(raw)
				if not record.is_empty() and not _contains_record(records, record):
					records.append(record)
		if records.is_empty():
			records = defaults[action]
		result[action] = records
	return result


# --------------------------------------------------------------- comparisons

static func record_matches(a, b) -> bool:
	## True when two records describe the same physical input. Cross-category
	## records (keyboard vs controller) never match.
	if typeof(a) != TYPE_DICTIONARY or typeof(b) != TYPE_DICTIONARY:
		return false
	if a.get("device") != b.get("device"):
		return false
	match a.get("device"):
		DEVICE_KEYBOARD:
			return (
				a.get("code") == b.get("code")
				and a.get("ctrl", false) == b.get("ctrl", false)
				and a.get("alt", false) == b.get("alt", false)
				and a.get("shift", false) == b.get("shift", false)
			)
		DEVICE_JOY_BUTTON:
			return a.get("index") == b.get("index")
		DEVICE_JOY_AXIS:
			return a.get("axis") == b.get("axis") and signf(float(a.get("value"))) == signf(float(b.get("value")))
	return false


static func _contains_record(records: Array, record: Dictionary) -> bool:
	for other in records:
		if record_matches(other, record):
			return true
	return false


static func device_category(record: Dictionary) -> String:
	## "keyboard" or "controller"; "" for unknown devices.
	match record.get("device"):
		DEVICE_KEYBOARD:
			return "keyboard"
		DEVICE_JOY_BUTTON, DEVICE_JOY_AXIS:
			return "controller"
	return ""


static func records_for_category(records: Array, category: String) -> Array:
	var result: Array = []
	for record in records:
		if device_category(record) == category:
			result.append(record)
	return result


static func find_conflict(profile: Dictionary, action: String, record: Dictionary) -> String:
	## Returns the name of another action already owning this record, or "".
	for other in profile:
		if other == action or not (profile[other] is Array):
			continue
		for other_record in profile[other]:
			if record_matches(other_record, record):
				return other
	return ""


# --------------------------------------------------------------- categories

static func default_keyboard_profile() -> Dictionary:
	## The shared keyboard profile: keyboard records of the canonical
	## default profile, one entry per known action (some may be empty).
	return category_profile(default_profile(), "keyboard")


static func default_controller_profile() -> Dictionary:
	## The default controller-only profile for fresh player profiles.
	return category_profile(default_profile(), "controller")


static func category_profile(profile, category: String) -> Dictionary:
	## Extracts one device category from a (possibly mixed) profile into a
	## complete action-keyed profile. Empty actions stay empty; no defaults
	## are reintroduced.
	var result := {}
	var source: Dictionary = profile if profile is Dictionary else {}
	for action in ACTION_NAMES:
		result[action] = records_for_category(source.get(action, []), category)
	return result


static func sanitize_category_profile(profile, category: String) -> Dictionary:
	## Validates category-only data: invalid and foreign-category records
	## are dropped, duplicates removed, and every known action key exists.
	## An intentionally empty action stays empty (sanitation never
	## reintroduces defaults here).
	var result := {}
	var source: Dictionary = profile if profile is Dictionary else {}
	for action in ACTION_NAMES:
		var records: Array = []
		var list = source.get(action)
		if list is Array:
			for raw in list:
				var record := sanitize_record(raw)
				if not record.is_empty() and device_category(record) == category and not _contains_record(records, record):
					records.append(record)
		result[action] = records
	return result


# ------------------------------------------------------------ device polling

const AXIS_DEADZONE := 0.5


static func record_satisfied(record: Dictionary, button_down: bool, axis_value: float, deadzone: float = AXIS_DEADZONE) -> bool:
	## Pure check: does the supplied live input state satisfy this
	## controller record? Keyboard records never match (they are not polled
	## per device).
	match record.get("device"):
		DEVICE_JOY_BUTTON:
			return button_down
		DEVICE_JOY_AXIS:
			if absf(axis_value) < deadzone:
				return false
			return signf(axis_value) == signf(float(record.get("value")))
	return false


static func device_matches_record(device: int, record: Dictionary) -> bool:
	## Polls a connected joypad device against one controller record.
	if device < 0:
		return false
	match record.get("device"):
		DEVICE_JOY_BUTTON:
			return Input.is_joy_button_pressed(device, _as_int(record.get("index")))
		DEVICE_JOY_AXIS:
			return record_satisfied(record, false, Input.get_joy_axis(device, _as_int(record.get("axis"))))
	return false


static func device_action_pressed(device: int, records: Array) -> bool:
	## True when the device currently satisfies any record of the action.
	for record in records:
		if device_matches_record(device, record):
			return true
	return false


static func action_for_record(profile: Dictionary, record: Dictionary) -> String:
	## Which canonical action (if any) this controller record is bound to
	## inside the profile, in ACTION_NAMES order.
	for action in ACTION_NAMES:
		for other in profile.get(action, []):
			if record_matches(other, record):
				return action
	return ""


static func apply_keyboard_profile(profile) -> void:
	## Rebuilds the InputMap from the shared keyboard profile only.
	## Controller records are never installed globally: they are polled per
	## assigned device so several profiles can coexist.
	var sanitized := sanitize_category_profile(profile, "keyboard")
	for action in ACTION_NAMES:
		if not InputMap.has_action(action):
			InputMap.add_action(action)
		InputMap.action_erase_events(action)
		for record in sanitized[action]:
			var ev := event_from_record(record)
			if ev != null:
				InputMap.action_add_event(action, ev)


# ------------------------------------------------------------------ InputMap

static func ensure_actions() -> void:
	## Registers every action with its default bindings.
	apply_profile(default_profile())


static func apply_profile(profile) -> void:
	## Rebuilds every action's InputMap events from a profile. Existing events
	## are erased first so repeated applications never duplicate bindings.
	var sanitized := sanitize_profile(profile)
	for action in ACTION_NAMES:
		if not InputMap.has_action(action):
			InputMap.add_action(action)
		InputMap.action_erase_events(action)
		for record in sanitized[action]:
			var ev := event_from_record(record)
			if ev != null:
				InputMap.action_add_event(action, ev)


# ------------------------------------------------------------------ display

static func key_display_name(code: int) -> String:
	var probe := InputEventKey.new()
	probe.physical_keycode = code as Key
	return probe.as_text().replace(" (Physical)", "")


static func record_display_name(record: Dictionary) -> String:
	match record.get("device"):
		DEVICE_KEYBOARD:
			return key_display_name(record.get("code"))
		DEVICE_JOY_BUTTON:
			return "Button %d" % record.get("index")
		DEVICE_JOY_AXIS:
			var suffix := "+" if float(record.get("value")) > 0.0 else "-"
			return "Axis %d %s" % [record.get("axis"), suffix]
	return "?"


# ------------------------------------------------------------------ internal

static func _as_int(value) -> int:
	if value is int:
		return value
	if value is float and float(value) == floorf(float(value)):
		return int(value)
	return -1


static func _as_bool(value) -> bool:
	return value == true
