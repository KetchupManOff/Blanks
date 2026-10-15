extends "res://tests/test_lib.gd"
## Host shell flow smoke tests: startup state, profile-picker routing into
## solo runs, run lifecycle, pause/settings round trip preserving the core,
## result persistence into profile histories, profile management (screen,
## on-screen keyboard, guided controller rebinding), and results handling.
## The suite setup runs once, so every test returns the host to a known
## state first and uses freshly created profiles instead of depending on
## test order.

const CoreGame = preload("res://scripts/core/game.gd")
const ModeRules = preload("res://scripts/core/mode_rules.gd")
const SettingsClass = preload("res://scripts/persistence/settings.gd")
const DefaultBindings = preload("res://scripts/input/default_bindings.gd")
const OnlineServiceScript = preload("res://scripts/online/online_service.gd")

var _host: Node = null
# Fake joypad snapshot fed to claim trackers in this suite.
var _fake_pressed: Dictionary = {}


func setup() -> void:
	var scene: PackedScene = load("res://scenes/main.tscn")
	_host = scene.instantiate()
	tree.root.add_child(_host)
	# Adding a node during the runner's construction defers _ready to the
	# first frame, which never happens before quit. Drive the host's _ready
	# body manually, initializing the scripted children that own UI state.
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


func teardown() -> void:
	if _host != null:
		_host.free()
		_host = null


## Discards any run/overlay state and shows the main menu.
func _to_menu() -> void:
	_host._osk.close()
	if _host._profile_screen.is_open():
		_host._profile_screen.close()
	_host._show_main_menu()


## Creates a uniquely named probe profile; test bodies depend on no
## cross-test state.
func _fresh_profile(tag: String) -> String:
	return _host.settings.create_profile(tag)


func _start_solo(mode: int, profile_id: String = "") -> void:
	## Start a solo run through the host command the profile picker uses.
	_to_menu()
	var id: String = profile_id if not profile_id.is_empty() else _host.settings.active_profile_id
	_host.cmd_solo_profile_selected(id, mode)


func _menu_labels() -> Array:
	var labels: Array = []
	for item in _host._menu._items:
		labels.append(item["label"])
	return labels


# ------------------------------------------------------------------ startup

func test_00_startup_state() -> void:
	check_eq(_host.state, _host.HostState.MAIN_MENU, "host starts in main menu")
	check_true(_host.core == null, "no gameplay core until a mode is selected")
	check_true(_host._menu.is_open(), "main menu visible")
	check_false(_host._pause_menu.is_open(), "pause menu hidden")
	check_false(_host._settings_screen.visible, "settings screen hidden")
	check_false(_host._profile_screen.visible, "profile screen hidden")
	check_false(_host._osk.visible, "name entry hidden")
	check_false(_host._field.visible, "playfield hidden without a run")
	check_false(_host._hud.visible, "hud hidden without a run")


func test_portable_dirs_disabled_in_editor() -> void:
	# Loose content folders resolve against the running executable; from
	# the editor that would be the editor binary's folder, so they must
	# stay disabled while developing and testing.
	check_eq(_host._portable_dir("themes"), "", "no portable themes dir in editor")
	check_eq(_host._portable_dir("music"), "", "no portable music dir in editor")
	check_eq(_host._portable_dir("sfx"), "", "no portable sfx dir in editor")


func test_main_menu_lists_categories() -> void:
	_to_menu()
	check_eq(_menu_labels(), [
		"SOLO",
		"LOCAL MULTIPLAYER",
		"ONLINE MULTIPLAYER",
		"PROFILES",
		"SETTINGS",
		"QUIT",
	], "main menu lists the six categories in order")


func test_main_menu_shows_active_profile() -> void:
	_to_menu()
	check_true(_host._menu._detail.text.contains(_host.active_profile_name().to_upper()), "main menu shows the active profile name")
	var id := _fresh_profile("Zeta")
	check_true(id != "", "second profile created")
	_host.settings.set_active_profile(id)
	_host._show_main_menu()
	check_true(_host._menu._detail.text.contains("ZETA"), "summary follows the active profile")


func test_solo_menu_open_and_back() -> void:
	_to_menu()
	_host.cmd_open_solo_menu()
	check_eq(_host.state, _host.HostState.MAIN_MENU, "solo chooser keeps the menu state")
	check_eq(_menu_labels(), ["MARATHON", "40-LINE SPRINT", "TOWER", "BACK"], "solo chooser lists the solo modes and back")
	_host.cmd_solo_menu_back()
	check_eq(_menu_labels(), [
		"SOLO",
		"LOCAL MULTIPLAYER",
		"ONLINE MULTIPLAYER",
		"PROFILES",
		"SETTINGS",
		"QUIT",
	], "back restores the top-level menu")


# -------------------------------------------- cinematic menu presentation
# The shared controller renders a lower-center composition: no centered
# dialog card, one full-width row per item, and the selected row alone
# carrying the theme's panel treatment. Every screen that inherits the
# controller must keep that contract.

func _menu() -> CanvasLayer:
	return _host._menu


func test_menu_cinematic_layout_structure() -> void:
	_to_menu()
	var menu: CanvasLayer = _menu()
	check_true(menu._root.find_children("*", "CenterContainer", true, false).is_empty(), "no legacy centered dialog wrapper")
	check_true(menu._root.find_children("*", "HBoxContainer", true, false).is_empty(), "no legacy split columns")
	check_true(menu._menu_block != null and menu._items_box != null, "lower-center menu block built")
	check_true(menu._menu_block is VBoxContainer, "menu block is a vertical stack")
	check_true(is_equal_approx(menu._menu_block.anchor_left, 0.5), "menu block anchored to the horizontal center")
	check_true(is_equal_approx(menu._menu_block.anchor_right, 0.5), "menu block keeps both horizontal anchors centered")
	check_true(menu._menu_block.anchor_top > 0.5, "menu block sits below the vertical midpoint")
	check_eq(menu._menu_block.grow_horizontal, Control.GROW_DIRECTION_BOTH, "menu block grows symmetrically")
	check_eq(menu._rows.size(), menu._items.size(), "one row control per logical item")
	check_eq(menu._rows.size(), 6, "top-level menu rows present")
	check_eq(menu._labels.size(), menu._rows.size(), "one label per row")
	for i in menu._rows.size():
		check_true(menu._rows[i] is PanelContainer, "row is a panel surface")
		check_eq(menu._rows[i].get_parent(), menu._items_box, "row parented to the menu container")
		check_eq(menu._labels[i].get_parent(), menu._rows[i], "label parented to its row")


func test_menu_selected_row_distinguished() -> void:
	_to_menu()
	var menu: CanvasLayer = _menu()
	var tokens: Dictionary = _host.themes.tokens()
	var sel: int = menu._selected
	check_eq(menu._row_styles[sel].bg_color, tokens["menu.panel"], "selected row background comes from menu.panel")
	check_eq(menu._row_styles[sel].border_color, tokens["menu.divider"], "selected row border comes from menu.divider")
	check_eq(menu._labels[sel].get_theme_color("font_color"), tokens["menu.focus"], "selected label uses menu.focus")
	var other: int = 0 if sel != 0 else 1
	check_eq(menu._row_styles[other].bg_color.a, 0.0, "unselected row background is transparent")
	check_eq(menu._row_styles[other].border_width_left, 0, "unselected row has no border")
	check_eq(menu._labels[other].get_theme_color("font_color"), tokens["theme.dim"], "unselected label uses theme.dim")
	# Movement swaps the treatment synchronously so tests and instant
	# relayouts always observe the final state.
	menu._move(1)
	var moved: int = menu._selected
	check_eq(menu._row_styles[moved].bg_color, tokens["menu.panel"], "highlight follows movement instantly")
	check_eq(menu._row_styles[moved].border_color, tokens["menu.divider"], "border follows movement instantly")
	check_eq(menu._row_styles[sel].bg_color.a, 0.0, "previously selected row fades out of the treatment")


func test_menu_bounds_centered_inside_root() -> void:
	_to_menu()
	var menu: CanvasLayer = _menu()
	var root_rect: Rect2 = menu._root.get_global_rect()
	var block_rect: Rect2 = menu._menu_block.get_global_rect()
	var header_rect: Rect2 = menu._header.get_global_rect()
	check_true(root_rect.size.x > 0.0 and root_rect.size.y > 0.0, "menu root sized to the viewport")
	check_true(root_rect.encloses(block_rect), "menu block stays inside the root bounds")
	check_true(absf(block_rect.get_center().x - root_rect.get_center().x) <= 1.0, "menu block horizontally centered")
	check_true(block_rect.position.y >= header_rect.end.y, "heading region and menu block never overlap")
	# The headless runner processes no frames, so a live viewport resize
	# cannot be observed here; the resize-proof contract is the anchor
	# data itself: symmetric horizontal anchors with zero offsets and
	# bidirectional growth re-center the block under any viewport size.
	check_eq(menu._menu_block.offset_left, 0.0, "menu block needs no horizontal offset to be centered")
	check_eq(menu._menu_block.offset_right, 0.0, "menu block keeps symmetric offsets")
	check_eq(menu._menu_block.grow_vertical, Control.GROW_DIRECTION_BOTH, "menu block grows symmetrically vertically")


func test_menu_presentation_shared_across_screens() -> void:
	var menu: CanvasLayer = _menu()
	var tokens: Dictionary = _host.themes.tokens()
	_to_menu()
	_host.cmd_open_solo_menu()
	check_eq(menu._rows.size(), menu._items.size(), "solo chooser rows rebuilt")
	check_eq(menu._rows.size(), 4, "solo chooser row count")
	check_eq(menu._items_box.get_parent(), menu._menu_block, "solo chooser keeps the shared composition")
	check_eq(menu._row_styles[menu._selected].bg_color, tokens["menu.panel"], "solo chooser selected row themed")
	_host.cmd_solo_menu_back()

	# Pause and its confirmation inherit the same presentation.
	_start_solo(ModeRules.Mode.MARATHON)
	_host.action_pause()
	check_eq(_host._pause_menu._rows.size(), _host._pause_menu._items.size(), "pause rows match its items")
	check_eq(_host._pause_menu._row_styles[_host._pause_menu._selected].bg_color, tokens["menu.panel"], "pause selected row themed")
	_host.cmd_confirm_return_to_menu()
	check_eq(_host._pause_menu._rows.size(), 2, "confirmation rows rebuilt")
	check_eq(_host._pause_menu._row_styles[_host._pause_menu._selected].bg_color, tokens["menu.panel"], "confirmation selected row themed")
	_host.cmd_resume()

	# Result overlays keep the composition too.
	_host.core.phase = CoreGame.Phase.GAME_OVER
	_host._process(0.0)
	check_true(menu.is_open(), "results overlay open")
	check_eq(menu._rows.size(), 3, "results rows rebuilt")
	check_eq(menu._row_styles[menu._selected].bg_color, tokens["menu.panel"], "results selected row themed")
	check_eq(menu._labels[menu._selected].get_theme_color("font_color"), tokens["menu.focus"], "results selected label themed")


# ------------------------------------------------------------ profile picker

func test_solo_modes_select_profile_first() -> void:
	# Solo games start through the profile picker; the host itself stays
	# in the menu until a profile is picked.
	_to_menu()
	_host.cmd_open_solo_menu()
	_host.cmd_start_marathon()
	check_eq(_host.state, _host.HostState.MAIN_MENU, "marathon command opens the picker without starting")
	check_true(_host._profile_screen.is_open(), "profile screen visible")
	check_false(_host._menu.is_open(), "menu closed behind the picker")
	_host.cmd_profile_screen_back()
	check_eq(_host.state, _host.HostState.MAIN_MENU, "picker back stays in the menu state")
	var solo_labels := _menu_labels()
	check(solo_labels.has("MARATHON"), "picker cancel restores the solo chooser")
	check_false(solo_labels.has("QUIT"), "picker cancel does not reach the top-level list")

	_host.cmd_start_sprint()
	check_true(_host._profile_screen.is_open(), "sprint opens the picker too")
	_start_solo(ModeRules.Mode.SPRINT)
	check_eq(_host.state, _host.HostState.PLAYING, "picking a profile starts the run")
	check_eq(_host.core.mode, ModeRules.Mode.SPRINT, "sprint mode selected")
	check_true(_host.core != null, "core created")
	check_false(_host._profile_screen.is_open(), "picker closed")


func test_profile_manage_back_returns_to_top_level() -> void:
	# Profile management (not a solo start) still backs out to the
	# top-level menu, never the solo chooser.
	_to_menu()
	_host.cmd_open_profiles()
	check_true(_host._profile_screen.is_open(), "profile browser opens")
	_host.cmd_profile_screen_back()
	check_false(_host._profile_screen.is_open(), "browser closed")
	var labels := _menu_labels()
	check(labels.has("QUIT"), "profile management back lands on the top-level menu")
	check_false(labels.has("MARATHON"), "management back never opens the solo chooser")


func test_start_marathon() -> void:
	_start_solo(ModeRules.Mode.MARATHON)
	check_eq(_host.state, _host.HostState.PLAYING, "marathon starts playing")
	check_eq(_host.core.mode, ModeRules.Mode.MARATHON, "marathon mode selected")
	check_true(_host._field.visible, "playfield visible during run")
	check_true(_host._hud.visible, "hud visible during run")
	check_false(_host._menu.is_open(), "menu closed")
	_host._process(0.5)
	check_true(_host.core.elapsed > 0.0, "simulation advances while playing")


func test_solo_start_assigns_first_connected_pad() -> void:
	# Headless runs have no pads: solo input stays keyboard-only.
	_start_solo(ModeRules.Mode.MARATHON)
	check_eq(_host.input_solo_profile_id(), _host.settings.active_profile_id, "solo profile assigned to the input layer")
	check_eq(_host.input_solo_device(), -1, "no connected pad means keyboard-only input")
	check_false(_host.input_solo_bindings().is_empty(), "solo controller bindings cached for polling")


func test_solo_start_records_participating_profile() -> void:
	var id := _fresh_profile("SoloTrack")
	_start_solo(ModeRules.Mode.MARATHON, id)
	check_eq(_host._run_profile_ids, [id], "run tracks its participating profile")


# --------------------------------------------------------------- pause cycle

func test_pause_settings_resume_preserves_run() -> void:
	_start_solo(ModeRules.Mode.MARATHON)
	_host._process(0.3)
	var core_id: int = _host.core.get_instance_id()
	var elapsed: float = _host.core.elapsed

	_host.action_pause()
	check_eq(_host.state, _host.HostState.PAUSED, "pause freezes the run")
	check_true(_host._pause_menu.is_open(), "pause menu shown")

	_host.cmd_open_settings_from_pause()
	check_eq(_host.state, _host.HostState.SETTINGS, "settings opens over pause")
	check_true(_host._settings_screen.visible, "settings screen visible")
	_host._process(1.0)
	check_eq(_host.core.elapsed, elapsed, "simulation timer frozen while in settings")
	check_eq(_host.core.get_instance_id(), core_id, "same core instance kept")

	_host.cmd_settings_back()
	check_eq(_host.state, _host.HostState.PAUSED, "settings returns to pause")
	check_true(_host._pause_menu.is_open(), "pause menu restored")

	_host.cmd_resume()
	check_eq(_host.state, _host.HostState.PLAYING, "resume continues the run")
	check_eq(_host.core.get_instance_id(), core_id, "resume keeps the same core instance")
	check_eq(_host.core.elapsed, elapsed, "elapsed time did not advance while paused")
	check_false(_host._pause_menu.is_open(), "pause menu closed on resume")


func test_pause_resume_via_pause_action() -> void:
	_start_solo(ModeRules.Mode.MARATHON)
	_host.action_pause()
	check_eq(_host.state, _host.HostState.PAUSED, "pause action pauses")
	_host.action_pause()
	check_eq(_host.state, _host.HostState.PLAYING, "pause action resumes")


func test_restart_from_pause() -> void:
	_start_solo(ModeRules.Mode.MARATHON)
	var first_id: int = _host.core.get_instance_id()
	_host.action_pause()
	_host.cmd_restart_run()
	check_eq(_host.state, _host.HostState.PLAYING, "restart returns to playing")
	check_true(_host.core.get_instance_id() != first_id, "restart creates a fresh core")
	check_eq(_host.input_solo_profile_id(), _host.settings.active_profile_id, "restart keeps the solo profile assignment")
	check_false(_host._pause_menu.is_open(), "pause menu closed after restart")


func test_return_to_menu_clears_run() -> void:
	_start_solo(ModeRules.Mode.MARATHON)
	_host.cmd_return_to_menu()
	check_eq(_host.state, _host.HostState.MAIN_MENU, "back to main menu")
	check_true(_host.core == null, "core released")
	check_true(_host._menu.is_open(), "main menu shown")
	check_false(_host._field.visible, "playfield hidden again")
	check_false(_host._hud.visible, "hud hidden again")
	check_eq(_host._run_profile_ids, [], "run bookkeeping cleared")


# -------------------------------------------------------- result persistence

func test_marathon_game_over_records_result() -> void:
	var id := _fresh_profile("MgoProbe")
	_start_solo(ModeRules.Mode.MARATHON, id)
	_host.core.score = 5000
	_host.core.phase = CoreGame.Phase.GAME_OVER
	_host._process(0.0)
	var history: Array = _host.settings.profile_history(id, "solo_marathon")
	check_eq(history.size(), 1, "game over records one result")
	check_eq(history[0]["score"], 5000, "score stored")
	check_eq(history[0]["players"], 1, "solo player count stored")
	check_eq(history[0]["mode"], "solo_marathon", "mode key stored")
	check_true(history[0]["elapsed"] >= 0.0, "elapsed stored")
	check_eq(_host._last_results["subtitle"], "Score 5000", "first result has no personal-best suffix")
	check_eq(_host.state, _host.HostState.GAME_OVER, "game over state")
	# The guard holds across repeated _process observations.
	_host._process(0.0)
	check_eq(_host.settings.profile_history(id, "solo_marathon").size(), 1, "no duplicate record")


func test_second_marathon_run_places_against_personal_best() -> void:
	var id := _fresh_profile("SecondProbe")
	_start_solo(ModeRules.Mode.MARATHON, id)
	_host.core.score = 5000
	_host.core.phase = CoreGame.Phase.GAME_OVER
	_host._process(0.0)
	_host.cmd_restart_run()
	check_eq(_host.settings.profile_history(id, "solo_marathon").size(), 1, "retry alone adds no result")
	_host.core.score = 3000
	_host.core.phase = CoreGame.Phase.GAME_OVER
	_host._process(0.0)
	var history: Array = _host.settings.profile_history(id, "solo_marathon")
	check_eq(history.size(), 2, "the retried run records its own result")
	check_eq(history[0]["score"], 5000, "best first")
	check_true(_host._last_results["subtitle"].contains("Best 5000"), "subtitle shows the personal best")
	check_true(_host._last_results["subtitle"].contains("#2"), "subtitle shows the placement")


func test_new_personal_best_announced() -> void:
	var id := _fresh_profile("BestProbe")
	_start_solo(ModeRules.Mode.MARATHON, id)
	_host.core.score = 2000
	_host.core.phase = CoreGame.Phase.GAME_OVER
	_host._process(0.0)
	_host.cmd_restart_run()
	_host.core.score = 9000
	_host.core.phase = CoreGame.Phase.GAME_OVER
	_host._process(0.0)
	check_true(_host._last_results["subtitle"].contains("NEW PERSONAL BEST"), "beating the best announces it")
	check_eq(_host.settings.profile_history(id, "solo_marathon")[0]["score"], 9000, "history reordered to the new best")


func test_sprint_game_over_records_nothing() -> void:
	var id := _fresh_profile("SgoProbe")
	_start_solo(ModeRules.Mode.SPRINT, id)
	_host.core.phase = CoreGame.Phase.GAME_OVER
	_host._process(0.0)
	check_eq(_host.state, _host.HostState.GAME_OVER, "game over state")
	check_eq(_host.settings.profile_history(id, "solo_sprint").size(), 0, "abandoned sprint records nothing")


func test_sprint_finish_records_time() -> void:
	var id := _fresh_profile("SfinProbe")
	_start_solo(ModeRules.Mode.SPRINT, id)
	_host.core.phase = CoreGame.Phase.FINISHED
	_host._process(0.0)
	check_eq(_host.state, _host.HostState.FINISHED, "finished state")
	var history: Array = _host.settings.profile_history(id, "solo_sprint")
	check_eq(history.size(), 1, "finished sprint records one result")
	check_true(_host._last_results["subtitle"].contains("40 lines in"), "finish subtitle kept")


func test_menu_return_discards_unfinished_run() -> void:
	var id := _fresh_profile("DiscardProbe")
	_start_solo(ModeRules.Mode.MARATHON, id)
	_host.cmd_return_to_menu()
	_host._process(0.0)
	check_eq(_host.state, _host.HostState.MAIN_MENU, "menu state")
	check_eq(_host.settings.profile_history(id, "solo_marathon").size(), 0, "unfinished run never recorded")


# ----------------------------------------------------- profile screen flows

func test_profile_screen_browse_and_activate() -> void:
	_to_menu()
	_host.cmd_open_profiles()
	check_true(_host._profile_screen.is_open(), "profile browser opens")
	var labels: Array = []
	for item in _host._profile_screen._items:
		labels.append(item["label"])
	check(labels.has("Player 1  [ACTIVE]") or _labels_have_active(labels), "active profile marked")
	check(labels.has("CREATE PROFILE"), "create entry present")

	var id_b := _fresh_profile("Bravo")
	check_true(id_b != "", "second profile created")
	_host._profile_screen.refresh()
	# Select the second profile row, open its submenu, and activate it.
	var row := _find_profile_row(id_b)
	check_true(row >= 0, "new profile listed")
	_host._profile_screen._selected = row
	_host._profile_screen._activate()
	check_eq(_host._profile_screen._submenu_profile_id, id_b, "submenu opens for the profile")
	_host._profile_screen._selected = 0
	_host._profile_screen._activate()
	check_eq(_host.settings.active_profile_id, id_b, "set active applied")
	_host._show_main_menu()
	check_true(_host._menu._detail.text.contains("BRAVO"), "menu summary follows the new active profile")


func _labels_have_active(labels: Array) -> bool:
	for label in labels:
		if String(label).contains("[ACTIVE]"):
			return true
	return false


func _find_profile_row(profile_id: String) -> int:
	for i in _host._profile_screen._items.size():
		var bound: Array = (_host._profile_screen._items[i]["callback"] as Callable).get_bound_arguments()
		if bound.size() > 0 and String(bound[0]) == profile_id:
			return i
	return -1


func test_profile_screen_histories_detail() -> void:
	var id := _fresh_profile("HistProbe")
	_host.settings.append_result(id, "solo_marathon", {"score": 4321, "elapsed": 10.0, "completed_at": 5, "players": 1, "mode": "solo_marathon"}, true)
	_host.settings.append_result(id, "solo_sprint", {"score": 400, "elapsed": 61.5, "completed_at": 6, "players": 1, "mode": "solo_sprint"}, false)
	_to_menu()
	_host.cmd_open_profiles()
	_host._profile_screen._selected = _find_profile_row(id)
	_host._profile_screen._update_detail()
	var text: String = _host._profile_screen._detail.text
	check_true(text.contains("HISTPROBE"), "detail names the profile")
	check_true(text.contains("MARATHON:"), "marathon history listed")
	check_true(text.contains("4321"), "score shown")
	check_true(text.contains("01:01.50"), "sprint time formatted")
	# Empty histories report cleanly.
	var id_empty := _fresh_profile("EchoProbe")
	_host._profile_screen.refresh()
	_host._profile_screen._selected = _find_profile_row(id_empty)
	_host._profile_screen._update_detail()
	check_true(_host._profile_screen._detail.text.contains("NO RESULTS YET"), "profile without results says so")


# --------------------------------------------------------- on-screen keyboard

func _osk() -> CanvasLayer:
	return _host._osk


func test_osk_create_profile_flow() -> void:
	_to_menu()
	_host.cmd_open_profiles()
	_host._profile_screen._selected = _host._profile_screen._items.size() - 2  # CREATE PROFILE row
	_host._profile_screen._activate()
	check_true(_osk().is_open(), "name entry opens for a new profile")
	_osk()._type_char("R")
	_osk()._type_char("o")
	_osk()._type_char("x")
	_osk()._confirm()
	check_false(_osk().is_open(), "keyboard closes on commit")
	check_true(_host.settings.profile_name_taken("Rox"), "profile created through the host")
	check_true(_host._profile_screen.is_open(), "profile browser stays open after create")
	var found := false
	for item in _host._profile_screen._items:
		if String(item["label"]).contains("Rox"):
			found = true
	check_true(found, "new profile listed")


func test_osk_grid_navigation() -> void:
	_to_menu()
	_host.cmd_open_name_create(-1)
	check_eq(_osk()._cursor, 0, "cursor starts at A")
	_osk()._move_cursor(1, 0)
	check_eq(_osk()._cursor, 6, "down moves a full row")
	_osk()._move_cursor(0, 1)
	check_eq(_osk()._cursor, 7, "right moves one cell")
	_osk()._move_cursor(0, -1)
	check_eq(_osk()._cursor, 6, "left clamps at the row start")
	for i in 7:
		_osk()._move_cursor(1, 0)
	check_eq(_osk()._cursor, 42, "down lands on the control row")
	_osk()._move_cursor(0, 1)
	check_eq(_osk()._cursor, 43, "right moves within the control row")
	_osk()._move_cursor(0, 1)
	_osk()._move_cursor(0, 1)
	check_eq(_osk()._cursor, 44, "control row clamps at its width")
	_osk()._move_cursor(-1, 0)
	check_eq(_osk()._cursor, 38, "up from the control row lands on the last char row")


func test_osk_delete_and_backspace() -> void:
	_to_menu()
	_host.cmd_open_name_create(-1)
	_osk()._type_char("A")
	_osk()._type_char("B")
	_osk()._delete_char()
	check_eq(_osk()._text, "A", "delete removes the last letter")
	_osk()._delete_char()
	_osk()._delete_char()
	check_eq(_osk()._text, "", "delete on empty text is a no-op")


func test_osk_blank_and_duplicate_rejected() -> void:
	_to_menu()
	_host.cmd_open_name_create(-1)
	_osk()._confirm()
	check_true(_osk().is_open(), "blank name does not commit")
	check_true(_osk()._status.text.contains("empty"), "blank name reports an error")

	_osk()._type_char("Player 1")
	_osk()._confirm()
	check_true(_osk().is_open(), "duplicate name does not commit")
	check_true(_osk()._status.text.contains("already"), "duplicate name reports an error")

	while not _osk()._text.is_empty():
		_osk()._delete_char()
	_osk()._type_char("Quasar")
	_osk()._confirm()
	check_false(_osk().is_open(), "unique name commits")
	check_true(_host.settings.profile_name_taken("Quasar"), "created with the typed name")


func test_osk_cancel_keeps_profiles() -> void:
	_to_menu()
	var before: int = _host.settings.profiles.size()
	_host.cmd_open_name_create(-1)
	_osk()._cancel()
	check_false(_osk().is_open(), "cancel closes the keyboard")
	check_eq(_host.settings.profiles.size(), before, "no profile created on cancel")


func test_osk_rename_flow() -> void:
	_to_menu()
	var id: String = _host.settings.active_profile_id
	var old_name: String = _host.settings.profile_name(id)
	_host.cmd_open_name_rename(id)
	check_true(_osk().is_open(), "rename opens the keyboard")
	check_eq(_osk()._text, old_name, "rename starts with the current name")
	while not _osk()._text.is_empty():
		_osk()._delete_char()
	_osk()._type_char("A")
	_osk()._type_char("c")
	_osk()._type_char("e")
	_osk()._confirm()
	check_eq(_host.settings.profile_name(id), "Ace", "rename committed through the host")


# ------------------------------------------------- guided controller rebinding

func _claim() -> Node:
	return _host._settings_screen._claim


func _capture() -> Node:
	return _host._settings_screen._capture


func _fake_pressed_snapshot() -> Dictionary:
	return _fake_pressed


func _press(device: int, buttons: Array) -> void:
	_fake_pressed = {device: buttons}


func _open_guided() -> void:
	_to_menu()
	_fake_pressed = {}
	_claim().poll_pressed = Callable(self, "_fake_pressed_snapshot")
	_host.cmd_open_settings_from_menu()
	_host._settings_screen.open_controller_binding(_host.settings.active_profile_id)
	check_eq(_host._settings_screen._mode, "padbind", "guided mode opens")
	check_eq(_host._settings_screen._pad_stage, "claim", "flow starts with the pad claim")


func _joy_button(button: int) -> InputEventJoypadButton:
	var ev := InputEventJoypadButton.new()
	ev.device = 7
	ev.button_index = button
	ev.pressed = true
	return ev


func test_guided_claim_requires_full_hold_and_release() -> void:
	_open_guided()
	_press(7, [0])
	_claim().tick(1.9)
	check_eq(_host._settings_screen._pad_stage, "claim", "1.9s is not enough")
	check_true(is_equal_approx(_claim().progress(), 1.9 / 2.0), "progress tracked")
	_claim().tick(0.1)
	check_eq(_host._settings_screen._pad_stage, "release", "2s claims the pad")
	check_eq(_host._settings_screen._pad_device, 7, "session device remembered")
	# Releasing before the hold completes never claims.
	_claim().stop()
	_host._settings_screen.open_controller_binding(_host.settings.active_profile_id)
	_press(7, [0])
	_claim().tick(1.0)
	_press(7, [])
	_claim().tick(1.0)
	check_eq(_host._settings_screen._pad_stage, "claim", "release resets the hold")
	check_eq(_claim().progress(), 0.0, "progress back to zero")
	_claim().stop()


func test_guided_capture_sequence_and_commit() -> void:
	_open_guided()
	_press(7, [3])
	_claim().tick(2.0)
	check_eq(_host._settings_screen._pad_stage, "release", "pad claimed")
	_press(7, [])
	_claim().tick(0.1)
	check_eq(_host._settings_screen._pad_stage, "capture", "release starts the capture")
	check_true(_capture().active, "capture consumes pad input")

	# Capture every action in canonical order with distinct buttons
	# (button 1 is the reserved cancel and must not be offered).
	var buttons := [0, 2, 3, 4, 5, 6, 7, 9, 10]
	for i in DefaultBindings.ACTION_NAMES.size():
		var action: String = DefaultBindings.ACTION_NAMES[i]
		check_eq(_host._settings_screen._pad_index, i, "%s is the current action" % action)
		_capture()._input(_joy_button(buttons[i]))
	check_eq(_host._settings_screen._pad_stage, "review", "all nine captured reaches review")
	check_eq(_host._settings_screen._pad_captured.size(), DefaultBindings.ACTION_NAMES.size(), "one record per action")
	check_false(_capture().active, "capture stops in review")

	# Finish commits the whole controller-only profile atomically.
	var id: String = _host.settings.active_profile_id
	var before: Dictionary = _host.settings.controller_bindings_for(id)
	_host._settings_screen._selected = _host._settings_screen._rows.size() - 2  # FINISH AND SAVE
	_host._settings_screen._activate()
	var after: Dictionary = _host.settings.controller_bindings_for(id)
	check_true(after != before, "profile controller bindings replaced")
	check_eq(after["hard_drop"], [DefaultBindings.joy_button_record(4)], "hard drop got its captured button")
	check_eq(_host._settings_screen._mode, "controls", "flow returns to controls after saving")


func test_guided_conflict_rejected_inside_profile() -> void:
	_open_guided()
	_press(7, [0])
	_claim().tick(2.0)
	_press(7, [])
	_claim().tick(0.1)
	check_eq(_host._settings_screen._pad_stage, "capture", "capture starts")
	_capture()._input(_joy_button(4))
	check_eq(_host._settings_screen._pad_index, 1, "first capture advances")
	# Reusing the same button for the next action is refused.
	_capture()._input(_joy_button(4))
	check_eq(_host._settings_screen._pad_index, 1, "conflict does not advance")
	check_true(_capture().active, "capture restarts after a conflict")
	check_true(_host._settings_screen._status.text.contains("Already used"), "conflict reported by action label")
	_host._settings_screen._cancel_padbind()


func test_guided_cancel_discards_uncommitted_sequence() -> void:
	_open_guided()
	_press(7, [0])
	_claim().tick(2.0)
	_press(7, [])
	_claim().tick(0.1)
	_capture()._input(_joy_button(5))
	check_eq(_host._settings_screen._pad_captured.size(), 1, "one action captured")
	# B is the reserved cancel during capture.
	_capture()._input(_joy_button(JOY_BUTTON_B))
	check_eq(_host._settings_screen._pad_stage, "", "capture cancelled back to idle")
	check_eq(_host._settings_screen._mode, "controls", "screen back on controls")
	check_eq(
		_host.settings.controller_bindings_for(_host.settings.active_profile_id),
		DefaultBindings.default_controller_profile(),
		"profile untouched by the cancelled sequence"
	)


func test_guided_from_pause_live_reloads_input() -> void:
	var id := _fresh_profile("PauseRebind")
	_start_solo(ModeRules.Mode.MARATHON, id)
	_host.action_pause()
	_host.cmd_open_settings_from_pause()
	_fake_pressed = {}
	_claim().poll_pressed = Callable(self, "_fake_pressed_snapshot")
	_host._settings_screen.open_controller_binding(id)
	_press(7, [0])
	_claim().tick(2.0)
	_press(7, [])
	_claim().tick(0.1)
	for i in DefaultBindings.ACTION_NAMES.size():
		_capture()._input(_joy_button(11 + i))
	check_eq(_host._settings_screen._pad_stage, "review", "captures complete")
	# Finishing the sequence commits the profile and the paused run's
	# input assignment live-reloads it.
	_host._settings_screen._selected = _host._settings_screen._rows.size() - 2
	_host._settings_screen._activate()
	check_eq(_host.input_solo_bindings()["hard_drop"], [DefaultBindings.joy_button_record(14)], "paused run's input assignment live-reloads the rebind")
	check_eq(_host._settings_screen._mode, "controls", "flow returns to controls after saving")


func test_settings_controls_rows() -> void:
	_to_menu()
	_host.cmd_open_settings_from_menu()
	var screen: CanvasLayer = _host._settings_screen
	check_eq(screen._mode, "controls", "settings opens on controls")
	var ids: Array = []
	for row in screen._rows:
		ids.append(row.get("id", row.get("kind")))
	check(ids.has("keyboard"), "keyboard bindings row present")
	check(ids.has("controller"), "controller bindings row present")
	var controller_row := -1
	for i in screen._rows.size():
		if screen._rows[i].get("id") == "controller":
			controller_row = i
	check_true(String(screen._row_label(screen._rows[controller_row])).contains(_host.active_profile_name()), "controller row names the active profile")
	# The old per-row controller editing mode is gone.
	check_false(ids.has("pad"), "per-row pad editing removed")


# ------------------------------------------------------ settings round trips

func test_settings_from_menu_round_trip() -> void:
	_to_menu()
	_host.cmd_open_settings_from_menu()
	check_eq(_host.state, _host.HostState.SETTINGS, "settings opens from main menu")
	check_true(_host._settings_screen.visible, "settings screen visible")
	_host.cmd_settings_back()
	check_eq(_host.state, _host.HostState.MAIN_MENU, "back returns to main menu")
	check_true(_host._menu.is_open(), "main menu restored")


func test_keyboard_bindings_page_flow() -> void:
	_to_menu()
	var id := _fresh_profile("KbProbe")
	_start_solo(ModeRules.Mode.MARATHON, id)
	# A single-record hold keeps the page's per-action record cap out of
	# the expected shape below.
	var kb := DefaultBindings.default_keyboard_profile()
	kb["hold"] = [DefaultBindings.key_record(KEY_C)]
	check_true(_host.cmd_keyboard_bindings_captured(id, kb), "single-record hold committed")
	_host.action_pause()
	_host.cmd_open_settings_from_pause()
	var screen: CanvasLayer = _host._settings_screen
	# The Settings entry edits the active profile's keyboard mapping.
	screen._run_command("keyboard")
	check_eq(screen._mode, "kb", "keyboard page opened from the controls category")
	check_eq(screen._kb_profile_id, _host.settings.active_profile_id, "page targets the active profile")
	var row := -1
	for i in screen._rows.size():
		if screen._rows[i].get("kind") == "binding" and screen._rows[i]["action"] == "hold":
			row = i
	check_true(row >= 0, "hold binding row present")
	screen._selected = row
	screen._rebuild()
	var before: Array = screen._kb_profile["hold"]
	# Capture a keyboard key event through the capture node.
	screen._capture.start()
	var ev := InputEventKey.new()
	ev.physical_keycode = KEY_T
	ev.pressed = true
	screen._capture._input(ev)
	check_eq(_host.settings.keyboard_bindings_for(id)["hold"], before + [DefaultBindings.key_record(KEY_T)], "keyboard capture appends to the targeted profile")
	check_eq(screen._kb_profile["hold"], _host.settings.keyboard_bindings_for(id)["hold"], "working copy re-read after commit")
	check_true(InputMap.event_is_action(_key_event(KEY_T), "hold"), "InputMap rebuilt with the active profile's new binding")
	# Controller events never enter the profile keyboard mapping.
	screen._capture.start()
	var pad := InputEventJoypadButton.new()
	pad.device = 3
	pad.button_index = 9
	pad.pressed = true
	screen._capture._input(pad)
	check_eq(_host.settings.keyboard_bindings_for(id)["hold"].size(), before.size() + 1, "pad capture ignored on the keyboard page")
	check_true(screen._capture.active, "keyboard capture keeps waiting after an ignored pad event")
	screen._capture.stop()


func test_keyboard_bindings_page_targets_other_profiles() -> void:
	_to_menu()
	var active: String = _host.settings.active_profile_id
	var active_hold_before: Array = _host.settings.keyboard_bindings_for(active)["hold"]
	var other := _fresh_profile("KbOther")
	# Opening the keyboard page for a non-active profile commits only that
	# profile's mapping; the InputMap (active profile) stays untouched.
	_host.cmd_profile_bind_keyboard(other)
	check_eq(_host.state, _host.HostState.SETTINGS, "settings opened from the profile browser")
	var screen: CanvasLayer = _host._settings_screen
	check_eq(screen._kb_profile_id, other, "page targets the browsed profile")
	var profile := DefaultBindings.default_keyboard_profile()
	profile["hold"] = [DefaultBindings.key_record(KEY_F8)]
	check_true(_host.cmd_keyboard_bindings_captured(other, profile), "commit succeeds for the browsed profile")
	check_eq(_host.settings.keyboard_bindings_for(other)["hold"], [DefaultBindings.key_record(KEY_F8)], "browsed profile carries the custom record")
	check_false(InputMap.event_is_action(_key_event(KEY_F8), "hold"), "InputMap untouched while a non-active profile changed")
	check_eq(_host.settings.keyboard_bindings_for(active)["hold"], active_hold_before, "active profile mapping untouched")
	# Back returns to the profile browser (settings-from-profiles flow).
	_host.cmd_settings_back()
	check_true(_host._profile_screen.is_open(), "back returns to the profile browser")


func _key_event(code: int) -> InputEventKey:
	var ev := InputEventKey.new()
	ev.physical_keycode = code
	ev.pressed = true
	return ev


func test_reset_commands() -> void:
	_to_menu()
	_host.cmd_open_settings_from_menu()
	var screen: CanvasLayer = _host._settings_screen
	var id := _fresh_profile("ResetProbe")
	_host.settings.set_active_profile(id)
	var kb := DefaultBindings.default_keyboard_profile()
	kb["hold"] = [DefaultBindings.key_record(KEY_T)]
	check_true(_host.cmd_keyboard_bindings_captured(id, kb), "custom keyboard committed")
	_host.settings.find_profile(id)["controller_bindings"]["hard_drop"] = [DefaultBindings.joy_button_record(9)]
	screen._mode = "reset"
	screen._rebuild()
	var reset_kb := -1
	var reset_pad := -1
	for i in screen._rows.size():
		if screen._rows[i].get("id") == "reset_kb":
			reset_kb = i
		if screen._rows[i].get("id") == "reset_pad":
			reset_pad = i
	check_eq(screen._rows[reset_kb]["label"], "Reset Keyboard Bindings (%s)" % _host.active_profile_name(), "keyboard reset names the active profile")
	screen._selected = reset_kb
	screen._activate()
	check_eq(_host.settings.keyboard_bindings_for(id), DefaultBindings.default_keyboard_profile(), "active profile keyboard reset to defaults")
	check_eq(_host.settings.keyboard_bindings_for(_host.settings.active_profile_id)["hold"], DefaultBindings.default_keyboard_profile()["hold"], "reset mapping applied")
	screen._selected = reset_pad
	screen._activate()
	check_eq(_host.settings.controller_bindings_for(id), DefaultBindings.default_controller_profile(), "active profile controller reset to defaults")


func test_active_profile_switch_rebuilds_input_map() -> void:
	_to_menu()
	var other := _fresh_profile("ActiveProbe")
	var defaults := DefaultBindings.default_keyboard_profile()
	var custom_key: int = KEY_F6
	while defaults["hold"].has(DefaultBindings.key_record(custom_key)):
		custom_key += 1
	var kb := defaults.duplicate(true)
	kb["hold"] = [DefaultBindings.key_record(custom_key)]
	check_true(_host.cmd_keyboard_bindings_captured(other, kb), "custom keyboard committed")
	check_false(InputMap.event_is_action(_key_event(custom_key), "hold"), "non-active profile binding not installed")
	check_true(InputMap.event_is_action(_key_event(int(defaults["hold"][0]["code"])), "hold"), "previous active mapping installed")
	_host.cmd_set_active_profile(other)
	check_true(InputMap.event_is_action(_key_event(custom_key), "hold"), "active switch installs the new mapping")
	check_eq(_host.active_profile_name(), "ActiveProbe", "active name follows the switch")


func test_profile_browser_keyboard_binding_entry() -> void:
	_to_menu()
	var other := _fresh_profile("BrowserProbe")
	_host._profile_screen.open_manage()
	check_true(_host._profile_screen.is_open(), "profile browser opens")
	# Open the keyboard bindings flow from the profile submenu.
	_host.cmd_profile_bind_keyboard(other)
	check_eq(_host.state, _host.HostState.SETTINGS, "settings opened for the profile keyboard page")
	var screen: CanvasLayer = _host._settings_screen
	check_eq(screen._mode, "kb", "keyboard page opened")
	check_eq(screen._kb_profile_id, other, "page targets the browsed profile")
	# Back returns to the profile browser.
	_host.cmd_settings_back()
	check_true(_host._profile_screen.is_open(), "back returns to the profile browser")


# ------------------------------------------------------------- input gating

func test_gameplay_actions_gated() -> void:
	_start_solo(ModeRules.Mode.MARATHON)
	check_true(_host.is_gameplay_input_enabled(), "input enabled while playing")
	_host.action_pause()
	check_false(_host.is_gameplay_input_enabled(), "input disabled while paused")
	_host.cmd_open_settings_from_pause()
	check_false(_host.is_gameplay_input_enabled(), "input disabled in settings")


func test_online_client_pause_is_host_authoritative() -> void:
	## Full-GameHost integration: an online client's twin match follows the
	## host-authoritative pause - client keys are inert, focus loss only
	## releases held controls, remote pause applies passively by revision,
	## and stale revisions never flip a newer state.
	_to_menu()
	_host.online_begin_client_match({
		"mode": ModeRules.Mode.MARATHON, "seed": 7, "player_count": 2, "own_slot": 1,
	})
	check_eq(_host.state, _host.HostState.PLAYING, "client twin match begins playing")
	check_true(_host.is_online_client(), "host reports the client role")
	# Client pause keys never locally pause the authoritative run.
	_host.action_pause()
	check_eq(_host.state, _host.HostState.PLAYING, "client pause key ignored")
	# Focus loss only releases held controls; it never pauses an online client.
	_host.auto_pause_on_focus_loss()
	check_eq(_host.state, _host.HostState.PLAYING, "focus loss never pauses an online client")
	# The remote pause applies passively: overlay, released input, paused music.
	_host.online_set_paused(true, 1)
	check_eq(_host.state, _host.HostState.PAUSED, "remote pause applied")
	check_true(_host._pause_menu.is_open(), "passive pause overlay shown")
	check_eq(_host._pause_menu._title.text, "PAUSED", "overlay titled for the remote pause")
	check_true(_host._pause_menu._detail.text.contains("HOST"), "overlay copy identifies the host pause")
	check_true(_host._audio.is_host_paused(), "music paused under the remote pause")
	check_false(_host.is_gameplay_input_enabled(), "input disabled under the remote pause")
	# Client keys stay inert while passively paused.
	_host.action_pause()
	check_eq(_host.state, _host.HostState.PAUSED, "client keys ignored while remotely paused")
	# A stale revision never flips the newer pause state.
	_host.online_set_paused(false, 0)
	_host.online_set_paused(true, 0)
	check_eq(_host.state, _host.HostState.PAUSED, "stale revisions ignored")
	# A newer resume returns to play.
	_host.online_set_paused(false, 2)
	check_eq(_host.state, _host.HostState.PLAYING, "remote resume returns to play")
	check_false(_host._pause_menu.is_open(), "overlay closed on resume")
	check_false(_host._audio.is_host_paused(), "music resumed with the match")
	# Restore the shared host: the direct hook left the client role and the
	# twin state on this instance (later tests must start fresh).
	_host._online_teardown_run()
	check_eq(_host.state, _host.HostState.MAIN_MENU, "client role cleared after the probe")


func test_online_client_results_preserve_session_and_settings_context() -> void:
	_to_menu()
	_host.online_begin_client_match({
		"mode": ModeRules.Mode.MARATHON, "seed": 11, "player_count": 2, "own_slot": 1,
	})
	var twin = _host.coop
	_host.online_show_results({"title": "GAME OVER", "subtitle": "round complete"})
	check_true(_host.is_online_client(), "client role remains active while results are visible")
	check_true(_host.coop == twin, "client twin remains available until lobby return")
	check_eq(_host.state, _host.HostState.GAME_OVER, "client enters a terminal host state")
	check_eq(_menu_labels(), ["RETURN TO LOBBY", "SETTINGS"], "client results expose an independent lobby return")
	_host.cmd_open_settings_from_results()
	_host.cmd_settings_back()
	check_eq(_menu_labels(), ["RETURN TO LOBBY", "SETTINGS"], "settings returns to online result actions")
	_host._online_teardown_run()


func test_results_overlay_retry_and_menu() -> void:
	_start_solo(ModeRules.Mode.MARATHON)
	_host.core.phase = CoreGame.Phase.GAME_OVER
	_host._process(0.0)
	check_eq(_host.state, _host.HostState.GAME_OVER, "game over state")
	check_true(_host._menu.is_open(), "results overlay shown")
	_host.cmd_restart_run()
	check_eq(_host.state, _host.HostState.PLAYING, "retry starts a new run")
	check_true(_host.core.phase == CoreGame.Phase.ACTIVE, "fresh run is active")
	_host.core.phase = CoreGame.Phase.FINISHED
	_host._process(0.0)
	check_eq(_host.state, _host.HostState.FINISHED, "finished state")
	_host.cmd_return_to_menu()
	check_eq(_host.state, _host.HostState.MAIN_MENU, "menu return after finish")


# ------------------------------------------------- multiplayer overlay copy

func test_local_multiplayer_lobby_copy() -> void:
	_to_menu()
	_host.cmd_open_coop_setup()
	check_true(_host._coop_setup.is_open(), "local multiplayer lobby opens")
	check_eq(_host._coop_setup._title.text, "LOCAL MULTIPLAYER", "lobby titled for the multiplayer category")
	_host.cmd_coop_setup_back()
	check_true(_host._menu.is_open(), "lobby back returns to the main menu")
	check_eq(_menu_labels(), [
		"SOLO",
		"LOCAL MULTIPLAYER",
		"ONLINE MULTIPLAYER",
		"PROFILES",
		"SETTINGS",
		"QUIT",
	], "lobby back lands on the top-level menu")


func test_online_multiplayer_entry_copy() -> void:
	# Static copy only: the online service is absent in tests, so the
	# screens are driven directly and never touch the network.
	_to_menu()
	_host._online_menu.open_entry()
	check_eq(_host._online_menu._title.text, "ONLINE MULTIPLAYER", "entry titled for the multiplayer category")
	check_true(_host._online_menu._detail.text.contains("Relay-backed online multiplayer"), "entry detail follows the category wording")
	_host._online_menu.open_lobby()
	check_eq(_host._online_menu._title.text, "ONLINE MULTIPLAYER LOBBY", "lobby titled for the multiplayer category")
	_host._online_menu.close()
	check_false(_host._online_menu.is_open(), "online screens closed after the copy checks")


func test_online_lobby_room_code_visible_to_client() -> void:
	var service = OnlineServiceScript.new()
	service.is_host = false
	service.room_code = "ABC1234"
	_host._online_menu._service = service
	_host._online_menu._refresh_lobby_detail()
	check_true(_host._online_menu._detail.text.contains("ABC1234"), "client lobby displays the shared room code")
	_host._online_menu._service = null
	service.free()
