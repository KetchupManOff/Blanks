extends "res://tests/test_lib.gd"
## Theme system tests: .theme parsing/resolution/diagnostics (colors, media
## paths, presentation, dither, bloom), discovery and reload, asset
## resolution and fallbacks, settings persistence of theme_id, and
## host-level application (selection from pause keeps the active run
## intact, category navigation, backdrop media/font/skin plumbing, video
## lifecycle).

const ThemeProfile = preload("res://scripts/ui/theme_profile.gd")
const ThemeManager = preload("res://scripts/ui/theme_manager.gd")
const CellDither = preload("res://scripts/presentation/cell_dither.gd")
const SettingsClass = preload("res://scripts/persistence/settings.gd")
const ModeRules = preload("res://scripts/core/mode_rules.gd")

const USER_DIR := "user://test_themes"
const PORTABLE_DIR := "user://test_portable_themes"
const SETTINGS_PATH := "user://settings.json"
const SETTINGS_TEST_PATH := "user://test_theme_settings.json"

var _host: Node = null
var _settings_backup: String = ""


func setup() -> void:
	_remove_dir_recursive(USER_DIR)
	_remove_dir_recursive(PORTABLE_DIR)
	if FileAccess.file_exists(SETTINGS_TEST_PATH):
		DirAccess.remove_absolute(SETTINGS_TEST_PATH)
	_backup_settings()
	var scene: PackedScene = load("res://scenes/main.tscn")
	_host = scene.instantiate()
	tree.root.add_child(_host)
	if _host._hud == null:
		_host.settings = SettingsClass.new()
		_host._build_scene()
		_host._hud._ready()
		_host._menu._ready()
		_host._pause_menu._ready()
		_host._settings_screen._ready()
		_host._coop_setup._ready()
		_host._profile_screen._ready()
		_host._osk._ready()
		_host._online_menu._ready()
		_host._show_main_menu()


## Host flow helpers: solo games start through the profile picker, coop
## runs need per-player profile assignments.
func _start_solo(mode: int) -> void:
	_host.cmd_return_to_menu()
	_host.cmd_solo_profile_selected(_host.settings.active_profile_id, mode)


var _coop_probe: int = 0


func _start_coop(count: int, mode: int) -> void:
	var assignments: Array = []
	for i in count:
		_coop_probe += 1
		var id: String = _host.settings.create_profile("ThemeCoop%d" % _coop_probe)
		assignments.append({"profile_id": id, "device": -1})
	_host.cmd_start_coop(assignments, mode)


func teardown() -> void:
	if _host != null:
		_host.free()
		_host = null
	_restore_settings()
	_remove_dir_recursive(USER_DIR)
	_remove_dir_recursive(PORTABLE_DIR)
	if FileAccess.file_exists(SETTINGS_TEST_PATH):
		DirAccess.remove_absolute(SETTINGS_TEST_PATH)


func _backup_settings() -> void:
	_settings_backup = ""
	if FileAccess.file_exists(SETTINGS_PATH):
		var f := FileAccess.open(SETTINGS_PATH, FileAccess.READ)
		_settings_backup = f.get_as_text()
		f.close()


func _restore_settings() -> void:
	DirAccess.remove_absolute(SETTINGS_PATH)
	if not _settings_backup.is_empty():
		var f := FileAccess.open(SETTINGS_PATH, FileAccess.WRITE)
		f.store_string(_settings_backup)
		f.close()


func _remove_dir_recursive(dir_path: String) -> void:
	if not DirAccess.dir_exists_absolute(dir_path):
		return
	var da := DirAccess.open(dir_path)
	if da == null:
		return
	var names: Array[String] = []
	da.list_dir_begin()
	var file := da.get_next()
	while not file.is_empty():
		names.append(file)
		file = da.get_next()
	da.list_dir_end()
	for name in names:
		if name == "." or name == "..":
			continue
		var full := dir_path.path_join(name)
		if DirAccess.dir_exists_absolute(full):
			_remove_dir_recursive(full)
		else:
			DirAccess.remove_absolute(full)
	DirAccess.remove_absolute(dir_path)


func _write_theme(file_name: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(USER_DIR)
	var path := USER_DIR.path_join(file_name)
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


## Writes a generated PNG asset relative to the user theme dir; real image
## fixtures are generated at runtime, no binary files needed in the repo.
func _write_png_asset(rel: String, color: Color) -> void:
	var path := USER_DIR.path_join(rel)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var img := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	img.fill(color)
	img.save_png(path)


## Writes raw bytes as an asset relative to the user theme dir (magic-byte
## fixtures for video/font gates, corrupt image data).
func _write_raw_asset(rel: String, data: PackedByteArray) -> void:
	var path := USER_DIR.path_join(rel)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer(data)
	f.close()


func _write_portable_theme(file_name: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(PORTABLE_DIR)
	var path := PORTABLE_DIR.path_join(file_name)
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


## The runner sets up once per suite, so every test isolates its own dirs
## instead of relying on test order.
func _isolate_test_dirs() -> void:
	_remove_dir_recursive(USER_DIR)
	_remove_dir_recursive(PORTABLE_DIR)


## Points the host's manager at the test dirs (clean) and rescans, so
## host-level media tests can use generated user themes without touching
## the real user://themes library.
func _reload_host_themes_with_test_dirs() -> void:
	_isolate_test_dirs()
	_host.themes.setup("res://themes", USER_DIR, PORTABLE_DIR)
	_host.cmd_themes_reload()


## Restores the host's standard editor-time theme configuration (built-ins,
## the real user://themes library, no portable dir) and the default
## selection, so later tests in this suite see an uncontaminated host.
func _restore_host_themes_standard() -> void:
	_isolate_test_dirs()
	_host.themes.setup("res://themes", "user://themes", "")
	_host.cmd_theme_selected("builtin:modern_neon")


# ------------------------------------------------------------------ parser

func test_builtin_files_parse_valid() -> void:
	for file in ["modern_neon.theme", "retro_crt.theme", "clean_tournament.theme", "game_boy.theme", "Yanks_Theme.theme", "reference.theme"]:
		var f := FileAccess.open("res://themes".path_join(file), FileAccess.READ)
		check_true(f != null, "built-in file readable: " + file)
		if f == null:
			continue
		var text := f.get_as_text()
		f.close()
		var result: Dictionary = ThemeProfile.parse(text)
		check_true(result["valid"], "built-in theme valid: " + file)
		check_false(result["name"].is_empty(), "built-in theme has a name: " + file)
		check_eq(result["diagnostics"].size(), 0, "built-in theme has no diagnostics: " + file)


func test_parse_comments_and_whitespace() -> void:
	var result: Dictionary = ThemeProfile.parse("""
		# leading comment
		theme {
		  name: "Partial";   // trailing comment
		  accent: #39e6ff;
		}
		menu {
		  panel: #151a3d;
		}
	""")
	check_true(result["valid"], "comments and whitespace accepted")
	check_eq(result["name"], "Partial", "name parsed")
	check_eq(result["overrides"]["theme.accent"], Color("#39e6ff"), "inline // comment stripped")
	check_eq(result["overrides"]["menu.panel"], Color("#151a3d"), "block with comments parses")
	check_false(result["overrides"].has("menu.scrim"), "unspecified tokens absent from overrides")
	check_eq(result["diagnostics"].size(), 0, "no diagnostics")


func test_partial_override_resolves_over_defaults() -> void:
	var result: Dictionary = ThemeProfile.parse("""
		theme {
			name: "X";
		}
		menu {
			focus: #b6ff4a;
		}
	""")
	var tokens: Dictionary = ThemeProfile.resolve(result["overrides"])
	check_eq(tokens["menu.focus"], Color("#b6ff4a"), "override applied")
	check_eq(tokens["board.bg"], ThemeProfile.DEFAULT_TOKENS["board.bg"], "other tokens inherit Modern Neon defaults")


func test_color_formats() -> void:
	var result: Dictionary = ThemeProfile.parse("""
		theme { name: "X"; accent: #39e6ff; }
		menu { panel: #123; focus: #1234; scrim: #11223344; }
	""")
	check_eq(result["overrides"]["theme.accent"], Color("#39e6ff"), "6-digit hex")
	check_eq(result["overrides"]["menu.panel"], Color("#112233"), "3-digit hex expands")
	check_eq(result["overrides"]["menu.focus"], Color("#11223344"), "4-digit hex expands to rgba")
	check_eq(result["overrides"]["menu.scrim"], Color("#11223344"), "8-digit hex rgba")


func test_invalid_values_diagnosed_and_ignored() -> void:
	var result: Dictionary = ThemeProfile.parse("""
		theme {
			name: "X";
			accent: nope;
		}
		menu {
			title_size: 900;
			spacing: -5;
			panel: 12;
		}
	""")
	check_true(result["valid"], "per-property errors do not reject the file")
	check_eq(result["overrides"].size(), 0, "invalid values produce no overrides")
	check_eq(result["diagnostics"].size(), 4, "each invalid value reported")


func test_unknown_selector_and_property_diagnosed() -> void:
	var result: Dictionary = ThemeProfile.parse("""
		theme {
			name: "X";
		}
		bogus {
			accent: #ffffff;
		}
		menu {
			hyper_color: #ffffff;
		}
	""")
	check_true(result["valid"], "unknowns do not reject the file")
	check_eq(result["overrides"].size(), 0, "unknown selector/property ignored")
	check_eq(result["diagnostics"].size(), 2, "both unknowns reported")


func test_duplicate_declaration_diagnosed() -> void:
	var result: Dictionary = ThemeProfile.parse("""
		theme { name: "X"; accent: #111111; accent: #222222; }
	""")
	check_eq(result["overrides"]["theme.accent"], Color("#111111"), "first declaration wins")
	check_eq(result["diagnostics"].size(), 1, "duplicate reported")


func test_missing_identity_rejected() -> void:
	var result: Dictionary = ThemeProfile.parse("menu { focus: #b6ff4a; }")
	check_false(result["valid"], "missing theme block rejected")
	result = ThemeProfile.parse('theme { accent: #39e6ff; }')
	check_false(result["valid"], "missing name rejected")
	result = ThemeProfile.parse('theme { name: ""; }')
	check_false(result["valid"], "empty name rejected")


func test_broken_structure_rejected() -> void:
	var result: Dictionary = ThemeProfile.parse('theme { name: "X"')
	check_false(result["valid"], "unclosed block rejected")
	check_true(result["diagnostics"].size() > 0, "structural problem reported")


func test_piece_contrast_fallback() -> void:
	var tokens := ThemeProfile.default_tokens()
	# Same color as the board background: unreadable, must fall back.
	tokens["pieces.i"] = tokens["board.bg"]
	var warnings: Array = []
	var colors: Dictionary = ThemeProfile.piece_colors(tokens, warnings)
	check_eq(colors["i"], ThemeProfile.DEFAULT_TOKENS["pieces.i"], "unreadable piece falls back per piece")
	check_eq(colors["o"], tokens["pieces.o"], "readable piece keeps the override")
	check_eq(warnings.size(), 1, "fallback reported as a warning")


func test_game_background_override_parses() -> void:
	var result: Dictionary = ThemeProfile.parse("""
		theme {
			name: "X";
		}
		game {
			background: #1a2b3c;
		}
	""")
	check_true(result["valid"], "game block accepted")
	check_eq(result["overrides"]["game.background"], Color("#1a2b3c"), "game.background override parsed")
	check_eq(result["diagnostics"].size(), 0, "no diagnostics for a valid game override")
	var tokens: Dictionary = ThemeProfile.resolve(result["overrides"])
	check_eq(tokens["game.background"], Color("#1a2b3c"), "override resolves over the default")
	check_eq(tokens["board.bg"], ThemeProfile.DEFAULT_TOKENS["board.bg"], "board.bg untouched by a game override")


func test_game_background_omitted_inherits_default() -> void:
	var result: Dictionary = ThemeProfile.parse('theme {\n\tname: "Partial";\n}\n')
	check_true(result["valid"], "omitting game.background keeps the file valid")
	check_false(result["overrides"].has("game.background"), "omitted token absent from overrides")
	var tokens: Dictionary = ThemeProfile.resolve(result["overrides"])
	check_eq(tokens["game.background"], ThemeProfile.DEFAULT_TOKENS["game.background"], "omitted game.background inherits the default")


func test_game_background_invalid_diagnosed_and_ignored() -> void:
	var result: Dictionary = ThemeProfile.parse("""
		theme {
			name: "X";
		}
		game {
			background: nope;
		}
	""")
	check_true(result["valid"], "invalid game.background does not reject the file")
	check_eq(result["overrides"].size(), 0, "invalid game.background produces no override")
	check_eq(result["diagnostics"].size(), 1, "invalid game.background reported")
	var tokens: Dictionary = ThemeProfile.resolve(result["overrides"])
	check_eq(tokens["game.background"], ThemeProfile.DEFAULT_TOKENS["game.background"], "invalid value falls back to the default")


# --------------------------------------------------------- parser: media

func test_media_path_parsing() -> void:
	var result: Dictionary = ThemeProfile.parse("""
		theme {
			name: "Media";
			image: "assets/menu.png";
			font: "fonts/body.ttf";
			title_font: "fonts/title.otf";
		}
		game {
			video: "media/bg.ogv";
			fit: contain;
			opacity: 0.75;
			tint: #00112266;
		}
		pieces {
			i: "skins/i.png";
			o: #ff8800;
		}
	""")
	check_true(result["valid"], "media declarations keep the file valid")
	check_eq(result["diagnostics"].size(), 0, "no diagnostics for valid media")
	check_eq(result["media"]["theme.image"], "assets/menu.png", "theme image path")
	check_eq(result["media"]["theme.font"], "fonts/body.ttf", "body font path")
	check_eq(result["media"]["theme.title_font"], "fonts/title.otf", "title font path")
	check_eq(result["media"]["game.video"], "media/bg.ogv", "game video path")
	check_eq(result["media"]["game.fit"], "contain", "game fit")
	check_eq(result["media"]["game.opacity"], 0.75, "game opacity")
	check_eq(result["media"]["game.tint"], Color("#00112266"), "game tint")
	check_eq(result["media"]["pieces.i"], "skins/i.png", "piece skin path")
	check_false(result["overrides"].has("pieces.i"), "a skinned piece leaves the color token untouched")
	check_eq(result["overrides"]["pieces.o"], Color("#ff8800"), "a color piece still overrides its token")


func test_media_path_normalization() -> void:
	var result: Dictionary = ThemeProfile.parse("""
		theme {
			name: "Norm";
			image: "art\\back.png";
			video: "a/./b/./loop.ogv";
		}
	""")
	check_eq(result["media"]["theme.image"], "art/back.png", "backslashes normalized to forward slashes")
	check_eq(result["media"]["theme.video"], "a/b/loop.ogv", "dot segments resolved")
	var inner: Dictionary = ThemeProfile.parse('theme {\n\tname: "N2";\n\timage: "a/../b.png";\n}\n')
	check_eq(inner["media"]["theme.image"], "b.png", "climb-and-return stays inside the theme folder")


func test_media_path_syntax_rejected() -> void:
	# Every malformed or escaping path is diagnosed and produces no media
	# entry (the theme itself stays valid).
	for bad in [
		'image: assets/menu.png;',
		'image: "assets/menu.png;',
		'image: "res://themes/x.png";',
		'image: "user://themes/x.png";',
		'image: "/abs/x.png";',
		'image: "C:/x.png";',
		'image: "../outside.png";',
		'image: "a/../../outside.png";',
		'image: "a;b.png";',
		'image: "a{b}.png";',
		'image: "a//b.png";',
		'image: "a:b.png";',
		'image: "";',
	]:
		var result: Dictionary = ThemeProfile.parse('theme {\n\tname: "Bad";\n\t%s\n}\n' % bad)
		check_false(result["media"].has("theme.image"), "no media entry for: " + bad)
		check_true(result["diagnostics"].size() >= 1, "malformed path diagnosed: " + bad)


func test_media_extension_validation() -> void:
	var result: Dictionary = ThemeProfile.parse("""
		theme {
			name: "Ext";
			image: "x.gif";
			video: "x.mp4";
			font: "x.woff";
		}
	""")
	check_false(result["media"].has("theme.image"), "gif image rejected")
	check_false(result["media"].has("theme.video"), "mp4 video rejected")
	check_false(result["media"].has("theme.font"), "woff font rejected")
	check_eq(result["diagnostics"].size(), 3, "each unsupported format reported")
	for diag in result["diagnostics"]:
		check_true(String(diag).contains("unsupported format"), "diagnostic names the problem: " + String(diag))
	var skins: Dictionary = ThemeProfile.parse('theme {\n\tname: "S";\n}\npieces {\n\ti: "skins/x.bmp";\n}\n')
	check_false(skins["media"].has("pieces.i"), "bmp skin rejected")
	check_eq(skins["diagnostics"].size(), 1, "unsupported skin format reported")


func test_media_presentation_validation() -> void:
	var result: Dictionary = ThemeProfile.parse("""
		theme {
			name: "Pres";
			fit: stretch;
			opacity: 1.5;
			tint: nope;
		}
		pieces {
			dither: waves;
			dither_strength: -0.2;
		}
	""")
	check_true(result["valid"], "presentation errors never reject the file")
	check_eq(result["media"].size(), 0, "invalid presentation produces no media")
	check_eq(result["diagnostics"].size(), 5, "each invalid presentation value reported")


func test_media_duplicate_declaration_diagnosed() -> void:
	var result: Dictionary = ThemeProfile.parse("""
		theme {
			name: "Dup";
			image: "a.png";
			image: "b.png";
		}
	""")
	check_eq(result["media"]["theme.image"], "a.png", "first media declaration wins")
	check_eq(result["diagnostics"].size(), 1, "duplicate media declaration reported")

	var mixed: Dictionary = ThemeProfile.parse('theme { name: "Dup2"; }\npieces {\n\ti: #ffffff;\n\ti: "skin.png";\n}\n')
	check_true(mixed["overrides"].has("pieces.i"), "first piece declaration wins (color form)")
	check_false(mixed["media"].has("pieces.i"), "second skin form ignored as a duplicate")
	check_eq(mixed["diagnostics"].size(), 1, "color/skin duplicate reported")


func test_media_defaults_resolve() -> void:
	var media: Dictionary = ThemeProfile.resolve_media({})
	check_eq(media["theme.fit"], "cover", "default fit is cover")
	check_eq(media["theme.opacity"], 1.0, "default opacity is opaque")
	check_eq(media["theme.tint"], ThemeProfile.NO_TINT, "default tint is fully transparent")
	check_eq(media["theme.image"], "", "no default menu image")
	check_eq(media["theme.video"], "", "no default menu video")
	check_eq(media["theme.font"], "", "no default body font")
	check_eq(media["theme.title_font"], "", "no default title font")
	check_eq(media["game.fit"], "cover", "game fit defaults to cover")
	check_eq(media["pieces.dither"], "none", "dither off by default")
	check_eq(media["pieces.dither_strength"], ThemeProfile.DEFAULT_DITHER_STRENGTH, "representative default strength")
	check_eq(media["pieces.bloom"], 0.0, "bloom off by default")
	check_eq(media["pieces.i"], "", "no default skins")


# ------------------------------------------------------------- bloom parsing

func test_bloom_grammar_parsing() -> void:
	var on: Dictionary = ThemeProfile.parse('theme {\n\tname: "Bloom";\n}\npieces {\n\tbloom: true;\n}\n')
	check_true(on["valid"], "bloom keeps the file valid")
	check_eq(on["media"]["pieces.bloom"], ThemeProfile.DEFAULT_BLOOM_INTENSITY, "literal true resolves to the default intensity")
	check_eq(on["diagnostics"].size(), 0, "valid declaration has no diagnostics")
	var off: Dictionary = ThemeProfile.parse('theme {\n\tname: "Bloom";\n}\npieces {\n\tbloom: false;\n}\n')
	check_eq(off["media"]["pieces.bloom"], 0.0, "literal false resolves to zero")
	var cased: Dictionary = ThemeProfile.parse('theme {\n\tname: "Bloom";\n}\npieces {\n\tbloom: TRUE;\n}\n')
	check_eq(cased["media"]["pieces.bloom"], ThemeProfile.DEFAULT_BLOOM_INTENSITY, "boolean literals are case-insensitive")
	var cased_off: Dictionary = ThemeProfile.parse('theme {\n\tname: "Bloom";\n}\npieces {\n\tbloom: False;\n}\n')
	check_eq(cased_off["media"]["pieces.bloom"], 0.0, "case-insensitive false also resolves to zero")

	var numeric: Dictionary = ThemeProfile.parse('theme {\n\tname: "Bloom";\n}\npieces {\n\tbloom: 1.25;\n}\n')
	check_eq(numeric["media"]["pieces.bloom"], 1.25, "explicit numeric intensity parsed")
	check_eq(numeric["diagnostics"].size(), 0, "numeric in-range declaration has no diagnostics")
	var zero: Dictionary = ThemeProfile.parse('theme {\n\tname: "Bloom";\n}\npieces {\n\tbloom: 0.0;\n}\n')
	check_eq(zero["media"]["pieces.bloom"], 0.0, "explicit zero parses as disabled")
	var maxed: Dictionary = ThemeProfile.parse('theme {\n\tname: "Bloom";\n}\npieces {\n\tbloom: 2.0;\n}\n')
	check_eq(maxed["media"]["pieces.bloom"], 2.0, "the schema maximum parses")


func test_bloom_default_and_validation() -> void:
	var partial: Dictionary = ThemeProfile.parse('theme {\n\tname: "Partial";\n}\n')
	check_true(partial["valid"], "omitting bloom keeps the file valid")
	check_false(partial["media"].has("pieces.bloom"), "omitted declaration absent from media")
	check_eq(ThemeProfile.resolve_media(partial["media"])["pieces.bloom"], 0.0, "omitted declaration inherits zero")

	var invalid: Dictionary = ThemeProfile.parse('theme {\n\tname: "Bad";\n}\npieces {\n\tbloom: yes;\n}\n')
	check_true(invalid["valid"], "invalid bloom does not reject the file")
	check_false(invalid["media"].has("pieces.bloom"), "invalid value produces no media entry")
	check_eq(invalid["diagnostics"].size(), 1, "invalid value reported")
	check_true(String(invalid["diagnostics"][0]).contains("invalid value"), "diagnostic names the problem")
	check_eq(ThemeProfile.resolve_media(invalid["media"])["pieces.bloom"], 0.0, "invalid declaration falls back to zero")

	var over: Dictionary = ThemeProfile.parse('theme {\n\tname: "Bad";\n}\npieces {\n\tbloom: 2.5;\n}\n')
	check_false(over["media"].has("pieces.bloom"), "out-of-range value produces no media entry")
	check_eq(over["diagnostics"].size(), 1, "out-of-range value reported")
	check_true(String(over["diagnostics"][0]).contains("out of range"), "out-of-range diagnostic names the problem")
	var under: Dictionary = ThemeProfile.parse('theme {\n\tname: "Bad";\n}\npieces {\n\tbloom: -0.5;\n}\n')
	check_false(under["media"].has("pieces.bloom"), "negative value produces no media entry")

	var quoted: Dictionary = ThemeProfile.parse('theme {\n\tname: "Quoted";\n}\npieces {\n\tbloom: "true";\n}\n')
	check_false(quoted["media"].has("pieces.bloom"), "quoted booleans are rejected, never treated as skin paths")
	check_eq(quoted["diagnostics"].size(), 1, "quoted boolean reported")

	var duplicate: Dictionary = ThemeProfile.parse('theme {\n\tname: "Dup";\n}\npieces {\n\tbloom: true;\n\tbloom: false;\n}\n')
	check_eq(duplicate["media"]["pieces.bloom"], ThemeProfile.DEFAULT_BLOOM_INTENSITY, "first bloom declaration wins")
	check_eq(duplicate["diagnostics"].size(), 1, "duplicate bloom reported")


func test_retired_dither_bloom_names_diagnosed() -> void:
	# Deliberate schema break: the retired boolean and the retired dither
	# names soft-diagnose and resolve to their defaults (off / none).
	var legacy: Dictionary = ThemeProfile.parse('theme {\n\tname: "Legacy";\n}\npieces {\n\tdither: checker;\n\tdither_bloom: true;\n}\n')
	check_true(legacy["valid"], "retired declarations never reject the file")
	check_false(legacy["media"].has("pieces.dither"), "retired dither name produces no media entry")
	check_false(legacy["media"].has("pieces.bloom"), "retired boolean is now an unknown property")
	check_eq(legacy["diagnostics"].size(), 2, "each retired declaration reported")
	var resolved: Dictionary = ThemeProfile.resolve_media(legacy["media"])
	check_eq(resolved["pieces.dither"], "none", "retired dither name falls back to none")
	check_eq(resolved["pieces.bloom"], 0.0, "retired boolean falls back to off")


# --------------------------------------------------------- dither helper

func _dark_count(mode: String, kind: int, strength: float) -> int:
	var dark := 0
	for i in CellDither.GRID:
		for j in CellDither.GRID:
			if CellDither.sample_dark(mode, kind, i, j, strength):
				dark += 1
	return dark


func test_dither_mode_vocabulary() -> void:
	check_eq(CellDither.MODES, ["none", "bayer", "hatch", "scanline", "stipple"], "the curated 16-bit vocabulary replaces the retired names")
	for retired in ["checker", "dots", "scanlines", "noise"]:
		check_false(CellDither.MODES.has(retired), "retired name removed: " + retired)
		check_eq(_dark_count(retired, 0, 1.0), 0, "retired name darkens nothing: " + retired)
	check_eq(_dark_count("none", 0, 1.0), 0, "none darkens nothing")


func test_bayer_rank_order() -> void:
	# Canonical 8x8 Bayer matrix: exact ranks at anchor positions and a
	# full permutation of 0..63 across the grid.
	check_eq(CellDither.sample_rank("bayer", 2, 0, 0), 0, "bayer (0,0) is rank 0")
	check_eq(CellDither.sample_rank("bayer", 2, 1, 0), 32, "bayer (1,0) is rank 32")
	check_eq(CellDither.sample_rank("bayer", 2, 0, 1), 48, "bayer (0,1) is rank 48")
	check_eq(CellDither.sample_rank("bayer", 2, 7, 7), 21, "bayer (7,7) is rank 21")
	var ranks: Array = []
	for i in CellDither.GRID:
		for j in CellDither.GRID:
			ranks.append(CellDither.sample_rank("bayer", 5, i, j))
	ranks.sort()
	for n in CellDither.SAMPLES:
		check_eq(ranks[n], n, "bayer ranks are the full ordered permutation")


func test_ranked_modes_density_rises_with_strength() -> void:
	for mode in ["bayer", "hatch", "stipple"]:
		var prev := -1
		for strength in [0.0, 0.125, 0.25, 0.5, 0.75, 1.0]:
			var dark: int = _dark_count(mode, 2, strength)
			check_true(dark >= prev, mode + " density is monotonic at strength " + str(strength))
			prev = dark
		check_eq(_dark_count(mode, 2, 0.0), 0, mode + " stays visually off at 0.0")
	check_eq(_dark_count("bayer", 2, 1.0), CellDither.SAMPLES, "bayer reaches full coverage at 1.0")
	# Hatch ramp: one "/" stroke, the full "/" pair, then the completed
	# cross-hatch - never an ink slab.
	check_eq(_dark_count("hatch", 2, 0.2), CellDither.GRID, "hatch starts with a single diagonal stroke")
	check_eq(_dark_count("hatch", 2, 0.5), CellDither.GRID * 2, "hatch completes its diagonal pair at mid strength")
	check_eq(_dark_count("hatch", 2, 1.0), 24, "hatch reaches the full cross-hatch treatment at 1.0")
	check_eq(_dark_count("scanline", 2, 1.0), CellDither.SAMPLES / 2, "scanline keeps its fixed alternating band parity")


func test_hatch_and_scanline_phase_continuous() -> void:
	# Hatch strokes continue across cell boundaries. At 0.2 only the
	# leading "/" stroke family is active, so darkness must transfer
	# exactly along "/" (right edge, one row up in the next cell).
	for j in CellDither.GRID:
		check_eq(
			CellDither.sample_dark("hatch", 4, 0, posmod(j - 1, CellDither.GRID), 0.2),
			CellDither.sample_dark("hatch", 4, CellDither.GRID - 1, j, 0.2),
			"hatch slash strokes continue across the cell boundary"
		)
	# At 0.625 the "\" stroke family is partially active: the back stroke
	# crossing the right edge stays dark one row down in the next cell.
	check_true(CellDither.sample_dark("hatch", 4, CellDither.GRID - 1, CellDither.GRID - 1, 0.625), "back stroke sample dark at the right edge")
	check_true(CellDither.sample_dark("hatch", 4, 0, 0, 0.625), "back stroke continues dark into the next cell")
	# Hatch is a pure function of the local samples: board-stable phase,
	# identical for every piece kind.
	for i in CellDither.GRID:
		for j in CellDither.GRID:
			check_eq(
				CellDither.sample_rank("hatch", 0, i, j),
				CellDither.sample_rank("hatch", 6, i, j),
				"hatch phase is kind-independent"
			)
	# Scanline bands depend only on the row parity, so the raster bands
	# stay continuous across every cell and column of the board.
	for i in CellDither.GRID:
		for j in CellDither.GRID:
			check_eq(
				CellDither.sample_dark("scanline", 4, i, j, 0.5),
				j % 2 == 0,
				"scanline band parity is cell- and column-independent"
			)


func test_stipple_deterministic_and_phased() -> void:
	# Stable output: identical inputs always produce identical ranks.
	for i in CellDither.GRID:
		for j in CellDither.GRID:
			check_eq(
				CellDither.sample_rank("stipple", 1, i, j),
				CellDither.sample_rank("stipple", 1, i, j),
				"stipple stable for identical inputs"
			)
	# The per-piece phase shifts the map lookup: kinds differ at some
	# samples without changing the rank vocabulary.
	var differ: int = 0
	for i in CellDither.GRID:
		for j in CellDither.GRID:
			if CellDither.sample_rank("stipple", 0, i, j) != CellDither.sample_rank("stipple", 3, i, j):
				differ += 1
	check_true(differ > 0, "per-piece phase shifts the stipple lattice")
	var ranks: Array = []
	for i in CellDither.GRID:
		for j in CellDither.GRID:
			ranks.append(CellDither.sample_rank("stipple", 3, i, j))
	ranks.sort()
	for n in CellDither.SAMPLES:
		check_eq(ranks[n], n, "stipple ranks stay a full ordered permutation under the phase shift")


# --------------------------------------------------------------- discovery

func _manager() -> Node:
	var manager: Node = ThemeManager.new()
	manager.setup("res://themes", USER_DIR)
	return manager


func test_builtin_discovery_order() -> void:
	var manager: Node = _manager()
	check_true(manager.entries.size() >= 3, "three built-in themes discovered")
	var sources: Array = []
	for entry in manager.entries:
		sources.append(entry["source"])
	check_eq(sources[0], "builtin", "built-ins come first")
	var ids: Array = []
	for entry in manager.entries:
		ids.append(entry["id"])
	check_true(ids.has("builtin:modern_neon"), "modern neon id")
	check_true(ids.has("builtin:retro_crt"), "retro crt id")
	check_true(ids.has("builtin:clean_tournament"), "clean tournament id")
	check_true(ids.has("builtin:game_boy"), "game boy id")
	manager.free()


func test_game_boy_theme_discovery() -> void:
	var manager: Node = _manager()
	check_true(manager.has_theme("builtin:game_boy"), "game boy discovered as a built-in")
	var entry: Dictionary = manager.entry("builtin:game_boy")
	check_eq(entry["name"], "Game Boy", "display name from the file")
	check_eq(entry["source"], "builtin", "built-in identity")
	check_eq(entry["media"]["dither"], "bayer", "bayer dither resolved")
	check_true(is_equal_approx(entry["media"]["dither_strength"], 0.45), "representative bayer strength")
	check_eq(entry["media"]["bloom"], 0.0, "built-in dithered theme stays bloom-free")
	for letter in ["i", "o", "t", "s", "z", "j", "l"]:
		check_eq(entry["tokens"]["pieces." + letter], Color("#0f380f"), "monochrome piece color: " + letter)
	check_true(entry["media"]["skins"]["i"] == null, "no skins needed: game boy stays asset-free")
	check_eq(entry["diagnostics"].size(), 0, "game boy parses clean")
	check_true(manager.select("builtin:game_boy"), "selectable like any built-in")
	check_eq(manager.media()["dither"], "bayer", "selected game boy media exposes the dither")
	manager.free()


func test_bundled_theme_dither_bloom_mappings() -> void:
	var manager: Node = _manager()
	var yanks: Dictionary = manager.entry("builtin:Yanks_Theme")
	check_eq(yanks["media"]["dither"], "stipple", "Yanks_Theme migrated noise to stipple")
	check_true(is_equal_approx(yanks["media"]["dither_strength"], 0.45), "Yanks_Theme retains its strength")
	check_eq(yanks["media"]["bloom"], ThemeProfile.DEFAULT_BLOOM_INTENSITY, "Yanks_Theme migrated to bloom enabled")
	check_eq(yanks["diagnostics"].size(), 0, "Yanks_Theme parses clean")
	var showcase: Dictionary = manager.entry("builtin:reference")
	check_eq(showcase["media"]["dither"], "hatch", "reference migrated checker to hatch")
	check_true(is_equal_approx(showcase["media"]["dither_strength"], 0.55), "reference retains its dither example")
	check_eq(showcase["media"]["bloom"], ThemeProfile.DEFAULT_BLOOM_INTENSITY, "reference migrated to bloom enabled")
	check_eq(showcase["diagnostics"].size(), 0, "reference parses clean")
	manager.free()


func test_user_discovery_and_reload() -> void:
	_isolate_test_dirs()
	var manager: Node = _manager()
	check_false(manager.has_theme("user:mine"), "user file not present before it exists")
	_write_theme("mine.theme", 'theme {\n\tname: "Mine";\n}\n')
	var result: Dictionary = manager.reload()
	check_false(result["repaired"], "nothing repaired")
	check_true(manager.has_theme("user:mine"), "reload discovers new user file")
	var entry: Dictionary = manager.entry("user:mine")
	check_eq(entry["name"], "Mine", "user entry name from file metadata")
	var tokens: Dictionary = entry["tokens"]
	check_eq(tokens["menu.panel"], ThemeProfile.DEFAULT_TOKENS["menu.panel"], "partial user theme inherits defaults")
	manager.free()


func test_invalid_custom_skipped_and_reported() -> void:
	# Missing identity AND an unknown property: the file is rejected
	# entirely and the per-line diagnostics are kept for the status line.
	_isolate_test_dirs()
	_write_theme("broken.theme", "menu {\n\tfocus: #b6ff4a;\n\tbogus: #123;\n}\n")
	var manager: Node = _manager()
	check_false(manager.has_theme("user:broken"), "invalid file not selectable")
	check_eq(manager.invalid.size(), 1, "invalid file reported for diagnostics")
	check_true(manager.invalid[0]["diagnostics"].size() > 0, "invalid file has diagnostics")
	manager.free()


func test_reload_preserves_selection_and_repairs() -> void:
	_isolate_test_dirs()
	_write_theme("mine.theme", 'theme {\n\tname: "Mine";\n}\n')
	var manager: Node = _manager()
	check_true(manager.select("user:mine"), "user theme selectable")
	var result: Dictionary = manager.reload()
	check_false(result["repaired"], "existing selection kept")
	check_eq(manager.selected_id, "user:mine", "selection preserved across reload")

	DirAccess.remove_absolute(USER_DIR.path_join("mine.theme"))
	result = manager.reload()
	check_true(result["repaired"], "lost selection repaired")
	check_eq(manager.selected_id, ThemeProfile.DEFAULT_THEME_ID, "repair falls back to Modern Neon")
	check_eq(result["lost"], "user:mine", "lost id reported")
	manager.free()


func test_unknown_selection_repairs_to_default() -> void:
	var manager: Node = _manager()
	check_eq(manager.select_valid("user:ghost"), ThemeProfile.DEFAULT_THEME_ID, "unknown preferred id repairs")
	check_eq(manager.select_valid("builtin:retro_crt"), "builtin:retro_crt", "known id selected")
	manager.free()


# ------------------------------------------------- media asset resolution

func test_user_theme_media_resolution() -> void:
	_isolate_test_dirs()
	_write_png_asset("assets/red.png", Color(0.9, 0.1, 0.1))
	_write_theme("media.theme", """
		theme {
			name: "Media";
			background: #123456;
			image: "assets/red.png";
		}
	""")
	var manager: Node = _manager()
	var entry: Dictionary = manager.entry("user:media")
	check_true(entry["media"]["menu"]["texture"] != null, "declared menu image loads from disk")
	check_eq(entry["media"]["menu"]["texture"].get_size(), Vector2(4, 4), "image decoded with its real size")
	check_eq(entry["media"]["menu"]["color"], Color("#123456"), "backdrop color keeps the themed background")
	check_eq(entry["media"]["menu"]["fit"], "cover", "presentation defaults resolve")
	check_eq(entry["media"]["menu"]["opacity"], 1.0, "default opacity resolves")
	check_eq(entry["media"]["menu"]["tint"], ThemeProfile.NO_TINT, "default tint resolves")
	check_true(entry["media"]["game"]["texture"] == null, "undeclared game image stays empty")
	check_true(entry["media"]["font"] == null, "no font declared")
	check_eq(entry["media"]["dither"], "none", "dither defaults")
	check_eq(manager.invalid.size(), 0, "no warnings for a healthy asset")
	manager.free()


func test_missing_asset_soft_diagnosed_and_selectable() -> void:
	_isolate_test_dirs()
	_write_theme("gone.theme", 'theme {\n\tname: "Gone";\n\tbackground: #abcdef;\n\timage: "assets/missing.png";\n}\n')
	var manager: Node = _manager()
	check_true(manager.has_theme("user:gone"), "theme with a missing asset stays selectable")
	var entry: Dictionary = manager.entry("user:gone")
	check_true(entry["media"]["menu"]["texture"] == null, "missing image falls back to no texture")
	check_eq(entry["media"]["menu"]["color"], Color("#abcdef"), "color fallback still applies")
	check_eq(entry["diagnostics"].size(), 1, "asset problem reported on the entry")
	check_true(String(entry["diagnostics"][0]).contains("file missing"), "diagnostic names the missing file")
	var soft: int = 0
	for invalid_entry in manager.invalid:
		if invalid_entry.get("soft", false):
			soft += 1
	check_eq(soft, 1, "missing asset reported as a soft warning, not a rejection")
	manager.free()


func test_unreadable_image_diagnosed() -> void:
	_isolate_test_dirs()
	_write_raw_asset("assets/garbage.png", PackedByteArray([1, 2, 3, 4]))
	_write_theme("garbage.theme", 'theme {\n\tname: "Garbage";\n\timage: "assets/garbage.png";\n}\n')
	var manager: Node = _manager()
	var entry: Dictionary = manager.entry("user:garbage")
	check_true(entry["media"]["menu"]["texture"] == null, "corrupt image data falls back")
	check_eq(entry["diagnostics"].size(), 1, "unreadable asset reported")
	check_true(String(entry["diagnostics"][0]).contains("unreadable"), "diagnostic names the corrupt file")
	manager.free()


func test_video_asset_resolution_and_magic_gate() -> void:
	_isolate_test_dirs()
	_write_raw_asset("assets/loop.ogv", PackedByteArray([0x4F, 0x67, 0x67, 0x53, 1, 2, 3, 4]))
	_write_raw_asset("assets/fake.ogv", PackedByteArray([1, 2, 3, 4, 5]))
	_write_theme("video.theme", 'theme {\n\tname: "Video";\n\tvideo: "assets/loop.ogv";\n}\ngame {\n\tvideo: "assets/fake.ogv";\n}\n')
	var manager: Node = _manager()
	var entry: Dictionary = manager.entry("user:video")
	check_true(String(entry["media"]["menu"]["video_path"]).ends_with("assets/loop.ogv"), "valid-magic video resolves to a playback path")
	check_true(String(entry["media"]["menu"]["video_path"]).begins_with(USER_DIR), "video path resolves against the theme file's folder")
	check_eq(entry["media"]["game"]["video_path"], "", "garbage video falls back to empty")
	check_eq(entry["diagnostics"].size(), 1, "invalid video reported")
	check_true(String(entry["diagnostics"][0]).contains("not a valid video"), "video diagnostic names the problem")
	manager.free()


func test_font_magic_gates_runtime_loading() -> void:
	_isolate_test_dirs()
	_write_raw_asset("fonts/body.ttf", PackedByteArray([0x00, 0x01, 0x00, 0x00, 1, 2, 3, 4]))
	_write_raw_asset("fonts/bad.ttf", PackedByteArray([9, 9, 9, 9, 1, 2, 3]))
	_write_theme("fonts.theme", 'theme {\n\tname: "Fonts";\n\tfont: "fonts/body.ttf";\n\ttitle_font: "fonts/bad.ttf";\n}\n')
	var manager: Node = _manager()
	var entry: Dictionary = manager.entry("user:fonts")
	check_true(entry["media"]["font"] is FontFile, "loose magic-passing font loads through the runtime FontFile path")
	check_eq(entry["media"]["title_font"], entry["media"]["font"], "title font falls back to the body font when its own file is invalid")
	check_eq(entry["diagnostics"].size(), 1, "bad font reported")
	check_true(String(entry["diagnostics"][0]).contains("not a valid font"), "font diagnostic names the problem")
	manager.free()


func test_manager_media_defaults_without_selection() -> void:
	var manager: Node = _manager()
	var defaults: Dictionary = manager.default_media_presentation()
	check_eq(defaults["menu"]["color"], ThemeProfile.DEFAULT_TOKENS["theme.background"], "default menu backdrop uses theme.background")
	check_eq(defaults["game"]["color"], ThemeProfile.DEFAULT_TOKENS["game.background"], "default game backdrop uses game.background")
	check_true(defaults["menu"]["texture"] == null and defaults["menu"]["video_path"] == "", "default menu media is color-only")
	check_true(defaults["font"] == null and defaults["title_font"] == null, "default presentation has no fonts")
	check_eq(defaults["dither"], "none", "default presentation has no dither")
	check_eq(defaults["bloom"], 0.0, "default presentation has no bloom")
	check_true(defaults["skins"]["i"] == null, "default presentation has no skins")
	# The manager always repairs its selection to a known entry: its media
	# tracks that entry's tokens rather than the raw defaults.
	var media: Dictionary = manager.media()
	check_eq(media["menu"]["color"], manager.tokens()["theme.background"], "media() follows the selected entry")
	check_eq(media["game"]["color"], manager.tokens()["game.background"], "media() follows the selected entry")
	check_eq(media["dither"], "none", "selected entry without dither stays none")
	manager.free()


func test_bloom_reaches_resolved_presentation() -> void:
	_isolate_test_dirs()
	_write_theme("bloom.theme", 'theme {\n\tname: "Bloom";\n}\npieces {\n\tbloom: true;\n}\n')
	_write_theme("numeric.theme", 'theme {\n\tname: "Numeric";\n}\npieces {\n\tbloom: 1.25;\n}\n')
	var manager: Node = _manager()
	var entry: Dictionary = manager.entry("user:bloom")
	check_eq(entry["media"]["bloom"], ThemeProfile.DEFAULT_BLOOM_INTENSITY, "declared bloom reaches the resolved presentation")
	var numeric: Dictionary = manager.entry("user:numeric")
	check_eq(numeric["media"]["bloom"], 1.25, "numeric bloom intensity reaches the resolved presentation")
	check_true(manager.select("user:numeric"), "numeric bloom theme selectable")
	check_eq(manager.media()["bloom"], 1.25, "selected media exposes the numeric bloom")
	check_eq(manager.default_media_presentation()["bloom"], 0.0, "default presentation keeps bloom off")
	check_eq(manager.entry("builtin:game_boy")["media"]["bloom"], 0.0, "game boy stays bloom-free")
	manager.free()


# ---------------------------------------------------- portable (loose) files
# Exported builds ship themes/ beside the executable as plain files: a
# basename matching a built-in replaces it in place, other files add
# "portable:" entries, and broken overrides never remove the packaged theme.

func _portable_manager() -> Node:
	var manager: Node = ThemeManager.new()
	manager.setup("res://themes", USER_DIR, PORTABLE_DIR)
	return manager


func test_portable_override_replaces_builtin() -> void:
	_isolate_test_dirs()
	_write_portable_theme("retro_crt.theme", 'theme {\n\tname: "Retro CRT Edited";\n\taccent: #ff0055;\n}\n')
	var manager: Node = _portable_manager()
	check_true(manager.has_theme("builtin:retro_crt"), "override keeps the built-in id")
	check_false(manager.has_theme("portable:retro_crt"), "no duplicate entry for an override")
	var entry: Dictionary = manager.entry("builtin:retro_crt")
	check_eq(entry["name"], "Retro CRT Edited", "name comes from the loose file")
	check_eq(entry["tokens"]["theme.accent"], Color("#ff0055"), "token comes from the loose file")
	check_eq(entry["source"], "builtin", "override keeps the built-in identity")
	check_eq(manager.selected_id, ThemeProfile.DEFAULT_THEME_ID, "selection state intact")
	manager.free()


func test_portable_override_invalid_falls_back_to_builtin() -> void:
	_isolate_test_dirs()
	_write_portable_theme("retro_crt.theme", "menu {\n\tfocus: #b6ff4a;\n\tbogus: #123;\n}\n")
	var manager: Node = _portable_manager()
	check_true(manager.has_theme("builtin:retro_crt"), "built-in kept despite broken override")
	var plain: Node = _manager()
	check_eq(
		manager.entry("builtin:retro_crt")["name"],
		plain.entry("builtin:retro_crt")["name"],
		"broken override changes nothing"
	)
	var reported := false
	for invalid_entry in manager.invalid:
		if invalid_entry["id"] == "portable:retro_crt":
			reported = true
	check_true(reported, "broken override reported for diagnostics")
	manager.free()
	plain.free()


func test_portable_new_theme_selectable() -> void:
	_isolate_test_dirs()
	_write_portable_theme("mine.theme", 'theme {\n\tname: "Loose";\n}\nmenu {\n\tpanel: #101010;\n}\n')
	var manager: Node = _portable_manager()
	check_true(manager.has_theme("portable:mine"), "loose-only file discovered")
	var entry: Dictionary = manager.entry("portable:mine")
	check_eq(entry["name"], "Loose", "portable entry name from file metadata")
	check_eq(entry["source"], "portable", "portable source reported")
	check_eq(entry["tokens"]["menu.panel"], Color("#101010"), "portable tokens resolved")
	check_eq(entry["tokens"]["board.bg"], ThemeProfile.DEFAULT_TOKENS["board.bg"], "partial portable theme inherits defaults")
	check_true(manager.select("portable:mine"), "portable theme selectable")
	check_eq(manager.selected_id, "portable:mine", "portable selection applied")
	manager.free()


func test_portable_theme_asset_in_subfolder() -> void:
	_isolate_test_dirs()
	var path := PORTABLE_DIR.path_join("art/sub/bg.png")
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var img := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.3, 0.6, 0.9))
	img.save_png(path)
	_write_portable_theme("packed.theme", 'theme {\n\tname: "Packed";\n\timage: "art/sub/bg.png";\n}\n')
	var manager: Node = _portable_manager()
	var entry: Dictionary = manager.entry("portable:packed")
	check_true(entry["media"]["menu"]["texture"] != null, "asset found in a nested subfolder beside the theme file")
	check_eq(entry["media"]["menu"]["texture"].get_size(), Vector2(4, 4), "nested asset decoded")
	manager.free()


func test_portable_dir_missing_is_safe() -> void:
	# Neither the portable dir nor the user dir exists: exactly the packaged
	# built-ins, with no diagnostics.
	var manager: Node = ThemeManager.new()
	manager.setup("res://themes", "user://test_theme_missing_user", "user://test_theme_missing_portable")
	check_true(manager.has_theme(ThemeProfile.DEFAULT_THEME_ID), "defaults intact without a portable dir")
	check_true(manager.has_theme("builtin:retro_crt"), "built-ins intact without a portable dir")
	check_eq(manager.invalid.size(), 0, "no diagnostics without a portable dir")
	manager.free()


# ------------------------------------------------------- settings persistence

func test_settings_theme_id_default_and_reset() -> void:
	var s := SettingsClass.new()
	check_eq(s.theme_id, "builtin:modern_neon", "default theme id")
	s.theme_id = "user:mine"
	s.reset_to_defaults()
	check_eq(s.theme_id, "builtin:modern_neon", "reset restores the default theme id")


func test_settings_theme_id_roundtrip() -> void:
	var s := SettingsClass.new()
	s.theme_id = "builtin:retro_crt"
	check_true(s.save(SETTINGS_TEST_PATH), "save succeeds")
	check_eq(s.to_dict()["display"]["theme_id"], "builtin:retro_crt", "serialized under display")
	var loaded := SettingsClass.new()
	check_true(loaded.load(SETTINGS_TEST_PATH), "load succeeds")
	check_eq(loaded.theme_id, "builtin:retro_crt", "theme id round trips")
	if FileAccess.file_exists(SETTINGS_TEST_PATH):
		DirAccess.remove_absolute(SETTINGS_TEST_PATH)


func test_settings_theme_id_invalid_and_absent() -> void:
	var s := SettingsClass.new()
	check_true(s._apply_dict({"version": 1, "display": {"theme_id": 42}}), "payload applies")
	check_eq(s.theme_id, "builtin:modern_neon", "non-string theme id keeps default")
	_write_settings_raw(JSON.stringify({"version": 1, "display": {"fullscreen": true}}))
	var legacy := SettingsClass.new()
	check_true(legacy.load(SETTINGS_TEST_PATH), "legacy payload loads")
	check_eq(legacy.theme_id, "builtin:modern_neon", "absent theme id keeps default")
	check_eq(legacy.fullscreen, true, "other display fields still load")


func _write_settings_raw(text: String) -> void:
	var f := FileAccess.open(SETTINGS_TEST_PATH, FileAccess.WRITE)
	f.store_string(text)
	f.close()


# ------------------------------------------------------------- host shell

func test_host_starts_with_theme_manager() -> void:
	check_true(_host.themes != null, "theme manager created")
	check_eq(_host.themes.selected_id, "builtin:modern_neon", "default theme selected")
	check_eq(_host.settings.theme_id, _host.themes.selected_id, "settings and manager agree")


func test_theme_change_preserves_active_run() -> void:
	_start_solo(ModeRules.Mode.MARATHON)
	_host._process(0.3)
	_host.action_pause()
	_host.cmd_open_settings_from_pause()
	check_eq(_host.state, _host.HostState.SETTINGS, "settings opens over pause")
	var core_id: int = _host.core.get_instance_id()
	var elapsed: float = _host.core.elapsed
	var board_snapshot: Array = []
	for y in _host.core.board.HEIGHT:
		for x in _host.core.board.WIDTH:
			board_snapshot.append(_host.core.board.get_cell(x, y))

	_host.cmd_theme_selected("builtin:retro_crt")
	check_eq(_host.settings.theme_id, "builtin:retro_crt", "selection persisted in settings")
	check_eq(_host.core.get_instance_id(), core_id, "same core instance kept")
	check_eq(_host.core.elapsed, elapsed, "timer frozen during theme change")
	var board_after: bool = true
	for y in _host.core.board.HEIGHT:
		for x in _host.core.board.WIDTH:
			if _host.core.board.get_cell(x, y) != board_snapshot[y * _host.core.board.WIDTH + x]:
				board_after = false
	check_true(board_after, "board unchanged by theme change")
	check_eq(_host.state, _host.HostState.SETTINGS, "still in settings after theme change")
	check_eq(_host._board_renderer._tokens["menu.scrim"], _host.themes.tokens()["menu.scrim"], "renderer tokens refreshed")

	_host.cmd_settings_back()
	check_eq(_host.state, _host.HostState.PAUSED, "settings back returns to pause after theme change")
	_host.cmd_resume()
	check_eq(_host.core.get_instance_id(), core_id, "resume keeps the same core instance")


func test_theme_change_updates_all_presentation_nodes() -> void:
	_start_solo(ModeRules.Mode.MARATHON)
	var tokens: Dictionary = _host.themes.tokens()
	_host.cmd_theme_selected("builtin:clean_tournament")
	var new_tokens: Dictionary = _host.themes.tokens()
	check_true(new_tokens["menu.scrim"] != tokens["menu.scrim"], "theme actually differs")
	check_eq(_host._menu._tokens["menu.scrim"], new_tokens["menu.scrim"], "menu updated")
	check_eq(_host._hud._tokens["theme.text"], new_tokens["theme.text"], "hud updated")
	check_eq(_host._settings_screen._tokens["theme.accent"], new_tokens["theme.accent"], "settings screen updated")
	check_eq(_host._online_menu._tokens["menu.scrim"], new_tokens["menu.scrim"], "online menu updated")
	check_eq(_host._board_renderer._tokens["board.bg"], new_tokens["board.bg"], "board renderer updated")
	check_eq(_host._hold_renderer._piece_colors["i"], new_tokens["pieces.i"], "hold mini updated")
	check_eq(_host._previews[0]._piece_colors["o"], new_tokens["pieces.o"], "preview mini updated")


func test_theme_refresh_updates_cinematic_menu_controls() -> void:
	_host.cmd_return_to_menu()
	_host.cmd_theme_selected("builtin:retro_crt")
	var tokens: Dictionary = _host.themes.tokens()
	var menu: CanvasLayer = _host._menu
	check_eq(menu._bg.color, tokens["menu.scrim"], "scrim follows the theme")
	check_eq(menu._title.get_theme_color("font_color"), tokens["theme.text"], "title color follows theme.text")
	check_eq(menu._title.get_theme_font_size("font_size"), tokens["menu.title_size"], "title size follows menu.title_size")
	check_eq(menu._subtitle.get_theme_color("font_color"), tokens["theme.dim"], "subtitle follows theme.dim")
	check_eq(menu._detail.get_theme_color("font_color"), tokens["theme.dim"], "detail follows theme.dim")
	var sel: int = menu._selected
	check_eq(menu._row_styles[sel].bg_color, tokens["menu.panel"], "selected row uses menu.panel")
	check_eq(menu._row_styles[sel].border_color, tokens["menu.divider"], "selected row border uses menu.divider")
	check_eq(menu._labels[sel].get_theme_color("font_color"), tokens["menu.focus"], "selected label uses menu.focus")
	check_eq(menu._labels[sel].get_theme_font_size("font_size"), tokens["menu.item_size"], "item size follows menu.item_size")
	for i in menu._labels.size():
		if i == sel:
			continue
		check_eq(menu._labels[i].get_theme_color("font_color"), tokens["theme.dim"], "unselected label uses theme.dim")
		check_eq(menu._row_styles[i].bg_color.a, 0.0, "unselected row background stays transparent")


func test_theme_refresh_updates_online_menu_controls() -> void:
	_host.cmd_return_to_menu()
	_host._online_menu.open_entry()
	_host.cmd_theme_selected("builtin:retro_crt")
	var tokens: Dictionary = _host.themes.tokens()
	var menu: CanvasLayer = _host._online_menu
	check_eq(menu._bg.color, tokens["menu.scrim"], "online scrim follows the theme")
	check_eq(menu._title.get_theme_color("font_color"), tokens["theme.text"], "online title follows theme.text")
	check_eq(menu._title.get_theme_font_size("font_size"), tokens["menu.title_size"], "online title size follows the theme")
	check_eq(menu._status.get_theme_font_size("font_size"), tokens["menu.detail_size"], "online status size follows the theme")
	check_eq(menu._items_box.get_theme_constant("separation"), tokens["menu.spacing"], "online row spacing follows the theme")
	var sel: int = menu._selected
	check_eq(menu._row_styles[sel].bg_color, tokens["menu.panel"], "online selected row uses menu.panel")
	check_eq(menu._row_styles[sel].border_color, tokens["menu.divider"], "online selected row uses menu.divider")
	check_eq(menu._labels[sel].get_theme_color("font_color"), tokens["menu.focus"], "online selection uses menu.focus")
	check_eq(menu._code_edit.get_theme_color("font_color"), tokens["theme.text"], "room code text follows theme.text")
	check_eq(menu._code_edit.get_theme_color("font_placeholder_color"), tokens["theme.dim"], "room code placeholder follows theme.dim")
	check_eq(menu._code_edit.get_theme_color("caret_color"), tokens["menu.focus"], "room code caret follows menu.focus")
	var code_style: StyleBoxFlat = menu._code_edit.get_theme_stylebox("normal")
	check_eq(code_style.bg_color, tokens["menu.panel"], "room code background follows menu.panel")
	check_eq(code_style.border_color, tokens["menu.divider"], "room code border follows menu.divider")
	menu.close()


func test_theme_switch_preserves_menu_rows_and_selection() -> void:
	_host.cmd_return_to_menu()
	var menu: CanvasLayer = _host._menu
	menu._move(1)
	menu._move(1)
	var selected: int = menu._selected
	var labels: Array = []
	for item in menu._items:
		labels.append(item["label"])
	_host.cmd_theme_selected("builtin:clean_tournament")
	check_eq(menu._selected, selected, "selection preserved across the theme switch")
	check_eq(menu._items.size(), 6, "item list unchanged")
	check_eq(menu._rows.size(), menu._items.size(), "row count preserved")
	var after: Array = []
	for item in menu._items:
		after.append(item["label"])
	check_eq(after, labels, "labels unchanged")
	var tokens: Dictionary = _host.themes.tokens()
	check_eq(menu._row_styles[selected].bg_color, tokens["menu.panel"], "selected row follows the new theme")
	check_eq(menu._labels[selected].get_theme_color("font_color"), tokens["menu.focus"], "selected label follows the new theme")
	menu._move(1)
	check_eq(menu._selected, wrapi(selected + 1, 0, menu._items.size()), "navigation still works after the switch")
	check_eq(menu._row_styles[menu._selected].bg_color, tokens["menu.panel"], "movement re-themes the newly selected row")


func test_menu_composition_across_builtin_themes() -> void:
	# The shared composition must express itself entirely through each
	# theme's resolved tokens: no fixed palette assumptions anywhere.
	for id in ["builtin:modern_neon", "builtin:retro_crt", "builtin:clean_tournament", "builtin:game_boy"]:
		_host.cmd_return_to_menu()
		_host.cmd_theme_selected(id)
		var tokens: Dictionary = _host.themes.tokens()
		var menu: CanvasLayer = _host._menu
		var sel: int = menu._selected
		var idle: int = 0 if sel != 0 else 1
		check_eq(menu._row_styles[sel].bg_color, tokens["menu.panel"], id + ": selected row themed from menu.panel")
		check_eq(menu._row_styles[sel].border_color, tokens["menu.divider"], id + ": divider themed from menu.divider")
		check_eq(menu._labels[sel].get_theme_color("font_color"), tokens["menu.focus"], id + ": focus color themed from menu.focus")
		check_eq(menu._labels[idle].get_theme_color("font_color"), tokens["theme.dim"], id + ": dim color themed from theme.dim")
		check_eq(menu._title.get_theme_color("font_color"), tokens["theme.text"], id + ": title color themed from theme.text")
		check_eq(menu._items_box.custom_minimum_size.x, clampf(float(tokens["menu.item_size"]) * 20.0, 480.0, 720.0), id + ": row width derived from the theme's item size")
		check_eq(menu._items_box.get_theme_constant("separation"), tokens["menu.spacing"], id + ": row gap derived from menu.spacing")
	_restore_host_themes_standard()
	_host.cmd_return_to_menu()


func test_backdrop_is_full_viewport_and_non_interactive() -> void:
	check_eq(_host._backdrop_layer.get_parent(), _host, "backdrop layer parented to the host root")
	check_true(_host._backdrop_layer.layer < 0, "backdrop layer draws below the base canvas")
	check_eq(_host._backdrop_root.get_parent(), _host._backdrop_layer, "wrapper control lives inside the dedicated backdrop layer")
	check_eq(_host._backdrop_root.mouse_filter, Control.MOUSE_FILTER_IGNORE, "wrapper ignores the mouse")
	var viewport_size: Vector2 = _host.get_viewport().get_visible_rect().size
	check_true(_host._backdrop_root.size.x > 0.0 and _host._backdrop_root.size.y > 0.0, "wrapper has a nonzero size after scene construction")
	check_true(_host._backdrop_root.size.is_equal_approx(viewport_size), "wrapper matches the viewport's logical size")
	for backdrop in [_host._game_backdrop, _host._menu_backdrop]:
		check_eq(backdrop.get_parent(), _host._backdrop_root, "backdrop lives under the wrapper, not the run field")
		check_eq(backdrop.mouse_filter, Control.MOUSE_FILTER_IGNORE, "backdrop ignores the mouse")
		check_eq(backdrop.anchor_left, 0.0, "backdrop anchored to the left edge")
		check_eq(backdrop.anchor_top, 0.0, "backdrop anchored to the top edge")
		check_eq(backdrop.anchor_right, 1.0, "backdrop anchored to the right edge")
		check_eq(backdrop.anchor_bottom, 1.0, "backdrop anchored to the bottom edge")
		check_true(backdrop.size.is_equal_approx(viewport_size), "backdrop matches the viewport's logical size")
		check_eq(backdrop.global_position, Vector2.ZERO, "backdrop covers the viewport origin")
		check_eq(backdrop._color.get_parent(), backdrop, "base color rect layered inside the backdrop")
		check_eq(backdrop._color.mouse_filter, Control.MOUSE_FILTER_IGNORE, "color layer ignores the mouse")


func test_backdrop_survives_run_lifecycle() -> void:
	# Menus hide the run field; the backdrop layer is independent of it and
	# must stay visible so the themed color always fills the window. The
	# menu backdrop shows only while no run is active.
	check_false(_host._field.visible, "no run: field hidden")
	check_true(_host._backdrop_layer.visible, "backdrop layer visible in the menu")
	check_true(_host._game_backdrop.is_visible_in_tree(), "game backdrop visible in the menu")
	check_true(_host._menu_backdrop.is_visible_in_tree(), "menu backdrop visible in the menu")

	_start_solo(ModeRules.Mode.MARATHON)
	check_true(_host._field.visible, "run active: field visible")
	check_true(_host._game_backdrop.is_visible_in_tree(), "game backdrop visible during a run")
	check_false(_host._menu_backdrop.is_visible_in_tree(), "menu backdrop hidden during a run")

	_host.action_pause()
	check_true(_host._game_backdrop.is_visible_in_tree(), "game backdrop visible while paused")
	check_false(_host._menu_backdrop.is_visible_in_tree(), "menu backdrop stays hidden while paused")

	_host.cmd_return_to_menu()
	check_false(_host._field.visible, "back in menu: field hidden again")
	check_eq(_host._backdrop_layer.get_parent(), _host, "backdrop never reparented by flow commands")
	check_true(_host._game_backdrop.is_visible_in_tree(), "game backdrop still visible back in the menu")
	check_true(_host._menu_backdrop.is_visible_in_tree(), "menu backdrop visible again back in the menu")
	check_true(_host._game_backdrop.size.x > 0.0 and _host._game_backdrop.size.y > 0.0, "backdrop keeps a nonzero size across the lifecycle")


func test_theme_change_updates_game_backdrop() -> void:
	_host.cmd_theme_selected("builtin:retro_crt")
	check_eq(_host._game_backdrop._color.color, Color("#020502"), "game backdrop uses retro crt game.background")
	check_eq(_host._game_backdrop._color.color, _host.themes.tokens()["game.background"], "host pushes the resolved token to the game backdrop")
	check_eq(_host._menu_backdrop._color.color, _host.themes.tokens()["theme.background"], "menu backdrop follows theme.background")
	check_eq(_host._board_renderer._tokens["board.bg"], Color("#04120a"), "playfield keeps its own board.bg")

	_host.cmd_theme_selected("builtin:clean_tournament")
	check_eq(_host._game_backdrop._color.color, Color("#f4f4f6"), "game backdrop follows theme changes")
	check_eq(_host._board_renderer._tokens["board.bg"], Color("#ffffff"), "board color independent of the backdrop")


func test_theme_media_reaches_backdrops() -> void:
	_reload_host_themes_with_test_dirs()
	_write_png_asset("assets/menu.png", Color(0.9, 0.1, 0.1))
	_write_png_asset("assets/game.png", Color(0.1, 0.1, 0.9))
	_write_theme("media_demo.theme", """
		theme {
			name: "Media Demo";
			background: #123456;
			image: "assets/menu.png";
			fit: contain;
			opacity: 0.6;
			tint: #00112280;
		}
		game {
			background: #654321;
			image: "assets/game.png";
		}
	""")
	_host.cmd_themes_reload()
	_host.cmd_theme_selected("user:media_demo")
	check_eq(_host._menu_backdrop._color.color, Color("#123456"), "menu backdrop base color follows theme.background")
	check_true(_host._menu_backdrop._image.texture != null, "menu backdrop shows the themed image")
	check_eq(_host._menu_backdrop._image.texture.get_size(), Vector2(4, 4), "menu image loaded from disk")
	check_eq(_host._menu_backdrop._image.stretch_mode, TextureRect.STRETCH_KEEP_ASPECT_CENTERED, "fit: contain letterboxes the image")
	check_eq(_host._menu_backdrop._media_root.modulate, Color(1.0, 1.0, 1.0, 0.6), "opacity applies to the media layer")
	check_eq(_host._menu_backdrop._tint.color, Color("#00112280"), "tint color applies over the media")
	check_eq(_host._game_backdrop._color.color, Color("#654321"), "game backdrop base color follows game.background")
	check_true(_host._game_backdrop._image.texture != null, "game backdrop shows the themed image")
	check_eq(_host._game_backdrop._image.stretch_mode, TextureRect.STRETCH_KEEP_ASPECT_COVERED, "default fit is cover")
	_restore_host_themes_standard()


func test_theme_video_backdrop_lifecycle() -> void:
	_reload_host_themes_with_test_dirs()
	_write_raw_asset("assets/loop.ogv", PackedByteArray([0x4F, 0x67, 0x67, 0x53, 1, 2, 3, 4]))
	_write_png_asset("assets/cover.png", Color(0.2, 0.2, 0.2))
	_write_theme("video_demo.theme", 'theme {\n\tname: "Video Demo";\n\timage: "assets/cover.png";\n\tvideo: "assets/loop.ogv";\n}\ngame {\n\tvideo: "assets/loop.ogv";\n}\n')
	_write_theme("plain_demo.theme", 'theme {\n\tname: "Plain Demo";\n\tbackground: #202020;\n}\n')
	_host.cmd_themes_reload()
	_host.cmd_theme_selected("user:video_demo")
	var menu_player: Node = _host._menu_backdrop._video
	var game_player: Node = _host._game_backdrop._video
	check_true(menu_player != null, "menu backdrop creates a video player for a themed video")
	check_true(game_player != null, "game backdrop creates a video player")
	check_true(menu_player.loop, "background videos loop")
	check_eq(menu_player.volume, 0.0, "background videos are muted")
	check_true(menu_player.autoplay, "background videos autoplay")
	check_true(_host._menu_backdrop._image.visible, "image stays visible beneath the video as a fallback")
	var old_player_id: int = menu_player.get_instance_id()

	_host.cmd_theme_selected("user:plain_demo")
	check_false(is_instance_valid(instance_from_id(old_player_id)), "previous video player stopped and freed on theme switch")
	check_true(_host._menu_backdrop._video == null, "color-only theme leaves no video player behind")
	check_true(_host._game_backdrop._video == null, "game backdrop video player freed too")

	_host.cmd_theme_selected("user:video_demo")
	check_true(_host._menu_backdrop._video != null, "re-selecting the video theme creates a fresh player")
	check_false(is_instance_valid(instance_from_id(old_player_id)), "the very first player was never revived")
	_restore_host_themes_standard()


func test_theme_fonts_propagate_to_labels() -> void:
	# Ensure a clean slate: back to the menu (clears lingering runs) and the
	# main menu open (items built), with a known built-in selection so the
	# entry mutation below hits the selected theme.
	_host.cmd_return_to_menu()
	_host.cmd_theme_selected("builtin:modern_neon")
	_host._show_main_menu()
	var entry: Dictionary = _host.themes.entry("builtin:modern_neon")
	var title_font := FontFile.new()
	var body_font := FontFile.new()
	entry["media"]["font"] = body_font
	entry["media"]["title_font"] = title_font
	_host._apply_theme()
	check_true(_host._menu._title.has_theme_font_override("font"), "menu heading uses the theme title font")
	check_true(_host._menu._subtitle.has_theme_font_override("font"), "menu subtitle uses the body font")
	check_true(_host._menu._detail.has_theme_font_override("font"), "menu detail uses the body font")
	check_eq(_host._menu._labels.size(), _host._menu._items.size(), "menu items rebuilt with fonts")
	check_eq(_host._menu._labels.size(), 6, "main menu category items present")
	for label in _host._menu._labels:
		check_true(label.has_theme_font_override("font"), "menu item labels use the body font")
	check_true(_host._hud._overlay_title.has_theme_font_override("font"), "hud overlay heading uses the title font")
	check_true(_host._hud._score_label.has_theme_font_override("font"), "hud stat values use the body font")
	check_true(_host._settings_screen._title.has_theme_font_override("font"), "settings heading uses the title font")
	check_true(_host._coop_setup._title.has_theme_font_override("font"), "coop setup heading uses the title font")
	check_true(_host._online_menu._title.has_theme_font_override("font"), "online heading uses the title font")
	check_true(_host._online_menu._status.has_theme_font_override("font"), "online status uses the body font")
	check_true(_host._online_menu._code_edit.has_theme_font_override("font"), "online room code uses the body font")
	for label in _host._title_labels:
		check_true(label.has_theme_font_override("font"), "hold/next labels use the body font")

	# Coop strips build their labels after selection; fonts must reach them.
	_start_coop(2, ModeRules.Mode.MARATHON)
	check_true(_host._coop_tags[0].has_theme_font_override("font"), "coop player tags use the body font")

	# Switching to a fontless built-in clears every override.
	_host.cmd_theme_selected("builtin:retro_crt")
	check_false(_host._menu._title.has_theme_font_override("font"), "menu title override removed with a fontless theme")
	check_false(_host._menu._subtitle.has_theme_font_override("font"), "menu subtitle override removed")
	check_false(_host._menu._detail.has_theme_font_override("font"), "menu detail override removed")
	check_false(_host._hud._score_label.has_theme_font_override("font"), "hud override removed")
	check_false(_host._settings_screen._title.has_theme_font_override("font"), "settings override removed")
	check_false(_host._coop_tags[0].has_theme_font_override("font"), "coop tag override removed")
	check_false(_host._online_menu._title.has_theme_font_override("font"), "online title override removed")
	check_false(_host._online_menu._code_edit.has_theme_font_override("font"), "online room code override removed")
	_host.cmd_return_to_menu()


func test_skins_and_dither_reach_renderers() -> void:
	_reload_host_themes_with_test_dirs()
	_write_png_asset("skins/i.png", Color(0.2, 0.8, 0.2))
	_write_theme("dither_demo.theme", """
		theme {
			name: "Dither Demo";
		}
		pieces {
			i: "skins/i.png";
			o: #ff8800;
			dither: stipple;
			dither_strength: 0.7;
		}
	""")
	_host.cmd_themes_reload()
	_host.cmd_theme_selected("user:dither_demo")
	check_eq(_host._board_renderer._dither, "stipple", "board renderer consumes the dither pattern")
	check_true(is_equal_approx(_host._board_renderer._dither_strength, 0.7), "board renderer consumes the dither strength")
	check_true(_host._board_renderer._skins["i"] != null, "board renderer consumes the i skin")
	check_true(_host._board_renderer._skins["o"] == null, "pieces without a skin stay color-driven")
	check_eq(_host._board_renderer._piece_colors["o"], Color("#ff8800"), "color piece keeps its override")
	check_eq(_host._board_renderer._piece_colors["i"], ThemeProfile.DEFAULT_TOKENS["pieces.i"], "skinned piece keeps the default color as its fallback")
	check_eq(_host._hold_renderer._dither, "stipple", "hold preview follows the dither pattern")
	check_true(_host._hold_renderer._skins["i"] != null, "hold preview consumes the skin")
	check_eq(_host._previews[0]._dither, "stipple", "next previews follow the dither pattern")

	# Coop renderer and minis get the same media when a coop run builds.
	_start_coop(2, ModeRules.Mode.MARATHON)
	check_eq(_host._coop_renderer._dither, "stipple", "coop renderer follows the dither pattern")
	check_true(_host._coop_holds[0]._skins["i"] != null, "coop hold preview consumes the skin")
	_host.cmd_return_to_menu()
	_restore_host_themes_standard()


func test_all_dither_modes_reach_the_board() -> void:
	_reload_host_themes_with_test_dirs()
	for mode in ["bayer", "hatch", "scanline", "stipple"]:
		_write_theme(
			"d_%s.theme" % mode,
			'theme {\n\tname: "D %s";\n}\npieces {\n\tdither: %s;\n}\n' % [mode, mode]
		)
	_host.cmd_themes_reload()
	for mode in ["bayer", "hatch", "scanline", "stipple"]:
		_host.cmd_theme_selected("user:d_" + mode)
		check_eq(_host._board_renderer._dither, mode, "board renderer switches to " + mode)
		check_eq(_host._hold_renderer._dither, mode, "hold preview switches to " + mode)
		check_eq(_host._previews[0]._dither, mode, "next preview switches to " + mode)
	_host.cmd_theme_selected("builtin:modern_neon")
	check_eq(_host._board_renderer._dither, "none", "built-ins without dither stay none")
	_restore_host_themes_standard()


func test_bloom_enables_board_presenter() -> void:
	_reload_host_themes_with_test_dirs()
	_write_png_asset("skins/i.png", Color(0.2, 0.8, 0.2))
	_write_theme("bloom_demo.theme", """
		theme {
			name: "Bloom Demo";
		}
		pieces {
			i: "skins/i.png";
			bloom: true;
		}
	""")
	_host.cmd_themes_reload()
	_host.cmd_theme_selected("user:bloom_demo")
	_start_solo(ModeRules.Mode.MARATHON)
	check_true(_host._board_presenter.bloom_active(), "bloom theme enables the presenter's effect")
	check_eq(_host._board_presenter.bloom_intensity(), ThemeProfile.DEFAULT_BLOOM_INTENSITY, "true normalizes to the default intensity for the presenter")
	check_eq(_host._board_renderer._dither, "none", "bloom activates with no dither declaration at all")
	check_true(_host._board_presenter.is_presenting(), "presenter runs while the field shows a run")
	check_true(_host._board_presenter.board_in_viewport(), "solo board renders through the off-screen viewport")
	check_eq(_host._board_presenter.installed_board(), _host._board_renderer, "solo board installed in the presenter")
	check_eq(_host._board_presenter.position, _host.BOARD_POS, "presenter positioned at the solo board location")
	check_eq(_host._board_presenter.board_size(), Vector2(320, 704), "solo render target covers the full board including hidden rows")
	check_true(_host._board_renderer._skins["i"] != null, "board renderer still consumes skins")
	check_eq(_host._hold_renderer._dither, "none", "hold preview stays undithered")
	check_eq(_host._hold_renderer.get_parent(), _host._field, "hold preview stays outside the bloom render target")
	check_eq(_host._previews[0].get_parent(), _host._field, "next previews stay outside the bloom render target")

	# Co-op: the same wrapper presents the shared board at its dynamic size.
	_start_coop(2, ModeRules.Mode.MARATHON)
	var cell: float = _host._coop_cell_size(2)
	var board_w: float = cell * 20
	check_eq(_host._board_presenter.installed_board(), _host._coop_renderer, "coop board installed in the presenter")
	check_eq(_host._board_presenter.board_size(), Vector2(board_w, cell * 22), "coop render target sized from the dynamic board")
	check_eq(_host._board_presenter.position, Vector2((float(_host.LOGICAL_VIEWPORT.x) - board_w) * 0.5, _host.COOP_BOARD_Y), "coop presenter follows the centered board position")
	check_true(_host._board_presenter.bloom_active(), "bloom stays active for the coop board")
	check_eq(_host._board_presenter.bloom_intensity(), ThemeProfile.DEFAULT_BLOOM_INTENSITY, "coop keeps the configured bloom intensity")
	check_true(_host._board_presenter.board_in_viewport(), "coop board renders through the viewport")
	check_false(_host._board_renderer.visible, "solo board parked and hidden during coop")

	# Teardown restores the solo board in the wrapper without stale coop output.
	_host.cmd_return_to_menu()
	check_eq(_host._board_presenter.installed_board(), _host._board_renderer, "solo board reinstalled after coop teardown")
	check_eq(_host._board_presenter.board_size(), Vector2(320, 704), "solo layout restored after coop teardown")
	check_eq(_host._board_presenter.position, _host.BOARD_POS, "solo position restored after coop teardown")
	check_true(_host._board_presenter.bloom_active(), "bloom state persists through coop teardown")
	check_false(_host._board_presenter.is_presenting(), "presenter idle in the menu")
	_restore_host_themes_standard()


func test_bloom_toggle_tracks_theme_changes() -> void:
	_reload_host_themes_with_test_dirs()
	_write_theme("bloom_toggle.theme", 'theme {\n\tname: "Bloom Toggle";\n}\npieces {\n\tdither: none;\n\tbloom: 1.25;\n}\n')
	_host.cmd_themes_reload()
	_host.cmd_theme_selected("user:bloom_toggle")
	_start_solo(ModeRules.Mode.MARATHON)
	_host._process(0.3)
	var core_id: int = _host.core.get_instance_id()
	var elapsed: float = _host.core.elapsed
	check_true(_host._board_presenter.bloom_active(), "numeric bloom active during the run")
	check_eq(_host._board_presenter.bloom_intensity(), 1.25, "presenter receives the custom numeric intensity")
	check_true(_host._board_presenter.board_in_viewport(), "board on the bloom path during the run")

	# Switching to a bloom-free built-in disables the wrapper immediately.
	_host.cmd_theme_selected("builtin:modern_neon")
	check_false(_host._board_presenter.bloom_active(), "bloom-free theme disables the presenter's effect")
	check_eq(_host._board_presenter.bloom_intensity(), 0.0, "bloom-free theme resets the intensity")
	check_false(_host._board_presenter.board_in_viewport(), "board back on the direct draw path")
	check_eq(_host._board_presenter.installed_board(), _host._board_renderer, "board never replaced by the toggle")
	check_eq(_host.core.get_instance_id(), core_id, "core instance kept across the toggle")
	check_eq(_host.core.elapsed, elapsed, "timer untouched by the toggle")

	# Editing the custom theme's numeric bloom applies mid-run via reload,
	# without replacing or mutating the active core.
	_write_theme("bloom_toggle.theme", 'theme {\n\tname: "Bloom Toggle";\n}\npieces {\n\tdither: bayer;\n\tdither_strength: 0.6;\n\tbloom: 0.4;\n}\n')
	_host.cmd_theme_selected("user:bloom_toggle")
	check_true(_host._board_presenter.bloom_active(), "reselecting the bloom theme re-enables the pass")
	check_eq(_host._board_presenter.bloom_intensity(), 1.25, "selection applies the previously scanned entry until the reload")
	_host.cmd_themes_reload()
	check_true(_host._board_presenter.bloom_active(), "reload keeps the edited bloom theme active")
	check_eq(_host._board_presenter.bloom_intensity(), 0.4, "edited numeric bloom reaches the presenter after reload")
	check_eq(_host._board_renderer._dither, "bayer", "edited dither reaches the board after reload")
	check_eq(_host.core.get_instance_id(), core_id, "core instance kept across the reload")

	# `false` and `0.0` use the direct board path, dither or not.
	_write_theme("bloom_toggle.theme", 'theme {\n\tname: "Bloom Toggle";\n}\npieces {\n\tdither: hatch;\n\tbloom: false;\n}\n')
	_host.cmd_themes_reload()
	check_false(_host._board_presenter.bloom_active(), "bloom false stays inactive even with a visible dither")
	check_eq(_host.core.get_instance_id(), core_id, "core instance kept across the false case")
	_write_theme("bloom_toggle.theme", 'theme {\n\tname: "Bloom Toggle";\n}\npieces {\n\tdither: none;\n\tbloom: 0.0;\n}\n')
	_host.cmd_themes_reload()
	check_false(_host._board_presenter.bloom_active(), "explicit zero stays inactive")
	check_eq(_host.core.get_instance_id(), core_id, "core instance kept across the zero case")

	# `true` activates the pass with dither none: bloom is dither-independent.
	_write_theme("bloom_toggle.theme", 'theme {\n\tname: "Bloom Toggle";\n}\npieces {\n\tdither: none;\n\tbloom: true;\n}\n')
	_host.cmd_themes_reload()
	check_true(_host._board_presenter.bloom_active(), "bloom true activates the pass even with dither none")
	check_eq(_host._board_presenter.bloom_intensity(), ThemeProfile.DEFAULT_BLOOM_INTENSITY, "true normalizes to the default intensity")
	check_eq(_host.core.get_instance_id(), core_id, "core instance kept to the end")
	_host.cmd_return_to_menu()
	_restore_host_themes_standard()


func test_theme_media_reload_after_asset_deleted() -> void:
	_reload_host_themes_with_test_dirs()
	_write_png_asset("assets/temp.png", Color(0.5, 0.5, 0.5))
	_write_theme("vanishing.theme", 'theme {\n\tname: "Vanishing";\n\timage: "assets/temp.png";\n}\n')
	_host.cmd_themes_reload()
	_host.cmd_theme_selected("user:vanishing")
	check_true(_host._menu_backdrop._image.texture != null, "image backdrop applied before deletion")

	DirAccess.remove_absolute(USER_DIR.path_join("assets/temp.png"))
	_host.cmd_themes_reload()
	check_eq(_host.themes.selected_id, "user:vanishing", "theme stays selected after its asset disappears")
	check_true(_host._menu_backdrop._image.texture == null, "media falls back after reload")
	check_eq(_host._menu_backdrop._color.color, _host.themes.tokens()["theme.background"], "color backdrop still applies")
	var warned := false
	for invalid_entry in _host.themes.invalid:
		if invalid_entry["id"] == "user:vanishing" and invalid_entry.get("soft", false):
			warned = true
	check_true(warned, "missing asset reported as a warning after reload")
	_restore_host_themes_standard()


func test_settings_screen_covers_with_menu_scrim() -> void:
	_host.cmd_theme_selected("builtin:clean_tournament")
	check_eq(_host._settings_screen._bg.color, _host.themes.tokens()["menu.scrim"], "settings screen dims the menu backdrop with menu.scrim")


func test_theme_reload_repairs_lost_selection() -> void:
	_host.cmd_theme_selected("builtin:retro_crt")
	var result: Dictionary = _host.cmd_themes_reload()
	check_false(result["repaired"], "existing theme kept on reload")
	check_eq(_host.themes.selected_id, "builtin:retro_crt", "selection preserved")
	check_eq(_host._game_backdrop._color.color, _host.themes.tokens()["game.background"], "reload keeps the backdrop in sync with the resolved theme")

	_host.cmd_theme_selected("user:ghost_missing")
	check_eq(_host.themes.selected_id, "builtin:retro_crt", "unknown id rejected, selection kept")
	check_eq(_host.settings.theme_id, "builtin:retro_crt", "settings untouched by rejected id")


# ---------------------------------------------------- settings screen layout

func test_settings_categories_reachable() -> void:
	var screen: CanvasLayer = _host._settings_screen
	screen.open()
	check_eq(screen._mode, "controls", "settings open on controls")
	for expected in ["display", "audio", "reset", "controls"]:
		screen._change_category(1)
		check_eq(screen._mode, expected, "category cycles in order: " + expected)

	var kinds: Array = []
	for mode in ["controls", "display", "audio", "reset"]:
		screen._mode = mode
		screen._rebuild()
		var has_back := false
		var has_category_row := false
		for row in screen._rows:
			if row["kind"] == "command" and row["id"] == "back":
				has_back = true
			if row["kind"] == "category":
				has_category_row = true
		check_true(has_back, "back available in " + mode)
		check_true(has_category_row, "category row in " + mode)
		kinds.append(mode)
	check_eq(kinds.size(), 4, "all four categories iterated")


func test_settings_display_has_theme_rows() -> void:
	var screen: CanvasLayer = _host._settings_screen
	screen.open()
	screen._mode = "display"
	screen._rebuild()
	var theme_row := -1
	var reload_row := -1
	for i in screen._rows.size():
		var row: Dictionary = screen._rows[i]
		if row["kind"] == "theme":
			theme_row = i
		if row["kind"] == "command" and row["id"] == "themes_reload":
			reload_row = i
	check_true(theme_row >= 0, "theme row present in display")
	check_true(reload_row >= 0, "reload themes row present in display")
	check_false(screen._row_value(screen._rows[theme_row]).is_empty(), "theme value shows the active theme")
	screen._cycle_theme(1)
	check_eq(_host.themes.selected_id, "builtin:retro_crt", "cycling selects the next theme")
	check_eq(_host.settings.theme_id, "builtin:retro_crt", "theme choice committed immediately")
	check_eq(_host._game_backdrop._color.color, _host.themes.tokens()["game.background"], "settings theme cycle recolors the backdrop live")


func test_settings_subviews_return_to_categories() -> void:
	var screen: CanvasLayer = _host._settings_screen
	screen.open()
	screen._mode = "kb"
	screen._rebuild()
	screen._back()
	check_eq(screen._mode, "controls", "keyboard bindings back to controls")
	screen._mode = "playlist"
	screen._rebuild()
	screen._back()
	check_eq(screen._mode, "audio", "playlist back to audio")
	# The guided controller flow discards back to the controls category.
	screen.open_controller_binding(_host.settings.active_profile_id)
	check_eq(screen._mode, "padbind", "guided controller flow opens")
	screen._cancel_padbind()
	check_eq(screen._mode, "controls", "controller binding back to controls")
	check_eq(screen._pad_stage, "", "guided flow discarded cleanly")


func test_settings_row_window_keeps_selection_visible() -> void:
	var screen: CanvasLayer = _host._settings_screen
	screen.open()
	screen._mode = "playlist"
	# Simulate a large library: windowing must keep the selection in view.
	var rows: Array = []
	for i in 60:
		rows.append({"kind": "library_track", "id": "track%d" % i})
	screen._rows = rows
	screen._selected = 0
	var window: Array = screen._window_range()
	check_eq(window[1] - window[0], screen.MAX_VISIBLE_ROWS_COMPACT, "window bounded to capacity")
	check_true(window[0] <= 0 and 0 < window[1], "first selection visible")
	screen._selected = 45
	window = screen._window_range()
	check_true(window[0] <= 45 and 45 < window[1], "deep selection scrolled into view")
	check_eq(window[1] - window[0], screen.MAX_VISIBLE_ROWS_COMPACT, "window size constant")
	screen._selected = 59
	window = screen._window_range()
	check_true(window[0] <= 59 and 59 < window[1], "last selection visible")


func test_theme_command_keeps_run_state_machine() -> void:
	_start_coop(3, ModeRules.Mode.MARATHON)
	_host.action_pause()
	var session_id: int = _host.coop.get_instance_id()
	_host.cmd_theme_selected("builtin:clean_tournament")
	check_eq(_host.coop.get_instance_id(), session_id, "coop session kept across theme change")
	check_eq(_host.themes.selected_id, "builtin:clean_tournament", "clean tournament applied")
	check_eq(_host._coop_renderer._tokens["board.bg"], _host.themes.tokens()["board.bg"], "coop renderer themed")
	_host.cmd_resume()
	check_eq(_host.coop.get_instance_id(), session_id, "coop session still the same after resume")
