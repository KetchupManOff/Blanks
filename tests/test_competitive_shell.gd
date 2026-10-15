extends "res://tests/test_lib.gd"
## Competitive shell flow smoke tests: the solo Tower menu/profile-picker
## route, leaderboard recording and personal-best feedback, the lobby mode
## cycle with the garbage row and the two-player minimum, versus run
## lifecycle with input routing and result recording, Tower presenter
## resizing on growth, and return-to-menu cleanup.

const CompetitiveGame = preload("res://scripts/core/competitive_game.gd")
const ModeRules = preload("res://scripts/core/mode_rules.gd")
const PlayConfig = preload("res://scripts/core/constants.gd")
const SettingsClass = preload("res://scripts/persistence/settings.gd")
const TetrominoData = preload("res://scripts/core/tetromino_data.gd")

var _host: Node = null
var _probe_index: int = 0


func setup() -> void:
	var scene: PackedScene = load("res://scenes/main.tscn")
	_host = scene.instantiate()
	tree.root.add_child(_host)
	if _host._hud == null:
		_host.settings = SettingsClass.new()
		_host._build_scene()
		_host._hud._ready()
		_host._menu._ready()
		_host._coop_setup._ready()
		_host._pause_menu._ready()
		_host._settings_screen._ready()
		_host._profile_screen._ready()
		_host._osk._ready()
		_host._show_main_menu()


func teardown() -> void:
	if _host != null:
		_host.free()
		_host = null


# ---------------------------------------------------------------- helpers

func _to_menu() -> void:
	_host._osk.close()
	if _host._profile_screen.is_open():
		_host._profile_screen.close()
	_host._show_main_menu()


func _fresh_profile(tag: String) -> String:
	_probe_index += 1
	return _host.settings.create_profile("%s%d" % [tag, _probe_index])


## Starts a local multiplayer competitive run with `count` fresh profiles.
func _start_competitive(count: int, mode: int, garbage: bool = false) -> Array:
	_to_menu()
	var ids: Array = []
	var assignments: Array = []
	for i in count:
		var id: String = _fresh_profile("Cmp")
		ids.append(id)
		assignments.append({"profile_id": id, "device": -1})
	_host.cmd_start_coop(assignments, mode, garbage)
	return ids


## Runs the match clock out so Tower finishes through the real host path.
func _expire_tower() -> void:
	_host.competitive.tick(999.0)
	_host._process(0.0)


# ------------------------------------------------------- solo tower routing

func test_solo_menu_lists_tower_entry() -> void:
	_to_menu()
	var top: Array = []
	for item in _host._menu._items:
		top.append(item["label"])
	check(top.has("LOCAL MULTIPLAYER"), "local multiplayer category present")
	check_false(top.has("TOWER"), "solo modes live behind the solo category")
	_host.cmd_open_solo_menu()
	var solo: Array = []
	for item in _host._menu._items:
		solo.append(item["label"])
	check(solo.has("TOWER"), "tower entry present in the solo chooser")


func test_tower_routes_through_profile_picker() -> void:
	_to_menu()
	_host.cmd_start_tower()
	check_eq(_host.state, _host.HostState.MAIN_MENU, "tower command opens the picker without starting")
	check_true(_host._profile_screen.is_open(), "profile picker visible")
	_host.cmd_profile_screen_back()
	check_true(_host._menu.is_open(), "back restores the menu")

	var id := _fresh_profile("SoloTower")
	_host.cmd_start_tower()
	_host.cmd_solo_profile_selected(id, ModeRules.Mode.TOWER)
	check_eq(_host.state, _host.HostState.PLAYING, "picking a profile starts the tower run")
	check_true(_host.competitive != null, "competitive core created")
	check_true(_host.core == null and _host.coop == null, "no solo/coop core for tower")
	check_eq(_host.competitive.mode, ModeRules.Mode.TOWER, "tower mode")
	check_eq(_host.competitive.player_count, 1, "solo tower is a one-player match")
	check_eq(_host.input_solo_profile_id(), id, "solo input path reused for tower")
	check_eq(_host._competitive_presenters.size(), 1, "one board presented")
	check_true(_host._field.visible, "playfield visible")
	_host._process(0.5)
	check_true(_host.competitive.elapsed > 0.0, "simulation advances")
	# The countdown shows through the shared HUD clock.
	check_true(_host.competitive.time_remaining() < ModeRules.TOWER_DURATION_SECONDS, "clock runs down")


func test_solo_tower_records_leaderboard_and_best_suffix() -> void:
	var id := _fresh_profile("TowerBest")
	_to_menu()
	_host.cmd_start_tower()
	_host.cmd_solo_profile_selected(id, ModeRules.Mode.TOWER)
	_host.competitive.debug_set_cell(0, 4, 21, TetrominoData.Kind.T)
	_host.competitive.players[0].score = 500
	_expire_tower()
	check_eq(_host.state, _host.HostState.FINISHED, "expiry finishes the run")
	check_eq(String(_host._last_results["title"]), "TIME!", "tower result title")
	check_true(String(_host._last_results["subtitle"]).contains("Height 1"), "height reported")
	var history: Array = _host.settings.profile_history(id, "solo_tower")
	check_eq(history.size(), 1, "one leaderboard record")
	check_eq(history[0]["height"], 1, "recorded height")
	check_eq(history[0]["score"], 500, "recorded score")
	check_false(String(_host._last_results["subtitle"]).contains("Best"), "first record has no best suffix")
	# A second, taller run places second; the lower height stays first.
	_host.cmd_restart_run()
	check_eq(_host.state, _host.HostState.PLAYING, "retry starts a fresh clock")
	check_eq(_host.competitive.mode, ModeRules.Mode.TOWER, "retry keeps the mode")
	_host.competitive.debug_set_cell(0, 4, 21, TetrominoData.Kind.T)
	_host.competitive.debug_set_cell(0, 5, 20, TetrominoData.Kind.J)
	_expire_tower()
	history = _host.settings.profile_history(id, "solo_tower")
	check_eq(history.size(), 2, "two leaderboard records")
	check_eq(history[0]["height"], 1, "lower height ranks first")
	check_true(String(_host._last_results["subtitle"]).contains("#2"), "placement suffix shown")
	# A third run tying the best height but scoring less places second.
	_host.cmd_restart_run()
	_host.competitive.debug_set_cell(0, 4, 21, TetrominoData.Kind.T)
	_host.competitive.players[0].score = 50
	_expire_tower()
	history = _host.settings.profile_history(id, "solo_tower")
	check_eq(history[0]["score"], 500, "the tied height keeps the higher-scoring record first")
	check_true(String(_host._last_results["subtitle"]).contains("#2"), "tie on height loses to the higher score")


# ------------------------------------------------------------- lobby flow

func test_lobby_cycles_all_four_modes() -> void:
	_to_menu()
	_host.cmd_open_coop_setup()
	var lobby: CanvasLayer = _host._coop_setup
	lobby.game_mode = ModeRules.Mode.MARATHON
	lobby.open()
	check_eq(lobby.game_mode, ModeRules.Mode.MARATHON, "marathon default")
	lobby._selected = lobby.ROW_MODE
	for expected in [
		ModeRules.Mode.SPRINT,
		ModeRules.Mode.CLASSIC_VERSUS,
		ModeRules.Mode.TOWER,
		ModeRules.Mode.MARATHON,
	]:
		lobby._activate()
		check_eq(lobby.game_mode, expected, "mode cycles forward")


func test_lobby_garbage_row_only_for_versus() -> void:
	_to_menu()
	_host.cmd_open_coop_setup()
	var lobby: CanvasLayer = _host._coop_setup
	lobby.open()
	lobby.game_mode = ModeRules.Mode.CLASSIC_VERSUS
	lobby._refresh()
	check_eq(lobby._rows[lobby.ROW_GARBAGE].text.contains("GARBAGE"), true, "garbage row visible for versus")
	check_true(lobby._row_selectable(lobby.ROW_GARBAGE), "garbage row selectable")
	lobby.garbage_on = false
	lobby._selected = lobby.ROW_GARBAGE
	lobby._activate()
	check_true(lobby.garbage_on, "activating the row toggles garbage on")
	lobby.game_mode = ModeRules.Mode.MARATHON
	lobby._refresh()
	check_eq(lobby._rows[lobby.ROW_GARBAGE].text, "", "garbage row hidden outside versus")
	check_false(lobby._row_selectable(lobby.ROW_GARBAGE), "garbage row skipped outside versus")
	lobby.game_mode = ModeRules.Mode.TOWER
	check_false(lobby._row_selectable(lobby.ROW_GARBAGE), "tower never shows the garbage row")


func test_lobby_requires_two_profiles_for_competitive_modes() -> void:
	_to_menu()
	_host.cmd_open_coop_setup()
	var lobby: CanvasLayer = _host._coop_setup
	lobby.open()
	var id := _fresh_profile("OneOnly")
	lobby.slots[0] = {"profile_id": id, "device": -1, "name": "One"}
	# Versus and Tower refuse to start with a single joined profile.
	for mode in [ModeRules.Mode.CLASSIC_VERSUS, ModeRules.Mode.TOWER]:
		lobby.game_mode = mode
		lobby._selected = lobby.ROW_START
		lobby._activate()
		check_eq(_host.state, _host.HostState.MAIN_MENU, "%d needs two profiles" % mode)
		check_true(lobby.is_open(), "lobby stays open")
		check_false(lobby._row_selectable(lobby.ROW_START), "start row skipped below the minimum")
	# Marathon still allows the one-player team run.
	lobby.game_mode = ModeRules.Mode.MARATHON
	lobby._selected = lobby.ROW_START
	lobby._activate()
	check_eq(_host.state, _host.HostState.PLAYING, "solo coop marathon still allowed")


func test_lobby_competitive_settings_persist_across_retry() -> void:
	# Garbage Off and the lobby mode survive a finished run's retry.
	_to_menu()
	_host.cmd_open_coop_setup()
	var lobby: CanvasLayer = _host._coop_setup
	lobby.open()
	lobby.game_mode = ModeRules.Mode.CLASSIC_VERSUS
	lobby.garbage_on = false
	var ids: Array = []
	for i in 2:
		var id: String = _fresh_profile("Retry")
		ids.append(id)
		_host.cmd_lobby_join_profile(i, id)
	lobby._selected = lobby.ROW_START
	lobby._activate()
	check_eq(_host.state, _host.HostState.PLAYING, "versus run started from the lobby")
	check_true(_host.competitive != null, "competitive core created")
	check_false(_host.competitive.garbage_enabled, "garbage choice carried into the match")
	check_eq(_host._run_profile_ids, ids, "both profiles tracked")
	_host.action_pause()
	_host.cmd_restart_run()
	check_eq(_host.state, _host.HostState.PLAYING, "retry works mid-match")
	check_false(_host.competitive.garbage_enabled, "garbage setting survives the retry")
	check_eq(_host._coop_setup.game_mode, ModeRules.Mode.CLASSIC_VERSUS, "lobby keeps the mode")
	check_eq(_host._coop_setup.garbage_on, false, "lobby keeps the garbage switch")


# ------------------------------------------------------- versus run lifecycle

func test_versus_run_input_routing_and_results() -> void:
	var ids := _start_competitive(2, ModeRules.Mode.CLASSIC_VERSUS, true)
	check_eq(_host.competitive.player_count, 2, "two-player versus match")
	check_eq(_host._competitive_presenters.size(), 2, "two boards presented")
	check_eq(_host._run_profile_ids, ids, "both profiles tracked")
	# Coop-indexed actions route to the independent boards.
	var x_before: int = _host.competitive.players[0].piece_x
	var moved := false
	for dx in [-1, 1, -1, 1, -1, 1]:
		if _host.action_coop_move(0, dx):
			moved = true
	check_true(moved, "player 0's piece moved through the coop input path")
	var x1_before: int = _host.competitive.players[1].piece_x
	_host.action_coop_move(0, -1)
	check_eq(_host.competitive.players[1].piece_x, x1_before, "player 1 board untouched by player 0 moves")
	# Eliminate player 1 through a real lock-out and let the host observe.
	_host.competitive.debug_spawn_piece(1, TetrominoData.Kind.O, 4, 0)
	for x in 10:
		for y in range(2, 22):
			_host.competitive.debug_set_cell(1, x, y, TetrominoData.Kind.I)
	_host.action_coop_hard_drop(1)
	check_true(_host.competitive.players[1].eliminated, "lock-out eliminates player 1")
	# Match end is evaluated on the next simulation step.
	_host.competitive.tick(0.0)
	_host._process(0.0)
	check_eq(_host.state, _host.HostState.FINISHED, "match finished at one survivor")
	check_true(String(_host._last_results["title"]).contains("WINS"), "winner announced")
	# Both participating profiles keep a match record from their own view.
	for i in 2:
		var matches: Array = _host.settings.profile_match_history(ids[i])
		check_eq(matches.size(), 1, "profile %d has one match record" % i)
		if matches.size() == 1:
			check_eq(matches[0]["players"], 2, "player count stored")
			check_eq(matches[0]["garbage"], true, "garbage setting stored")
			if i == 0:
				check_eq(matches[0]["placement"], 1, "winner placement stored")
				check_true(matches[0]["won"], "winner flagged")
			else:
				check_eq(matches[0]["placement"], 2, "runner-up placement stored")
				check_false(matches[0]["won"], "runner-up not flagged as winner")
	# The result appears in the profile browser detail.
	_to_menu()
	_host.cmd_open_profiles()
	_host._profile_screen._selected = _find_profile_row(ids[0])
	_host._profile_screen._update_detail()
	check_true(_host._profile_screen._detail.text.contains("MATCHES:"), "match history listed")
	check_true(_host._profile_screen._detail.text.contains("1ST"), "the win is summarized")


## The lobby row index whose callback is bound to this profile id.
func _find_profile_row(profile_id: String) -> int:
	for i in _host._profile_screen._items.size():
		var bound: Array = (_host._profile_screen._items[i].get("callback", Callable()) as Callable).get_bound_arguments()
		if bound.size() > 0 and String(bound[0]) == profile_id:
			return i
	return -1


func test_tower_growth_relayouts_presenters() -> void:
	_to_menu()
	var id := _fresh_profile("Grow")
	_host.cmd_start_tower()
	_host.cmd_solo_profile_selected(id, ModeRules.Mode.TOWER)
	var heights: Array[int] = _host._competitive_layout_heights.duplicate()
	check_eq(heights, [22], "layout starts at the default height")
	var size_before: Vector2 = _host._competitive_presenters[0].board_size()
	var renderer = _host._competitive_presenters[0].installed_board()
	var board = _host.competitive.players[0].board
	renderer.sync_view(_host.competitive, size_before.x / 10.0)
	renderer._static_board_revision = board.revision
	renderer._static_height = board.HEIGHT
	renderer._static_cell = size_before.x / 10.0
	renderer.sync_view(_host.competitive, renderer._static_cell)
	check_eq(renderer._static_board_revision, board.revision, "unchanged board keeps its static layer")
	var clearing: Array[int] = [21]
	_host.competitive.players[0].clearing_rows = clearing
	renderer.sync_view(_host.competitive, renderer._static_cell)
	check_eq(renderer._static_board_revision, -1, "line-clear state invalidates locked cells")
	var no_clearing: Array[int] = []
	_host.competitive.players[0].clearing_rows = no_clearing
	renderer._static_board_revision = board.revision
	renderer._static_height = board.HEIGHT
	renderer._static_cell = size_before.x / 10.0
	renderer._static_clearing_rows = no_clearing
	_host.competitive.debug_set_cell(0, 0, 21, TetrominoData.Kind.I)
	renderer.sync_view(_host.competitive, renderer._static_cell)
	check_eq(renderer._static_board_revision, -1, "board mutation invalidates the static layer")
	# Force ceiling growth: a full stack under a grounded spawn piece.
	for x in 10:
		for y in range(2, 22):
			_host.competitive.debug_set_cell(0, x, y, TetrominoData.Kind.I)
	_host.competitive.debug_spawn_piece(0, TetrominoData.Kind.O, 4, 0)
	_host._process(PlayConfig.FIXED_STEP)
	check_eq(_host._competitive_layout_heights, [32], "layout cache follows the growth")
	var size_after: Vector2 = _host._competitive_presenters[0].board_size()
	# The complete board scales down to fit the available height: the
	# presented area stays fully used while the cell shrinks.
	check_true(size_after.x < size_before.x, "cells scale down as the board grows")
	check_true(is_equal_approx(size_after.y, size_before.y), "the presented board keeps filling the field height")


func test_return_to_menu_clears_competitive_run() -> void:
	var ids := _start_competitive(2, ModeRules.Mode.CLASSIC_VERSUS, true)
	check_true(_host.competitive != null, "run started")
	_host.cmd_return_to_menu()
	check_eq(_host.state, _host.HostState.MAIN_MENU, "back to main menu")
	check_true(_host.competitive == null, "competitive core released")
	check_eq(_host._competitive_presenters.size(), 0, "presenters torn down")
	check_eq(_host._competitive_nodes.size(), 0, "strip nodes torn down")
	check_eq(_host._run_profile_ids, [], "run bookkeeping cleared")
	check_false(_host._field.visible, "playfield hidden")
	# The solo presenter is restored as the presented field.
	check_eq(_host._board_presenter.installed_board(), _host._board_renderer, "solo renderer reinstalled")


func test_tower_results_overlay_retry() -> void:
	var id := _fresh_profile("TowerRetry")
	_to_menu()
	_host.cmd_start_tower()
	_host.cmd_solo_profile_selected(id, ModeRules.Mode.TOWER)
	_expire_tower()
	check_eq(_host.state, _host.HostState.FINISHED, "finished state")
	_host.cmd_restart_run()
	check_eq(_host.state, _host.HostState.PLAYING, "retry starts a new clock")
	check_eq(_host.competitive.mode, ModeRules.Mode.TOWER, "retry keeps tower")
	check_eq(_host.competitive.time_remaining(), ModeRules.TOWER_DURATION_SECONDS, "fresh countdown")
