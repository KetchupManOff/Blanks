extends RefCounted
## Versioned settings model and JSON persistence. Pure data: storing,
## validating, and serializing. Applying display/audio values is the host's
## job; this class never touches DisplayServer or AudioServer.
##
## Schema v2 replaces the single global mixed binding profile with:
## - `keyboard_bindings`: one shared keyboard-only profile for every mode.
## - `profiles`: a list of player profiles, each owning a controller-only
##   action mapping and the best results per stable mode key.
## - `active_profile_id`: the profile used by the next solo run.
## Version-1 files migrate transparently: the keyboard category becomes
## the shared keyboard profile and the controller category seeds a
## "Player 1" profile.

const DefaultBindings = preload("res://scripts/input/default_bindings.gd")
const ModeRules = preload("res://scripts/core/mode_rules.gd")

const DEFAULT_PATH := "user://settings.json"
const SCHEMA_VERSION := 2
const SUPPORTED_WINDOW_SCALES := [1, 2, 3]
## Music selection lives under the "audio" section as additive optional
## fields: older files without them keep loading with defaults, which is
## the migration path for this schema addition.
const MUSIC_MODES := ["off", "single", "playlist", "shuffle"]
## Default selected theme ID (Modern Neon Arcade); resolved against the
## discovered theme list by the host's theme manager.
const DEFAULT_THEME_ID := "builtin:modern_neon"
## Profile display names: non-empty, single line, bounded length.
const MAX_NAME_LENGTH := 16
## Each profile keeps at most this many results per mode key.
const MAX_RESULTS_PER_MODE := 5
## Fallback name for the first/default profile.
const DEFAULT_PROFILE_NAME := "Player 1"
## Known top-level keys; anything else is preserved as an unknown field.
const _OWNED_TOP_LEVEL := ["version", "display", "audio", "keyboard_bindings", "profiles", "active_profile_id"]

var fullscreen: bool = false
var window_scale: int = 1
## Selected visual theme under the "display" section as an
## additive optional field. Any string loads; an unknown/nonexistent ID is
## repaired by the theme manager to the default without blocking startup.
var theme_id: String = DEFAULT_THEME_ID
var master_volume: float = 1.0
var music_volume: float = 0.8
var sfx_volume: float = 1.0
var music_mode: String = "single"
var music_track: String = ""
## Optional separate track for the main menu. Empty means the menu follows
## the gameplay music mode/selection; a track ID makes the menu loop that
## track regardless of the gameplay music mode (additive field).
var menu_music_track: String = ""
var music_playlist: Array = []
## Keep user-provided tracks at a consistent perceived loudness. Enabled
## by default, including for settings files written before this field
## existed (absent means default).
var normalize_custom_music: bool = true
## Shared keyboard-only profile applied to the global InputMap.
var keyboard_bindings: Dictionary = {}
## Player profiles: Array of {id, name, controller_bindings, results}.
var profiles: Array = []
## ID of the profile used by the next solo run.
var active_profile_id: String = ""
var extra_fields: Dictionary = {}


func _init() -> void:
	_reset_to_defaults()


func _reset_to_defaults() -> void:
	fullscreen = false
	window_scale = 1
	theme_id = DEFAULT_THEME_ID
	master_volume = 1.0
	music_volume = 0.8
	sfx_volume = 1.0
	music_mode = "single"
	music_track = ""
	menu_music_track = ""
	music_playlist = []
	normalize_custom_music = true
	keyboard_bindings = DefaultBindings.default_keyboard_profile()
	profiles = [default_profile_record(DEFAULT_PROFILE_NAME, [])]
	active_profile_id = profiles[0]["id"]
	extra_fields = {}


func reset_to_defaults() -> void:
	_reset_to_defaults()


# ------------------------------------------------------------- serialization

func to_dict() -> Dictionary:
	var display := {"fullscreen": fullscreen, "window_scale": window_scale, "theme_id": theme_id}
	var audio := {
		"master_volume": master_volume,
		"music_volume": music_volume,
		"sfx_volume": sfx_volume,
		"music_mode": music_mode,
		"music_track": music_track,
		"menu_music_track": menu_music_track,
		"music_playlist": music_playlist.duplicate(),
		"normalize_custom_music": normalize_custom_music,
	}
	var out := {
		"version": SCHEMA_VERSION,
		"display": display,
		"audio": audio,
		"keyboard_bindings": keyboard_bindings,
		"active_profile_id": active_profile_id,
		"profiles": _profiles_deep_copy(profiles),
	}
	for key in extra_fields:
		out[key] = extra_fields[key]
	return out


func save(path: String = DEFAULT_PATH) -> bool:
	# Atomic write: write to a temp file, then replace the target only after
	# the full payload is on disk so a crash never leaves a partial file.
	var tmp := path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify(to_dict(), "\t"))
	var write_error: int = f.get_error()
	f.close()
	if write_error != OK:
		return false
	if FileAccess.file_exists(path):
		var rm_error := DirAccess.remove_absolute(path)
		if rm_error != OK:
			return false
	return DirAccess.rename_absolute(tmp, path) == OK


# -------------------------------------------------------------------- loading

func load(path: String = DEFAULT_PATH) -> bool:
	## Resets to defaults, then loads/validates the file. Returns true when a
	## compatible file was applied (including a migrated v1 file). Missing
	## or unusable files leave defaults.
	_reset_to_defaults()
	if not FileAccess.file_exists(path):
		return false
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return false
	var text := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(text)
	if parsed == null or not (parsed is Dictionary):
		return false
	return _apply_dict(parsed)


func _apply_dict(data: Dictionary) -> bool:
	# JSON parses every number as a float in Godot 4, so numeric fields are
	# coerced from integral floats too.
	var version := _as_int(data.get("version"), -1)
	match version:
		SCHEMA_VERSION:
			return _apply_v2(data)
		1:
			return _apply_v1(data)
	return false


func _apply_display(data: Dictionary) -> void:
	var display = data.get("display")
	if display is Dictionary:
		var fs = display.get("fullscreen")
		if fs is bool:
			fullscreen = fs
		var ws := _as_int(display.get("window_scale"), -1)
		if SUPPORTED_WINDOW_SCALES.has(ws):
			window_scale = ws
		# Any string is accepted here: whether the ID actually exists is the
		# theme manager's job (it repairs unknown IDs to the default).
		var theme = display.get("theme_id")
		if typeof(theme) == TYPE_STRING and not String(theme).is_empty():
			theme_id = theme


func _apply_audio(data: Dictionary) -> void:
	var audio = data.get("audio")
	if audio is Dictionary:
		master_volume = _sanitize_volume(audio.get("master_volume"), master_volume)
		music_volume = _sanitize_volume(audio.get("music_volume"), music_volume)
		sfx_volume = _sanitize_volume(audio.get("sfx_volume"), sfx_volume)
		var mode = audio.get("music_mode")
		if typeof(mode) == TYPE_STRING and MUSIC_MODES.has(mode):
			music_mode = mode
		var track = audio.get("music_track")
		if typeof(track) == TYPE_STRING:
			music_track = track
		var menu_track = audio.get("menu_music_track")
		if typeof(menu_track) == TYPE_STRING:
			menu_music_track = menu_track
		var playlist = audio.get("music_playlist")
		if typeof(playlist) == TYPE_ARRAY:
			music_playlist = _sanitize_playlist(playlist)
		var normalize = audio.get("normalize_custom_music")
		if normalize is bool:
			normalize_custom_music = normalize


func _apply_v2(data: Dictionary) -> bool:
	_apply_display(data)
	_apply_audio(data)
	# Keyboard sanitation keeps intentionally empty actions empty.
	keyboard_bindings = DefaultBindings.sanitize_category_profile(data.get("keyboard_bindings"), "keyboard")
	profiles = sanitize_profiles(data.get("profiles"))
	active_profile_id = _resolve_active_id(data.get("active_profile_id"), profiles)
	_collect_extra(data)
	return true


func _apply_v1(data: Dictionary) -> bool:
	# Migration: keep the display/audio sections verbatim, split the mixed
	# binding profile, and seed a "Player 1" profile with the old controller
	# category. There are no v1 profiles or high scores to carry over.
	_apply_display(data)
	_apply_audio(data)
	var mixed := DefaultBindings.sanitize_profile(data.get("bindings"))
	keyboard_bindings = DefaultBindings.category_profile(mixed, "keyboard")
	var migrated := default_profile_record(DEFAULT_PROFILE_NAME, [])
	migrated["controller_bindings"] = DefaultBindings.category_profile(mixed, "controller")
	profiles = [migrated]
	active_profile_id = migrated["id"]
	_collect_extra(data)
	return true


func _collect_extra(data: Dictionary) -> void:
	for key in data:
		if not _OWNED_TOP_LEVEL.has(key):
			extra_fields[key] = data[key]


func _resolve_active_id(raw, sanitized: Array) -> String:
	# An unknown, missing, or duplicate active id recovers to the first
	# profile so the settings stay usable without losing anything else.
	if typeof(raw) == TYPE_STRING and not String(raw).is_empty():
		for profile in sanitized:
			if profile["id"] == raw:
				return raw
	if not sanitized.is_empty():
		return sanitized[0]["id"]
	return ""


# ------------------------------------------------------------------ profiles

static func sanitize_profile_name(name, fallback: String) -> String:
	## Non-empty single-line display name, whitespace collapsed, bounded.
	var text := ""
	if name is String:
		text = name
	elif name is float or name is int:
		text = str(name)
	text = text.strip_edges().replace("\n", " ").replace("\t", " ")
	while text.contains("  "):
		text = text.replace("  ", " ")
	if text.length() > MAX_NAME_LENGTH:
		text = text.substr(0, MAX_NAME_LENGTH).strip_edges()
	if text.is_empty():
		return fallback
	return text


static func fresh_profile_id(existing_ids: Array) -> String:
	## Stable, unique, deterministic id for a new profile: the first
	## "p1", "p2", ... not already taken.
	var index := 1
	var candidate := "p1"
	while existing_ids.has(candidate):
		index += 1
		candidate = "p%d" % index
	return candidate


static func default_profile_record(name: String, existing_ids: Array = []) -> Dictionary:
	var id := fresh_profile_id(existing_ids)
	return {
		"id": id,
		"name": sanitize_profile_name(name, "Player"),
		"controller_bindings": DefaultBindings.default_controller_profile(),
		"results": {},
	}


static func sanitize_profiles(raw) -> Array:
	## Recovers any usable profiles; a missing or fully corrupt section
	## yields one fresh default profile. Unrelated settings are untouched.
	var out: Array = []
	var ids: Array = []
	if raw is Array:
		for entry in raw:
			var record := sanitize_profile_record(entry, ids)
			if record.is_empty():
				continue
			ids.append(record["id"])
			out.append(record)
	if out.is_empty():
		out = [default_profile_record(DEFAULT_PROFILE_NAME, ids)]
	return out


static func sanitize_profile_record(entry, reserved_ids: Array = []) -> Dictionary:
	if not (entry is Dictionary):
		return {}
	var id := String(entry.get("id", ""))
	if id.is_empty():
		# Recover an id-less entry instead of dropping its bindings/results.
		id = fresh_profile_id(reserved_ids)
	var name := sanitize_profile_name(entry.get("name", ""), "Player")
	var bindings := DefaultBindings.sanitize_category_profile(entry.get("controller_bindings"), "controller")
	var results := sanitize_results(entry.get("results"))
	return {"id": id, "name": name, "controller_bindings": bindings, "results": results}


func find_profile(profile_id: String) -> Dictionary:
	## The profile record with this id, or {} when it does not exist.
	for profile in profiles:
		if profile["id"] == profile_id:
			return profile
	return {}


func profile_name(profile_id: String) -> String:
	var profile := find_profile(profile_id)
	if profile.is_empty():
		return ""
	return profile["name"]


func active_profile() -> Dictionary:
	return find_profile(active_profile_id)


func active_profile_name() -> String:
	var name := profile_name(active_profile_id)
	return name if not name.is_empty() else DEFAULT_PROFILE_NAME


func profile_name_taken(name: String, exclude_id: String = "") -> bool:
	## Case-insensitive duplicate display-name check for create/rename.
	var cleaned := sanitize_profile_name(name, "")
	for profile in profiles:
		if profile["id"] == exclude_id:
			continue
		if profile["name"].to_lower() == cleaned.to_lower():
			return true
	return false


func create_profile(name: String) -> String:
	## Appends a new profile and returns its id; "" when the sanitized name
	## duplicates an existing profile (callers validate first, this guards).
	var cleaned := sanitize_profile_name(name, "")
	if cleaned.is_empty() or profile_name_taken(cleaned):
		return ""
	var ids: Array = []
	for profile in profiles:
		ids.append(profile["id"])
	var record := default_profile_record(cleaned, ids)
	profiles.append(record)
	return record["id"]


func rename_profile(profile_id: String, name: String) -> bool:
	var profile := find_profile(profile_id)
	if profile.is_empty():
		return false
	var cleaned := sanitize_profile_name(name, "")
	if cleaned.is_empty() or profile_name_taken(cleaned, profile_id):
		return false
	profile["name"] = cleaned
	return true


func set_active_profile(profile_id: String) -> bool:
	if find_profile(profile_id).is_empty():
		return false
	active_profile_id = profile_id
	return true


func controller_bindings_for(profile_id: String) -> Dictionary:
	## Sanitized copy of a profile's controller-only bindings; {} when the
	## profile does not exist.
	var profile := find_profile(profile_id)
	if profile.is_empty():
		return {}
	return (profile["controller_bindings"] as Dictionary).duplicate(true)


# ------------------------------------------------------------------- results

func append_result(profile_id: String, mode_key: String, result: Dictionary, higher_is_better: bool) -> int:
	## Appends one finished-run record to the profile's history for the mode
	## key, keeps it sorted by the supplied ranking rule (stable for ties:
	## new entries go after equal ones), trims to the best five, and
	## returns the 1-based placement of this run (0 on rejection).
	var profile := find_profile(profile_id)
	if profile.is_empty() or typeof(mode_key) != TYPE_STRING or mode_key.is_empty():
		return 0
	var clean := sanitize_result(result, mode_key)
	if clean.is_empty():
		return 0
	var history: Array = (profile["results"] as Dictionary).get(mode_key, [])
	var index := history.size()
	for i in history.size():
		if _result_better(clean, history[i], higher_is_better):
			index = i
			break
	history.insert(index, clean)
	if history.size() > MAX_RESULTS_PER_MODE:
		history.resize(MAX_RESULTS_PER_MODE)
	profile["results"][mode_key] = history
	var placement := history.find(clean) + 1
	return placement if placement > 0 else 0


func profile_history(profile_id: String, mode_key: String) -> Array:
	## The stored records for one mode key (best first), or [].
	var profile := find_profile(profile_id)
	if profile.is_empty():
		return []
	var history = (profile["results"] as Dictionary).get(mode_key, [])
	if history is Array:
		return history
	return []


static func _result_better(a: Dictionary, b: Dictionary, higher_is_better: bool) -> bool:
	if higher_is_better:
		return int(a["score"]) > int(b["score"])
	return float(a["elapsed"]) < float(b["elapsed"])


static func sanitize_result(result, mode_key: String) -> Dictionary:
	## Validates one result record; {} when unusable. Retains the metadata
	## needed for display and future rules: score, elapsed, completion
	## timestamp, player count, and mode key.
	if not (result is Dictionary):
		return {}
	var score := _as_int(result.get("score"), -1)
	if score < 0:
		return {}
	var elapsed = result.get("elapsed")
	if not (elapsed is int or elapsed is float) or float(elapsed) < 0.0:
		return {}
	var players := clampi(_as_int(result.get("players"), 1), 1, 4)
	var completed := maxi(0, _as_int(result.get("completed_at"), 0))
	var mode := String(result.get("mode", mode_key))
	if mode.is_empty():
		mode = mode_key
	return {
		"score": score,
		"elapsed": float(elapsed),
		"completed_at": completed,
		"players": players,
		"mode": mode,
	}


static func sanitize_results(raw) -> Dictionary:
	## Per-mode result histories: any non-empty mode key is kept (including
	## unknown future keys), records are validated, known modes are sorted
	## by their ranking rule (stable for ties: earlier completions first),
	## and each history is trimmed to the best five.
	var out := {}
	if not (raw is Dictionary):
		return out
	for key in raw:
		if typeof(key) != TYPE_STRING or String(key).is_empty():
			continue
		var mode_key := String(key)
		var history: Array = []
		if raw[key] is Array:
			for entry in raw[key]:
				var clean := sanitize_result(entry, mode_key)
				if not clean.is_empty():
					history.append(clean)
		out[mode_key] = _trim_history(history, mode_key)
	return out


static func _trim_history(history: Array, mode_key: String) -> Array:
	if history.size() <= MAX_RESULTS_PER_MODE:
		return history
	var descriptor: Dictionary = ModeRules.descriptor(mode_key)
	if descriptor.is_empty():
		# Unknown future mode: keep the stored order and the newest five.
		return history.slice(history.size() - MAX_RESULTS_PER_MODE)
	_sort_history_for_mode(history, descriptor["ranking"] == ModeRules.RANK_SCORE_DESC)
	return history.slice(0, MAX_RESULTS_PER_MODE)


static func _sort_history_for_mode(history: Array, higher_is_better: bool) -> void:
	# Deterministic order: metric first, completion timestamp breaks ties
	# (earlier completions rank first among equals).
	var comparator := func(a: Dictionary, b: Dictionary) -> bool:
		if higher_is_better:
			if int(a["score"]) != int(b["score"]):
				return int(a["score"]) > int(b["score"])
		else:
			if is_equal_approx(float(a["elapsed"]), float(b["elapsed"])):
				pass
			elif float(a["elapsed"]) < float(b["elapsed"]):
				return true
			else:
				return false
		return int(a["completed_at"]) < int(b["completed_at"])
	history.sort_custom(comparator)


# -------------------------------------------------------------------- helpers

static func _profiles_deep_copy(source: Array) -> Array:
	var out: Array = []
	for profile in source:
		if profile is Dictionary:
			out.append((profile as Dictionary).duplicate(true))
	return out


static func _sanitize_volume(value, fallback: float) -> float:
	if value is float or value is int:
		return clampf(float(value), 0.0, 1.0)
	return fallback


static func _sanitize_playlist(raw: Array) -> Array:
	# Structural sanitization only (strings, no duplicates, no empties);
	# checking IDs against the scanned audio library is the audio
	# manager's job because it knows which tracks exist.
	var out: Array = []
	var seen := {}
	for track_id in raw:
		if typeof(track_id) != TYPE_STRING or String(track_id).is_empty() or seen.has(track_id):
			continue
		out.append(track_id)
		seen[track_id] = true
	return out


static func _as_int(value, fallback: int) -> int:
	if value is int:
		return value
	if value is float and float(value) == floorf(float(value)):
		return int(value)
	return fallback
