extends CanvasLayer
## Text HUD and overlay screens. All labels are created in code to keep the
## scene file minimal. Pure view: host pushes state updates. Colors come
## from the resolved theme tokens.

const ThemeProfile = preload("res://scripts/ui/theme_profile.gd")

const MARGIN_X: float = 64.0


var _score_label: Label
var _level_label: Label
var _lines_label: Label
var _time_label: Label
var _event_label: Label
var _combo_label: Label
var _overlay_title: Label
var _overlay_body: Label
var _root: Control
var _stat_titles: Array[Label] = []
var _stat_values: Array[Label] = []
var _tokens: Dictionary = ThemeProfile.default_tokens()
# Theme fonts: body for stats/events, title for overlay headings.
var _font: Font = null
var _title_font: Font = null


func _ready() -> void:
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	_score_label = _stat_pair(Vector2(MARGIN_X, 470.0), "SCORE", true)
	_level_label = _stat_pair(Vector2(MARGIN_X, 540.0), "LEVEL", true)
	_lines_label = _stat_pair(Vector2(MARGIN_X, 610.0), "LINES", true)
	_time_label = _stat_pair(Vector2(1280.0 - MARGIN_X, 610.0), "TIME", false)

	_event_label = _centered_label(110.0, 40.0, 28, _font)
	_combo_label = _centered_label(156.0, 36.0, 22, _font)
	_overlay_title = _centered_label(280.0, 60.0, 44, _title_font)
	_overlay_body = _centered_label(350.0, 180.0, 22, _font)
	_overlay_body.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	hide_overlay()


## Push refreshed theme tokens and media from the host; safe before
## _ready.
func apply_theme(tokens: Dictionary, media: Dictionary) -> void:
	_tokens = tokens
	_font = media.get("font")
	_title_font = media.get("title_font")
	if _root == null:
		return
	var text: Color = _tokens["theme.text"]
	var dim: Color = _tokens["theme.dim"]
	var accent: Color = _tokens["theme.accent"]
	for label in _stat_titles:
		label.add_theme_color_override("font_color", dim)
		_apply_font_override(label, _font)
	for label in _stat_values:
		label.add_theme_color_override("font_color", text)
		_apply_font_override(label, _font)
	_event_label.add_theme_color_override("font_color", accent)
	_combo_label.add_theme_color_override("font_color", accent)
	_overlay_title.add_theme_color_override("font_color", text)
	_overlay_body.add_theme_color_override("font_color", dim)
	_apply_font_override(_event_label, _font)
	_apply_font_override(_combo_label, _font)
	_apply_font_override(_overlay_title, _title_font)
	_apply_font_override(_overlay_body, _font)


## Theme font override helper: null clears the override so the built-in
## font applies, non-null replaces it for that label only.
static func _apply_font_override(label: Label, font: Font) -> void:
	if font == null:
		label.remove_theme_font_override("font")
	else:
		label.add_theme_font_override("font", font)


func _centered_label(pos_y: float, height: float, size_px: int, font: Font = null) -> Label:
	var label := Label.new()
	label.add_theme_font_size_override("font_size", size_px)
	label.add_theme_color_override("font_color", _tokens["theme.text"])
	label.position = Vector2(0.0, pos_y)
	label.size = Vector2(1280.0, height)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_apply_font_override(label, font)
	_root.add_child(label)
	return label


func _stat_pair(pos: Vector2, title: String, left: bool) -> Label:
	var title_label := Label.new()
	title_label.text = title
	title_label.add_theme_font_size_override("font_size", 14)
	title_label.add_theme_color_override("font_color", _tokens["theme.dim"])
	var value := Label.new()
	value.add_theme_font_size_override("font_size", 26)
	value.add_theme_color_override("font_color", _tokens["theme.text"])
	if left:
		title_label.position = pos - Vector2(0.0, 28.0)
		value.position = pos
	else:
		title_label.position = Vector2(pos.x - 160.0, pos.y - 28.0)
		title_label.size = Vector2(160.0, 20.0)
		title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		value.position = Vector2(pos.x - 160.0, pos.y)
		value.size = Vector2(160.0, 40.0)
		value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_apply_font_override(title_label, _font)
	_apply_font_override(value, _font)
	_root.add_child(title_label)
	_root.add_child(value)
	_stat_titles.append(title_label)
	_stat_values.append(value)
	return value


# ----------------------------------------------------------------- updates

func set_score(value: int) -> void:
	_score_label.text = str(value)


func set_level(value: int) -> void:
	_level_label.text = str(value)


func set_lines(value: int) -> void:
	_lines_label.text = str(value)


## Hides the personal stat columns (score/level/lines): multiplayer
## competitive matches carry each player's score on their own board
## strip, so the shared left column would only show player 0.
func set_personal_stats_visible(visible: bool) -> void:
	for i in 3:
		_stat_titles[i].visible = visible
		_stat_values[i].visible = visible


func set_time(value: float) -> void:
	_time_label.text = _format_time(value)


func set_event(text: String, points: int) -> void:
	if text.is_empty() and points <= 0:
		_event_label.text = ""
		return
	var suffix: String = "  +%d" % points if points > 0 else ""
	_event_label.text = text + suffix


func set_combo(text: String) -> void:
	_combo_label.text = text


func show_overlay(title: String, body: String) -> void:
	_overlay_title.text = title
	_overlay_body.text = body
	_overlay_title.visible = true
	_overlay_body.visible = true


func hide_overlay() -> void:
	_overlay_title.visible = false
	_overlay_body.visible = false


static func _format_time(value: float) -> String:
	var minutes: int = int(value) / 60
	var seconds: float = value - minutes * 60
	return "%02d:%05.2f" % [minutes, seconds]
