extends CanvasLayer
## Code-built menu screen engine shared by the main menu, solo chooser,
## pause menu, result overlays, and the profile screens: a cinematic
## composition with a restrained top heading region, a lower-center stack
## of full-width item rows where the selected row alone carries the
## theme's panel/divider treatment, and an adjacent detail/status line.
## Selection moves with ui_up/ui_down plus the controller D-pad/left
## stick and activates on Enter or controller A; ui_cancel or controller
## B triggers the screen's back behavior when provided. Controller UI
## input is classified from raw events (ui_navigation.gd) so remapping
## gameplay buttons never strands a player in a menu. All visual values
## come from the resolved theme tokens.

const ThemeProfile = preload("res://scripts/ui/theme_profile.gd")
const UiNavigation = preload("res://scripts/ui/ui_navigation.gd")

# Cinematic composition anchors: the heading region hugs the top, the
# menu block centers on the horizontal axis in the lower-middle band.
# Row padding keeps a constant row height while only the selected row
# gains the panel background and divider border, so selection changes
# never reflow the stack.
const MENU_ANCHOR_Y := 0.58
const HEADER_TOP_MARGIN := 44.0
const HEADER_SEPARATION := 8
const ROW_PAD_X := 18.0
const ROW_PAD_Y := 8.0
const ROW_CORNER_RADIUS := 2
const ROW_PULSE_FROM := 0.35

var _host: Node = null
var _root: Control = null
var _bg: ColorRect = null
var _content: Control = null
var _header: VBoxContainer = null
var _title: Label = null
var _subtitle: Label = null
var _menu_block: VBoxContainer = null
var _items_box: VBoxContainer = null
var _detail: Label = null
var _items: Array = []
var _labels: Array[Label] = []
var _rows: Array[PanelContainer] = []
var _row_styles: Array[StyleBoxFlat] = []
var _selected: int = 0
var _back: Callable = Callable()
var _nav: UiNavigation = UiNavigation.new()
var _tokens: Dictionary = ThemeProfile.default_tokens()
# Theme fonts: body for items/subtitle/detail, title for the heading;
# applied to freshly built labels too (items rebuild on every open).
var _font: Font = null
var _title_font: Font = null
# Presentation-only tweens (screen entrance fade, selected-row pulse).
# Stylebox state itself always applies synchronously so relayouts and
# tests observe the final treatment; both tweens are killed whenever the
# menu closes, rebuilds, or reapplies a theme.
var _content_tween: Tween = null
var _highlight_tween: Tween = null


func _ready() -> void:
	layer = 10
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

	_content = Control.new()
	_content.set_anchors_preset(Control.PRESET_FULL_RECT)
	_content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_content)

	_header = VBoxContainer.new()
	_header.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_header.offset_top = HEADER_TOP_MARGIN
	_header.offset_bottom = HEADER_TOP_MARGIN
	_header.add_theme_constant_override("separation", HEADER_SEPARATION)
	_header.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_content.add_child(_header)

	_title = Label.new()
	_title.add_theme_font_size_override("font_size", _tokens["menu.title_size"])
	_title.add_theme_color_override("font_color", _tokens["theme.text"])
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_apply_font_override(_title, _title_font)
	_header.add_child(_title)

	_subtitle = Label.new()
	_subtitle.add_theme_font_size_override("font_size", _tokens["menu.detail_size"])
	_subtitle.add_theme_color_override("font_color", _tokens["theme.dim"])
	_subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_apply_font_override(_subtitle, _font)
	_header.add_child(_subtitle)

	_menu_block = VBoxContainer.new()
	_menu_block.anchor_left = 0.5
	_menu_block.anchor_right = 0.5
	_menu_block.anchor_top = MENU_ANCHOR_Y
	_menu_block.anchor_bottom = MENU_ANCHOR_Y
	_menu_block.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_menu_block.grow_vertical = Control.GROW_DIRECTION_BOTH
	_menu_block.add_theme_constant_override("separation", clampi(int(_tokens["menu.spacing"]), 8, 24))
	_menu_block.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_content.add_child(_menu_block)

	_items_box = VBoxContainer.new()
	_items_box.add_theme_constant_override("separation", _tokens["menu.spacing"])
	_items_box.custom_minimum_size.x = _row_min_width()
	_items_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_menu_block.add_child(_items_box)

	_detail = Label.new()
	_detail.text = "CHOOSE A CATEGORY\nTO PLAY"
	_detail.add_theme_font_size_override("font_size", _tokens["menu.detail_size"])
	_detail.add_theme_color_override("font_color", _tokens["theme.dim"])
	_detail.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_detail.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_apply_font_override(_detail, _font)
	_menu_block.add_child(_detail)


## Full-width row treatment: wide enough for the longest category labels
## at the theme's item size, clamped for tiny and huge fonts.
func _row_min_width() -> float:
	return clampf(float(_tokens["menu.item_size"]) * 20.0, 480.0, 720.0)


## Push refreshed theme tokens and media from the host; safe before
## _build. The item list and selection survive the rebuild so a live
## theme switch never disturbs navigation.
func apply_theme(tokens: Dictionary, media: Dictionary) -> void:
	_tokens = tokens
	_font = media.get("font")
	_title_font = media.get("title_font")
	if _root == null:
		return
	_bg.color = _tokens["menu.scrim"]
	_title.add_theme_font_size_override("font_size", _tokens["menu.title_size"])
	_title.add_theme_color_override("font_color", _tokens["theme.text"])
	_subtitle.add_theme_font_size_override("font_size", _tokens["menu.detail_size"])
	_subtitle.add_theme_color_override("font_color", _tokens["theme.dim"])
	_detail.add_theme_font_size_override("font_size", _tokens["menu.detail_size"])
	_detail.add_theme_color_override("font_color", _tokens["theme.dim"])
	_items_box.add_theme_constant_override("separation", _tokens["menu.spacing"])
	_items_box.custom_minimum_size.x = _row_min_width()
	_menu_block.add_theme_constant_override("separation", clampi(int(_tokens["menu.spacing"]), 8, 24))
	_apply_font_override(_title, _title_font)
	_apply_font_override(_subtitle, _font)
	_apply_font_override(_detail, _font)
	_rebuild_items()


## Theme font override helper: null clears the override so the built-in
## font applies, non-null replaces it for that label only.
static func _apply_font_override(label: Label, font: Font) -> void:
	if font == null:
		label.remove_theme_font_override("font")
	else:
		label.add_theme_font_override("font", font)


# ------------------------------------------------------------------- opening

func open(title: String, subtitle: String, items: Array, back: Callable = Callable()) -> void:
	_title.text = title
	_subtitle.text = subtitle
	_subtitle.visible = not subtitle.is_empty()
	_items = items
	_back = back
	_selected = 0
	_nav.reset()
	_rebuild_items()
	visible = true
	_fade_content_in()


func close() -> void:
	visible = false
	_items = []
	_labels = []
	_rows = []
	_row_styles = []
	_kill_tweens()
	if _content != null:
		_content.modulate.a = 1.0
	_nav.reset()


func show_main_menu(host: Node) -> void:
	_detail.text = "CHOOSE A CATEGORY TO PLAY\nPROFILE: %s" % host.active_profile_name().to_upper()
	open(
		"TETRIS YANK EDITION",
		"D-pad / Arrows: move    A / Enter: select    B / Esc: back",
		[
			make_item("SOLO", Callable(host, "cmd_open_solo_menu")),
			make_item("LOCAL MULTIPLAYER", Callable(host, "cmd_open_coop_setup")),
			make_item("ONLINE MULTIPLAYER", Callable(host, "cmd_open_online")),
			make_item("PROFILES", Callable(host, "cmd_open_profiles")),
			make_item("SETTINGS", Callable(host, "cmd_open_settings_from_menu")),
			make_item("QUIT", Callable(host, "cmd_quit")),
		]
	)


func show_solo_menu(host: Node) -> void:
	## Solo category submenu: every solo mode still picks a profile first,
	## so each mode opens the existing profile picker.
	_detail.text = "SELECT A MODE"
	open(
		"SOLO",
		"D-pad / Arrows: move    A / Enter: select    B / Esc: back",
		[
			make_item("MARATHON", Callable(host, "cmd_start_marathon")),
			make_item("40-LINE SPRINT", Callable(host, "cmd_start_sprint")),
			make_item("TOWER", Callable(host, "cmd_start_tower")),
			make_item("BACK", Callable(host, "cmd_solo_menu_back")),
		],
		Callable(host, "cmd_solo_menu_back")
	)


func show_results(host: Node, title: String, subtitle: String) -> void:
	open(
		title,
		subtitle,
		[
			make_item("RETRY", Callable(host, "cmd_restart_run")),
			make_item("SETTINGS", Callable(host, "cmd_open_settings_from_results")),
			make_item("MAIN MENU", Callable(host, "cmd_return_to_menu")),
		],
		Callable(host, "cmd_return_to_menu")
	)
	# The subtitle already carries the result line; stale instructional
	# copy from the previous screen must not ride along.
	_detail.text = ""


func show_online_results(host: Node, title: String, subtitle: String) -> void:
	## Online result overlays differ from local ones: no local retry (a
	## restart is a host lobby command that would desync peers). Every peer
	## may close its own result overlay; only the host broadcasts that return.
	if host.online_is_host():
		open(
			title,
			subtitle,
			[
				make_item("RETURN TO LOBBY", Callable(host, "cmd_online_return_to_lobby")),
				make_item("SETTINGS", Callable(host, "cmd_open_settings_from_results")),
			]
		)
	else:
		open(
			title,
			subtitle,
			[
				make_item("RETURN TO LOBBY", Callable(host, "cmd_online_return_to_lobby")),
				make_item("SETTINGS", Callable(host, "cmd_open_settings_from_results")),
			]
		)
	_detail.text = ""


func is_open() -> bool:
	return visible


# ------------------------------------------------------------------ rendering

func _rebuild_items() -> void:
	if _items_box == null:
		return
	_kill_tweens()
	if _content != null:
		# A rebuild can land mid-entrance-fade (live theme switch): the
		# fresh rows are fully styled, so the wrapper must not stay faded.
		_content.modulate.a = 1.0
	for child in _items_box.get_children():
		# Detach before queueing deletion so replaced rows stop counting
		# toward the container's minimum size immediately (queued frees
		# only complete at a frame boundary, which menu churn must not
		# depend on).
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
	_selected = clampi(_selected, 0, maxi(0, _items.size() - 1))
	_refresh_labels()


func _refresh_labels() -> void:
	for i in _labels.size():
		var selected: bool = i == _selected
		_labels[i].text = String(_items[i]["label"])
		_labels[i].add_theme_color_override("font_color", _tokens["menu.focus"] if selected else _tokens["theme.dim"])
	_apply_row_styles()


## The selected row alone carries the panel surface and divider border;
## unselected rows stay transparent so the row, not a dialog, is the
## structural element.
func _apply_row_styles() -> void:
	for i in _row_styles.size():
		var style: StyleBoxFlat = _row_styles[i]
		if i == _selected:
			style.bg_color = _tokens["menu.panel"]
			style.border_color = _tokens["menu.divider"]
			style.set_border_width_all(1)
		else:
			style.bg_color = Color(0.0, 0.0, 0.0, 0.0)
			style.set_border_width_all(0)


# ----------------------------------------------------------------- transitions

## menu.transition is the timing source for the restrained focus and
## entrance animations, mapped into a safe visible duration.
func _transition_duration() -> float:
	var amount: float = clampf(float(_tokens.get("menu.transition", 0.15)), 0.0, 1.0)
	return clampf(0.08 + amount * 0.4, 0.08, 0.45)


func _fade_content_in() -> void:
	if _content == null:
		return
	_kill_content_tween()
	if not is_inside_tree():
		_content.modulate.a = 1.0
		return
	_content.modulate.a = 0.0
	_content_tween = create_tween()
	_content_tween.tween_property(_content, "modulate:a", 1.0, _transition_duration())


func _pulse_selected_row() -> void:
	if _rows.is_empty():
		return
	for row in _rows:
		row.modulate.a = 1.0
	if not is_inside_tree():
		return
	_kill_highlight_tween()
	var row: PanelContainer = _rows[_selected]
	row.modulate.a = ROW_PULSE_FROM
	_highlight_tween = create_tween()
	_highlight_tween.tween_property(row, "modulate:a", 1.0, _transition_duration())


func _kill_tweens() -> void:
	_kill_content_tween()
	_kill_highlight_tween()


func _kill_content_tween() -> void:
	if _content_tween != null and _content_tween.is_valid():
		_content_tween.kill()
	_content_tween = null


func _kill_highlight_tween() -> void:
	if _highlight_tween != null and _highlight_tween.is_valid():
		_highlight_tween.kill()
	_highlight_tween = null


# -------------------------------------------------------------------- input

func _unhandled_input(event: InputEvent) -> void:
	if not visible or _items.is_empty():
		return
	var nav := _nav.classify(event)
	if _is_accept(event) or nav == UiNavigation.DIR_ACCEPT:
		_activate()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("ui_up") or nav == UiNavigation.DIR_UP:
		_move(-1)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("ui_down") or nav == UiNavigation.DIR_DOWN:
		_move(1)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("ui_cancel") or nav == UiNavigation.DIR_BACK:
		if _back.is_valid():
			get_viewport().set_input_as_handled()
			_play_nav_sfx("menu_back")
			var cb := _back
			cb.call()


static func _is_accept(event: InputEvent) -> bool:
	# Space is the hard-drop gameplay key, not a menu confirm.
	if event.is_action_pressed("ui_accept"):
		if event is InputEventKey and (event as InputEventKey).physical_keycode == KEY_SPACE:
			return false
		return true
	return false


func _move(delta: int) -> void:
	_selected = wrapi(_selected + delta, 0, _items.size())
	_refresh_labels()
	_pulse_selected_row()
	_play_nav_sfx("menu_move")


func _activate() -> void:
	if _selected < 0 or _selected >= _items.size():
		return
	_play_nav_sfx("menu_confirm")
	var callback: Callable = _items[_selected]["callback"]
	if callback.is_valid():
		callback.call()


func _play_nav_sfx(name: String) -> void:
	# Menu sounds route through the host so this layer never touches the
	# audio manager directly.
	if _host != null:
		_host.play_ui_sfx(name)


static func make_item(label: String, callback: Callable) -> Dictionary:
	return {"label": label, "callback": callback}
