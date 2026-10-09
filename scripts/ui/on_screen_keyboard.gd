extends CanvasLayer
## Focused name-entry layer: a controller-navigable grid of allowed
## characters with DEL / OK / CANCEL controls, plus direct physical
## keyboard typing. While open it consumes all key and controller UI
## navigation input so nothing beneath reacts. Duplicate and blank names
## are validated against the host's profile list before committing; the
## host routes the committed name by the flow that opened the keyboard.

signal name_committed(name: String)
signal entry_cancelled()

const ThemeProfile = preload("res://scripts/ui/theme_profile.gd")
const UiNavigation = preload("res://scripts/ui/ui_navigation.gd")

const MAX_NAME_LENGTH := 16

## Character grid (6 columns) followed by the control row.
const CHAR_ROWS := [
	["A", "B", "C", "D", "E", "F"],
	["G", "H", "I", "J", "K", "L"],
	["M", "N", "O", "P", "Q", "R"],
	["S", "T", "U", "V", "W", "X"],
	["Y", "Z", "0", "1", "2", "3"],
	["4", "5", "6", "7", "8", "9"],
	["_", "-", ".", "!", "?", " "],
]
const CONTROL_LABELS := ["DEL", "OK", "CANCEL"]
const CONTROL_KINDS := ["del", "ok", "cancel"]

var _host: Node = null
var _root: Control = null
var _bg: ColorRect = null
var _panel: PanelContainer = null
var _title: Label = null
var _preview: Label = null
var _status: Label = null
var _grid: GridContainer = null
var _cells: Array = []  # {"kind": "char"|"del"|"ok"|"cancel", "label": String}
var _cell_labels: Array[Label] = []
var _nav: UiNavigation = UiNavigation.new()
var _tokens: Dictionary = ThemeProfile.default_tokens()
var _font: Font = null
var _title_font: Font = null

var _text: String = ""
var _cursor: int = 0
var _exclude_profile_id: String = ""


func _ready() -> void:
	layer = 40
	visible = false
	_build()


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
	box.add_theme_constant_override("separation", 10)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_child(box)

	_title = Label.new()
	_title.add_theme_font_size_override("font_size", 30)
	_title.add_theme_color_override("font_color", _tokens["theme.text"])
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_apply_font_override(_title, _title_font)
	box.add_child(_title)

	_preview = Label.new()
	_preview.add_theme_font_size_override("font_size", 24)
	_preview.add_theme_color_override("font_color", _tokens["theme.accent"])
	_preview.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_preview.custom_minimum_size = Vector2(420.0, 0.0)
	_apply_font_override(_preview, _font)
	box.add_child(_preview)

	_grid = GridContainer.new()
	_grid.columns = 6
	_grid.add_theme_constant_override("h_separation", 8)
	_grid.add_theme_constant_override("v_separation", 6)
	_grid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(_grid)

	_status = Label.new()
	_status.add_theme_font_size_override("font_size", 16)
	_status.add_theme_color_override("font_color", _tokens["theme.dim"])
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_apply_font_override(_status, _font)
	box.add_child(_status)

	_build_cells()
	_style_panel()


func _build_cells() -> void:
	for row in CHAR_ROWS:
		for letter in row:
			_cells.append({"kind": "char", "label": letter})
	for i in CONTROL_LABELS.size():
		_cells.append({"kind": CONTROL_KINDS[i], "label": CONTROL_LABELS[i]})
	for cell in _cells:
		var label := Label.new()
		label.text = cell["label"]
		label.add_theme_font_size_override("font_size", 22)
		label.custom_minimum_size = Vector2(64.0, 34.0)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_apply_font_override(label, _font)
		_grid.add_child(label)
		_cell_labels.append(label)


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
	_preview.add_theme_color_override("font_color", _tokens["theme.accent"])
	_status.add_theme_color_override("font_color", _tokens["theme.dim"])
	_apply_font_override(_title, _title_font)
	_apply_font_override(_preview, _font)
	_apply_font_override(_status, _font)
	for label in _cell_labels:
		_apply_font_override(label, _font)
	_style_panel()
	_refresh()


# ---------------------------------------------------------------- lifecycle

func open(initial_text: String, title: String, exclude_profile_id: String = "") -> void:
	_text = initial_text
	_exclude_profile_id = exclude_profile_id
	_cursor = 0
	_title.text = title
	_status.text = "D-pad / Arrows: move    A / Enter: pick    B / Esc: cancel    type to add"
	_nav.reset()
	_refresh()
	visible = true


func close() -> void:
	visible = false
	_nav.reset()


func is_open() -> bool:
	return visible


# ------------------------------------------------------------------ grid math

func _row_count() -> int:
	return CHAR_ROWS.size() + 1  # char rows + control row


func _row_width(row: int) -> int:
	if row < CHAR_ROWS.size():
		return 6
	return CONTROL_LABELS.size()


func _row_of(index: int) -> int:
	if index < CHAR_ROWS.size() * 6:
		return index / 6
	return CHAR_ROWS.size()


func _index_at(row: int, col: int) -> int:
	return row * 6 + col


func _move_cursor(delta_row: int, delta_col: int) -> void:
	var row := _row_of(_cursor)
	var col := _cursor - _index_at(row, 0)
	if delta_col != 0:
		col = clampi(col + delta_col, 0, _row_width(row) - 1)
		_cursor = _index_at(row, col)
		_refresh()
	else:
		var target_row := clampi(row + delta_row, 0, _row_count() - 1)
		var target_col := mini(col, _row_width(target_row) - 1)
		_cursor = _index_at(target_row, target_col)
	_refresh()


# -------------------------------------------------------------------- input

func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventKey:
		# The keyboard layer owns all key input while open.
		get_viewport().set_input_as_handled()
		var k := event as InputEventKey
		if not k.pressed or k.is_echo():
			return
		match k.physical_keycode:
			KEY_BACKSPACE:
				_delete_char()
			KEY_ENTER, KEY_KP_ENTER:
				_confirm()
			KEY_ESCAPE:
				_cancel()
			_:
				var typed := char(k.unicode)
				if k.unicode >= 32 and not typed.is_empty():
					_type_char(typed)
		return
	var nav := _nav.classify(event)
	if nav == "":
		return
	get_viewport().set_input_as_handled()
	match nav:
		UiNavigation.DIR_UP:
			_move_cursor(-1, 0)
		UiNavigation.DIR_DOWN:
			_move_cursor(1, 0)
		UiNavigation.DIR_LEFT:
			_move_cursor(0, -1)
		UiNavigation.DIR_RIGHT:
			_move_cursor(0, 1)
		UiNavigation.DIR_ACCEPT:
			_activate_cell()
		UiNavigation.DIR_BACK:
			_cancel()


func _activate_cell() -> void:
	var cell: Dictionary = _cells[_cursor]
	match cell["kind"]:
		"char":
			_type_char(cell["label"])
		"del":
			_delete_char()
		"ok":
			_confirm()
		"cancel":
			_cancel()


func _type_char(letter: String) -> void:
	if _text.length() >= MAX_NAME_LENGTH:
		_status.text = "Name too long (max %d characters)" % MAX_NAME_LENGTH
		_refresh()
		return
	_text += letter
	_status.text = ""
	_refresh()


func _delete_char() -> void:
	if _text.is_empty():
		return
	_text = _text.substr(0, _text.length() - 1)
	_status.text = ""
	_refresh()


func _confirm() -> void:
	var candidate := _text.strip_edges()
	if candidate.is_empty():
		_status.text = "Name cannot be empty"
		_refresh()
		return
	if _host != null and _host.profile_name_taken(candidate, _exclude_profile_id):
		_status.text = "That name is already in use"
		_refresh()
		return
	close()
	name_committed.emit(candidate)


func _cancel() -> void:
	close()
	entry_cancelled.emit()


# ------------------------------------------------------------------ rendering

func _refresh() -> void:
	if _root == null:
		return
	_preview.text = _text if not _text.is_empty() else "_"
	for i in _cell_labels.size():
		var selected: bool = i == _cursor
		var is_control: bool = _row_of(i) >= CHAR_ROWS.size()
		var color: Color
		if selected:
			color = _tokens["menu.focus"]
		elif is_control:
			color = _tokens["theme.text"]
		else:
			color = _tokens["theme.dim"]
		_cell_labels[i].add_theme_color_override("font_color", color)
		var label: String = _cells[i]["label"]
		if _cells[i]["kind"] == "char" and label == " ":
			label = "SPC"
		_cell_labels[i].text = ("▸" if selected else " ") + label + ("◂" if selected else "")
