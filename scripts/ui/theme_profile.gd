extends RefCounted
## Pure .theme parsing and token/media resolution. No file IO, no nodes:
## asset loading and presentation ownership live in theme_manager and the
## host. Paths are parsed as quoted relative paths, normalized and
## confined to the theme's directory here; file existence and decoding
## are the manager's job.

const DEFAULT_THEME_ID := "builtin:modern_neon"
const DEFAULT_TOKENS := {
	"theme.background": Color(0.02, 0.03, 0.05), "theme.text": Color(0.92, 0.94, 0.98), "theme.dim": Color(0.92, 0.94, 0.98, 0.55), "theme.accent": Color(0.13, 0.80, 0.93),
	"game.background": Color(0.02, 0.03, 0.05),
	"menu.panel": Color(0.055, 0.07, 0.18, 0.94), "menu.scrim": Color(0.02, 0.03, 0.05, 0.86), "menu.focus": Color(0.71, 1.0, 0.29), "menu.title_size": 56, "menu.item_size": 30, "menu.spacing": 14, "menu.transition": 0.15, "menu.split_gap": 48, "menu.split_padding": 44, "menu.detail_size": 18, "menu.divider": Color(1, 1, 1, 0.18),
	"board.bg": Color(0.06, 0.075, 0.095), "board.peek": Color(0.06, 0.075, 0.095, 0.35), "board.grid": Color(1, 1, 1, 0.045), "board.border": Color(1, 1, 1, 0.35), "board.ghost": Color(1, 1, 1, 0.1), "board.ghost_line": Color(1, 1, 1, 0.35), "board.flash": Color(1, 1, 1, 0.85), "board.section_line": Color(1, 1, 1, 0.25), "board.section_tint_alpha": 0.03,
	"players.p1": Color(0.13, 0.8, 0.93), "players.p2": Color(0.95, 0.72, 0.02), "players.p3": Color(0.1, 0.85, 0.38), "players.p4": Color(0.72, 0.22, 0.87),
	"pieces.i": Color(0.13, 0.8, 0.93), "pieces.o": Color(0.95, 0.72, 0.02), "pieces.t": Color(0.72, 0.22, 0.87), "pieces.s": Color(0.1, 0.85, 0.38), "pieces.z": Color(0.94, 0.22, 0.3), "pieces.j": Color(0.22, 0.42, 0.96), "pieces.l": Color(0.98, 0.52, 0.09)
}
const KIND_LETTERS := {0: "i", 1: "o", 2: "t", 3: "s", 4: "z", 5: "j", 6: "l"}
const KEYS := {"theme": {"background":"theme.background", "text":"theme.text", "dim":"theme.dim", "accent":"theme.accent"}, "game": {"background":"game.background"}, "menu": {"panel":"menu.panel", "scrim":"menu.scrim", "focus":"menu.focus", "title_size":"menu.title_size", "item_size":"menu.item_size", "spacing":"menu.spacing", "transition":"menu.transition", "split_gap":"menu.split_gap", "split_padding":"menu.split_padding", "detail_size":"menu.detail_size", "divider":"menu.divider"}, "board": {"bg":"board.bg", "peek":"board.peek", "grid":"board.grid", "border":"board.border", "ghost":"board.ghost", "ghost_line":"board.ghost_line", "flash":"board.flash", "section_line":"board.section_line", "section_tint_alpha":"board.section_tint_alpha"}, "players":{"p1":"players.p1","p2":"players.p2","p3":"players.p3","p4":"players.p4"}, "pieces":{"i":"pieces.i","o":"pieces.o","t":"pieces.t","s":"pieces.s","z":"pieces.z","j":"pieces.j","l":"pieces.l"}}
const RANGES := {"menu.title_size":[20,96], "menu.item_size":[14,48], "menu.spacing":[0,48], "menu.transition":[0.0,1.0], "menu.split_gap":[0,160], "menu.split_padding":[12,96], "menu.detail_size":[12,32], "board.section_tint_alpha":[0.0,0.25], "theme.opacity":[0.0,1.0], "game.opacity":[0.0,1.0], "pieces.dither_strength":[0.0,1.0], "pieces.bloom":[0.0,2.0]}

## Selector -> property -> media metadata key, kept separate from color
## tokens: quoted asset paths, background presentation, fonts, and piece
## dither/bloom settings. Values are validated here (syntax, formats,
## ranges); file existence, decoding, and playback are the manager's/host's
## job.
const MEDIA_KEYS := {
	"theme": {"image":"theme.image", "video":"theme.video", "fit":"theme.fit", "opacity":"theme.opacity", "tint":"theme.tint", "font":"theme.font", "title_font":"theme.title_font"},
	"game": {"image":"game.image", "video":"game.video", "fit":"game.fit", "opacity":"game.opacity", "tint":"game.tint"},
	"pieces": {"dither":"pieces.dither", "dither_strength":"pieces.dither_strength", "bloom":"pieces.bloom"},
}
## Asset paths: backdrops, fonts, and per-piece skins (pieces.<letter>).
const PATH_KEYS := ["theme.image", "theme.video", "theme.font", "theme.title_font", "game.image", "game.video"]
## Piece-block declarations that are settings, never skin image paths.
const PIECE_SETTING_KEYS := ["pieces.dither", "pieces.dither_strength", "pieces.bloom"]
const IMAGE_EXTS := ["png", "jpg", "jpeg", "webp"]
const VIDEO_EXTS := ["ogv"]
const FONT_EXTS := ["ttf", "otf"]
const FITS := ["cover", "contain"]
const DITHERS := ["none", "bayer", "hatch", "scanline", "stipple"]
const NO_TINT := Color(1.0, 1.0, 1.0, 0.0)
const DEFAULT_DITHER_STRENGTH := 0.5
## Playfield bloom intensities: `bloom: true` resolves to the default and
## the schema caps explicit numbers at the maximum.
const DEFAULT_BLOOM_INTENSITY := 0.8
const MAX_BLOOM_INTENSITY := 2.0
## Resolved media defaults for themes that declare no media: color-only
## backdrops (no paths), documented presentation defaults (cover, fully
## opaque, no tint), and dithering and bloom off.
const DEFAULT_MEDIA := {
	"theme.image": "", "theme.video": "", "theme.fit": "cover", "theme.opacity": 1.0, "theme.tint": NO_TINT,
	"theme.font": "", "theme.title_font": "",
	"game.image": "", "game.video": "", "game.fit": "cover", "game.opacity": 1.0, "game.tint": NO_TINT,
	"pieces.dither": "none", "pieces.dither_strength": DEFAULT_DITHER_STRENGTH, "pieces.bloom": 0.0,
	"pieces.i": "", "pieces.o": "", "pieces.t": "", "pieces.s": "", "pieces.z": "", "pieces.j": "", "pieces.l": "",
}

static func default_tokens() -> Dictionary:
	return DEFAULT_TOKENS.duplicate(true)


static func default_media() -> Dictionary:
	return DEFAULT_MEDIA.duplicate(true)


## Relative luminance used when checking piece readability.
static func luminance(color: Color) -> float:
	return 0.2126 * color.r + 0.7152 * color.g + 0.0722 * color.b


static func _color(raw: String):
	if not raw.begins_with("#"): return null
	var h := raw.substr(1)
	if h.length() in [3, 4]:
		var expanded := ""
		for c in h: expanded += c + c
		h = expanded
	if h.length() not in [6, 8] or not h.is_valid_hex_number(): return null
	return Color("#" + h)


## Validates one raw media declaration. Returns {"value": ..., "error": ""}
## on success or {"value": null, "error": "<diagnostic text>"} on failure.
static func _media_value(key: String, raw: String) -> Dictionary:
	var is_path := PATH_KEYS.has(key) or (key.begins_with("pieces.") and not PIECE_SETTING_KEYS.has(key))
	if is_path:
		var rel := _rel_path(raw)
		if rel.is_empty(): return {"value": null, "error": "invalid value"}
		var exts: Array = IMAGE_EXTS
		if key.ends_with(".video"): exts = VIDEO_EXTS
		elif key == "theme.font" or key == "theme.title_font": exts = FONT_EXTS
		if not exts.has(rel.get_extension().to_lower()): return {"value": null, "error": "unsupported format"}
		return {"value": rel, "error": ""}
	if key == "pieces.dither" or key.ends_with(".fit"):
		var allowed: Array = DITHERS if key == "pieces.dither" else FITS
		if not allowed.has(raw.to_lower()): return {"value": null, "error": "invalid value"}
		return {"value": raw.to_lower(), "error": ""}
	if key == "pieces.bloom":
		# Grammar: boolean literals normalize to the default/off intensities,
		# explicit numbers are range-checked against the schema maximum.
		var lowered := raw.to_lower()
		if lowered == "true": return {"value": DEFAULT_BLOOM_INTENSITY, "error": ""}
		if lowered == "false": return {"value": 0.0, "error": ""}
		if not raw.is_valid_float(): return {"value": null, "error": "invalid value"}
		var bloom := float(raw)
		if bloom < RANGES[key][0] or bloom > RANGES[key][1]: return {"value": null, "error": "value out of range"}
		return {"value": bloom, "error": ""}
	if key == "pieces.dither_strength" or key.ends_with(".opacity"):
		if not raw.is_valid_float(): return {"value": null, "error": "invalid value"}
		var value := float(raw)
		if value < RANGES[key][0] or value > RANGES[key][1]: return {"value": null, "error": "value out of range"}
		return {"value": value, "error": ""}
	if key.ends_with(".tint"):
		var tint = _color(raw)
		if tint == null: return {"value": null, "error": "invalid value"}
		return {"value": tint, "error": ""}
	return {"value": null, "error": "invalid value"}


## Parses a quoted relative asset path: must be a double-quoted string
## without the characters the line-oriented parser splits on ({ } ; // "
## and friends), no absolute forms or schemes (res://, user://, drive
## letters), and it must stay inside the theme's directory after
## normalization. Backslashes are accepted and converted to forward
## slashes. Returns the normalized confined path or "" when malformed.
static func _rel_path(raw: String) -> String:
	if raw.length() < 3 or not raw.begins_with("\"") or not raw.ends_with("\""): return ""
	var inner := raw.substr(1, raw.length() - 2)
	if inner.is_empty() or inner != inner.strip_edges(): return ""
	for c in ["{", "}", ";", ":", "\"", "|", "?", "*", "<", ">"]:
		if inner.contains(c): return ""
	var norm := inner.replace("\\", "/")
	if norm.contains("//") or norm.begins_with("/"): return ""
	return confine(norm)


## Confines a relative path to the theme's directory: resolves `.` and
## `..` segments and returns "" when the result would escape the root.
## The parser rejects absolute paths and URL schemes, so only segment
## traversal matters here.
static func confine(path: String) -> String:
	var out: PackedStringArray = []
	for part in path.split("/"):
		if part.is_empty() or part == ".": continue
		if part == "..":
			if out.is_empty(): return ""
			out.remove_at(out.size() - 1)
			continue
		out.append(part)
	if out.is_empty(): return ""
	return "/".join(out)

static func parse(text: String) -> Dictionary:
	var diagnostics: Array[String] = []; var overrides := {}; var media := {}; var name := ""; var selector := ""; var saw := false
	var lines := text.replace("{", "{\n").replace("}", "\n}\n").replace(";", ";\n").split("\n")
	for n in lines.size():
		var line: String = lines[n].strip_edges()
		var comment := line.find("//")
		if comment >= 0: line = line.substr(0, comment).strip_edges()
		if line.is_empty() or line.begins_with("#"): continue
		if line == "}":
			if selector.is_empty(): diagnostics.append("line %d: unexpected closing brace" % (n + 1))
			selector = ""
			continue
		if selector.is_empty():
			if not line.ends_with("{"): diagnostics.append("line %d: expected block" % (n + 1)); continue
			selector = line.trim_suffix("{").strip_edges()
			if not KEYS.has(selector) and selector != "theme":
				diagnostics.append("line %d: unknown selector" % (n + 1))
				selector = "?"
			if selector == "theme": saw = true
			continue
		if selector == "?": continue
		var parts := line.trim_suffix(";").split(":", true, 1)
		if parts.size() != 2:
			diagnostics.append("line %d: expected property" % (n + 1))
			continue
		var prop := parts[0].strip_edges(); var raw := parts[1].strip_edges(); var key := ""
		if selector == "theme" and prop == "name":
			if not name.is_empty(): diagnostics.append("line %d: duplicate property" % (n + 1)); continue
			name = raw.trim_prefix("\"").trim_suffix("\""); continue
		var media_key := ""
		if MEDIA_KEYS.has(selector) and MEDIA_KEYS[selector].has(prop):
			media_key = MEDIA_KEYS[selector][prop]
		elif selector == "pieces" and KEYS[selector].has(prop) and raw.begins_with("\""):
			# Piece colors are dual-type: a quoted value declares a skin
			# image instead of a color. Missing/invalid skins fall back per
			# piece to the resolved color at load time.
			media_key = KEYS[selector][prop]
		if not media_key.is_empty():
			if media.has(media_key) or overrides.has(media_key): diagnostics.append("line %d: duplicate property" % (n + 1)); continue
			var parsed_media := _media_value(media_key, raw)
			if parsed_media["value"] == null:
				diagnostics.append("line %d: %s" % [(n + 1), parsed_media["error"]])
				continue
			media[media_key] = parsed_media["value"]
			continue
		if not KEYS[selector].has(prop): diagnostics.append("line %d: unknown property" % (n + 1)); continue
		key = KEYS[selector][prop]
		if overrides.has(key): diagnostics.append("line %d: duplicate property" % (n + 1)); continue
		var expected = DEFAULT_TOKENS[key]; var value = _color(raw) if expected is Color else (float(raw) if expected is float and raw.is_valid_float() else (int(raw) if expected is int and raw.is_valid_int() else null))
		if value == null: diagnostics.append("line %d: invalid value" % (n + 1)); continue
		if RANGES.has(key) and (value < RANGES[key][0] or value > RANGES[key][1]): diagnostics.append("line %d: value out of range" % (n + 1)); continue
		overrides[key] = value
	if not selector.is_empty(): diagnostics.append("line %d: unclosed block" % lines.size())
	return {"valid": saw and not name.is_empty() and selector.is_empty(), "name": name, "overrides": overrides, "media": media, "diagnostics": diagnostics}
static func resolve(overrides: Dictionary) -> Dictionary:
	var t := default_tokens()
	for k in overrides:
		if t.has(k): t[k] = overrides[k]
	return t


## Merges declared media over the defaults; undeclared entries inherit
## DEFAULT_MEDIA exactly like tokens inherit DEFAULT_TOKENS.
static func resolve_media(media: Dictionary) -> Dictionary:
	var m := default_media()
	for k in media:
		if m.has(k): m[k] = media[k]
	return m

static func piece_colors(tokens: Dictionary, warnings: Array = []) -> Dictionary:
	var result := {}
	for key in ["i", "o", "t", "s", "z", "j", "l"]:
		var color: Color = tokens["pieces." + key]
		if luminance(color) == luminance(tokens["board.bg"]):
			color = DEFAULT_TOKENS["pieces." + key]
			warnings.append(key)
		result[key] = color
	return result
