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


func test_main_menu_lists_profile_entry() -> void:
	_to_menu()
	var labels: Array = []
	for item in _host._menu._items:
		labels.append(item["label"])
	check(labels.has("PROFILES"), "main menu has a profiles entry")
	check(labels.has("MARATHON"), "marathon present")
	check(labels.has("CO-OP"), "coop present")


func test_main_menu_shows_active_profile() -> void:
	_to_menu()
	check_true(_host._menu._detail.text.contains(_host.active_profile_name().to_upper()), "main menu shows the active profile name")
	var id := _fresh_profile("Zeta")
	check_true(id != "", "second profile created")
	_host.settings.set_active_profile(id)
	_host._show_main_menu()
	check_true(_host._menu._detail.text.contains("ZETA"), "summary follows the active profile")


# ------------------------------------------------------------ profile picker

func test_solo_modes_select_profile_first() -> void:
	# Solo games start through the profile picker; the host itself stays
	# in the menu until a profile is picked.
	_to_menu()
	_host.cmd_start_marathon()
	check_eq(_host.state, _host.HostState.MAIN_MENU, "marathon command opens the picker without starting")
	check_true(_host._profile_screen.is_open(), "profile screen visible")
	check_false(_host._menu.is_open(), "menu closed behind the picker")
	_host.cmd_profile_screen_back()
	check_eq(_host.state, _host.HostState.MAIN_MENU, "back returns to the menu")
	check_true(_host._menu.is_open(), "menu restored")

	_host.cmd_start_sprint()
	check_true(_host._profile_screen.is_open(), "sprint opens the picker too")
	_start_solo(ModeRules.Mode.SPRINT)
	check_eq(_host.state, _host.HostState.PLAYING, "picking a profile starts the run")
	check_eq(_host.core.mode, ModeRules.Mode.SPRINT, "sprint mode selected")
	check_true(_host.core != null, "core created")
	check_false(_host._profile_screen.is_open(), "picker closed")


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
	_claim().tick(2.9)
	check_eq(_host._settings_screen._pad_stage, "claim", "2.9s is not enough")
	check_true(is_equal_approx(_claim().progress(), 2.9 / 3.0), "progress tracked")
	_claim().tick(0.1)
	check_eq(_host._settings_screen._pad_stage, "release", "3s claims the pad")
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
	_claim().tick(3.0)
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
	_claim().tick(3.0)
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
	_claim().tick(3.0)
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
	_claim().tick(3.0)
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
	_host.action_pause()
	_host.cmd_open_settings_from_pause()
	var screen: CanvasLayer = _host._settings_screen
	screen._mode = "kb"
	screen._rebuild()
	# The kb page edits the shared keyboard profile only.
	var row := -1
	for i in screen._rows.size():
		if screen._rows[i].get("kind") == "binding" and screen._rows[i]["action"] == "hold":
			row = i
	check_true(row >= 0, "hold binding row present")
	_host.settings.keyboard_bindings["hold"] = [DefaultBindings.key_record(KEY_C)]
	screen._selected = row
	screen._rebuild()
	var before: Array = _host.settings.keyboard_bindings["hold"]
	# Capture a keyboard key event through the capture node.
	screen._capture.start()
	var ev := InputEventKey.new()
	ev.physical_keycode = KEY_T
	ev.pressed = true
	screen._capture._input(ev)
	check_eq(_host.settings.keyboard_bindings["hold"], before + [DefaultBindings.key_record(KEY_T)], "keyboard capture appends to the shared profile")
	check_true(InputMap.event_is_action(_key_event(KEY_T), "hold"), "InputMap rebuilt with the new keyboard binding")
	# Controller events never enter the shared keyboard profile.
	screen._capture.start()
	var pad := InputEventJoypadButton.new()
	pad.device = 3
	pad.button_index = 9
	pad.pressed = true
	screen._capture._input(pad)
	check_eq(_host.settings.keyboard_bindings["hold"].size(), before.size() + 1, "pad capture ignored on the keyboard page")
	check_true(screen._capture.active, "keyboard capture keeps waiting after an ignored pad event")
	screen._capture.stop()


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
	_host.settings.keyboard_bindings["hold"] = [DefaultBindings.key_record(KEY_T)]
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
	screen._selected = reset_kb
	screen._activate()
	check_eq(_host.settings.keyboard_bindings, DefaultBindings.default_keyboard_profile(), "keyboard reset to defaults")
	screen._selected = reset_pad
	screen._activate()
	check_eq(_host.settings.controller_bindings_for(id), DefaultBindings.default_controller_profile(), "active profile controller reset to defaults")


# ------------------------------------------------------------- input gating

func test_gameplay_actions_gated() -> void:
	_start_solo(ModeRules.Mode.MARATHON)
	check_true(_host.is_gameplay_input_enabled(), "input enabled while playing")
	_host.action_pause()
	check_false(_host.is_gameplay_input_enabled(), "input disabled while paused")
	_host.cmd_open_settings_from_pause()
	check_false(_host.is_gameplay_input_enabled(), "input disabled in settings")


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
