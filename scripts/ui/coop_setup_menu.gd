extends CanvasLayer
## Local multiplayer lobby: one to four join slots instead of a fixed
## player count. A
## player claims a free pad by holding any button for two seconds (the
## claim tracker consumes the events, and the button must be released
## before the profile picker opens), or joins a slot with the keyboard.
## Every slot then picks or creates a profile - duplicates are rejected.
## The host can remove a joined slot, which frees its pad for a new claim.
## Mode selection and start stay; start passes the ordered profile ids
## plus device ids to the host. Everything routes through host commands.

const ModeRules = preload("res://scripts/core/mode_rules.gd")
const DefaultBindings = preload("res://scripts/input/default_bindings.gd")
const ThemeProfile = preload("res://scripts/ui/theme_profile.gd")
const UiNavigation = preload("res://scripts/ui/ui_navigation.gd")
const ControllerClaim = preload("res://scripts/input/controller_claim.gd")

const SLOT_ROWS: int = 4
const ROW_MODE: int = 4
const ROW_GARBAGE: int = 5
const ROW_START: int = 6
const ROW_BACK: int = 7
const ROW_COUNT: int = 8
## The lobby mode cycle: shared-board co-op plus the independent-board
## competitive modes.
const MODE_CYCLE: Array = [
	ModeRules.Mode.MARATHON,
	ModeRules.Mode.SPRINT,
	ModeRules.Mode.CLASSIC_VERSUS,
	ModeRules.Mode.TOWER,
]

var _host: Node = null
var _root: Control = null
var _bg: ColorRect = null
var _panel: PanelContainer = null
var _title: Label = null
var _subtitle: Label = null
var _rows: Array[Label] = []
var _pads: Label = null
var _nav: UiNavigation = UiNavigation.new()
var _claim: Node = null
## Slot state: {} free, or {"profile_id", "device", "name"} once joined
## (profile_id empty while the profile pick is pending after a claim).
## Initialized up front: theme application refreshes before _ready runs.
var slots: Array = [{}, {}, {}, {}]
var game_mode: int = ModeRules.Mode.MARATHON
## Versus lobby garbage switch (host decision, retained across retries).
var garbage_on: bool = true
var _selected: int = 0
var _claim_slot: int = -1
var _armed_remove: int = -1
var _tokens: Dictionary = ThemeProfile.default_tokens()
# Theme fonts: body for rows/summary, title for the heading.
var _font: Font = null
var _title_font: Font = null


func _ready() -> void:
	layer = 10
	visible = false
	set_process(true)
	_build()
	_claim = ControllerClaim.new()
	add_child(_claim)
	_claim.claimed.connect(_on_pad_claimed)
	_claim.released.connect(_on_pad_released)
	_claim.cancelled.connect(_on_claim_cancelled)


func _process(_delta: float) -> void:
	# Live claim progress in the pads line while a hold accumulates.
	if visible and _claim != null and _claim.active and _claim_slot < 0:
		var progress: int = int(round(_claim.progress() * 100.0))
		_pads.text = "Claiming a pad: %d%%" % progress


func setup(host: Node) -> void:
	_host = host


func _build() -> void:
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	_bg = ColorRect.new()
	_bg.color = _tokens["menu.scrim"]
	_bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_bg)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(center)

	_panel = PanelContainer.new()
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.add_child(_panel)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_child(box)

	_title = Label.new()
	_title.text = "LOCAL MULTIPLAYER"
	_title.add_theme_font_size_override("font_size", 40)
	_title.add_theme_color_override("font_color", _tokens["theme.text"])
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_apply_font_override(_title, _title_font)
	box.add_child(_title)

	_subtitle = Label.new()
	_subtitle.add_theme_font_size_override("font_size", 17)
	_subtitle.add_theme_color_override("font_color", _tokens["theme.dim"])
	_subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_apply_font_override(_subtitle, _font)
	box.add_child(_subtitle)

	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0.0, 18.0)
	box.add_child(spacer)

	for i in ROW_COUNT:
		var label := Label.new()
		label.add_theme_font_size_override("font_size", 24)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_apply_font_override(label, _font)
		box.add_child(label)
		_rows.append(label)

	var spacer2 := Control.new()
	spacer2.custom_minimum_size = Vector2(0.0, 18.0)
	box.add_child(spacer2)

	_pads = Label.new()
	_pads.add_theme_font_size_override("font_size", 15)
	_pads.add_theme_color_override("font_color", _tokens["theme.dim"])
	_pads.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_apply_font_override(_pads, _font)
	box.add_child(_pads)

	_style_panel()


func _style_panel() -> void:
	if _panel == null:
		return
	var style := StyleBoxFlat.new()
	style.bg_color = _tokens["menu.panel"]
	style.set_corner_radius_all(12)
	style.set_border_width_all(1)
	style.border_color = Color(_tokens["theme.accent"], 0.25)
	style.content_margin_left = 48.0
	style.content_margin_right = 48.0
	style.content_margin_top = 28.0
	style.content_margin_bottom = 28.0
	_panel.add_theme_stylebox_override("panel", style)


## Theme font override helper: null clears the override so the built-in
## font applies, non-null replaces it for that label only.
static func _apply_font_override(label: Label, font: Font) -> void:
	if font == null:
		label.remove_theme_font_override("font")
	else:
		label.add_theme_font_override("font", font)


func apply_theme(tokens: Dictionary, media: Dictionary) -> void:
	_tokens = tokens
	_font = media.get("font")
	_title_font = media.get("title_font")
	if _root == null:
		return
	_bg.color = _tokens["menu.scrim"]
	_title.add_theme_color_override("font_color", _tokens["theme.text"])
	_subtitle.add_theme_color_override("font_color", _tokens["theme.dim"])
	_pads.add_theme_color_override("font_color", _tokens["theme.dim"])
	_apply_font_override(_title, _title_font)
	_apply_font_override(_subtitle, _font)
	_apply_font_override(_pads, _font)
	for label in _rows:
		_apply_font_override(label, _font)
	_style_panel()
	_refresh()


# ---------------------------------------------------------------- lifecycle

func open() -> void:
	slots = []
	for i in SLOT_ROWS:
		slots.append({})
	_claim_slot = -1
	_armed_remove = -1
	_selected = 0
	_nav.reset()
	_refresh()
	visible = true
	_restart_claim()


func close() -> void:
	visible = false
	if _claim != null:
		_claim.stop()
	_nav.reset()


func is_open() -> bool:
	return visible


func refresh() -> void:
	## Rebuild after a slot joined/left while the lobby stays open.
	if not visible:
		return
	_refresh()


func joined_count() -> int:
	var count := 0
	for slot in slots:
		if not slot.is_empty() and not String(slot.get("profile_id", "")).is_empty():
			count += 1
	return count


func cancel_pending_claim() -> void:
	## The profile picker for a claimed slot was cancelled: free the slot so
	## its pad can be claimed again.
	var changed := false
	for i in slots.size():
		var slot: Dictionary = slots[i]
		if not slot.is_empty() and String(slot.get("profile_id", "")).is_empty():
			slots[i] = {}
			changed = true
	_claim_slot = -1
	if changed:
		_refresh()
	_restart_claim()


func resume_claims() -> void:
	## The profile picker for a slot just closed (join or cancel): claims
	## resume for the remaining free slots with fresh exclusions.
	_restart_claim()


func _taken_profile_ids(except_slot: int) -> Array:
	var taken: Array = []
	for i in slots.size():
		if i == except_slot:
			continue
		var slot: Dictionary = slots[i]
		if not slot.is_empty() and not String(slot.get("profile_id", "")).is_empty():
			taken.append(slot["profile_id"])
	return taken


func _restart_claim() -> void:
	## Keep the claim tracker running while a free slot exists, excluding
	## every device already assigned to a slot.
	if _claim == null or not visible:
		return
	if _first_free_slot() < 0:
		_claim.stop()
		return
	_claim.start(_claimed_devices())


func _claimed_devices() -> Array:
	var devices: Array = []
	for slot in slots:
		if not slot.is_empty():
			devices.append(int(slot.get("device", -1)))
	return devices


func _first_free_slot() -> int:
	for i in slots.size():
		if slots[i].is_empty():
			return i
	return -1


# ------------------------------------------------------------------ claiming

func _on_pad_claimed(device: int) -> void:
	# Assign the claimed pad to the first free slot; the profile pick stays
	# pending until the button is released.
	var slot := _first_free_slot()
	if slot < 0:
		_pads.text = "All slots full - pad %d ignored" % device
		return
	_claim_slot = slot
	slots[slot] = {"profile_id": "", "device": device, "name": ""}
	if _host != null:
		_host.play_ui_sfx("menu_confirm")
	_pads.text = "Pad %d claimed - release the button to pick a profile" % device
	_refresh()


func _on_pad_released(_device: int) -> void:
	if _claim_slot < 0:
		_restart_claim()
		return
	var slot := _claim_slot
	_claim_slot = -1
	# Stop claiming while a picker is open: a second claim would fight it.
	if _claim != null:
		_claim.stop()
	_refresh()
	if _host != null:
		_host.cmd_lobby_open_profile_picker(slot)


func _on_claim_cancelled() -> void:
	_pads.text = "Claim cancelled"
	_restart_claim()


# ---------------------------------------------------------------- rendering

func min_players_for_mode() -> int:
	## Competitive modes are versus matches: they need at least two joined
	## profiles. Shared-board co-op keeps the one-player team option.
	return 2 if ModeRules.is_competitive(game_mode) else 1


func _refresh() -> void:
	if _rows.is_empty():
		return
	var mode_name: String = ModeRules.mode_display_name(game_mode)
	var show_garbage: bool = game_mode == ModeRules.Mode.CLASSIC_VERSUS
	for i in SLOT_ROWS:
		_rows[i].text = "%s  %s" % [_marker(i), _slot_text(i)]
	_rows[ROW_MODE].text = "%s  MODE:  %s" % [_marker(ROW_MODE), mode_name]
	if show_garbage:
		_rows[ROW_GARBAGE].text = "%s  GARBAGE:  %s" % [_marker(ROW_GARBAGE), "ON" if garbage_on else "OFF"]
	else:
		_rows[ROW_GARBAGE].text = ""
	var ready_to_start: bool = joined_count() >= min_players_for_mode()
	_rows[ROW_START].text = "%s  START RUN" % _marker(ROW_START)
	_rows[ROW_BACK].text = "%s  BACK" % [_marker(ROW_BACK)]
	for i in ROW_COUNT:
		var row_selectable: bool = i != ROW_GARBAGE or show_garbage
		if i == ROW_START:
			row_selectable = ready_to_start
		var color: Color = _tokens["menu.focus"] if i == _selected and row_selectable else _tokens["theme.dim"]
		_rows[i].add_theme_color_override("font_color", color)

	_subtitle.text = "Hold any pad button 2s to join    A / Enter: select    B / Esc: back"

	var info: Array[String] = []
	if _claim != null and _claim.active and _claim_slot < 0:
		var progress: int = int(round(_claim.progress() * 100.0))
		info.append("Claiming a pad: %d%%" % progress)
	var pads_connected: int = Input.get_connected_joypads().size()
	info.append("Pads connected: %d" % pads_connected)
	var conflict := _shared_keyboard_conflict()
	if not conflict.is_empty():
		info.append(conflict)
	if joined_count() == 0:
		info.append("Waiting for players - at least one joined profile starts the run")
	elif joined_count() < min_players_for_mode():
		info.append("%s needs at least two joined profiles" % mode_name)
	_pads.text = "\n".join(info)


## Local co-op configuration warning: profiles sharing any keyboard record
## on one machine both react to the same key (online peers sit behind
## separate machines, so cross-profile duplicates stay valid there).
func _shared_keyboard_conflict() -> String:
	var joined: Array = []
	for slot in slots:
		if not slot.is_empty() and not String(slot.get("profile_id", "")).is_empty():
			joined.append(slot)
	for i in joined.size():
		var mine: Array = _keyboard_records(String(joined[i]["profile_id"]))
		for j in range(i + 1, joined.size()):
			var other: Array = _keyboard_records(String(joined[j]["profile_id"]))
			for record_a in mine:
				for record_b in other:
					if DefaultBindings.record_matches(record_a, record_b):
						return (
							"WARNING: P%d and P%d share a keyboard binding - one key drives both slots"
							% [i + 1, j + 1]
						)
	return ""


func _keyboard_records(profile_id: String) -> Array:
	var bindings: Dictionary = _host.settings.keyboard_bindings_for(profile_id)
	var records: Array = []
	for action in bindings:
		for record in bindings[action]:
			records.append(record)
	return records


func _slot_text(i: int) -> String:
	var slot: Dictionary = slots[i]
	if slot.is_empty():
		return "P%d  - hold a pad button 2s / Enter: keyboard join" % (i + 1)
	var device := int(slot.get("device", -1))
	var source := "PAD %d" % device if device >= 0 else "KEYBOARD"
	if String(slot.get("profile_id", "")).is_empty():
		return "P%d  - PAD %d - release to pick profile" % [i + 1, device]
	var text := "P%d  %s - %s" % [i + 1, String(slot.get("name", "")).to_upper(), source]
	var hint := _binding_hint(slot)
	if not hint.is_empty():
		text += "  -  %s" % hint
	if _armed_remove == i:
		text += "  [A / Enter: REMOVE]"
	return text


## Compact profile-specific controller summary for the lobby display.
func _binding_hint(slot: Dictionary) -> String:
	var profile_id := String(slot.get("profile_id", ""))
	if profile_id.is_empty() or _host == null:
		return ""
	var bindings: Dictionary = _host.settings.controller_bindings_for(profile_id)
	if bindings.is_empty():
		return ""
	var parts: Array[String] = []
	var action_labels := {"hard_drop": "drop", "rotate_cw": "rotate", "hold": "hold"}
	for action in ["hard_drop", "rotate_cw", "hold"]:
		var records: Array = bindings.get(action, [])
		if records.is_empty():
			continue
		parts.append("%s %s" % [action_labels[action], DefaultBindings.record_display_name(records[0]).to_lower()])
	return ", ".join(parts)


func _marker(row: int) -> String:
	return "▸" if row == _selected else " "


# -------------------------------------------------------------------- input

func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	var nav := _nav.classify(event)
	if _is_accept(event) or nav == UiNavigation.DIR_ACCEPT:
		get_viewport().set_input_as_handled()
		_activate()
	elif event.is_action_pressed("ui_up") or nav == UiNavigation.DIR_UP:
		get_viewport().set_input_as_handled()
		_move(-1)
	elif event.is_action_pressed("ui_down") or nav == UiNavigation.DIR_DOWN:
		get_viewport().set_input_as_handled()
		_move(1)
	elif event.is_action_pressed("ui_left") or nav == UiNavigation.DIR_LEFT:
		get_viewport().set_input_as_handled()
		_adjust(-1)
	elif event.is_action_pressed("ui_right") or nav == UiNavigation.DIR_RIGHT:
		get_viewport().set_input_as_handled()
		_adjust(1)
	elif event.is_action_pressed("ui_cancel") or nav == UiNavigation.DIR_BACK:
		get_viewport().set_input_as_handled()
		_back()


static func _is_accept(event: InputEvent) -> bool:
	# Space is a hard-drop gameplay key, not a menu confirm.
	if event.is_action_pressed("ui_accept"):
		if event is InputEventKey and (event as InputEventKey).physical_keycode == KEY_SPACE:
			return false
		return true
	return false


func _move(delta: int) -> void:
	var next := _selected
	for i in ROW_COUNT:
		next = wrapi(next + delta, 0, ROW_COUNT)
		if _row_selectable(next):
			break
	_selected = next
	if _armed_remove != _selected:
		_armed_remove = -1
	_play_nav_sfx("menu_move")
	_refresh()


func _row_selectable(row: int) -> bool:
	if row == ROW_START:
		return joined_count() >= min_players_for_mode()
	if row == ROW_GARBAGE:
		return game_mode == ModeRules.Mode.CLASSIC_VERSUS
	return true


func _activate() -> void:
	match _selected:
		ROW_MODE:
			_adjust_mode(1)
		ROW_GARBAGE:
			if game_mode == ModeRules.Mode.CLASSIC_VERSUS:
				garbage_on = not garbage_on
				_play_nav_sfx("menu_move")
				_refresh()
		ROW_START:
			if joined_count() >= min_players_for_mode():
				_play_nav_sfx("menu_confirm")
				_host.cmd_start_coop(_assignments(), game_mode, garbage_on)
			else:
				_pads.text = (
					"At least two joined profiles are required"
					if ModeRules.is_competitive(game_mode)
					else "At least one joined profile is required"
				)
		ROW_BACK:
			_back()
		_:
			if _selected < SLOT_ROWS:
				var slot: Dictionary = slots[_selected]
				if slot.is_empty():
					# Keyboard join: pick a profile for this slot without a pad.
					_play_nav_sfx("menu_confirm")
					if _claim != null:
						_claim.stop()
					_host.cmd_lobby_open_profile_picker(_selected)
				elif String(slot.get("profile_id", "")).is_empty():
					_pads.text = "Release the claimed pad button first"
				elif _armed_remove == _selected:
					_remove_slot(_selected)
				else:
					_armed_remove = _selected
					_pads.text = "Press A / Enter again to remove %s" % String(slot.get("name", ""))
					_refresh()


func _remove_slot(index: int) -> void:
	var slot: Dictionary = slots[index]
	var device := int(slot.get("device", -1))
	slots[index] = {}
	_armed_remove = -1
	_play_nav_sfx("menu_back")
	_pads.text = "Removed %s (pad %d free again)" % [String(slot.get("name", "player")), device]
	_refresh()
	_restart_claim()


func _adjust(delta: int) -> void:
	if _selected == ROW_MODE:
		_adjust_mode(delta)
	elif _selected == ROW_GARBAGE and game_mode == ModeRules.Mode.CLASSIC_VERSUS:
		garbage_on = delta > 0
		_play_nav_sfx("menu_move")
		_refresh()


func _adjust_mode(delta: int) -> void:
	var idx: int = MODE_CYCLE.find(game_mode)
	if idx < 0:
		idx = 0
	idx = wrapi(idx + (1 if delta >= 0 else -1), 0, MODE_CYCLE.size())
	game_mode = int(MODE_CYCLE[idx])
	_refresh()
	_play_nav_sfx("menu_move")


func _back() -> void:
	_play_nav_sfx("menu_back")
	_host.cmd_coop_setup_back()


func _assignments() -> Array:
	## Ordered profile/device pairs for the host; only joined slots, in
	## slot order, so player indexes stay compact.
	var out: Array = []
	for slot in slots:
		if not slot.is_empty() and not String(slot.get("profile_id", "")).is_empty():
			out.append({
				"profile_id": slot["profile_id"],
				"device": int(slot.get("device", -1)),
			})
	return out


func _play_nav_sfx(name: String) -> void:
	if _host != null:
		_host.play_ui_sfx(name)
