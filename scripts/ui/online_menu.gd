extends CanvasLayer
## Code-built online room screens (entry / join-by-code / lobby).
## Pure UI: every mutation flows through GameHost cmd_* commands, which
## delegate to the OnlineService autoload; this layer only reads service
## state and service signals for display. Controller navigation matches
## the other menu screens (ui_navigation classification); the room-code
## row uses a real LineEdit because typed input beats an on-screen
## keyboard for short codes. The service's state_changed signal drives
## screen transitions when create/join completes.

const ThemeProfile = preload("res://scripts/ui/theme_profile.gd")
const UiNavigation = preload("res://scripts/ui/ui_navigation.gd")

const ModeRules = preload("res://scripts/core/mode_rules.gd")

enum ScreenMode { CLOSED, ENTRY, CODE, LOBBY }

const MAX_ROSTER_ROWS: int = 4
const ROW_CORNER_RADIUS: int = 8
const ROW_PAD_X: float = 18.0
const ROW_PAD_Y: float = 6.0

var _host: Node = null
var _service: Node = null

var _root: Control = null
var _bg: ColorRect = null
var _panel: PanelContainer = null
var _title: Label = null
var _status: Label = null
var _detail: Label = null
var _items_box: VBoxContainer = null
var _roster_box: VBoxContainer = null
var _roster_labels: Array[Label] = []
var _code_edit: LineEdit = null

var _mode: int = ScreenMode.CLOSED
var _items: Array = []  # {"label": String, "callback": Callable}
var _labels: Array[Label] = []
var _rows: Array[PanelContainer] = []
var _row_styles: Array[StyleBoxFlat] = []
var _selected: int = 0
var _last_service_state: int = -1
# Item-structure key (mode, role, garbage): rebuilding on every roster
# twitch would reset the selection, so the list only rebuilds when the
# lobby's visible rows actually change.
var _lobby_structure: String = ""
var _nav: UiNavigation = UiNavigation.new()
var _tokens: Dictionary = ThemeProfile.default_tokens()
var _font: Font = null
var _title_font: Font = null


func _ready() -> void:
	layer = 12
	visible = false
	_build()


func setup(host: Node) -> void:
	_host = host
	if host != null:
		_service = host.online_service()
	if _service != null:
		_service.status_changed.connect(_on_status_changed)
		_service.lobby_changed.connect(_on_lobby_changed)
		_service.state_changed.connect(_on_state_changed)


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
	box.add_theme_constant_override("separation", 10)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_child(box)

	_title = Label.new()
	_title.add_theme_font_size_override("font_size", _tokens["menu.title_size"])
	_title.add_theme_color_override("font_color", _tokens["theme.text"])
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_apply_font_override(_title, _title_font)
	box.add_child(_title)

	_status = Label.new()
	_status.add_theme_font_size_override("font_size", _tokens["menu.detail_size"])
	_status.add_theme_color_override("font_color", _tokens["theme.dim"])
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_apply_font_override(_status, _font)
	box.add_child(_status)

	_detail = Label.new()
	_detail.add_theme_font_size_override("font_size", _tokens["menu.detail_size"])
	_detail.add_theme_color_override("font_color", _tokens["theme.dim"])
	_detail.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_apply_font_override(_detail, _font)
	box.add_child(_detail)

	_roster_box = VBoxContainer.new()
	_roster_box.add_theme_constant_override("separation", 2)
	_roster_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(_roster_box)
	for i in MAX_ROSTER_ROWS:
		var row := Label.new()
		row.add_theme_font_size_override("font_size", _tokens["menu.detail_size"])
		row.add_theme_color_override("font_color", _tokens["theme.dim"])
		row.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.visible = false
		_apply_font_override(row, _font)
		_roster_box.add_child(row)
		_roster_labels.append(row)

	_items_box = VBoxContainer.new()
	_items_box.add_theme_constant_override("separation", _tokens["menu.spacing"])
	_items_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(_items_box)

	_code_edit = LineEdit.new()
	_code_edit.placeholder_text = "ROOM CODE"
	_code_edit.alignment = HORIZONTAL_ALIGNMENT_CENTER
	_code_edit.max_length = 16
	_code_edit.custom_minimum_size = Vector2(420.0, 0.0)
	_code_edit.visible = false
	_code_edit.text_submitted.connect(_on_code_submitted)
	box.add_child(_code_edit)

	_style_panel()
	_style_code_edit()


func _style_panel() -> void:
	if _panel == null:
		return
	var style := StyleBoxFlat.new()
	style.bg_color = _tokens["menu.panel"]
	style.set_corner_radius_all(12)
	style.set_border_width_all(1)
	style.border_color = _tokens["menu.divider"]
	style.content_margin_left = 36.0
	style.content_margin_right = 36.0
	style.content_margin_top = 24.0
	style.content_margin_bottom = 24.0
	_panel.add_theme_stylebox_override("panel", style)


func _style_code_edit() -> void:
	if _code_edit == null:
		return
	var normal := StyleBoxFlat.new()
	normal.bg_color = _tokens["menu.panel"]
	normal.border_color = _tokens["menu.divider"]
	normal.set_border_width_all(1)
	normal.set_corner_radius_all(ROW_CORNER_RADIUS)
	normal.content_margin_left = ROW_PAD_X
	normal.content_margin_right = ROW_PAD_X
	normal.content_margin_top = ROW_PAD_Y
	normal.content_margin_bottom = ROW_PAD_Y
	var focus: StyleBoxFlat = normal.duplicate()
	focus.border_color = _tokens["menu.focus"]
	focus.set_border_width_all(2)
	_code_edit.add_theme_stylebox_override("normal", normal)
	_code_edit.add_theme_stylebox_override("focus", focus)
	_code_edit.add_theme_stylebox_override("read_only", normal.duplicate())
	_code_edit.add_theme_color_override("font_color", _tokens["theme.text"])
	_code_edit.add_theme_color_override("font_placeholder_color", _tokens["theme.dim"])
	_code_edit.add_theme_color_override("caret_color", _tokens["menu.focus"])
	var selection: Color = _tokens["theme.accent"]
	selection.a = 0.35
	_code_edit.add_theme_color_override("selection_color", selection)
	_code_edit.add_theme_font_size_override("font_size", _tokens["menu.item_size"])
	_apply_font_override(_code_edit, _font)


func apply_theme(tokens: Dictionary, media: Dictionary) -> void:
	_tokens = tokens
	_font = media.get("font")
	_title_font = media.get("title_font")
	if _root == null:
		return
	_bg.color = _tokens["menu.scrim"]
	_title.add_theme_font_size_override("font_size", _tokens["menu.title_size"])
	_title.add_theme_color_override("font_color", _tokens["theme.text"])
	_status.add_theme_font_size_override("font_size", _tokens["menu.detail_size"])
	_status.add_theme_color_override("font_color", _tokens["theme.dim"])
	_detail.add_theme_font_size_override("font_size", _tokens["menu.detail_size"])
	_detail.add_theme_color_override("font_color", _tokens["theme.dim"])
	_apply_font_override(_title, _title_font)
	_apply_font_override(_status, _font)
	_apply_font_override(_detail, _font)
	for label in _roster_labels:
		label.add_theme_font_size_override("font_size", _tokens["menu.detail_size"])
		label.add_theme_color_override("font_color", _tokens["theme.dim"])
		_apply_font_override(label, _font)
	_items_box.add_theme_constant_override("separation", _tokens["menu.spacing"])
	_style_panel()
	_style_code_edit()
	_rebuild_items()


static func _apply_font_override(control: Control, font: Font) -> void:
	if font == null:
		control.remove_theme_font_override("font")
	else:
		control.add_theme_font_override("font", font)


# ------------------------------------------------------------------- screens

func open_entry() -> void:
	_mode = ScreenMode.ENTRY
	_title.text = "ONLINE MULTIPLAYER"
	_detail.text = "Relay-backed online multiplayer\nCreate a room and share its code, or join with a code"
	_code_edit.visible = false
	_code_edit.text = ""
	_set_items(_entry_items())
	visible = true
	refresh_status()


func open_lobby() -> void:
	_mode = ScreenMode.LOBBY
	_title.text = "ONLINE MULTIPLAYER LOBBY"
	_code_edit.visible = false
	_code_edit.text = ""
	_lobby_structure = ""
	_set_items(_lobby_items())
	_lobby_structure = _structure_key()
	visible = true
	refresh_status()
	_refresh_roster()


func _structure_key() -> String:
	if _service == null:
		return ""
	return "%d|%s|%s" % [int(_service.lobby_mode), bool(_service.is_host), bool(_service.lobby_garbage)]


func open_code() -> void:
	_mode = ScreenMode.CODE
	_title.text = "JOIN ROOM"
	_detail.text = "Type the room code and press Enter (Esc to cancel)"
	_code_edit.visible = true
	_code_edit.text = ""
	_set_items([])
	_code_edit.grab_focus()
	visible = true
	refresh_status()


func close() -> void:
	visible = false
	_mode = ScreenMode.CLOSED
	_items = []
	_labels = []
	_rows = []
	_row_styles = []
	_nav.reset()


func is_open() -> bool:
	return visible


func refresh_status() -> void:
	if _service == null:
		_status.text = "Online unavailable"
		return
	_status.text = String(_service.status_text)
	_refresh_roster()


# ------------------------------------------------------------------- items

func _entry_items() -> Array:
	var items: Array = []
	items.append(_item("CREATE ROOM", Callable(_host, "cmd_online_create")))
	items.append(_item("JOIN ROOM", Callable(_host, "cmd_online_join_code_open")))
	items.append(_item("BACK", Callable(_host, "cmd_online_back")))
	return items


func _lobby_items() -> Array:
	var items: Array = []
	if _service == null:
		return items
	var is_host: bool = bool(_service.is_host)
	var mode: int = int(_service.lobby_mode)
	if is_host:
		items.append(_item("MODE: %s" % _mode_label(mode), Callable(_host, "cmd_online_mode_next")))
	else:
		items.append(_item("MODE: %s  (HOST SETS)" % _mode_label(mode), Callable()))
	if mode == ModeRules.Mode.CLASSIC_VERSUS:
		# The garbage switch is a Versus-only host decision.
		if is_host:
			items.append(_item("GARBAGE: %s" % ("ON" if bool(_service.lobby_garbage) else "OFF"), Callable(_host, "cmd_online_toggle_garbage")))
		else:
			items.append(_item("GARBAGE: %s  (HOST SETS)" % ("ON" if bool(_service.lobby_garbage) else "OFF"), Callable()))
	if not is_host:
		# Clients toggle their own ready flag; the host is implicitly ready.
		items.append(_item("TOGGLE READY", Callable(_host, "cmd_online_toggle_ready")))
	items.append(_item("LEAVE", Callable(_host, "cmd_online_leave")))
	if is_host:
		items.append(_item("START ROUND", Callable(_host, "cmd_online_start_round")))
	return items


func _mode_label(mode: int) -> String:
	match mode:
		ModeRules.Mode.MARATHON: return "MARATHON"
		ModeRules.Mode.SPRINT: return "40-LINE SPRINT"
		ModeRules.Mode.CLASSIC_VERSUS: return "CLASSIC VERSUS"
		ModeRules.Mode.TOWER: return "TOWER"
		_: return "MODE %d" % mode


static func _item(label: String, callback: Callable) -> Dictionary:
	return {"label": label, "callback": callback}


# ------------------------------------------------------------------- render

func _set_items(items: Array) -> void:
	_items = items
	_selected = 0
	_nav.reset()
	_rebuild_items()


func _rebuild_items() -> void:
	if _items_box == null:
		return
	for child in _items_box.get_children():
		_items_box.remove_child(child)
		child.queue_free()
	_labels = []
	_rows = []
	_row_styles = []
	for item in _items:
		var style := StyleBoxFlat.new()
		style.bg_color = Color(0.0, 0.0, 0.0, 0.0)
		style.set_corner_radius_all(ROW_CORNER_RADIUS)
		style.content_margin_left = ROW_PAD_X
		style.content_margin_right = ROW_PAD_X
		style.content_margin_top = ROW_PAD_Y
		style.content_margin_bottom = ROW_PAD_Y
		var row := PanelContainer.new()
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_theme_stylebox_override("panel", style)
		var label := Label.new()
		label.add_theme_font_size_override("font_size", _tokens["menu.item_size"])
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_apply_font_override(label, _font)
		row.add_child(label)
		_items_box.add_child(row)
		_rows.append(row)
		_row_styles.append(style)
		_labels.append(label)
	_refresh_labels()


func _refresh_labels() -> void:
	for i in _labels.size():
		var selected: bool = i == _selected
		_labels[i].text = String(_items[i]["label"])
		_labels[i].add_theme_color_override("font_color", _tokens["menu.focus"] if selected else _tokens["theme.dim"])
	for i in _row_styles.size():
		var style: StyleBoxFlat = _row_styles[i]
		if i == _selected:
			style.bg_color = _tokens["menu.panel"]
			style.border_color = _tokens["menu.divider"]
			style.set_border_width_all(1)
		else:
			style.bg_color = Color(0.0, 0.0, 0.0, 0.0)
			style.set_border_width_all(0)


func _refresh_roster() -> void:
	# Roster rows only show on the lobby screen.
	var show_roster: bool = _mode == ScreenMode.LOBBY and _service != null
	var roster: Array = _service.roster if _service != null else []
	for i in MAX_ROSTER_ROWS:
		if not show_roster or i >= roster.size():
			_roster_labels[i].visible = false
			continue
		var entry: Dictionary = roster[i]
		var ready_tag := "READY" if bool(entry.get("ready", false)) else "..."
		_roster_labels[i].text = "P%d  %s  [%s]" % [int(entry.get("slot", i)) + 1, String(entry.get("name", "?")), ready_tag]
		_roster_labels[i].visible = true
	if show_roster:
		_refresh_lobby_detail()


func _refresh_lobby_detail() -> void:
	# The relay gives every peer the canonical code, so any lobby member can
	# invite another player even when the host is not the one sharing it.
	var code := String(_service.session_code())
	if code.is_empty():
		_detail.text = "WAITING FOR THE ROOM CODE"
	elif bool(_service.is_host):
		_detail.text = "ROOM CODE: %s\nShare it - players join with JOIN ROOM" % code
	else:
		_detail.text = "ROOM CODE: %s\nShare it - waiting for the host to start" % code


func _process(_delta: float) -> void:
	# Poll-driven display: service status, roster, and mode stay live without
	# this screen owning any state.
	if not visible or _service == null:
		return
	_status.text = String(_service.status_text)
	if _mode == ScreenMode.LOBBY:
		_refresh_roster()
		# Ready toggles and peer changes mutate labels only; item structure
		# is stable while the lobby screen is open.
		if bool(_service.is_host) and _items.size() > 0:
			var mode_idx := 0
			for i in _items.size():
				if String(_items[i]["label"]).begins_with("MODE:"):
					mode_idx = i
					break
			_items[mode_idx]["label"] = "MODE: %s" % _mode_label(int(_service.lobby_mode))
			_refresh_labels()


# ------------------------------------------------------------------ signals

func _on_status_changed(text: String) -> void:
	_status.text = text
	_refresh_roster()


func _on_lobby_changed() -> void:
	if _mode == ScreenMode.LOBBY:
		_refresh_roster()
		if _structure_key() != _lobby_structure:
			_lobby_structure = _structure_key()
			_set_items(_lobby_items())


func _on_state_changed() -> void:
	## Screen transitions driven by the service: create/join completion
	## swaps the entry/code screens for the lobby. Round-end LOBBY
	## transitions are excluded - each peer's results overlay owns that flow
	## until that player returns to the lobby.
	if _service == null:
		return
	var current: int = int(_service.state)
	if current == _service.State.LOBBY and _last_service_state in [
		_service.State.CREATING_LOBBY,
		_service.State.JOINING,
		_service.State.CONNECTING,
	]:
		open_lobby()
	_last_service_state = current


func _on_code_submitted(text: String) -> void:
	if _host == null:
		return
	_host.cmd_online_join_code(text)


# -------------------------------------------------------------------- input

func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if _mode == ScreenMode.CODE:
		if event.is_action_pressed("ui_cancel"):
			_input_back_from_code()
			get_viewport().set_input_as_handled()
		return
	if _items.is_empty():
		return
	var nav := _nav.classify(event)
	if event.is_action_pressed("ui_accept") or nav == UiNavigation.DIR_ACCEPT:
		_activate()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("ui_up") or nav == UiNavigation.DIR_UP:
		_move(-1)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("ui_down") or nav == UiNavigation.DIR_DOWN:
		_move(1)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("ui_cancel") or nav == UiNavigation.DIR_BACK:
		_back()
		get_viewport().set_input_as_handled()


func _input_back_from_code() -> void:
	_code_edit.visible = false
	_code_edit.release_focus()
	open_entry()


func _move(delta: int) -> void:
	if _items.is_empty():
		return
	_selected = wrapi(_selected + delta, 0, _items.size())
	_refresh_labels()
	if _host != null:
		_host.play_ui_sfx("menu_move")


func _activate() -> void:
	if _selected < 0 or _selected >= _items.size():
		return
	if _host != null:
		_host.play_ui_sfx("menu_confirm")
	var callback: Callable = _items[_selected]["callback"]
	if callback.is_valid():
		callback.call()


func _back() -> void:
	match _mode:
		ScreenMode.ENTRY:
			if _host != null:
				_host.cmd_online_back()
		ScreenMode.LOBBY:
			# Lobby back leaves the session deliberately (explicit action).
			if _host != null:
				_host.cmd_online_leave()
		_:
			open_entry()
