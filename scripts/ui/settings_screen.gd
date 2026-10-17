extends CanvasLayer
## Settings screen: category-based layout (Controls / Display / Audio /
## Reset) with a bounded, windowed row list; the profile-targeted keyboard
## bindings page with live keyboard capture; the guided controller
## rebinding flow (3-second pad claim, then one capture per canonical
## action, review, commit); the playlist manager (catalog, per-playlist
## editor with add/remove/reorder, playback actions, delete confirmation);
## theme selection/reload; and resets. All changes are committed through
## host commands so the host stays the orchestration boundary. Visual
## values come from the resolved theme tokens.

const DefaultBindings = preload("res://scripts/input/default_bindings.gd")
const BindingCapture = preload("res://scripts/ui/binding_capture.gd")
const ControllerClaim = preload("res://scripts/input/controller_claim.gd")
const ThemeProfile = preload("res://scripts/ui/theme_profile.gd")
const UiNavigation = preload("res://scripts/ui/ui_navigation.gd")

const ACTION_LABELS := {
	"move_left": "Move Left",
	"move_right": "Move Right",
	"soft_drop": "Soft Drop",
	"hard_drop": "Hard Drop",
	"rotate_cw": "Rotate CW",
	"rotate_ccw": "Rotate CCW",
	"hold": "Hold",
	"pause": "Pause",
	"restart": "Restart",
}

const CATEGORIES := ["controls", "display", "audio", "reset"]
const CATEGORY_LABELS := {
	"controls": "Controls",
	"display": "Display",
	"audio": "Audio",
	"reset": "Reset",
}

const VOLUME_STEP := 0.1
const MAX_PER_CATEGORY := 2
const WINDOW_SCALES := [1, 2, 3]
const MUSIC_MODE_LABELS := {
	"off": "Off",
	"single": "Single",
	"playlist": "Playlist",
	"shuffle": "Shuffle",
}
# Bounded row window so every category and sub-view fits the 720px logical
# viewport; navigation still moves through the full row list and the window
# scrolls the selection into view.
const MAX_VISIBLE_ROWS := 16
const MAX_VISIBLE_ROWS_COMPACT := 22

# Guided controller binding stages.
const PAD_STAGE_IDLE := ""
const PAD_STAGE_CLAIM := "claim"
const PAD_STAGE_RELEASE := "release"
const PAD_STAGE_CAPTURE := "capture"
const PAD_STAGE_REVIEW := "review"

var _host: Node = null
var _root: Control = null
var _bg: ColorRect = null
var _title: Label = null
var _rows_box: VBoxContainer = null
var _status: Label = null
var _capture: Node = null
var _claim: Node = null
var _rows: Array = []
var _selected: int = 0
# settings sub-view. The playlist manager uses three: "playlist" (catalog
# landing), "playlist_detail" (one playlist's editor), and
# "playlist_delete" (delete confirmation).
var _mode: String = "controls"  # controls|display|audio|reset|kb|padbind|playlist|playlist_detail|playlist_delete
var _nav: UiNavigation = UiNavigation.new()
var _tokens: Dictionary = ThemeProfile.default_tokens()
# Theme fonts: body for rows/status, title for the heading; applied to
# freshly rebuilt row labels too.
var _font: Font = null
var _title_font: Font = null

# --- Guided controller rebinding state (target profile + session device) ---
var _pad_profile_id: String = ""
var _pad_device: int = -1
var _pad_stage: String = PAD_STAGE_IDLE
var _pad_index: int = 0
var _pad_captured: Dictionary = {}

# --- Profile-targeted keyboard bindings page state ---
# The page edits one profile's keyboard mapping through a working copy;
# every mutation commits atomically through the host command.
var _kb_profile_id: String = ""
var _kb_profile: Dictionary = {}

# --- Playlist manager state ---
# The catalog/detail/delete sub-modes target one playlist id; the delete
# index anchors the deterministic post-delete selection.
var _playlist_id: String = ""
var _playlist_delete_index: int = 0
var _playlist_track_set: Dictionary = {}


func _ready() -> void:
	layer = 20
	visible = false
	_build()
	_capture = BindingCapture.new()
	add_child(_capture)
	_capture.captured.connect(_on_captured)
	_capture.cleared.connect(_on_cleared)
	_capture.cancelled.connect(_on_capture_cancelled)
	_claim = ControllerClaim.new()
	add_child(_claim)
	_claim.claimed.connect(_on_pad_claimed)
	_claim.released.connect(_on_pad_released)
	_claim.cancelled.connect(_on_claim_cancelled)


func setup(host: Node) -> void:
	_host = host


func _build() -> void:
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	_bg = ColorRect.new()
	# Same scrim as the menu screens so the host's menu backdrop (theme
	# background media) stays visible under the settings list instead of
	# being covered by a near-opaque fill.
	_bg.color = _tokens["menu.scrim"]
	_bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_bg)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(center)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.add_child(box)

	_title = Label.new()
	_title.add_theme_font_size_override("font_size", 40)
	_title.add_theme_color_override("font_color", _tokens["theme.text"])
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_apply_font_override(_title, _title_font)
	box.add_child(_title)

	_rows_box = VBoxContainer.new()
	_rows_box.add_theme_constant_override("separation", 4)
	_rows_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(_rows_box)

	_status = Label.new()
	_status.add_theme_font_size_override("font_size", 16)
	_status.add_theme_color_override("font_color", _tokens["theme.dim"])
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_apply_font_override(_status, _font)
	box.add_child(_status)


## Push refreshed theme tokens and media from the host; safe before
## _build.
func apply_theme(tokens: Dictionary, media: Dictionary) -> void:
	_tokens = tokens
	_font = media.get("font")
	_title_font = media.get("title_font")
	if _root == null:
		return
	_bg.color = _tokens["menu.scrim"]
	_title.add_theme_color_override("font_color", _tokens["theme.text"])
	_status.add_theme_color_override("font_color", _tokens["theme.dim"])
	_apply_font_override(_title, _title_font)
	_apply_font_override(_status, _font)
	_render_rows()


## Theme font override helper: null clears the override so the built-in
## font applies, non-null replaces it for that label only.
static func _apply_font_override(label: Label, font: Font) -> void:
	if font == null:
		label.remove_theme_font_override("font")
	else:
		label.add_theme_font_override("font", font)


func _process(_delta: float) -> void:
	# Live claim progress in the status line while the guided flow waits
	# for the 3-second hold.
	if visible and _mode == "padbind" and _pad_stage == PAD_STAGE_CLAIM:
		_update_padbind_status()


# ------------------------------------------------------------------ lifecycle

func open() -> void:
	_mode = "controls"
	_selected = 0
	_cancel_padbind()
	_rebuild()
	visible = true


func close() -> void:
	visible = false
	_cancel_padbind()
	_capture.stop()
	if _host != null:
		_host.cmd_music_preview_stop()


func refresh() -> void:
	if visible:
		_rebuild()


func _rebuild() -> void:
	# A manager sub-mode targeting a playlist that vanished (deleted from
	# the OSK rename flow, or a reset elsewhere) falls back to the catalog.
	if _mode == "playlist_detail" and not _host.playlist_exists(_playlist_id):
		_mode = "playlist"
	if _mode == "playlist_delete" and not _host.playlist_exists(_playlist_id):
		_mode = "playlist"
	_playlist_track_set.clear()
	_rows = _build_rows()
	_selected = clampi(_selected, 0, maxi(0, _rows.size() - 1))
	_ensure_selectable()
	_render_rows()
	_refresh_title()


func _refresh_title() -> void:
	match _mode:
		"controls", "display", "audio", "reset":
			_title.text = "SETTINGS"
			_status.text = "A / Enter: change    D-pad / Left-Right: adjust    B / Esc: back"
		"kb":
			_title.text = "KEYBOARD BINDINGS - %s" % _host.profile_name(_kb_profile_id).to_upper()
			_status.text = "Enter: change    Left/Right: adjust or reset    Esc: back"
		"padbind":
			_title.text = "CONTROLLER BINDINGS"
			_update_padbind_status()
		"playlist":
			_title.text = "PLAYLIST MANAGER"
			_status.text = "Enter: open playlist / play song    Left/Right on a playlist: play    Esc: back"
		"playlist_detail":
			_title.text = "PLAYLIST - %s" % _host.playlist_name(_playlist_id).to_upper()
			_status.text = "Enter: add/remove/play    Left/Right: reorder    Esc: back"
		"playlist_delete":
			_title.text = "DELETE PLAYLIST"
			_status.text = "Enter: confirm delete    Esc: cancel"


# --------------------------------------------------------------------- rows

func _build_rows() -> Array:
	var rows: Array = []
	match _mode:
		"controls":
			rows.append(_category_row())
			rows.append(_command("keyboard", "Keyboard Bindings (%s)" % _host.active_profile_name()))
			rows.append(_command("controller", "Controller Bindings (%s)" % _host.active_profile_name()))
			rows.append(_command("back", "Back"))
		"display":
			rows.append(_category_row())
			rows.append(_toggle("fullscreen", "Fullscreen"))
			rows.append(_cycle("window_scale", "Window Scale"))
			rows.append({"kind": "theme", "label": "Theme"})
			rows.append(_command("themes_reload", "Reload Themes"))
			rows.append(_note("Custom themes: %s" % _host.theme_user_dir_hint()))
			rows.append(_command("back", "Back"))
		"audio":
			rows.append(_category_row())
			rows.append(_note("Custom tracks: %s (.ogg .mp3 .wav)" % _host.audio_music_dir_hint()))
			rows.append(_volume("master_volume", "Master Volume"))
			rows.append(_volume("music_volume", "Music Volume"))
			rows.append(_volume("sfx_volume", "SFX Volume"))
			rows.append({"kind": "music_mode", "label": "Music Mode"})
			rows.append({"kind": "menu_music_track", "label": "Menu Music"})
			rows.append({"kind": "music_track", "label": "Music Track"})
			rows.append(_command("music_preview", "Preview Track"))
			rows.append(_toggle("normalize_custom_music", "Normalize Custom Music"))
			rows.append(_command("music_rescan", "Rescan Music Library"))
			rows.append(_command("music_editor", "Playlist Manager"))
			rows.append(_note(_host.music_now_playing_summary()))
			rows.append(_note("F1: skip current track"))
			rows.append(_note("Custom music must be legally obtained."))
			rows.append(_command("back", "Back"))
		"reset":
			rows.append(_category_row())
			rows.append(_command("reset_kb", "Reset Keyboard Bindings (%s)" % _host.active_profile_name()))
			rows.append(_command("reset_pad", "Reset Controller Bindings (%s)" % _host.active_profile_name()))
			rows.append(_command("reset_all", "Reset All Settings"))
			rows.append(_command("back", "Back"))
		"kb":
			rows.append(_header("PROFILE: %s" % _host.profile_name(_kb_profile_id).to_upper()))
			for action in DefaultBindings.ACTION_NAMES:
				rows.append(_binding(action))
			rows.append(_command("reset_list", "Reset This List To Defaults"))
			rows.append(_command("back", "Back"))
		"padbind":
			rows.append(_header("PROFILE: %s" % _host.profile_name(_pad_profile_id).to_upper()))
			for action in DefaultBindings.ACTION_NAMES:
				rows.append({"kind": "pad_action", "action": action})
			if _pad_stage == PAD_STAGE_REVIEW:
				rows.append(_command("pad_finish", "FINISH AND SAVE"))
			rows.append(_command("pad_cancel", "CANCEL"))
		"playlist":
			# Catalog landing: current playback state, the playlist list,
			# and the whole library (Enter plays a song as Single).
			rows.append(_note(_host.music_now_playing_summary()))
			rows.append(_note("F1: skip current track"))
			rows.append(_command("playlist_create", "Create Playlist"))
			var playlists: Array = _host.playlists()
			if playlists.is_empty():
				rows.append(_note("No playlists yet"))
			else:
				rows.append(_header("PLAYLISTS"))
				for playlist in playlists:
					rows.append({
						"kind": "playlist_item",
						"id": playlist["id"],
						"label": playlist["name"],
						"track_count": (playlist["tracks"] as Array).size(),
					})
			rows.append(_header("LIBRARY"))
			var track_ids: Array = _host.audio_track_ids()
			if track_ids.is_empty():
				rows.append(_note("No tracks - place files in %s" % _host.audio_music_dir_hint()))
			for track_id in track_ids:
				rows.append({"kind": "library_track", "id": track_id})
			rows.append(_command("back", "Back"))
		"playlist_detail":
			# One playlist's editor: playback actions and rename/delete,
			# then the ordered track list and the library to add from.
			var detail_tracks: Array = _host.playlist_tracks(_playlist_id)
			for track_id in detail_tracks:
				_playlist_track_set[track_id] = true
			rows.append(_command("playlist_play", "Play In Order"))
			rows.append(_command("playlist_shuffle", "Shuffle Playlist"))
			rows.append(_command("playlist_rename", "Rename"))
			rows.append(_command("playlist_delete", "Delete"))
			rows.append(_header("TRACKS - %d" % detail_tracks.size()))
			if detail_tracks.is_empty():
				rows.append(_note("Empty - add tracks from the library below"))
			for i in detail_tracks.size():
				rows.append({"kind": "playlist_entry", "index": i, "id": detail_tracks[i]})
			rows.append(_header("LIBRARY"))
			var detail_track_ids: Array = _host.audio_track_ids()
			if detail_track_ids.is_empty():
				rows.append(_note("No tracks - place files in %s" % _host.audio_music_dir_hint()))
			for track_id in detail_track_ids:
				rows.append({"kind": "library_track", "id": track_id})
			rows.append(_command("back", "Back"))
		"playlist_delete":
			# Delete confirmation: destructive actions never fire without
			# this explicit two-step consent.
			rows.append(_note("Delete '%s'?" % _host.playlist_name(_playlist_id)))
			rows.append(_note("This cannot be undone."))
			rows.append(_command("playlist_delete_confirm", "YES, DELETE"))
			rows.append(_command("playlist_delete_cancel", "CANCEL"))
	return rows


func _category_row() -> Dictionary:
	return {"kind": "category", "label": "CATEGORY"}


func _header(text: String) -> Dictionary:
	return {"kind": "header", "label": text}


func _note(text: String) -> Dictionary:
	return {"kind": "note", "label": text}


func _binding(action: String) -> Dictionary:
	return {"kind": "binding", "action": action}


func _toggle(field: String, label: String) -> Dictionary:
	return {"kind": "toggle", "field": field, "label": label}


func _cycle(field: String, label: String) -> Dictionary:
	return {"kind": "cycle", "field": field, "label": label}


func _volume(field: String, label: String) -> Dictionary:
	return {"kind": "volume", "field": field, "label": label}


func _command(id: String, label: String) -> Dictionary:
	return {"kind": "command", "id": id, "label": label}


func _action_label(action: String) -> String:
	return String(ACTION_LABELS.get(action, action.capitalize()))


func _row_label(row: Dictionary) -> String:
	match row["kind"]:
		"binding":
			return _action_label(row["action"])
		"pad_action":
			return _action_label(row["action"])
		"playlist_entry", "library_track":
			return _host.audio_track_title(row["id"])
		"playlist_item":
			return String(row["label"])
		"toggle", "cycle", "volume", "command", "music_mode", "menu_music_track", "music_track", "theme", "category":
			return row["label"]
	return ""


func _row_value(row: Dictionary) -> String:
	var settings = _host.settings
	match row["kind"]:
		"binding":
			var records := _category_records(row["action"])
			if records.is_empty():
				return "-"
			var names: Array[String] = []
			for record in records:
				names.append(DefaultBindings.record_display_name(record))
			return " / ".join(names)
		"pad_action":
			return _pad_action_value(row["action"])
		"toggle":
			return "ON" if settings.get(row["field"]) else "OFF"
		"cycle":
			var value: int = settings.get(row["field"])
			return "%dx" % value
		"volume":
			return "%d%%" % int(round(settings.get(row["field"]) * 100.0))
		"music_mode":
			return String(MUSIC_MODE_LABELS.get(settings.music_mode, settings.music_mode))
		"menu_music_track":
			if settings.menu_music_track.is_empty():
				return "Follow Game Music"
			var menu_title: String = _host.audio_track_title(settings.menu_music_track)
			return menu_title if not menu_title.is_empty() else "-"
		"music_track":
			if settings.music_track.is_empty():
				return "None"
			var title: String = _host.audio_track_title(settings.music_track)
			return title if not title.is_empty() else "-"
		"playlist_entry":
			return "%d." % (row["index"] + 1)
		"library_track":
			if _mode == "playlist_detail":
				# The editor marks the songs already in the target list.
				return "Added" if _playlist_track_set.has(row["id"]) else ""
			return "Playing" if _host.music_current_track_id() == row["id"] else ""
		"playlist_item":
			var active_marker := "ACTIVE - " if _host.active_playlist_id() == row["id"] else ""
			return "%s%d tracks" % [active_marker, row["track_count"]]
		"command":
			if row["id"] == "music_preview":
				return "PLAYING" if _host.music_previewing() else ""
			if row["id"] == "playlist_play" and _mode == "playlist_detail":
				return "ACTIVE" if _playlist_is_ordered_source() else ""
			if row["id"] == "playlist_shuffle" and _mode == "playlist_detail":
				return "ACTIVE" if _playlist_is_shuffle_source() else ""
			return ""
		"theme":
			return _theme_value()
		"category":
			return "‹  %s  %d/%d  ›" % [
				CATEGORY_LABELS.get(_mode, _mode),
				CATEGORIES.find(_mode) + 1,
				CATEGORIES.size(),
			]
	return ""


func _pad_action_value(action: String) -> String:
	# Captured record display, the live "press now" marker, or "-".
	if _pad_captured.has(action):
		return DefaultBindings.record_display_name(_pad_captured[action])
	if _pad_stage == PAD_STAGE_CAPTURE and _pad_index < DefaultBindings.ACTION_NAMES.size() and DefaultBindings.ACTION_NAMES[_pad_index] == action:
		return "press a button or axis  (%d/%d)" % [_pad_index + 1, DefaultBindings.ACTION_NAMES.size()]
	return "-"


func _theme_value() -> String:
	var entries: Array = _host.theme_entries()
	for entry in entries:
		if entry["id"] == _host.theme_selected_id():
			var origin := "Custom"
			if entry["source"] == "builtin":
				origin = "Built-in"
			elif entry["source"] == "portable":
				origin = "Portable"
			return "%s (%s)" % [entry["name"], origin]
	return "-"


# ------------------------------------------------------------------ rendering

func _render_rows() -> void:
	if _rows_box == null:
		return
	for child in _rows_box.get_children():
		child.queue_free()
	var compact: bool = _is_playlist_mode()
	_rows_box.add_theme_constant_override("separation", 2 if compact else 4)
	var font_size := 17 if compact else 22
	var name_width := 500.0 if compact else 420.0
	var window := _window_range()
	var start: int = window[0]
	var end: int = window[1]
	if start > 0:
		_add_window_marker()
	for i in range(start, end):
		var row: Dictionary = _rows[i]
		var is_header: bool = row["kind"] == "header" or row["kind"] == "note"
		var selected: bool = i == _selected and not is_header
		if is_header:
			var label := Label.new()
			label.text = row["label"]
			label.add_theme_font_size_override("font_size", 17 if row["kind"] == "header" else 15)
			var header_color: Color
			if row["kind"] == "header":
				header_color = _tokens["theme.dim"]
			else:
				header_color = Color(_tokens["theme.accent"], 0.8)
			label.add_theme_color_override("font_color", header_color)
			label.mouse_filter = Control.MOUSE_FILTER_IGNORE
			_apply_font_override(label, _font)
			_rows_box.add_child(label)
			continue
		var line := HBoxContainer.new()
		line.add_theme_constant_override("separation", 24)
		line.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var name := Label.new()
		name.text = ("▸ " if selected else "  ") + _row_label(row)
		name.add_theme_font_size_override("font_size", font_size)
		name.custom_minimum_size = Vector2(name_width, 0.0)
		name.mouse_filter = Control.MOUSE_FILTER_IGNORE
		line.add_child(name)
		var spacer := Control.new()
		spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
		line.add_child(spacer)
		var value := Label.new()
		value.text = _row_value(row)
		value.add_theme_font_size_override("font_size", font_size)
		value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		value.mouse_filter = Control.MOUSE_FILTER_IGNORE
		line.add_child(value)
		var color: Color = _tokens["theme.accent"] if selected else _tokens["theme.dim"]
		name.add_theme_color_override("font_color", color)
		value.add_theme_color_override("font_color", color)
		_apply_font_override(name, _font)
		_apply_font_override(value, _font)
		_rows_box.add_child(line)
	if end < _rows.size():
		_add_window_marker()


## True while one of the playlist manager's modes is showing; those lists
## render compact and window tightly like the old playlist editor.
func _is_playlist_mode() -> bool:
	return _mode == "playlist" or _mode == "playlist_detail" or _mode == "playlist_delete"


## True while this screen (not its caller) owns raw input: a pending key
## capture or an active guided-controller stage. The host's global F1
## skip checks this so fixed shortcuts never fire mid-capture.
func owns_raw_input() -> bool:
	return visible and (
		_capture.active
		or _pad_stage == PAD_STAGE_CLAIM
		or _pad_stage == PAD_STAGE_RELEASE
		or _pad_stage == PAD_STAGE_CAPTURE
	)


## Host hook after an F1 skip: refresh the now-playing rows and surface
## the skip result in the status line. Only the views that display music
## state react; the delete confirmation keeps its prompt.
func on_music_skipped(message: String) -> void:
	if not visible:
		return
	if _mode != "audio" and _mode != "playlist" and _mode != "playlist_detail":
		return
	_rebuild()
	_status.text = message


## Visible row window: scrolls the selection into view, bounded so no row
## renders outside the logical viewport. Returns [start, end).
func _window_range() -> Array:
	var capacity := (
		MAX_VISIBLE_ROWS_COMPACT
		if _is_playlist_mode()
		else MAX_VISIBLE_ROWS
	)
	if _rows.size() <= capacity:
		return [0, _rows.size()]
	var start: int = clampi(_selected - capacity / 2, 0, maxi(0, _rows.size() - capacity))
	return [start, start + capacity]


func _add_window_marker() -> void:
	# "..." hint that the list is windowed; selection stays visible.
	var marker := Label.new()
	marker.text = "..."
	marker.add_theme_font_size_override("font_size", 15)
	marker.add_theme_color_override("font_color", _tokens["theme.dim"])
	marker.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	marker.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_apply_font_override(marker, _font)
	_rows_box.add_child(marker)


# -------------------------------------------------------------------- input

func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if _capture.active:
		return
	# The active guided stages own their input (claim/capture consume raw
	# events, including Escape/B); no navigation fires meanwhile.
	if _pad_stage == PAD_STAGE_CLAIM or _pad_stage == PAD_STAGE_RELEASE or _pad_stage == PAD_STAGE_CAPTURE:
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
	elif event.is_action_pressed("ui_left") or nav == UiNavigation.DIR_LEFT:
		_adjust(-1)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("ui_right") or nav == UiNavigation.DIR_RIGHT:
		_adjust(1)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("ui_cancel") or nav == UiNavigation.DIR_BACK:
		get_viewport().set_input_as_handled()
		_back()


static func _is_accept(event: InputEvent) -> bool:
	if event.is_action_pressed("ui_accept"):
		if event is InputEventKey and (event as InputEventKey).physical_keycode == KEY_SPACE:
			return false
		return true
	return false


func _move(delta: int) -> void:
	# User-facing navigation: sounds only for actual selection changes.
	if _step_selection(delta):
		_play_nav_sfx("menu_move")


func _step_selection(delta: int) -> bool:
	if _rows.is_empty():
		return false
	var index := _selected
	for i in _rows.size():
		index = wrapi(index + delta, 0, _rows.size())
		if _is_selectable(index):
			break
	if index != _selected or not _is_selectable(_selected):
		_selected = index
		_render_rows()
		return true
	return false


func _ensure_selectable() -> void:
	# Silent internal adjustment (screen open, rebuilds).
	if not _is_selectable(_selected):
		_step_selection(1)


func _is_selectable(index: int) -> bool:
	if index < 0 or index >= _rows.size():
		return false
	var kind: String = _rows[index]["kind"]
	return kind != "header" and kind != "note" and kind != "pad_action"


# ----------------------------------------------------------------- actions

func _activate() -> void:
	if not _is_selectable(_selected):
		return
	var row: Dictionary = _rows[_selected]
	match row["kind"]:
		"binding":
			_status.text = "Press a key...    Esc: cancel    Del: clear latest"
			_capture.start()
		"toggle":
			_play_nav_sfx("menu_move")
			var settings = _host.settings
			settings.set(row["field"], not settings.get(row["field"]))
			_commit_values()
			_update_toggle_status(row)
		"cycle":
			_play_nav_sfx("menu_move")
			_cycle_field(row["field"], 1)
		"volume":
			_play_nav_sfx("menu_move")
			_adjust_volume(row["field"], 1)
		"music_mode":
			_play_nav_sfx("menu_move")
			_cycle_music_mode(1)
		"menu_music_track":
			_play_nav_sfx("menu_move")
			_cycle_menu_music_track(1)
		"music_track":
			_play_nav_sfx("menu_move")
			_cycle_music_track(1)
		"theme":
			_play_nav_sfx("menu_move")
			_cycle_theme(1)
		"category":
			_play_nav_sfx("menu_move")
			_change_category(1)
		"playlist_entry":
			_play_nav_sfx("menu_confirm")
			_remove_playlist_track(row["index"])
		"playlist_item":
			_play_nav_sfx("menu_confirm")
			_open_playlist_detail(String(row["id"]))
		"library_track":
			_play_nav_sfx("menu_confirm")
			if _mode == "playlist_detail":
				_add_track_to_playlist(String(row["id"]))
			else:
				_play_library_track(String(row["id"]))
		"command":
			_run_command(row["id"])


func _adjust(delta: int) -> void:
	if not _is_selectable(_selected):
		return
	var row: Dictionary = _rows[_selected]
	match row["kind"]:
		"binding":
			_reset_action(row["action"])
			_play_nav_sfx("menu_move")
			_status.text = "Reset to default: %s" % _row_value(row)
		"toggle":
			_play_nav_sfx("menu_move")
			var settings = _host.settings
			settings.set(row["field"], not settings.get(row["field"]))
			_commit_values()
			_update_toggle_status(row)
		"cycle":
			_play_nav_sfx("menu_move")
			_cycle_field(row["field"], delta)
		"volume":
			_play_nav_sfx("menu_move")
			_adjust_volume(row["field"], delta)
		"music_mode":
			_play_nav_sfx("menu_move")
			_cycle_music_mode(delta)
		"menu_music_track":
			_play_nav_sfx("menu_move")
			_cycle_menu_music_track(delta)
		"music_track":
			_play_nav_sfx("menu_move")
			_cycle_music_track(delta)
		"theme":
			_play_nav_sfx("menu_move")
			_cycle_theme(delta)
		"category":
			_play_nav_sfx("menu_move")
			_change_category(delta)
		"playlist_entry":
			_play_nav_sfx("menu_move")
			_move_playlist_track(row["index"], delta)
		"playlist_item":
			_play_nav_sfx("menu_confirm")
			_play_playlist_in_order(String(row["id"]))


func _change_category(delta: int) -> void:
	var index: int = CATEGORIES.find(_mode)
	if index < 0:
		return
	_mode = CATEGORIES[wrapi(index + delta, 0, CATEGORIES.size())]
	_selected = 0
	_rebuild()


func _cycle_field(field: String, delta: int) -> void:
	var settings = _host.settings
	var values := WINDOW_SCALES
	var current: int = settings.get(field)
	var index: int = values.find(current)
	index = wrapi(index + delta, 0, values.size())
	settings.set(field, values[index])
	_commit_values()


func _adjust_volume(field: String, delta: int) -> void:
	var settings = _host.settings
	settings.set(field, clampf(snappedf(settings.get(field) + delta * VOLUME_STEP, VOLUME_STEP), 0.0, 1.0))
	_commit_values()


func _run_command(id: String) -> void:
	if id != "back" and id != "pad_cancel":
		_play_nav_sfx("menu_confirm")
	match id:
		"keyboard":
			open_keyboard_binding(_host.settings.active_profile_id)
		"controller":
			open_controller_binding(_host.settings.active_profile_id)
		"themes_reload":
			_reload_themes()
		"music_preview":
			if _host.music_previewing():
				_host.cmd_music_preview_stop()
				_status.text = "Preview stopped"
			else:
				_host.cmd_music_preview()
				if not _host.music_previewing():
					_status.text = "No track to preview"
				elif _host.audio_normalization_active():
					_status.text = "Previewing - measuring loudness before normalizing"
				else:
					_status.text = "Previewing selected track"
			_render_rows()
		"music_rescan":
			_host.cmd_music_rescan()
			var count: int = _host.audio_track_count()
			var skipped: int = _host.audio_skipped_count()
			_status.text = "Library: %d track%s" % [count, "s" if count != 1 else ""]
			if skipped > 0:
				_status.text += " - %d unreadable file%s skipped" % [skipped, "s" if skipped != 1 else ""]
			_rebuild_preserving_selection()
		"music_editor":
			_mode = "playlist"
			_selected = 0
			_rebuild()
		"playlist_create":
			var created: Dictionary = _host.cmd_playlist_create()
			if bool(created.get("ok", false)):
				_host.cmd_open_playlist_rename(String(created.get("id", "")))
			else:
				_status.text = String(created.get("message", ""))
		"playlist_play":
			var played: Dictionary = _host.cmd_playlist_play(_playlist_id)
			# The rebuild resets the status line, so the result lands after.
			_rebuild_preserving_selection()
			_status.text = String(played.get("message", ""))
		"playlist_shuffle":
			var shuffled: Dictionary = _host.cmd_playlist_shuffle(_playlist_id)
			_rebuild_preserving_selection()
			_status.text = String(shuffled.get("message", ""))
		"playlist_rename":
			_host.cmd_open_playlist_rename(_playlist_id)
		"playlist_delete":
			_enter_playlist_delete()
		"playlist_delete_confirm":
			_confirm_playlist_delete()
		"playlist_delete_cancel":
			_cancel_playlist_delete()
		"reset_kb":
			_host.cmd_reset_keyboard_bindings(_host.settings.active_profile_id)
			_status.text = "Keyboard bindings reset for %s" % _host.active_profile_name()
			_render_rows()
		"reset_pad":
			_host.cmd_reset_controller_bindings(_host.settings.active_profile_id)
			_status.text = "Controller bindings reset"
			_render_rows()
		"reset_list":
			_reset_category("keyboard")
			_status.text = "Bindings reset"
		"reset_all":
			_host.cmd_reset_all_settings()
			_rebuild()
			_status.text = "All settings reset"
		"pad_finish":
			_commit_pad_bindings()
		"pad_cancel":
			_cancel_padbind()
			_rebuild()
			_status.text = "Controller binding cancelled"
		"back":
			_back()


func _back() -> void:
	if _mode == "padbind":
		# Review stage: back discards the uncommitted sequence.
		_play_nav_sfx("menu_back")
		_cancel_padbind()
		_rebuild()
		_status.text = "Controller binding cancelled"
		return
	_play_nav_sfx("menu_back")
	if CATEGORIES.has(_mode):
		_host.cmd_settings_back()
		return
	match _mode:
		"kb":
			_mode = "controls"
		"playlist":
			_mode = "audio"
		"playlist_detail":
			_mode = "playlist"
		"playlist_delete":
			# Esc cancels the pending delete and returns to the catalog.
			_cancel_playlist_delete()
			return
	_selected = 0
	_rebuild()


# ----------------------------------------------------- guided controller flow

## Opens the guided rebinding flow for one profile: hold any pad button for
## two seconds, release it, then capture every canonical action in order.
func open_controller_binding(profile_id: String) -> void:
	_mode = "padbind"
	_pad_profile_id = profile_id
	_pad_device = -1
	_pad_index = 0
	_pad_captured = {}
	_pad_stage = PAD_STAGE_CLAIM
	_selected = 0
	_capture.stop()
	_rebuild()
	visible = true
	_claim.start([])


## Opens the keyboard bindings page for one profile: every mutation works
## on a copy of that profile's mapping and commits through the host
## command, so bindings never bleed between profiles.
func open_keyboard_binding(profile_id: String) -> void:
	_mode = "kb"
	_kb_profile_id = profile_id
	_kb_profile = _host.settings.keyboard_bindings_for(profile_id)
	_selected = 0
	_cancel_padbind()
	_capture.stop()
	_rebuild()
	visible = true


func _cancel_padbind() -> void:
	## Discards any uncommitted guided sequence and returns to the controls
	## category.
	if _pad_stage == PAD_STAGE_IDLE and _mode != "padbind":
		if _claim != null:
			_claim.stop()
		return
	_pad_stage = PAD_STAGE_IDLE
	_pad_captured = {}
	_pad_index = 0
	_pad_device = -1
	_claim.stop()
	_capture.stop()
	if visible and _mode == "padbind":
		_mode = "controls"
		_selected = 0
		_rebuild()


func _update_padbind_status() -> void:
	match _pad_stage:
		PAD_STAGE_CLAIM:
			var progress: int = int(round(_claim.progress() * 100.0))
			_status.text = "Hold any pad button 2 seconds...  %d%%" % progress
		PAD_STAGE_RELEASE:
			_status.text = "Pad %d claimed - release the button to start" % _pad_device
		PAD_STAGE_CAPTURE:
			var action: String = DefaultBindings.ACTION_NAMES[_pad_index]
			_status.text = "Press a controller input for: %s (%d/%d)    Esc / B: cancel" % [
				_action_label(action), _pad_index + 1, DefaultBindings.ACTION_NAMES.size(),
			]
		PAD_STAGE_REVIEW:
			_status.text = "Review - A / Enter: save    B / Esc: cancel"


func _on_pad_claimed(device: int) -> void:
	if _mode != "padbind" or _pad_stage != PAD_STAGE_CLAIM:
		return
	_pad_stage = PAD_STAGE_RELEASE
	_pad_device = device
	_play_nav_sfx("menu_confirm")
	_update_padbind_status()


func _on_pad_released(device: int) -> void:
	if _mode != "padbind" or _pad_stage != PAD_STAGE_RELEASE or device != _pad_device:
		return
	_pad_stage = PAD_STAGE_CAPTURE
	_pad_index = 0
	_claim.stop()
	_capture.start_controller(_pad_device)
	_update_padbind_status()
	_rebuild()


func _on_claim_cancelled() -> void:
	if _mode != "padbind" or _pad_stage == PAD_STAGE_IDLE:
		return
	_cancel_padbind()
	_status.text = "Controller binding cancelled"


func _on_controller_captured(record: Dictionary) -> void:
	if _pad_stage != PAD_STAGE_CAPTURE:
		return
	var action: String = DefaultBindings.ACTION_NAMES[_pad_index]
	# Conflicts are enforced only inside the profile being edited.
	var conflict := ""
	for other_action in DefaultBindings.ACTION_NAMES:
		if other_action == action or not _pad_captured.has(other_action):
			continue
		if DefaultBindings.record_matches(_pad_captured[other_action], record):
			conflict = other_action
			break
	if not conflict.is_empty():
		_status.text = "Already used by: %s - press another input" % _action_label(conflict)
		_capture.start_controller(_pad_device)
		return
	_pad_captured[action] = record
	_play_nav_sfx("menu_confirm")
	_pad_index += 1
	if _pad_index >= DefaultBindings.ACTION_NAMES.size():
		_pad_stage = PAD_STAGE_REVIEW
		_rebuild()
		_update_padbind_status()
	else:
		# One-shot capture: re-arm for the next canonical action.
		_capture.start_controller(_pad_device)
		_rebuild()
		_update_padbind_status()


func _commit_pad_bindings() -> void:
	if _pad_captured.size() < DefaultBindings.ACTION_NAMES.size():
		_status.text = "Sequence incomplete - nothing saved"
		return
	if _host.cmd_controller_bindings_captured(_pad_profile_id, _pad_captured):
		var profile_name: String = _host.profile_name(_pad_profile_id)
		_pad_stage = PAD_STAGE_IDLE
		_mode = "controls"
		_selected = 0
		_claim.stop()
		_rebuild()
		_status.text = "Controller bindings saved for %s" % profile_name
	else:
		_status.text = "Could not save - profile missing"


# ------------------------------------------------------------------ theme

func _cycle_theme(delta: int) -> void:
	var entries: Array = _host.theme_entries()
	if entries.is_empty():
		_status.text = "No themes found - check %s" % _host.theme_user_dir_hint()
		return
	var ids: Array = []
	for entry in entries:
		ids.append(entry["id"])
	var index: int = ids.find(_host.theme_selected_id())
	index = wrapi(index + delta, 0, ids.size())
	_host.cmd_theme_selected(ids[index])
	_render_rows()
	_report_theme_status()


func _reload_themes() -> void:
	var result: Dictionary = _host.cmd_themes_reload()
	_rebuild_preserving_selection()
	_report_theme_status()
	if result["repaired"]:
		_status.text = "Selected theme lost - repaired to Modern Neon Arcade"


func _report_theme_status() -> void:
	var invalid_entries: Array = _host.theme_invalid_entries()
	var hard_failures := 0
	var warnings := 0
	for entry in invalid_entries:
		if entry.get("soft", false):
			warnings += 1
		else:
			hard_failures += 1
	var text := "Themes: %d loaded" % _host.theme_entries().size()
	if hard_failures > 0:
		text += " - %d invalid file%s skipped" % [hard_failures, "s" if hard_failures != 1 else ""]
	if warnings > 0:
		text += " - %d file%s with warnings" % [warnings, "s" if warnings != 1 else ""]
	_status.text = text


# ------------------------------------------------------------------ music

func _cycle_music_mode(delta: int) -> void:
	var modes: Array = _host.settings.MUSIC_MODES
	var index: int = modes.find(_host.settings.music_mode)
	if index < 0:
		index = 0
	index = wrapi(index + delta, 0, modes.size())
	_host.cmd_music_mode_changed(modes[index])
	_render_rows()


func _cycle_menu_music_track(delta: int) -> void:
	# "" (follow the gameplay music) plus every library track, in order.
	var track_ids: Array = _host.audio_track_ids()
	var ids: Array = [""]
	ids.append_array(track_ids)
	var index: int = ids.find(_host.settings.menu_music_track)
	if index < 0:
		index = 0 if delta > 0 else ids.size() - 1
	else:
		index = wrapi(index + delta, 0, ids.size())
	_host.cmd_menu_music_selected(ids[index])
	_render_rows()


func _cycle_music_track(delta: int) -> void:
	var track_ids: Array = _host.audio_track_ids()
	if track_ids.is_empty():
		_status.text = "No tracks - place files in %s" % _host.audio_music_dir_hint()
		return
	var index: int = track_ids.find(_host.settings.music_track)
	if index < 0:
		index = 0 if delta > 0 else track_ids.size() - 1
	index = wrapi(index + delta, 0, track_ids.size())
	_host.cmd_music_track_selected(track_ids[index])
	if _host.music_previewing():
		_status.text = "Previewing: %s" % _host.audio_track_title(track_ids[index])
	_render_rows()


# --------------------------------------------------------- playlist manager
# The manager edits one playlist at a time through working copies of its
# track array; every mutation commits atomically through a host command
# and the rows rebuild with the selection preserved.

func _open_playlist_detail(playlist_id: String) -> void:
	if not _host.playlist_exists(playlist_id):
		_status.text = "Playlist no longer exists"
		_rebuild_preserving_selection()
		return
	_playlist_id = playlist_id
	_mode = "playlist_detail"
	_selected = 0
	_rebuild()


func _add_track_to_playlist(track_id: String) -> void:
	var tracks: Array = _host.playlist_tracks(_playlist_id)
	if tracks.has(track_id):
		_status.text = "Already in the playlist"
		return
	tracks.append(track_id)
	var result: Dictionary = _host.cmd_playlist_set_tracks(_playlist_id, tracks)
	# Rebuild before reporting: the rebuild resets the status line.
	_rebuild_preserving_selection()
	if bool(result.get("ok", false)):
		_status.text = "Added: %s" % _host.audio_track_title(track_id)
	else:
		_status.text = String(result.get("message", ""))


func _remove_playlist_track(index: int) -> void:
	var tracks: Array = _host.playlist_tracks(_playlist_id)
	if index < 0 or index >= tracks.size():
		return
	var title: String = _host.audio_track_title(String(tracks[index]))
	tracks.remove_at(index)
	var result: Dictionary = _host.cmd_playlist_set_tracks(_playlist_id, tracks)
	# Rebuild before reporting: the rebuild resets the status line.
	_rebuild_preserving_selection()
	if bool(result.get("ok", false)):
		_status.text = "Removed: %s" % title
	else:
		_status.text = String(result.get("message", ""))


func _move_playlist_track(index: int, delta: int) -> void:
	var tracks: Array = _host.playlist_tracks(_playlist_id)
	var target: int = index + delta
	if index < 0 or index >= tracks.size() or target < 0 or target >= tracks.size():
		return
	var swapped = tracks[index]
	tracks[index] = tracks[target]
	tracks[target] = swapped
	_host.cmd_playlist_set_tracks(_playlist_id, tracks)
	_rebuild_preserving_selection()


func _play_playlist_in_order(playlist_id: String) -> void:
	# Left/Right on a catalog playlist row: same action as the editor's
	# Play In Order.
	var result: Dictionary = _host.cmd_playlist_play(playlist_id)
	_rebuild_preserving_selection()
	_status.text = String(result.get("message", ""))


func _play_library_track(track_id: String) -> void:
	# Catalog library row: play one song immediately as Single.
	var result: Dictionary = _host.cmd_music_play_track(track_id)
	_rebuild_preserving_selection()
	_status.text = String(result.get("message", ""))


func _playlist_is_ordered_source() -> bool:
	# True when the detail playlist is the active ordered-playback source.
	return _host.active_playlist_id() == _playlist_id and _host.settings.music_mode == "playlist"


func _playlist_is_shuffle_source() -> bool:
	# True when the detail playlist is the active playlist-scoped shuffle
	# source.
	return (
		_host.active_playlist_id() == _playlist_id
		and _host.settings.music_mode == "shuffle"
		and _host.settings.music_shuffle_source == "playlist"
	)


func _enter_playlist_delete() -> void:
	# Confirmation state: remember the catalog position so the selection
	# after delete/cancel is deterministic.
	var playlists: Array = _host.playlists()
	_playlist_delete_index = 0
	for i in playlists.size():
		if String(playlists[i]["id"]) == _playlist_id:
			_playlist_delete_index = i
			break
	_mode = "playlist_delete"
	_selected = 0
	_rebuild()


func _confirm_playlist_delete() -> void:
	var result: Dictionary = _host.cmd_playlist_delete(_playlist_id)
	_mode = "playlist"
	_selected = 0
	_rebuild()
	_status.text = String(result.get("message", ""))
	_select_playlist_after_delete()


func _cancel_playlist_delete() -> void:
	_mode = "playlist"
	_selected = 0
	_rebuild()
	_select_playlist_row(_playlist_id)
	_status.text = "Delete cancelled"


## Deterministic post-delete selection: the playlist that took the deleted
## one's position (or the new last one, or the Create row when none
## remain).
func _select_playlist_after_delete() -> void:
	var item_rows: Array = []
	var create_row := -1
	for i in _rows.size():
		if String(_rows[i].get("kind")) == "playlist_item":
			item_rows.append(i)
		if String(_rows[i].get("kind")) == "command" and String(_rows[i].get("id")) == "playlist_create":
			create_row = i
	if item_rows.is_empty():
		if create_row >= 0:
			_selected = create_row
			_render_rows()
		return
	_selected = item_rows[mini(_playlist_delete_index, item_rows.size() - 1)]
	_render_rows()


func _select_playlist_row(playlist_id: String) -> void:
	for i in _rows.size():
		var row: Dictionary = _rows[i]
		if String(row.get("kind")) == "playlist_item" and String(row.get("id")) == playlist_id and _is_selectable(i):
			_selected = i
			_render_rows()
			return


func _rebuild_preserving_selection() -> void:
	# Keep the cursor on the same logical row (identified by kind plus
	# track id, or label for commands) across playlist mutations and
	# rescans that shift row indexes.
	var anchor := {}
	if _selected >= 0 and _selected < _rows.size():
		var row: Dictionary = _rows[_selected]
		anchor = {"kind": row.get("kind", ""), "key": row.get("id", row.get("label", ""))}
	_rebuild()
	if anchor.is_empty():
		return
	for i in _rows.size():
		var row: Dictionary = _rows[i]
		if row.get("kind", "") == anchor["kind"] and row.get("id", row.get("label", "")) == anchor["key"] and _is_selectable(i):
			_selected = i
			_render_rows()
			return


func _play_nav_sfx(name: String) -> void:
	if _host != null:
		_host.play_ui_sfx(name)


# ---------------------------------------------------------------- capture

func _selected_row() -> Dictionary:
	if _selected < 0 or _selected >= _rows.size():
		return {}
	return _rows[_selected]


func _on_captured(record: Dictionary) -> void:
	if _capture.mode == BindingCapture.MODE_CONTROLLER:
		_on_controller_captured(record)
		return
	var row: Dictionary = _selected_row()
	if row.get("kind") != "binding":
		return
	var action: String = row["action"]
	var profile: Dictionary = _kb_profile
	if _has_matching(profile.get(action, []), record):
		_status.text = "Already bound to this action"
		return
	var conflict := DefaultBindings.find_conflict(profile, action, record)
	if not conflict.is_empty():
		_status.text = "Already used by: %s" % _action_label(conflict)
		return
	var records: Array = []
	for existing in profile.get(action, []):
		records.append(existing)
	if records.size() >= MAX_PER_CATEGORY:
		records.resize(MAX_PER_CATEGORY - 1)
	records.append(record)
	profile[action] = records
	_remove_records_from_other_actions(action, [record])
	_commit_bindings()
	_status.text = "Bound: %s" % DefaultBindings.record_display_name(record)


func _on_cleared() -> void:
	var row: Dictionary = _selected_row()
	if row.get("kind") != "binding":
		return
	var action: String = row["action"]
	var records: Array = []
	for existing in _kb_profile.get(action, []):
		records.append(existing)
	if records.is_empty():
		_status.text = "Nothing to clear"
		return
	records.remove_at(records.size() - 1)
	_kb_profile[action] = records
	_commit_bindings()
	_status.text = "Cleared latest keyboard binding"


func _on_capture_cancelled() -> void:
	if _capture.mode == BindingCapture.MODE_CONTROLLER:
		if _mode == "padbind" and _pad_stage != PAD_STAGE_IDLE:
			_cancel_padbind()
			_status.text = "Controller binding cancelled"
		return
	_status.text = "Capture cancelled"


# ----------------------------------------------------------------- resets

func _reset_action(action: String) -> void:
	var defaults := DefaultBindings.default_keyboard_profile()
	var records: Array = []
	for record in defaults[action]:
		records.append(record)
	_kb_profile[action] = records
	_remove_records_from_other_actions(action, records)
	_commit_bindings()


func _reset_category(_category: String) -> void:
	_kb_profile = DefaultBindings.default_keyboard_profile()
	_dedupe_profile(_kb_profile)
	_commit_bindings()


func _remove_records_from_other_actions(action: String, records: Array) -> void:
	var profile: Dictionary = _kb_profile
	for other in profile:
		if other == action:
			continue
		var kept: Array = []
		for record in profile[other]:
			if not _has_matching(records, record):
				kept.append(record)
		profile[other] = kept


static func _has_matching(records: Array, record: Dictionary) -> bool:
	for other in records:
		if DefaultBindings.record_matches(other, record):
			return true
	return false


func _dedupe_profile(profile: Dictionary) -> void:
	# Keep the first occurrence of every record in ACTION_NAMES order.
	var seen: Array = []
	for action in DefaultBindings.ACTION_NAMES:
		var kept: Array = []
		for record in profile.get(action, []):
			if _has_matching(seen, record):
				continue
			seen.append(record)
			kept.append(record)
		profile[action] = kept


# ----------------------------------------------------------------- helpers

func _category_records(action: String) -> Array:
	return DefaultBindings.records_for_category(_kb_profile.get(action, []), "keyboard")


func _update_toggle_status(row: Dictionary) -> void:
	# The normalization toggle reports its policy concisely, including a
	# live measurement or, while active, the analyzed track.
	if row.get("field") != "normalize_custom_music":
		return
	if _host.settings.normalize_custom_music:
		_status.text = _host.audio_normalization_status() if _host.audio_normalization_active() else "Custom tracks play at a matched loudness"
	else:
		_status.text = "Custom tracks play at their original volume"


func _commit_values() -> void:
	_host.cmd_settings_changed()
	_render_rows()


func _commit_bindings() -> void:
	## Commit the working copy to the target profile atomically, then
	## re-read the sanitized result so the page and the profile stay in
	## sync (sanitation may drop invalid records).
	if _host.cmd_keyboard_bindings_captured(_kb_profile_id, _kb_profile):
		_kb_profile = _host.settings.keyboard_bindings_for(_kb_profile_id)
	_render_rows()
