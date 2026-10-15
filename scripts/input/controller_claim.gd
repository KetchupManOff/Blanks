extends Node
## Session-scoped controller claim: while active, the player holds any
## button on an available pad for two seconds to claim it for a lobby
## slot or a binding flow. Consumes joypad input from candidate devices in
## _input() so no menu or gameplay reacts to the claim, and Escape cancels.
## The hold logic lives in HoldTracker (pure); the snapshot poller is a
## Callable so headless tests can feed synthetic input.

signal claimed(device: int)
signal released(device: int)
signal cancelled()

const HoldTracker = preload("res://scripts/input/hold_tracker.gd")

var active: bool = false
var excluded_devices: Array = []
## Snapshot provider: {device_id: [pressed button indexes]}. Overridable
## for tests; defaults to the real Input singleton.
var poll_pressed: Callable = Callable()

var _tracker: HoldTracker = HoldTracker.new()


func _init() -> void:
	poll_pressed = Callable(self, "_poll_real_pressed")


func start(excluded: Array = []) -> void:
	excluded_devices = excluded.duplicate()
	_tracker.reset()
	active = true


func stop() -> void:
	active = false
	_tracker.reset()


func progress() -> float:
	return _tracker.progress()


func claimed_device() -> int:
	return _tracker.device()


func is_waiting_release() -> bool:
	return _tracker.state() == HoldTracker.STATE_COMPLETE


func _input(event: InputEvent) -> void:
	if not active:
		return
	if event is InputEventJoypadButton or event is InputEventJoypadMotion:
		# Claim events never reach menus or gameplay.
		if not excluded_devices.has(event.device):
			get_viewport().set_input_as_handled()
	elif event is InputEventKey:
		var k := event as InputEventKey
		if k.pressed and not k.is_echo() and k.physical_keycode == KEY_ESCAPE:
			get_viewport().set_input_as_handled()
			_finish_cancelled()


func _process(delta: float) -> void:
	tick(delta)


## Single step of the claim state machine; also callable from tests.
func tick(delta: float) -> void:
	if not active:
		return
	var result: Dictionary = _tracker.update(poll_pressed.call(), excluded_devices, delta)
	match result["event"]:
		"claimed":
			claimed.emit(result["device"])
		"released":
			released.emit(result["device"])


func _finish_cancelled() -> void:
	var was_active := active
	stop()
	if was_active:
		cancelled.emit()


func _poll_real_pressed() -> Dictionary:
	var out := {}
	for device in Input.get_connected_joypads():
		var buttons: Array = []
		for button in JOY_BUTTON_MAX:
			if Input.is_joy_button_pressed(device, button):
				buttons.append(button)
		if not buttons.is_empty():
			out[device] = buttons
	return out
