extends Node
## Translates raw keyboard/controller input into logical gameplay actions on
## the host. Owns DAS/ARR movement timing, single-fire edges for rotation/
## drop/hold, and focus-loss cancellation of held inputs.
##
## Controller ownership is session-scoped and explicit: solo holds one
## (profile, device) assignment, coop holds one per player slot. Each
## assigned device is polled against its slot's profile controller
## bindings only - never against the global InputMap - so several profiles
## can coexist on different pads and one pad never drives several players.
## Keyboard ownership follows the same rule: the active profile's mapping
## drives the global InputMap for solo input and menus, while coop slots
## poll their own profile's keyboard records directly so bindings never
## bleed between players. Pause/restart fire from any pollable slot's own
## profile mapping locally; online they are host-only (clients ignore
## them) so a local key can never pause or reset an authoritative run.

const PlayConfig = preload("res://scripts/core/constants.gd")
const DefaultBindings = preload("res://scripts/input/default_bindings.gd")

# Single-fire actions and the host methods they trigger.
const _SINGLE_FIRE := {
	"hard_drop": "action_hard_drop",
	"rotate_cw": "action_rotate_cw",
	"rotate_ccw": "action_rotate_ccw",
	"hold": "action_hold",
	"pause": "action_pause",
	"restart": "action_restart",
}

# Actions that stay shared in coop (keyboard or pad via any slot's own
# profile mapping, host-only while online).
const _SHARED_ACTIONS := ["pause", "restart"]

# Per-slot single-fire gameplay actions (movement-held actions excluded).
const _COOP_SINGLE_FIRE := ["hard_drop", "rotate_cw", "rotate_ccw", "hold"]

const AXIS_DEADZONE := 0.5

var _host: Node = null
var _prev_single_fire := {}
var _left_held: bool = false
var _right_held: bool = false
var _active_dir: int = 0
var _das_timer: float = 0.0
var _arr_timer: float = 0.0
var _soft_drop_held: bool = false
var _was_focused: bool = true

# --- Solo assignment (profile id + session device; device < 0 = keyboard only) ---
var _solo_profile_id: String = ""
var _solo_device: int = -1
var _solo_bindings: Dictionary = {}

# --- Coop per-slot assignments and held state (empty while a solo run is active) ---
var _coop_player_count: int = 0
var _coop_profile_ids: Array = []  # per-slot profile id
var _coop_profiles: Array = []  # per-slot sanitized controller-only profiles
var _coop_keyboards: Array = []  # per-slot sanitized keyboard-only profiles
var _coop_devices: Array = []  # per-slot device id (< 0 = keyboard only)
# Online coop: slots are network-wide; only the local slot is pollable.
# Remote slots keep aligned indices but never read local hardware.
var _coop_pollable: Array = []  # per-slot bool
var _coop_left: Array = []
var _coop_right: Array = []
var _coop_dir: Array = []
var _coop_das: Array = []
var _coop_arr: Array = []
var _coop_soft: Array = []
var _coop_fire_prev: Array = []


func _init(host: Node) -> void:
	_host = host


func _process(delta: float) -> void:
	_check_focus()
	if _coop_player_count > 0:
		_poll_shared_single_fire()
		_poll_coop(delta)
	else:
		_poll_actions(delta)
		_run_das(delta)


# ------------------------------------------------------------------ focus

func _check_focus() -> void:
	var focused: bool = true
	var window := get_window()
	if window != null:
		focused = window.has_focus()
	if _was_focused and not focused:
		release_all()
		_host.auto_pause_on_focus_loss()
	_was_focused = focused


func release_all() -> void:
	_left_held = false
	_right_held = false
	_active_dir = 0
	_das_timer = 0.0
	_arr_timer = 0.0
	if _soft_drop_held:
		_soft_drop_held = false
		_host.action_soft_drop(false)
	for i in _coop_player_count:
		_coop_dir[i] = 0
		_coop_das[i] = 0.0
		_coop_arr[i] = 0.0
		if _coop_soft[i]:
			_coop_soft[i] = false
			_host.action_coop_soft_drop(i, false)


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		release_all()
		_host.auto_pause_on_focus_loss()


# ------------------------------------------------------------ assignments

func begin_solo(profile_id: String, device: int) -> void:
	## Solo routes the assigned device to this profile's controller
	## bindings; a missing profile or device leaves keyboard-only input.
	_solo_profile_id = profile_id
	_solo_device = device
	_solo_bindings = _bindings_for_profile(profile_id)


func begin_coop(assignments: Array) -> void:
	## Each entry is {"profile_id": String, "device": int}; slot order is
	## player order. Every slot polls its own profile's keyboard records
	## directly (plus its assigned pad against the controller records).
	_coop_player_count = 0
	_coop_profile_ids = []
	_coop_profiles = []
	_coop_keyboards = []
	_coop_devices = []
	_coop_pollable = []
	_coop_left = []
	_coop_right = []
	_coop_dir = []
	_coop_das = []
	_coop_arr = []
	_coop_soft = []
	_coop_fire_prev = []
	for assignment in assignments:
		if not (assignment is Dictionary):
			continue
		var profile_id := String(assignment.get("profile_id", ""))
		var device := int(assignment.get("device", -1))
		_coop_profile_ids.append(profile_id)
		_coop_profiles.append(_bindings_for_profile(profile_id))
		_coop_keyboards.append(_keybindings_for_profile(profile_id))
		_coop_devices.append(device)
		_coop_pollable.append(true)
		_coop_left.append(false)
		_coop_right.append(false)
		_coop_dir.append(0)
		_coop_das.append(0.0)
		_coop_arr.append(0.0)
		_coop_soft.append(false)
		_coop_fire_prev.append({})
		_coop_player_count += 1


func begin_online(own_slot: int, player_count: int, profile_id: String, device: int) -> void:
	## Online coop: slot indices are network-wide roster slots. Only
	## `own_slot` maps to local hardware - its profile's keyboard records
	## plus the assigned pad polled against the local profile's controller
	## bindings. Remote slots exist as placeholders so indices stay aligned
	## but never poll, so local input can never drive another peer's
	## player.
	reset_online_session()
	if own_slot < 0 or own_slot >= player_count:
		push_error("input: online begin with own_slot %d outside %d slots" % [own_slot, player_count])
		return
	for i in player_count:
		var is_own: bool = i == own_slot
		var slot_profile := profile_id if is_own else ""
		var slot_device := device if is_own else -1
		_coop_profile_ids.append(slot_profile)
		_coop_profiles.append(_bindings_for_profile(slot_profile))
		_coop_keyboards.append(_keybindings_for_profile(slot_profile))
		_coop_devices.append(slot_device)
		_coop_pollable.append(is_own)
		_coop_left.append(false)
		_coop_right.append(false)
		_coop_dir.append(0)
		_coop_das.append(0.0)
		_coop_arr.append(0.0)
		_coop_soft.append(false)
		_coop_fire_prev.append({})
		_coop_player_count += 1


func reset_online_session() -> void:
	## Release held edges and discard slot ownership before an online run is
	## torn down or rebuilt. The controller node persists across rounds.
	release_all()
	_prev_single_fire = {}
	end_coop()


func end_coop() -> void:
	_coop_player_count = 0
	_coop_profile_ids = []
	_coop_profiles = []
	_coop_keyboards = []
	_coop_devices = []
	_coop_pollable = []
	_coop_left = []
	_coop_right = []
	_coop_dir = []
	_coop_das = []
	_coop_arr = []
	_coop_soft = []
	_coop_fire_prev = []


func refresh_profile(profile_id: String) -> void:
	## Live rebind support: reload a profile's controller and keyboard
	## bindings while a run holds the assignment (e.g. guided rebinding
	## opened from pause or the profile browser).
	if _solo_profile_id == profile_id:
		_solo_bindings = _bindings_for_profile(profile_id)
	for i in _coop_player_count:
		if String(_coop_profile_ids[i]) == profile_id:
			_coop_profiles[i] = _bindings_for_profile(profile_id)
			_coop_keyboards[i] = _keybindings_for_profile(profile_id)


func _bindings_for_profile(profile_id: String) -> Dictionary:
	if profile_id.is_empty() or _host == null or _host.settings == null:
		return {}
	return _host.settings.controller_bindings_for(profile_id)


func _keybindings_for_profile(profile_id: String) -> Dictionary:
	if profile_id.is_empty() or _host == null or _host.settings == null:
		return {}
	return _host.settings.keyboard_bindings_for(profile_id)


func coop_device_for(player: int) -> int:
	## Test/inspection helper: the device assigned to a coop slot.
	if player < 0 or player >= _coop_player_count:
		return -1
	return _coop_devices[player]


func coop_profile_bindings(player: int) -> Dictionary:
	if player < 0 or player >= _coop_player_count:
		return {}
	return _coop_profiles[player]


func coop_keyboard_bindings(player: int) -> Dictionary:
	## Test/inspection helper: the keyboard bindings polled for a slot.
	if player < 0 or player >= _coop_player_count:
		return {}
	return _coop_keyboards[player]


# ------------------------------------------------------------------- input

func _unhandled_input(event: InputEvent) -> void:
	# Instant response for single-fire actions; polling below also reconciles
	# missed edges. Outside active play the UI owns key/button events so
	# menus can navigate (Enter/A/Space overlap gameplay bindings).
	if event.is_echo():
		return
	if _host != null and not _host.is_gameplay_input_enabled():
		return
	if _coop_player_count > 0:
		_coop_event(event)
		return
	for action in _SINGLE_FIRE:
		if event.is_action_pressed(action):
			_fire(action)
			_prev_single_fire[action] = true
			get_viewport().set_input_as_handled()
			return
	_solo_device_event(event)


func _poll_actions(delta: float) -> void:
	# Reconcile held movement and single-fire edges via polling so state is
	# robust against missed events (focus changes, fast taps). Solo input
	# combines the shared keyboard profile (global InputMap) with the
	# assigned device polled against the solo profile's controller records.
	var connected: Array = Input.get_connected_joypads()
	var left: bool = Input.is_action_pressed("move_left") or _device_action(_solo_device, _solo_bindings, "move_left", connected)
	var right: bool = Input.is_action_pressed("move_right") or _device_action(_solo_device, _solo_bindings, "move_right", connected)
	if left and not _left_held:
		_press_dir(-1)
	if right and not _right_held:
		_press_dir(1)
	if not left and _left_held:
		_release_dir(-1)
	if not right and _right_held:
		_release_dir(1)
	_left_held = left
	_right_held = right

	var soft: bool = Input.is_action_pressed("soft_drop") or _device_action(_solo_device, _solo_bindings, "soft_drop", connected)
	if soft != _soft_drop_held:
		_soft_drop_held = soft
		_host.action_soft_drop(soft)

	for action in _SINGLE_FIRE:
		var pressed: bool = Input.is_action_pressed(action) or _device_action(_solo_device, _solo_bindings, action, connected)
		var previous: bool = _prev_single_fire.get(action, false)
		if pressed and not previous:
			_fire(action)
		_prev_single_fire[action] = pressed


func _fire(action: String) -> void:
	_host.call(_SINGLE_FIRE[action])


# ------------------------------------------------------------------- coop

func _poll_shared_single_fire() -> void:
	# Pause/restart stay shared: any pollable slot's own profile mapping may
	# fire them - keyboard records polled directly, pads via the assigned
	# device. Online clients never locally transition an authoritative run,
	# so the shared actions stop firing (and stop tracking) there.
	if not _shared_fire_allowed():
		_prev_single_fire = {}
		return
	var connected: Array = Input.get_connected_joypads()
	for action in _SHARED_ACTIONS:
		var pressed: bool = false
		for i in _coop_player_count:
			if not bool(_coop_pollable[i]):
				continue
			if DefaultBindings.keyboard_action_held(_coop_keyboards[i], action):
				pressed = true
				break
			if _device_action(_coop_devices[i], _coop_profiles[i], action, connected):
				pressed = true
				break
		var previous: bool = _prev_single_fire.get(action, false)
		if pressed and not previous:
			_fire(action)
		_prev_single_fire[action] = pressed


## True while shared (pause/restart) actions may fire. Online clients may
## never locally pause or restart the host-authoritative run; the host
## alone owns the match-state transitions.
func _shared_fire_allowed() -> bool:
	return _host == null or not _host.is_online_client()


func _poll_coop(delta: float) -> void:
	var connected: Array = Input.get_connected_joypads()
	for i in _coop_player_count:
		if not bool(_coop_pollable[i]):
			# Remote online slots never read local hardware.
			continue
		_poll_coop_player(i, connected, delta)


func _poll_coop_player(i: int, connected: Array, delta: float) -> void:
	var keys: Dictionary = _coop_keyboards[i]
	var device: int = _coop_devices[i]
	var bindings: Dictionary = _coop_profiles[i]
	var left: bool = DefaultBindings.keyboard_action_held(keys, "move_left") or _device_action(device, bindings, "move_left", connected)
	var right: bool = DefaultBindings.keyboard_action_held(keys, "move_right") or _device_action(device, bindings, "move_right", connected)
	var soft: bool = DefaultBindings.keyboard_action_held(keys, "soft_drop") or _device_action(device, bindings, "soft_drop", connected)

	if left and not _coop_left[i]:
		_coop_press_dir(i, -1)
	if right and not _coop_right[i]:
		_coop_press_dir(i, 1)
	if not left and _coop_left[i]:
		_coop_release_dir(i, -1)
	if not right and _coop_right[i]:
		_coop_release_dir(i, 1)
	_coop_left[i] = left
	_coop_right[i] = right

	if soft != _coop_soft[i]:
		_coop_soft[i] = soft
		_host.action_coop_soft_drop(i, soft)

	for action in _COOP_SINGLE_FIRE:
		var pressed: bool = DefaultBindings.keyboard_action_held(keys, action) or _device_action(device, bindings, action, connected)
		var previous: bool = _coop_fire_prev[i].get(action, false)
		if pressed and not previous:
			_coop_fire(i, action)
		_coop_fire_prev[i][action] = pressed

	_run_coop_das(i, delta)


func _coop_event(event: InputEvent) -> void:
	# Instant single-fire response for coop: per-slot keyboard records and
	# profile-mapped events from an assigned pad. Online remote slots are
	# skipped: a local keypress must never move another peer's player.
	if event is InputEventKey:
		var record := DefaultBindings.record_from_event(event)
		if record.is_empty():
			return
		for i in _coop_player_count:
			if not bool(_coop_pollable[i]):
				continue
			var action := DefaultBindings.action_for_record(_coop_keyboards[i], record)
			if action.is_empty():
				continue
			if _fire_matched_action(i, action):
				return
	elif event is InputEventJoypadButton or event is InputEventJoypadMotion:
		var pad_record := _record_from_event(event)
		if pad_record.is_empty():
			return
		for i in _coop_player_count:
			if not bool(_coop_pollable[i]):
				continue
			if event.device != _coop_devices[i]:
				continue
			var action := DefaultBindings.action_for_record(_coop_profiles[i], pad_record)
			if action.is_empty():
				continue
			if _fire_matched_action(i, action):
				return


## Fire one action matched for a slot's bindings. Returns true when the
## event is consumed. Shared actions are host-gated online; movement
## actions belong to the polling loop and never fire from events.
func _fire_matched_action(i: int, action: String) -> bool:
	if _SHARED_ACTIONS.has(action):
		if not _shared_fire_allowed():
			return false
		_fire(action)
		_prev_single_fire[action] = true
		get_viewport().set_input_as_handled()
		return true
	if _COOP_SINGLE_FIRE.has(action):
		_coop_fire(i, action)
		_coop_fire_prev[i][action] = true
		get_viewport().set_input_as_handled()
		return true
	return false


func _solo_device_event(event: InputEvent) -> void:
	if _solo_device < 0:
		return
	if not (event is InputEventJoypadButton or event is InputEventJoypadMotion):
		return
	if event.device != _solo_device:
		return
	var record := _record_from_event(event)
	if record.is_empty():
		return
	var action := DefaultBindings.action_for_record(_solo_bindings, record)
	if action.is_empty() or not _SINGLE_FIRE.has(action):
		return
	_fire(action)
	_prev_single_fire[action] = true
	get_viewport().set_input_as_handled()


static func _record_from_event(event: InputEvent) -> Dictionary:
	# Records ignore the device id (bindings are profile-portable); axis
	# drift below the deadzone produces no record.
	if event is InputEventJoypadButton:
		return DefaultBindings.record_from_event(event)
	if event is InputEventJoypadMotion:
		var m := event as InputEventJoypadMotion
		if absf(m.axis_value) < AXIS_DEADZONE:
			return {}
		return DefaultBindings.record_from_event(m)
	return {}


func _device_action(device: int, bindings: Dictionary, action: String, connected: Array) -> bool:
	# A disconnected device reads as unpressed: held states clear through
	# the normal edge logic and never leak to another profile.
	if device < 0 or bindings.is_empty() or not connected.has(device):
		return false
	return DefaultBindings.device_action_pressed(device, bindings.get(action, []))


func _coop_fire(i: int, action: String) -> void:
	match action:
		"hard_drop":
			_host.action_coop_hard_drop(i)
		"rotate_cw":
			_host.action_coop_rotate(i, 1)
		"rotate_ccw":
			_host.action_coop_rotate(i, -1)
		"hold":
			_host.action_coop_hold(i)


func _coop_press_dir(i: int, dir: int) -> void:
	_coop_dir[i] = dir
	_coop_das[i] = 0.0
	_coop_arr[i] = 0.0
	_host.action_coop_move(i, dir)


func _coop_release_dir(i: int, dir: int) -> void:
	if _coop_dir[i] != dir:
		return
	# Last-pressed priority: fall back to the other direction if still held.
	if dir == -1 and _coop_right[i]:
		_coop_press_dir(i, 1)
	elif dir == 1 and _coop_left[i]:
		_coop_press_dir(i, -1)
	else:
		_coop_dir[i] = 0
		_coop_das[i] = 0.0
		_coop_arr[i] = 0.0


func _run_coop_das(i: int, delta: float) -> void:
	if _coop_dir[i] == 0:
		return
	_coop_das[i] += delta
	if _coop_das[i] < PlayConfig.DAS_SECONDS:
		return
	if PlayConfig.ARR_SECONDS <= 0.0:
		# ARR 0: slam to the wall instantly.
		while _host.action_coop_move(i, _coop_dir[i]):
			pass
		return
	_coop_arr[i] += delta
	while _coop_arr[i] >= PlayConfig.ARR_SECONDS:
		_coop_arr[i] -= PlayConfig.ARR_SECONDS
		if not _host.action_coop_move(i, _coop_dir[i]):
			_coop_arr[i] = 0.0
			break


# --------------------------------------------------------------------- DAS

func _press_dir(dir: int) -> void:
	_active_dir = dir
	_das_timer = 0.0
	_arr_timer = 0.0
	_host.action_move(dir)


func _release_dir(dir: int) -> void:
	if _active_dir != dir:
		return
	# Last-pressed priority: fall back to the other direction if still held.
	if dir == -1 and _right_held:
		_press_dir(1)
	elif dir == 1 and _left_held:
		_press_dir(-1)
	else:
		_active_dir = 0
		_das_timer = 0.0
		_arr_timer = 0.0


func _run_das(delta: float) -> void:
	if _active_dir == 0:
		return
	_das_timer += delta
	if _das_timer < PlayConfig.DAS_SECONDS:
		return
	if PlayConfig.ARR_SECONDS <= 0.0:
		# ARR 0: slam to the wall instantly.
		while _host.action_move(_active_dir):
			pass
		return
	_arr_timer += delta
	while _arr_timer >= PlayConfig.ARR_SECONDS:
		_arr_timer -= PlayConfig.ARR_SECONDS
		if not _host.action_move(_active_dir):
			_arr_timer = 0.0
			break
