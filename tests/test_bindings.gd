extends "res://tests/test_lib.gd"
## Input bindings tests: record serialization, categories, conflicts,
## keyboard-only InputMap application (no profile controller leakage),
## per-device record polling, the hold tracker behind controller claims,
## and the raw controller UI navigation classifier.

const DefaultBindings = preload("res://scripts/input/default_bindings.gd")
const CoopBindings = preload("res://scripts/input/coop_bindings.gd")
const ModeRules = preload("res://scripts/core/mode_rules.gd")
const HoldTracker = preload("res://scripts/input/hold_tracker.gd")
const UiNavigation = preload("res://scripts/ui/ui_navigation.gd")

const K_LEFT: int = KEY_LEFT
const K_RIGHT: int = KEY_RIGHT
const K_DOWN: int = KEY_DOWN
const K_SPACE: int = KEY_SPACE
const K_UP: int = KEY_UP
const K_Z: int = KEY_Z
const K_C: int = KEY_C
const K_ESC: int = KEY_ESCAPE
const K_R: int = KEY_R


# ---------------------------------------------------------------- defaults

func test_action_names_canonical() -> void:
	check_eq(DefaultBindings.ACTION_NAMES, [
		"move_left", "move_right", "soft_drop", "hard_drop",
		"rotate_cw", "rotate_ccw", "hold", "pause", "restart",
	], "canonical action list in guided-capture order")


func test_default_profile_categories() -> void:
	var profile := DefaultBindings.default_profile()
	for action in DefaultBindings.ACTION_NAMES:
		var records: Array = profile[action]
		check(records.size() >= 1, "default action bound: %s" % action)
		var keyboard: Array = DefaultBindings.records_for_category(records, "keyboard")
		var controller: Array = DefaultBindings.records_for_category(records, "controller")
		check(keyboard.size() + controller.size() == records.size(), "default records are keyboard or controller: %s" % action)


func test_default_category_profiles_are_complete() -> void:
	# Both category profiles cover every action key; the shared keyboard
	# profile binds all nine, the controller profile leaves restart empty
	# (no canonical default pad button) rather than inventing one.
	var keyboard := DefaultBindings.default_keyboard_profile()
	var controller := DefaultBindings.default_controller_profile()
	for action in DefaultBindings.ACTION_NAMES:
		check(keyboard.has(action), "keyboard profile covers %s" % action)
		check(keyboard[action].size() >= 1, "keyboard default binds %s" % action)
		check(controller.has(action), "controller profile covers %s" % action)
		for record in controller[action]:
			check_eq(DefaultBindings.device_category(record), "controller", "controller profile keeps only controller records")


func test_category_profile_extraction() -> void:
	var profile := DefaultBindings.default_profile()
	profile["move_left"] = [
		DefaultBindings.key_record(K_LEFT),
		DefaultBindings.joy_button_record(13),
		DefaultBindings.joy_axis_record(0, -1.0),
	]
	var keyboard := DefaultBindings.category_profile(profile, "keyboard")
	var controller := DefaultBindings.category_profile(profile, "controller")
	check_eq(keyboard["move_left"], [DefaultBindings.key_record(K_LEFT)], "keyboard extraction keeps only keys")
	check_eq(controller["move_left"], [DefaultBindings.joy_button_record(13), DefaultBindings.joy_axis_record(0, -1.0)], "controller extraction keeps buttons and axes")
	for action in DefaultBindings.ACTION_NAMES:
		check(keyboard.has(action), "extraction completes every action key: %s" % action)
	# Missing or non-dictionary input yields an empty-but-complete profile.
	var empty := DefaultBindings.category_profile(null, "keyboard")
	check_eq(empty["hold"], [], "null profile extracts to empty records")


func test_sanitize_category_profile_keeps_intentional_empties() -> void:
	# An action deliberately left empty in a category profile must stay
	# empty; sanitation must not reintroduce defaults.
	var dirty := {
		"hold": [],
		"pause": [DefaultBindings.key_record(K_ESC), "junk", DefaultBindings.key_record(K_ESC)],
		"move_left": [DefaultBindings.joy_button_record(5)],
	}
	var keyboard := DefaultBindings.sanitize_category_profile(dirty, "keyboard")
	check_eq(keyboard["hold"], [], "empty action stays empty")
	check_eq(keyboard["pause"], [DefaultBindings.key_record(K_ESC)], "invalid records dropped and duplicates removed")
	check_eq(keyboard["move_left"], [], "foreign-category records dropped")
	check_eq(keyboard["restart"], [], "missing action completed with an empty record list")


# ----------------------------------------------------------------- records

func test_key_record_roundtrip() -> void:
	var r := DefaultBindings.key_record(K_Z)
	check_eq(r["device"], "keyboard", "keyboard device tag")
	var ev: InputEventKey = DefaultBindings.event_from_record(r)
	check_eq(ev.physical_keycode, K_Z, "event keycode round trips")
	ev.pressed = true
	var back: Dictionary = DefaultBindings.record_from_event(ev)
	check_eq(back, r, "record round trips through an event")


func test_joy_button_record() -> void:
	var r := DefaultBindings.joy_button_record(3)
	check_eq(r["device"], "joy_button", "controller button device tag")
	check_eq(r["index"], 3, "button index")
	check_eq(DefaultBindings.device_category(r), "controller", "category")
	check_eq(DefaultBindings.record_display_name(r), "Button 3", "display name")


func test_joy_axis_record() -> void:
	var r := DefaultBindings.joy_axis_record(0, -1.0)
	check_eq(r["device"], "joy_axis", "controller axis device tag")
	check_eq(r["axis"], 0, "axis index")
	check_eq(r["value"], -1.0, "axis direction")
	check_eq(DefaultBindings.record_display_name(r), "Axis 0 -", "axis display name")
	check_eq(DefaultBindings.record_display_name(DefaultBindings.joy_axis_record(1, 1.0)), "Axis 1 +", "down direction display name")


func test_joy_records_ignore_device_id() -> void:
	# Records are profile-portable: the device id is deliberately absent
	# so the same profile works on any pad.
	var b := DefaultBindings.joy_button_record(2)
	var a := DefaultBindings.joy_axis_record(1, -1.0)
	check_false(b.has("device_id"), "button record has no device id")
	check_false(a.has("device_id"), "axis record has no device id")


func test_record_matches() -> void:
	var kb := DefaultBindings.joy_button_record(3)
	check_true(DefaultBindings.record_matches(kb, DefaultBindings.joy_button_record(3)), "same button matches")
	check_false(DefaultBindings.record_matches(kb, DefaultBindings.joy_button_record(4)), "different button rejected")
	check_true(DefaultBindings.record_matches(DefaultBindings.joy_axis_record(0, 1.0), DefaultBindings.joy_axis_record(0, 0.5)), "axis direction normalized by sign")
	check_false(DefaultBindings.record_matches(kb, DefaultBindings.key_record(K_C)), "button never matches a key")


func test_record_conflicts() -> void:
	var profile := DefaultBindings.default_profile()
	check_eq(DefaultBindings.find_conflict(profile, "move_left", DefaultBindings.key_record(K_RIGHT)), "move_right", "cross-action conflict found")
	check_eq(DefaultBindings.find_conflict(profile, "move_left", DefaultBindings.key_record(K_LEFT)), "", "own records are not conflicts")
	check_eq(DefaultBindings.find_conflict(profile, "move_left", DefaultBindings.key_record(K_C)), "hold", "hold conflict detected")


# ------------------------------------------------------------------- InputMap

func test_apply_keyboard_profile_installs_no_joypad_events() -> void:
	# The shared keyboard profile must be the only thing in the global
	# InputMap: profile controller records are polled per device instead,
	# so one pad can never trigger several players.
	DefaultBindings.apply_keyboard_profile(DefaultBindings.default_keyboard_profile())
	for action in DefaultBindings.ACTION_NAMES:
		check_true(InputMap.has_action(action), "action registered: " + action)
		for event in InputMap.action_get_events(action):
			check_false(event is InputEventJoypadButton, "no joypad buttons in the InputMap: " + action)
			check_false(event is InputEventJoypadMotion, "no joypad axes in the InputMap: " + action)
	var ev := InputEventKey.new()
	ev.physical_keycode = K_LEFT
	ev.pressed = true
	check_true(InputMap.event_is_action(ev, "move_left"), "keyboard events still drive the InputMap")


func test_apply_keyboard_profile_keeps_empties_unbound() -> void:
	# A user may fully clear a keyboard action: after applying the shared
	# profile the action has no events and stays keyboard-unbound.
	var custom := DefaultBindings.default_keyboard_profile()
	custom["hold"] = []
	DefaultBindings.apply_keyboard_profile(custom)
	check_eq(InputMap.action_get_events("hold").size(), 0, "cleared action unbound in the InputMap")
	# Restore defaults for later suites.
	DefaultBindings.apply_keyboard_profile(DefaultBindings.default_keyboard_profile())


# ------------------------------------------------------- per-device polling

func test_record_satisfied_button() -> void:
	var record := DefaultBindings.joy_button_record(5)
	check_true(DefaultBindings.record_satisfied(record, true, 0.0), "pressed button satisfies")
	check_false(DefaultBindings.record_satisfied(record, false, 0.0), "released button does not")
	var key := DefaultBindings.key_record(K_LEFT)
	check_false(DefaultBindings.record_satisfied(key, true, 0.0), "keyboard records never satisfy device polling")


func test_record_satisfied_axis_deadzone_and_direction() -> void:
	var left := DefaultBindings.joy_axis_record(0, -1.0)
	var down := DefaultBindings.joy_axis_record(1, 1.0)
	check_true(DefaultBindings.record_satisfied(left, false, -0.75), "left axis satisfied")
	check_false(DefaultBindings.record_satisfied(left, false, 0.75), "wrong direction rejected")
	check_false(DefaultBindings.record_satisfied(left, false, -0.3), "drift below the deadzone rejected")
	check_false(DefaultBindings.record_satisfied(down, false, -1.0), "down axis not satisfied by up")
	check_true(DefaultBindings.record_satisfied(down, false, 1.0), "down axis satisfied")


func test_device_action_pressed_without_pads() -> void:
	# Headless runs have no pads connected: polling must read as unpressed
	# instead of erroring or guessing.
	var records: Array = [DefaultBindings.joy_button_record(0), DefaultBindings.joy_axis_record(0, -1.0)]
	check_false(DefaultBindings.device_action_pressed(-1, records), "no device never satisfies")
	check_false(DefaultBindings.device_action_pressed(99, records), "unknown device reads unpressed")
	check_false(DefaultBindings.device_matches_record(-1, records[0]), "record match requires a device")


func test_action_for_record_prefers_canonical_order() -> void:
	var profile := DefaultBindings.default_controller_profile()
	check_eq(DefaultBindings.action_for_record(profile, DefaultBindings.joy_button_record(0)), "rotate_cw", "A button found for rotate_cw")
	check_eq(DefaultBindings.action_for_record(profile, DefaultBindings.joy_button_record(1)), "hard_drop", "B button found for hard_drop")
	check_eq(DefaultBindings.action_for_record(profile, DefaultBindings.joy_button_record(15)), "", "unbound button reports no action")
	var empty: Dictionary = {}
	check_eq(DefaultBindings.action_for_record(empty, DefaultBindings.joy_button_record(0)), "", "empty profile reports no action")


# ------------------------------------------------------------- coop presets

func test_keyboard_presets_are_disjoint() -> void:
	var reserved: Array = [KEY_ENTER, KEY_ESCAPE, KEY_SPACE, KEY_P, KEY_R]
	var seen: Array = []
	for player in CoopBindings.MAX_PLAYERS:
		var preset: Dictionary = CoopBindings.keyboard_preset(player)
		for action in CoopBindings.ACTIONS:
			check(preset.has(action), "player %d preset defines %s" % [player, action])
			var code: int = preset[action]
			check_false(seen.has(code), "key %d used by only one player" % code)
			check_false(reserved.has(code), "key %d not used by menu/shared actions" % code)
			seen.append(code)


func test_coop_bindings_retired_fixed_controller_layout() -> void:
	# Controller routing is per-profile now; the fixed pad layout and its
	# joypad summary are gone while the keyboard clusters remain as the
	# non-controller fallback.
	check(CoopBindings.ACTIONS.size() == 7, "seven cluster actions")
	check_eq(CoopBindings.SINGLE_FIRE_ACTIONS, ["rotate_cw", "rotate_ccw", "hold", "hard_drop"], "single-fire actions listed")
	check_false(CoopBindings.keyboard_summary(0).is_empty(), "keyboard cluster summary still describes the fallback")
	check_false(CoopBindings.keyboard_preset(0).is_empty(), "keyboard presets intact")
	for action in ["pause", "restart"]:
		check_false(CoopBindings.ACTIONS.has(action), "pause/restart are shared, not cluster actions")


# ------------------------------------------------------------- hold tracker

func _tick(tracker, pressed: Dictionary, excluded: Array, step: float) -> Dictionary:
	return tracker.update(pressed, excluded, step)


func test_hold_tracker_completes_after_three_seconds() -> void:
	var t := HoldTracker.new()
	var event := {}
	for i in 6:
		event = _tick(t, {0: [2]}, [], 0.5)
	check_eq(event["event"], "claimed", "3 seconds of hold claims the pad")
	check_eq(event["device"], 0, "claimed device reported")
	check_eq(t.state(), HoldTracker.STATE_COMPLETE, "tracker waits for release")


func test_hold_tracker_progress_and_reset() -> void:
	var t := HoldTracker.new()
	_tick(t, {3: [0]}, [], 1.0)
	check_true(is_equal_approx(t.progress(), 1.0 / 3.0), "progress accumulates")
	_tick(t, {3: [0]}, [], 1.0)
	check_true(is_equal_approx(t.progress(), 2.0 / 3.0), "progress keeps accumulating")
	# Releasing mid-hold resets to zero.
	_tick(t, {}, [], 0.5)
	check_eq(t.progress(), 0.0, "release resets progress")
	check_eq(t.device(), -1, "candidate forgotten after release")


func test_hold_tracker_resets_on_button_or_device_change() -> void:
	var t := HoldTracker.new()
	_tick(t, {1: [4]}, [], 2.0)
	check_true(is_equal_approx(t.progress(), 2.0 / 3.0), "initial hold accumulates")
	_tick(t, {1: [5]}, [], 0.5)
	check_true(is_equal_approx(t.progress(), 0.5 / 3.0), "switching buttons restarts the hold from zero")
	_tick(t, {2: [5]}, [], 0.5)
	check_true(is_equal_approx(t.progress(), 0.5 / 3.0), "switching devices restarts the hold")
	check_eq(t.device(), 2, "candidate follows the new device")


func test_hold_tracker_excludes_claimed_devices() -> void:
	var t := HoldTracker.new()
	var event := _tick(t, {0: [1]}, [0], 3.0)
	check_eq(event["event"], "", "excluded pad is not a candidate")
	check_eq(event["device"], -1, "no candidate while only excluded pads are held")
	var claim := _tick(t, {0: [1], 1: [1]}, [0], 3.0)
	check_eq(claim["event"], "claimed", "a free pad claims while the excluded pad is held")
	check_eq(claim["device"], 1, "claim names the free pad, never the excluded one")


func test_hold_tracker_requires_release_after_claim() -> void:
	var t := HoldTracker.new()
	_tick(t, {0: [1]}, [], 3.0)
	check_eq(_tick(t, {0: [1, 2]}, [], 1.0)["event"], "", "still holding: no second event")
	var event := _tick(t, {}, [], 1.0)
	check_eq(event["event"], "released", "release reported after the claim")
	check_eq(event["device"], 0, "release names the claimed device")
	check_eq(t.state(), HoldTracker.STATE_IDLE, "tracker reusable after release")


# -------------------------------------------------------- UI nav classification

func _joy_button_event(button: int, pressed: bool = true) -> InputEventJoypadButton:
	var ev := InputEventJoypadButton.new()
	ev.device = 2
	ev.button_index = button
	ev.pressed = pressed
	return ev


func _joy_motion_event(axis: int, value: float, device: int = 2) -> InputEventJoypadMotion:
	var ev := InputEventJoypadMotion.new()
	ev.device = device
	ev.axis = axis
	ev.axis_value = value
	return ev


func test_ui_nav_button_classification() -> void:
	var nav := UiNavigation.new()
	check_eq(nav.classify(_joy_button_event(JOY_BUTTON_A)), "accept", "A is accept")
	check_eq(nav.classify(_joy_button_event(JOY_BUTTON_B)), "back", "B is back")
	check_eq(nav.classify(_joy_button_event(JOY_BUTTON_DPAD_UP)), "up", "D-pad up")
	check_eq(nav.classify(_joy_button_event(JOY_BUTTON_DPAD_LEFT)), "left", "D-pad left")
	check_eq(nav.classify(_joy_button_event(JOY_BUTTON_X)), "", "gameplay-only buttons never navigate")
	check_eq(nav.classify(_joy_button_event(JOY_BUTTON_A, false)), "", "button release never navigates")


func test_ui_nav_stick_edge_protection() -> void:
	var nav := UiNavigation.new()
	check_eq(nav.classify(_joy_motion_event(JOY_AXIS_LEFT_Y, 0.2)), "", "drift below the deadzone is ignored")
	check_eq(nav.classify(_joy_motion_event(JOY_AXIS_LEFT_Y, -0.8)), "up", "stick up fires once")
	for i in 5:
		check_eq(nav.classify(_joy_motion_event(JOY_AXIS_LEFT_Y, -1.0)), "", "held stick does not repeat")
	check_eq(nav.classify(_joy_motion_event(JOY_AXIS_LEFT_Y, -0.1)), "", "return to neutral is silent")
	check_eq(nav.classify(_joy_motion_event(JOY_AXIS_LEFT_Y, 0.9)), "down", "re-armed stick fires the other way")
	check_eq(nav.classify(_joy_motion_event(JOY_AXIS_LEFT_X, 0.9)), "right", "x axis fires right")
	check_eq(nav.classify(_joy_motion_event(JOY_AXIS_LEFT_X, -0.9)), "left", "x axis fires left")


func test_ui_nav_stick_state_is_per_device() -> void:
	var nav := UiNavigation.new()
	check_eq(nav.classify(_joy_motion_event(JOY_AXIS_LEFT_X, 0.9, 0)), "right", "device 0 fires")
	check_eq(nav.classify(_joy_motion_event(JOY_AXIS_LEFT_X, 0.9, 1)), "right", "device 1 fires independently")
	nav.reset()
	check_eq(nav.classify(_joy_motion_event(JOY_AXIS_LEFT_X, 1.0, 0)), "right", "reset re-arms the stick")


# ------------------------------------------------------------- mode metadata

func test_mode_descriptors() -> void:
	var keys: Array = []
	for d in ModeRules.descriptors():
		keys.append(d["key"])
	check_eq(keys, ["solo_marathon", "coop_marathon", "solo_sprint", "coop_sprint"], "stable mode keys")
	check_eq(ModeRules.mode_key(ModeRules.Mode.MARATHON, false), "solo_marathon", "solo marathon key")
	check_eq(ModeRules.mode_key(ModeRules.Mode.SPRINT, true), "coop_sprint", "coop sprint key")
	check_eq(ModeRules.descriptor("coop_sprint")["ranking"], ModeRules.RANK_TIME_ASC, "sprint ranks by time")
	check_eq(ModeRules.descriptor("solo_marathon")["ranking"], ModeRules.RANK_SCORE_DESC, "marathon ranks by score")
	check_eq(ModeRules.descriptor("unknown_mode"), {}, "unknown key has no descriptor")
	check_true(ModeRules.higher_score_wins(ModeRules.Mode.MARATHON), "marathon keeps higher scores")
	check_false(ModeRules.higher_score_wins(ModeRules.Mode.SPRINT), "sprint keeps lower times")


func test_mode_recording_eligibility() -> void:
	check_true(ModeRules.records_on_game_over(ModeRules.Mode.MARATHON), "marathon records on game over")
	check_false(ModeRules.records_on_game_over(ModeRules.Mode.SPRINT), "sprint game over records nothing")
	check_true(ModeRules.records_on_finish(ModeRules.Mode.SPRINT), "sprint records on finish")
	check_false(ModeRules.records_on_finish(ModeRules.Mode.MARATHON), "marathon never finishes")
	check_eq(ModeRules.format_time(83.456), "01:23.46", "time formatting matches the results overlay")
