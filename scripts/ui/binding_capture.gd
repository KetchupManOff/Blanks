extends Node
## One-shot input capture for binding remaps. While active, consumes raw
## input events in _input() so menus and gameplay never react to them.
##
## Capture modes:
## - keyboard: keyboard keys only (with modifiers). Escape cancels; Delete
##   or Backspace requests clearing the latest secondary binding.
## - controller(device): joypad buttons and axis directions above the
##   deadzone from that specific device only. Escape or the pad's B button
##   cancels; the device identity is preserved for the session.
## Pure modifier keys are ignored so bindings like Shift can be captured.

signal captured(record: Dictionary)
signal cleared()
signal cancelled()

const DefaultBindings = preload("res://scripts/input/default_bindings.gd")

const AXIS_DEADZONE := 0.5

const _MODIFIER_KEYS := [KEY_SHIFT, KEY_CTRL, KEY_ALT, KEY_META]

const MODE_KEYBOARD := "keyboard"
const MODE_CONTROLLER := "controller"

var active: bool = false
var mode: String = MODE_KEYBOARD
var device: int = -1


## Keyboard-only capture for the shared keyboard bindings page.
func start() -> void:
	mode = MODE_KEYBOARD
	device = -1
	active = true


## Controller capture locked to one device for the guided binding flow.
func start_controller(capture_device: int) -> void:
	mode = MODE_CONTROLLER
	device = capture_device
	active = true


func stop() -> void:
	active = false


func _input(event: InputEvent) -> void:
	if not active:
		return
	if mode == MODE_KEYBOARD:
		_capture_keyboard(event)
	else:
		_capture_controller(event)


func _capture_keyboard(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var k := event as InputEventKey
	if not k.pressed or k.is_echo():
		return
	get_viewport().set_input_as_handled()
	if k.physical_keycode == KEY_ESCAPE:
		_finish_cancelled()
		return
	if k.physical_keycode == KEY_DELETE or k.physical_keycode == KEY_BACKSPACE:
		_finish_cleared()
		return
	if k.physical_keycode in _MODIFIER_KEYS:
		return  # keep waiting for the actual key
	var record := DefaultBindings.record_from_event(k)
	if record.is_empty():
		return
	_finish_captured(record)


func _capture_controller(event: InputEvent) -> void:
	if not (event is InputEventJoypadButton or event is InputEventJoypadMotion):
		# Keyboard input other than Escape is ignored, not consumed.
		if event is InputEventKey:
			var k := event as InputEventKey
			if k.pressed and not k.is_echo() and k.physical_keycode == KEY_ESCAPE:
				get_viewport().set_input_as_handled()
				_finish_cancelled()
		return
	# Events from other pads are consumed and ignored: the session device
	# owns the capture.
	get_viewport().set_input_as_handled()
	if event.device != device:
		return
	if event is InputEventJoypadButton:
		var b := event as InputEventJoypadButton
		if not b.pressed:
			return
		if b.button_index == JOY_BUTTON_B:
			# B is the reserved cancel control for the guided flow.
			_finish_cancelled()
			return
		_finish_captured(DefaultBindings.record_from_event(b))
		return
	var m := event as InputEventJoypadMotion
	if absf(m.axis_value) < AXIS_DEADZONE:
		return
	_finish_captured(DefaultBindings.record_from_event(m))


func _finish_captured(record: Dictionary) -> void:
	active = false
	captured.emit(record)


func _finish_cleared() -> void:
	active = false
	cleared.emit()


func _finish_cancelled() -> void:
	active = false
	cancelled.emit()
