extends Node
## Theme manager: discovers built-in (`res://themes/`), portable (loose
## `themes/` folder beside the exported executable), and custom
## (`user://themes/`) `.theme` files, keeps a deterministic selectable list,
## tracks the selection, and exposes resolved tokens plus resolved media
## presentation (loaded backdrop images/fonts/piece skins, video paths,
## dither settings). Pure data + file IO; applying to presentation nodes is
## the host's job.

const ThemeProfile = preload("res://scripts/ui/theme_profile.gd")

## Entries: {id, name, source, path, tokens, media, diagnostics}. Built-ins
## first, then portable/user files, each group sorted by display name.
## `media` is the resolved presentation: menu/game backdrop specs
## {color, texture, video_path, fit, opacity, tint}, font/title_font, a
## per-letter skin texture map, and pieces dither/bloom settings. Invalid
## files are never selectable but are kept in `invalid` for the settings
## diagnostics.
var entries: Array = []
var invalid: Array = []
var selected_id: String = ""

var _builtin_dir := "res://themes"
var _portable_dir := ""
var _user_dir := "user://themes"

## Resolved-path -> loaded resource caches, rebuilt on every scan so
## edited or added assets reload with "Reload Themes" instead of serving
## stale resources. Failed loads cache null for the rest of the scan.
var _texture_cache := {}
var _font_cache := {}


func setup(
	builtin_dir: String = "res://themes",
	user_dir: String = "user://themes",
	portable_dir: String = ""
) -> void:
	_builtin_dir = builtin_dir
	_user_dir = user_dir
	_portable_dir = portable_dir
	scan()


func scan() -> void:
	entries = []
	invalid = []
	_texture_cache = {}
	_font_cache = {}
	_scan_dir(_builtin_dir, "builtin")
	_scan_portable_dir(_portable_dir)
	_scan_dir(_user_dir, "user")
	entries.sort_custom(_builtin_first_then_name)
	var seen_ids := {}
	var kept: Array = []
	for entry in entries:
		if seen_ids.has(entry["id"]):
			continue
		seen_ids[entry["id"]] = true
		kept.append(entry)
	entries = kept
	if not has_theme(selected_id):
		selected_id = ThemeProfile.DEFAULT_THEME_ID


func _scan_dir(dir: String, source: String) -> void:
	# A missing user directory is an empty custom library, never an error.
	if not DirAccess.dir_exists_absolute(dir):
		return
	var paths: Array = []
	var da := DirAccess.open(dir)
	if da == null:
		return
	da.list_dir_begin()
	var file := da.get_next()
	while not file.is_empty():
		if not da.current_is_dir() and file.get_extension().to_lower() == "theme":
			paths.append(file)
		file = da.get_next()
	da.list_dir_end()
	paths.sort()
	for theme_file in paths:
		var path := dir.path_join(theme_file)
		var id := "%s:%s" % [source, theme_file.get_basename()]
		var loaded := _load_theme_file(id, path)
		if not loaded["ok"]:
			invalid.append({"id": id, "path": path, "diagnostics": loaded["diagnostics"]})
			continue
		var entry: Dictionary = loaded["entry"]
		entry["source"] = source
		if not loaded["diagnostics"].is_empty():
			# Keep per-property and asset diagnostics for the status line.
			invalid.append({"id": id, "path": path, "diagnostics": loaded["diagnostics"], "soft": true})
		entries.append(entry)


func _scan_portable_dir(dir: String) -> void:
	## Loose folder shipped beside the executable ("open files" install): a
	## file sharing a built-in's basename replaces that built-in in place,
	## keeping its id (so persisted selections keep working) and its
	## built-in identity; any other file adds a "portable:" entry. A broken
	## override never removes the packaged built-in: the invalid file is
	## only reported for the settings status line.
	if dir.is_empty() or not DirAccess.dir_exists_absolute(dir):
		return
	var da := DirAccess.open(dir)
	if da == null:
		return
	var paths: Array = []
	da.list_dir_begin()
	var file := da.get_next()
	while not file.is_empty():
		if not da.current_is_dir() and file.get_extension().to_lower() == "theme":
			paths.append(file)
		file = da.get_next()
	da.list_dir_end()
	paths.sort()
	for theme_file in paths:
		var path := dir.path_join(theme_file)
		var id: String = "portable:" + theme_file.get_basename()
		var builtin_id: String = "builtin:" + theme_file.get_basename()
		var loaded := _load_theme_file(id, path)
		if not loaded["ok"]:
			invalid.append({"id": id, "path": path, "diagnostics": loaded["diagnostics"]})
			continue
		if not loaded["diagnostics"].is_empty():
			# Keep per-property and asset diagnostics for the status line;
			# the valid overrides still apply.
			invalid.append({"id": id, "path": path, "diagnostics": loaded["diagnostics"], "soft": true})
		var entry: Dictionary = loaded["entry"]
		var source := "portable"
		if has_theme(builtin_id):
			id = builtin_id
			source = "builtin"
		entry["id"] = id
		entry["source"] = source
		if source == "builtin":
			for i in entries.size():
				if entries[i]["id"] == builtin_id:
					entries[i] = entry
					break
		else:
			entries.append(entry)


## Parses and resolves one .theme file: tokens from color overrides, the
## media presentation from declared metadata (assets resolved and loaded
## against this file's actual location), and merged soft diagnostics.
## Returns {"ok", "entry", "diagnostics"}; entry["source"] is set by the
## scanning caller.
func _load_theme_file(id: String, path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {"ok": false, "entry": {}, "diagnostics": ["file unreadable"]}
	var text := f.get_as_text()
	f.close()
	var result: Dictionary = ThemeProfile.parse(text)
	if not result["valid"]:
		return {"ok": false, "entry": {}, "diagnostics": result["diagnostics"]}
	var tokens: Dictionary = ThemeProfile.resolve(result["overrides"])
	var media: Dictionary = ThemeProfile.resolve_media(result["media"])
	var asset_diags: Array[String] = []
	var presentation := _resolve_presentation(path, tokens, media, asset_diags)
	var diagnostics: Array = (result["diagnostics"] as Array).duplicate()
	diagnostics.append_array(asset_diags)
	return {
		"ok": true,
		"entry": {
			"id": id,
			"name": result["name"],
			"path": path,
			"tokens": tokens,
			"media": presentation,
			"diagnostics": diagnostics,
		},
		"diagnostics": diagnostics,
	}


## Builds the resolved presentation shared by the host and renderers:
## backdrop specs (media with per-block fit/opacity/tint), fonts (title
## font falls back to the body font), per-piece skins, dithering, and the
## independent numeric playfield bloom intensity.
func _resolve_presentation(theme_path: String, tokens: Dictionary, media: Dictionary, diags: Array[String]) -> Dictionary:
	var skins := {}
	for letter in ["i", "o", "t", "s", "z", "j", "l"]:
		skins[letter] = _load_image_texture(theme_path, media["pieces." + letter], diags, "piece skin " + letter)
	var font: Font = null
	if not String(media["theme.font"]).is_empty():
		font = _load_font(theme_path, media["theme.font"], diags, "theme font")
	var title_font: Font = null
	if not String(media["theme.title_font"]).is_empty():
		title_font = _load_font(theme_path, media["theme.title_font"], diags, "theme title font")
	if title_font == null:
		title_font = font
	return {
		"menu": _resolve_backdrop(theme_path, tokens["theme.background"], "theme", media, diags),
		"game": _resolve_backdrop(theme_path, tokens["game.background"], "game", media, diags),
		"font": font,
		"title_font": title_font,
		"skins": skins,
		"dither": media["pieces.dither"],
		"dither_strength": media["pieces.dither_strength"],
		"bloom": media["pieces.bloom"],
	}


func _resolve_backdrop(theme_path: String, fallback_color: Color, block: String, media: Dictionary, diags: Array[String]) -> Dictionary:
	# Backdrop precedence is applied by the host: valid video, then valid
	# image, then the themed color. Missing/invalid assets produce soft
	# diagnostics here and fall through without rejecting the theme.
	var video_path := ""
	if not String(media[block + ".video"]).is_empty():
		if not ClassDB.class_exists("VideoStreamTheora"):
			diags.append("%s video: video playback not supported in this build" % block)
		else:
			video_path = _resolve_video_path(theme_path, media[block + ".video"], diags, block + " video")
	var texture: Texture2D = null
	if not String(media[block + ".image"]).is_empty():
		texture = _load_image_texture(theme_path, media[block + ".image"], diags, block + " image")
	return {
		"color": fallback_color,
		"texture": texture,
		"video_path": video_path,
		"fit": media[block + ".fit"],
		"opacity": media[block + ".opacity"],
		"tint": media[block + ".tint"],
	}


## Resolves a declared relative path against the theme file's directory,
## confined to that directory (no traversal outside it). Returns "" with a
## soft diagnostic when the path escapes or the file is missing.
func _resolve_asset(theme_path: String, rel: String, diags: Array[String], label: String) -> String:
	if rel.is_empty():
		return ""
	var confined := ThemeProfile.confine(rel)
	if confined.is_empty():
		diags.append("%s: path escapes the theme folder (%s)" % [label, rel])
		return ""
	var resolved := theme_path.get_base_dir().path_join(confined)
	if not FileAccess.file_exists(resolved):
		diags.append("%s: file missing (%s)" % [label, rel])
		return ""
	return resolved


func _load_image_texture(theme_path: String, rel: String, diags: Array[String], label: String) -> Texture2D:
	var resolved := _resolve_asset(theme_path, rel, diags, label)
	if resolved.is_empty():
		return null
	if _texture_cache.has(resolved):
		return _texture_cache[resolved]
	var texture: Texture2D = null
	if resolved.begins_with("res://"):
		# Built-in assets ship as imported resources (editor and PCK):
		# prefer the imported form before raw buffer decoding.
		var imported = load(resolved)
		if imported is Texture2D:
			texture = imported
	if texture == null:
		texture = _decode_image_file(resolved)
	if texture == null:
		diags.append("%s: unreadable file (%s)" % [label, rel])
	_texture_cache[resolved] = texture
	return texture


func _load_font(theme_path: String, rel: String, diags: Array[String], label: String) -> Font:
	var resolved := _resolve_asset(theme_path, rel, diags, label)
	if resolved.is_empty():
		return null
	if _font_cache.has(resolved):
		return _font_cache[resolved]
	var font: Font = null
	if resolved.begins_with("res://"):
		var imported = load(resolved)
		if imported is Font:
			font = imported
	if font == null:
		font = _load_dynamic_font(resolved, rel, diags, label)
	_font_cache[resolved] = font
	return font


func _resolve_video_path(theme_path: String, rel: String, diags: Array[String], label: String) -> String:
	var resolved := _resolve_asset(theme_path, rel, diags, label)
	if resolved.is_empty():
		return ""
	if not _ogg_magic_ok(resolved):
		diags.append("%s: not a valid video file (%s)" % [label, rel])
		return ""
	return resolved


## Decodes a loose image file (user://, portable folder, or raw file inside
## the PCK) from its bytes; import-free so modded files need no editor.
static func _decode_image_file(path: String) -> Texture2D:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	var buffer := f.get_buffer(f.get_length())
	f.close()
	var img := Image.new()
	var err := ERR_FILE_UNRECOGNIZED
	match path.get_extension().to_lower():
		"png": err = img.load_png_from_buffer(buffer)
		"jpg", "jpeg": err = img.load_jpg_from_buffer(buffer)
		"webp": err = img.load_webp_from_buffer(buffer)
	if err != OK or img.is_empty() or img.get_width() < 1 or img.get_height() < 1:
		return null
	return ImageTexture.create_from_image(img)


## Loads a loose TTF/OTF at runtime. The magic check keeps corrupt files
## from reaching FreeType (which would spam errors on first use); it also
## serves as the invalid-font diagnostic gate.
static func _load_dynamic_font(path: String, rel: String, diags: Array[String], label: String) -> Font:
	if not _font_magic_ok(path):
		diags.append("%s: not a valid font file (%s)" % [label, rel])
		return null
	var font := FontFile.new()
	if font.load_dynamic_font(path) != OK:
		diags.append("%s: not a valid font file (%s)" % [label, rel])
		return null
	return font


static func _font_magic_ok(path: String) -> bool:
	# TrueType (\x00\x01\x00\x00), CFF OpenType ("OTTO"), legacy ("true"),
	# and collections ("ttcf").
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return false
	var magic := f.get_buffer(4)
	f.close()
	return magic == PackedByteArray([0x00, 0x01, 0x00, 0x00]) \
		or magic == PackedByteArray([0x4F, 0x54, 0x54, 0x46]) \
		or magic == PackedByteArray([0x74, 0x72, 0x75, 0x65]) \
		or magic == PackedByteArray([0x74, 0x74, 0x63, 0x66])


static func _ogg_magic_ok(path: String) -> bool:
	# Ogg containers start with "OggS".
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return false
	var magic := f.get_buffer(4)
	f.close()
	return magic == PackedByteArray([0x4F, 0x67, 0x67, 0x53])


static func _builtin_first_then_name(a: Dictionary, b: Dictionary) -> bool:
	if a["source"] != b["source"]:
		return a["source"] == "builtin"
	return String(a["name"]) < String(b["name"])


func has_theme(id: String) -> bool:
	for entry in entries:
		if entry["id"] == id:
			return true
	return false


func entry(id: String) -> Dictionary:
	for e in entries:
		if e["id"] == id:
			return e
	return {}


## Select a known theme; unknown ids keep the current selection.
func select(id: String) -> bool:
	if has_theme(id):
		selected_id = id
		return true
	return false


## Select `preferred` when it exists, otherwise repair to the Modern Neon
## default. Returns the applied id.
func select_valid(preferred: String) -> String:
	if not preferred.is_empty() and select(preferred):
		return selected_id
	select(ThemeProfile.DEFAULT_THEME_ID)
	return selected_id


## Rescan for files added/edited while running. Keeps the selection when the
## file still exists and parses; otherwise repairs to the default. Returns
## { "repaired": bool, "lost": String }.
func reload() -> Dictionary:
	var previous := selected_id
	scan()
	var repaired := false
	if not previous.is_empty() and not has_theme(previous):
		select_valid(previous)
		repaired = selected_id != previous
	return {"repaired": repaired, "lost": previous if repaired else ""}


func selected_entry() -> Dictionary:
	return entry(selected_id)


## Resolved tokens of the selected theme (defaults when nothing matches).
func tokens() -> Dictionary:
	var e := selected_entry()
	if e.is_empty():
		return ThemeProfile.default_tokens()
	return e["tokens"]


## Resolved media presentation of the selected theme (color-only defaults
## when nothing matches).
func media() -> Dictionary:
	var e := selected_entry()
	if e.is_empty():
		return default_media_presentation()
	return e["media"]


## Presentation for themes without media declarations: color-only
## backdrops from the default tokens, no fonts, no skins, no dither or
## bloom.
func default_media_presentation() -> Dictionary:
	var empty_diags: Array[String] = []
	return _resolve_presentation("", ThemeProfile.default_tokens(), ThemeProfile.default_media(), empty_diags)


func user_dir_hint() -> String:
	return ProjectSettings.globalize_path(_user_dir)


func ensure_user_dir() -> void:
	# Lazily created on reload so users can drop files in.
	DirAccess.make_dir_recursive_absolute(_user_dir)
