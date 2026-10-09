extends CanvasLayer
## Code-built menu screen engine shared by the main menu, pause menu, and
## result overlays: title, subtitle, and a vertically navigated item list.
## Selection moves with ui_up/ui_down plus the controller D-pad/left stick
## and activates on Enter or controller A; ui_cancel or controller B
## triggers the screen's back behavior when provided. Controller UI input
## is classified from raw events (ui_navigation.gd) so remapping gameplay
## buttons never strands a player in a menu. All visual values come from
## the resolved theme tokens.

const ThemeProfile = preload("res://scripts/ui/theme_profile.gd")
const UiNavigation = preload("res://scripts/ui/ui_navigation.gd")

var _host: Node = null
var _root: Control = null
var _bg: ColorRect = null
var _panel: PanelContainer = null
var _title: Label = null
var _subtitle: Label = null
var _detail: Label = null
var _items_box: VBoxContainer = null
var _split: HBoxContainer = null
var _right: VBoxContainer = null
var _items: Array = []
var _labels: Array[Label] = []
var _selected: int = 0
var _back: Callable = Callable()
var _nav: UiNavigation = UiNavigation.new()
var _tokens: Dictionary = ThemeProfile.default_tokens()
# Theme fonts: body for items/subtitle/detail, title for the heading;
# applied to freshly built labels too (items rebuild on every open).
var _font: Font = null
var _title_font: Font = null


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

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(center)

	_panel = PanelContainer.new()
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.add_child(_panel)

	_split = HBoxContainer.new()
	_split.add_theme_constant_override("separation", _tokens["menu.split_gap"])
	_split.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_child(_split)

	var left := VBoxContainer.new()
	left.custom_minimum_size.x = 360.0
	left.add_theme_constant_override("separation", _tokens["menu.spacing"])
	left.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_split.add_child(left)

	_title = Label.new()
	_title.add_theme_font_size_override("font_size", _tokens["menu.title_size"])
	_title.add_theme_color_override("font_color", _tokens["theme.text"])
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_apply_font_override(_title, _title_font)
	left.add_child(_title)

	_subtitle = Label.new()
	_subtitle.add_theme_font_size_override("font_size", 20)
	_subtitle.add_theme_color_override("font_color", _tokens["theme.dim"])
	_subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_apply_font_override(_subtitle, _font)
	left.add_child(_subtitle)

	_detail = Label.new()
	_detail.text = "LOCAL PLAY\nARCADE MODES\n\nSELECT A MODE TO BEGIN"
	_detail.add_theme_font_size_override("font_size", _tokens["menu.detail_size"])
	_detail.add_theme_color_override("font_color", _tokens["theme.dim"])
	_detail.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_detail.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_detail.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_apply_font_override(_detail, _font)
	left.add_child(_detail)

	_right = VBoxContainer.new()
	_right.add_theme_constant_override("separation", _tokens["menu.spacing"])
	_right.custom_minimum_size.x = 340.0
	_right.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_split.add_child(_right)

	_items_box = VBoxContainer.new()
	_items_box.add_theme_constant_override("separation", _tokens["menu.spacing"])
	_items_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_right.add_child(_items_box)

	_style_panel()


func _style_panel() -> void:
	if _panel == null:
		return
	var style := StyleBoxFlat.new()
	style.bg_color = _tokens["menu.panel"]
	style.set_corner_radius_all(12)
	style.set_border_width_all(1)
	style.border_color = _tokens["menu.divider"]
	var margin: int = clampi(int(_tokens["menu.spacing"]), 8, 48)
	style.content_margin_left = _tokens["menu.split_padding"]
	style.content_margin_right = _tokens["menu.split_padding"]
	style.content_margin_top = _tokens["menu.split_padding"]
	style.content_margin_bottom = _tokens["menu.split_padding"]
	_panel.add_theme_stylebox_override("panel", style)


## Push refreshed theme tokens and media from the host; safe before
## _build.
func apply_theme(tokens: Dictionary, media: Dictionary) -> void:
	_tokens = tokens
	_font = media.get("font")
	_title_font = media.get("title_font")
	if _root == null:
		return
	_detail.add_theme_font_size_override("font_size", _tokens["menu.detail_size"])
	_detail.add_theme_color_override("font_color", _tokens["theme.dim"])
	_split.add_theme_constant_override("separation", _tokens["menu.split_gap"])
	_bg.color = _tokens["menu.scrim"]
	_title.add_theme_font_size_override("font_size", _tokens["menu.title_size"])
	_title.add_theme_color_override("font_color", _tokens["theme.text"])
	_subtitle.add_theme_color_override("font_color", _tokens["theme.dim"])
	_items_box.add_theme_constant_override("separation", _tokens["menu.spacing"])
	_apply_font_override(_title, _title_font)
	_apply_font_override(_subtitle, _font)
	_apply_font_override(_detail, _font)
	_style_panel()
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


func close() -> void:
	visible = false
	_items = []
	_labels = []
	_nav.reset()


func show_main_menu(host: Node) -> void:
	_detail.text = "LOCAL PLAY\nARCADE MODES\n\nPROFILE: %s" % host.active_profile_name().to_upper()
	open(
		"TETRIS YANK EDITION",
		"D-pad / Arrows: move    A / Enter: select    B / Esc: back",
		[
			make_item("MARATHON", Callable(host, "cmd_start_marathon")),
			make_item("40-LINE SPRINT", Callable(host, "cmd_start_sprint")),
			make_item("CO-OP", Callable(host, "cmd_open_coop_setup")),
			make_item("ONLINE CO-OP", Callable(host, "cmd_open_online")),
			make_item("PROFILES", Callable(host, "cmd_open_profiles")),
			make_item("SETTINGS", Callable(host, "cmd_open_settings_from_menu")),
			make_item("QUIT", Callable(host, "cmd_quit")),
		]
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


func show_online_results(host: Node, title: String, subtitle: String) -> void:
	## Online result overlays differ from local ones: no local retry (a
	## restart is a host lobby command that would desync peers), and only
	## the host can move everyone back to the lobby.
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
			subtitle + "   [THE HOST RETURNS EVERYONE TO THE LOBBY]",
			[
				make_item("SETTINGS", Callable(host, "cmd_open_settings_from_results")),
			]
		)


func is_open() -> bool:
	return visible


# ------------------------------------------------------------------ rendering

func _rebuild_items() -> void:
	if _items_box == null:
		return
	for child in _items_box.get_children():
		child.queue_free()
	_labels = []
	for item in _items:
		var label := Label.new()
		label.add_theme_font_size_override("font_size", _tokens["menu.item_size"])
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_apply_font_override(label, _font)
		_items_box.add_child(label)
		_labels.append(label)
	_refresh_labels()


func _refresh_labels() -> void:
	for i in _labels.size():
		var selected: bool = i == _selected
		_labels[i].text = ("▸  " if selected else "   ") + String(_items[i]["label"])
		_labels[i].add_theme_color_override("font_color", _tokens["menu.focus"] if selected else _tokens["theme.dim"])


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
