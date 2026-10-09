extends RefCounted
## Fixed local keyboard presets for cooperative play, kept as a
## non-controller fallback for lobby slots. Keyboard clusters are
## hard-coded per player so coop deliberately never touches the persisted
## keyboard profile or the global InputMap: solo bindings and settings
## round trips stay untouched. Controller input is routed per lobby slot
## from each player's profile (see input_controller.gd); pause and
## restart stay shared actions.

const DefaultBindings = preload("res://scripts/input/default_bindings.gd")

const MAX_PLAYERS: int = 4

# Per-player keyboard clusters: every key appears in at most one preset, and
# no preset uses Enter, Escape, or Space (menu confirm/cancel/hard drop of
# the shared keyboard profile) or P/R (shared pause/restart).
const KEYBOARD_PRESETS := [
	{  # Player 1: left-hand QWE/ASD/F cluster
		"move_left": KEY_A,
		"move_right": KEY_D,
		"soft_drop": KEY_S,
		"rotate_cw": KEY_W,
		"rotate_ccw": KEY_Q,
		"hold": KEY_E,
		"hard_drop": KEY_F,
	},
	{  # Player 2: arrows plus comma/period/slash cluster
		"move_left": KEY_LEFT,
		"move_right": KEY_RIGHT,
		"soft_drop": KEY_DOWN,
		"rotate_cw": KEY_UP,
		"rotate_ccw": KEY_COMMA,
		"hold": KEY_PERIOD,
		"hard_drop": KEY_SLASH,
	},
	{  # Player 3: numpad cluster
		"move_left": KEY_KP_4,
		"move_right": KEY_KP_6,
		"soft_drop": KEY_KP_2,
		"rotate_cw": KEY_KP_8,
		"rotate_ccw": KEY_KP_7,
		"hold": KEY_KP_9,
		"hard_drop": KEY_KP_0,
	},
	{  # Player 4: right-hand YUI/HJK/N cluster
		"move_left": KEY_H,
		"move_right": KEY_K,
		"soft_drop": KEY_J,
		"rotate_cw": KEY_U,
		"rotate_ccw": KEY_Y,
		"hold": KEY_I,
		"hard_drop": KEY_N,
	},
]

const AXIS_DEADZONE: float = 0.5

const ACTIONS := ["move_left", "move_right", "soft_drop", "rotate_cw", "rotate_ccw", "hold", "hard_drop"]
const SINGLE_FIRE_ACTIONS := ["rotate_cw", "rotate_ccw", "hold", "hard_drop"]


static func keyboard_preset(player: int) -> Dictionary:
	return KEYBOARD_PRESETS[clampi(player, 0, MAX_PLAYERS - 1)]


static func key_name(code: int) -> String:
	return DefaultBindings.key_display_name(code)


static func keyboard_summary(player: int) -> String:
	var keys: Dictionary = keyboard_preset(player)
	return "%s/%s move  %s soft  %s/%s rotate  %s hold  %s drop" % [
		key_name(keys["move_left"]),
		key_name(keys["move_right"]),
		key_name(keys["soft_drop"]),
		key_name(keys["rotate_cw"]),
		key_name(keys["rotate_ccw"]),
		key_name(keys["hold"]),
		key_name(keys["hard_drop"]),
	]


static func connected_joypad_count() -> int:
	return Input.get_connected_joypads().size()
