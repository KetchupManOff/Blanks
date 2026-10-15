extends "res://tests/test_lib.gd"
## Coop lobby and run flow smoke tests: lobby open/close, the two-second
## pad claim with device exclusions, profile joins (pad and keyboard),
## duplicate rejection, slot removal, mode/start gating, coop runs carrying
## ordered profile/device assignments, pause/restart/results, team result
## recording, and returning to solo untouched.

const CoreGame = preload("res://scripts/core/game.gd")
const CoopGame = preload("res://scripts/core/coop_game.gd")
const ModeRules = preload("res://scripts/core/mode_rules.gd")
const SettingsClass = preload("res://scripts/persistence/settings.gd")
const DefaultBindings = preload("res://scripts/input/default_bindings.gd")

var _host: Node = null
var _fake_pressed: Dictionary = {}
var _probe_index: int = 0


func setup() -> void:
	var scene: PackedScene = load("res://scenes/main.tscn")
	_host = scene.instantiate()
	tree.root.add_child(_host)
	# Drive the host's _ready body manually like test_shell does: children
	# that own UI state need their _ready before use.
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

func _lobby() -> CanvasLayer:
	return _host._coop_setup


func _fake_pressed_snapshot() -> Dictionary:
	return _fake_pressed


func _press(device: int, buttons: Array) -> void:
	_fake_pressed = {device: buttons}


func _use_fake_claim() -> void:
	_fake_pressed = {}
	_lobby()._claim.poll_pressed = Callable(self, "_fake_pressed_snapshot")


func _to_menu() -> void:
	_host._osk.close()
	if _host._profile_screen.is_open():
		_host._profile_screen.close()
	_host._show_main_menu()


## Starts a coop run with `count` freshly created profiles on the given
## devices; returns the profile ids in player order.
func _start_coop(count: int, mode: int, devices: Array = []) -> Array:
	_to_menu()
	var ids: Array = []
	var assignments: Array = []
	for i in count:
		_probe_index += 1
		var id: String = _host.settings.create_profile("Coop%d" % _probe_index)
		var device := int(devices[i]) if i < devices.size() else -1
		ids.append(id)
		assignments.append({"profile_id": id, "device": device})
	_host.cmd_start_coop(assignments, mode)
	return ids


# ------------------------------------------------------------------ lobby

func test_coop_setup_flow() -> void:
	_to_menu()
	_host.cmd_open_coop_setup()
	check_true(_lobby().is_open(), "lobby visible")
	check_false(_host._menu.is_open(), "main menu hidden behind the lobby")
	check_eq(_host.state, _host.HostState.MAIN_MENU, "lobby stays in the menu state")
	_host.cmd_coop_setup_back()
	check_false(_lobby().is_open(), "lobby closed")
	check_true(_host._menu.is_open(), "main menu restored")


func test_lobby_defaults_to_four_free_slots() -> void:
	_to_menu()
	_lobby().open()
	check_eq(_lobby().slots.size(), 4, "four join slots")
	for slot in _lobby().slots:
		check_eq(slot, {}, "slots start free")
	check_eq(_lobby().joined_count(), 0, "no players joined yet")
	check_eq(_lobby().game_mode, ModeRules.Mode.MARATHON, "marathon is the default mode")
	_lobby().close()


func test_lobby_start_blocked_without_profiles() -> void:
	_to_menu()
	_use_fake_claim()
	_lobby().game_mode = ModeRules.Mode.MARATHON
	_lobby().open()
	# START cannot launch without at least one joined profile.
	_lobby()._selected = _lobby().ROW_START
	_lobby()._activate()
	check_eq(_host.state, _host.HostState.MAIN_MENU, "no run without a joined profile")
	check_true(_lobby().is_open(), "lobby stays open")
	# The START row is skipped while empty.
	_lobby()._selected = _lobby().ROW_MODE
	_lobby()._move(1)
	check_eq(_lobby()._selected, _lobby().ROW_BACK, "start row skipped without joins")
	_lobby().close()


func test_lobby_claim_requires_two_second_hold() -> void:
	_to_menu()
	_use_fake_claim()
	_lobby().open()
	_press(5, [0])
	_lobby()._claim.tick(1.5)
	check_eq(_lobby().slots[0], {}, "1.5s of hold claims nothing")
	_lobby()._claim.tick(0.5)
	var slot: Dictionary = _lobby().slots[0]
	check_false(slot.is_empty(), "2s of hold claims the first free slot")
	check_eq(slot.get("device", -2), 5, "claimed device recorded")
	check_eq(slot.get("profile_id", "pending"), "", "profile pick pending until release")
	check_eq(_lobby().joined_count(), 0, "pending claim is not a joined player yet")
	# Releasing the held button opens the profile picker for that slot.
	_press(5, [])
	_lobby()._claim.tick(0.1)
	check_true(_host._profile_screen.is_open(), "release opens the profile picker")
	check_false(_lobby()._claim.active, "claim pauses while the picker is open")
	_lobby().close()


func test_lobby_claim_release_resets_progress() -> void:
	_to_menu()
	_use_fake_claim()
	_lobby().open()
	_press(5, [0])
	_lobby()._claim.tick(1.0)
	_press(5, [])
	_lobby()._claim.tick(0.5)
	check_eq(_lobby().slots[0], {}, "release before 2s claims nothing")
	_lobby()._claim.tick(2.5)
	check_eq(_lobby().slots[0], {}, "hold restarts from zero after a release")
	_press(5, [0])
	_lobby()._claim.tick(2.0)
	check_false(_lobby().slots[0].is_empty(), "a fresh full hold claims the pad")
	_lobby().close()


func test_lobby_claim_excludes_assigned_devices() -> void:
	_to_menu()
	_use_fake_claim()
	_lobby().open()
	# Slot 0 joins with pad 5 through the claim flow.
	_press(5, [1])
	_lobby()._claim.tick(2.0)
	_press(5, [])
	_lobby()._claim.tick(0.1)
	var id: String = _host.settings.active_profile_id
	_host.cmd_lobby_join_profile(0, id)
	check_eq(_lobby().slots[0]["profile_id"], id, "first slot joined")
	check_true(_lobby()._claim.active, "claim resumes after the join")
	# Pad 5 is excluded now; a second pad claims the next free slot.
	_press(5, [1])
	_lobby()._claim.tick(2.0)
	check_eq(_lobby().slots[1], {}, "an already-assigned pad cannot claim again")
	_press(6, [2])
	_lobby()._claim.tick(2.0)
	check_eq(_lobby().slots[1].get("device", -1), 6, "a free pad claims the second slot")
	_lobby().close()


func test_lobby_join_completes_slot_with_profile() -> void:
	_to_menu()
	_use_fake_claim()
	_lobby().open()
	_press(2, [3])
	_lobby()._claim.tick(2.0)
	_press(2, [])
	_lobby()._claim.tick(0.1)
	var id: String = _host.settings.active_profile_id
	_host.cmd_lobby_join_profile(0, id)
	check_false(_host._profile_screen.is_open(), "picker closed after the join")
	var slot: Dictionary = _lobby().slots[0]
	check_eq(slot["profile_id"], id, "slot records the joined profile")
	check_eq(slot["name"], _host.settings.profile_name(id), "slot records the display name")
	check_eq(slot["device"], 2, "slot keeps the claimed device")
	check_eq(_lobby().joined_count(), 1, "one joined player")
	var id_b: String = _host.settings.create_profile("LobbyMate")
	_host.cmd_lobby_join_profile(1, id_b)
	check_eq(_lobby().joined_count(), 2, "second slot joins")
	check_eq(_lobby().slots[1]["device"], -1, "keyboard join has no pad")
	_lobby().close()


func test_lobby_rejects_duplicate_profile_joins() -> void:
	_to_menu()
	_lobby().open()
	var id: String = _host.settings.active_profile_id
	_host.cmd_lobby_join_profile(0, id)
	_host.cmd_lobby_join_profile(1, id)
	check_eq(_lobby().slots[1], {}, "the same profile cannot join two slots")
	var id_b: String = _host.settings.create_profile("SoloMate")
	_host.cmd_lobby_join_profile(1, id_b)
	check_eq(_lobby().slots[1]["profile_id"], id_b, "a free profile joins another slot")
	# The picker also hides profiles that already joined elsewhere.
	_host.cmd_lobby_open_profile_picker(2)
	var labels: Array = []
	for item in _host._profile_screen._items:
		labels.append(item["label"])
	for label in labels:
		check_false(String(label).contains("PLAYER 1"), "taken profile hidden from the picker")
	_host.cmd_profile_screen_back()
	check_eq(_lobby().slots[2], {}, "cancelling the picker leaves that slot free")
	check_eq(_lobby().slots[0]["profile_id"], id, "joined slots survive another slot's picker cancel")
	_lobby().close()


func test_lobby_keyboard_join_opens_picker() -> void:
	_to_menu()
	_lobby().open()
	_lobby()._selected = 0
	_lobby()._activate()
	check_true(_host._profile_screen.is_open(), "activating a free slot opens the picker")
	check_eq(_host._profile_screen._mode, "lobby", "picker is in lobby mode")
	var id: String = _host.settings.active_profile_id
	_host.cmd_lobby_join_profile(0, id)
	check_eq(_lobby().slots[0]["device"], -1, "keyboard join has no pad")
	_lobby().close()


func test_lobby_remove_joined_slot() -> void:
	_to_menu()
	_lobby().open()
	var id: String = _host.settings.active_profile_id
	_host.cmd_lobby_join_profile(0, id)
	# Two-step removal: activate arms, activate again removes.
	_lobby()._selected = 0
	_lobby()._activate()
	check_eq(_lobby().slots[0]["profile_id"], id, "first activate only arms")
	_lobby()._activate()
	check_eq(_lobby().slots[0], {}, "second activate removes the slot")
	check_eq(_lobby().joined_count(), 0, "no players after removal")
	_lobby().close()


func test_lobby_mode_toggles() -> void:
	_to_menu()
	_lobby().game_mode = ModeRules.Mode.MARATHON
	_lobby().open()
	check_eq(_lobby().game_mode, ModeRules.Mode.MARATHON, "marathon default")
	_lobby()._selected = _lobby().ROW_MODE
	_lobby()._adjust(1)
	check_eq(_lobby().game_mode, ModeRules.Mode.SPRINT, "right toggles sprint")
	_lobby()._adjust(-1)
	check_eq(_lobby().game_mode, ModeRules.Mode.MARATHON, "left toggles back")
	# The full cycle covers every lobby mode and wraps around.
	for expected in [
		ModeRules.Mode.SPRINT,
		ModeRules.Mode.CLASSIC_VERSUS,
		ModeRules.Mode.TOWER,
		ModeRules.Mode.MARATHON,
	]:
		_lobby()._activate()
		check_eq(_lobby().game_mode, expected, "activation cycles forward")
	_lobby().close()


func test_lobby_start_launches_with_assignments() -> void:
	_to_menu()
	_lobby().game_mode = ModeRules.Mode.MARATHON
	_lobby().open()
	var id_a: String = _host.settings.active_profile_id
	var id_b: String = _host.settings.create_profile("LobbyStart")
	_host.cmd_lobby_join_profile(0, id_a)
	_host.cmd_lobby_join_profile(2, id_b)
	_lobby()._selected = _lobby().ROW_START
	_lobby()._activate()
	check_eq(_host.state, _host.HostState.PLAYING, "start launches the coop run")
	check_eq(_host.coop.player_count, 2, "joined slots become players")
	check_eq(_host._run_profile_ids, [id_a, id_b], "participating profiles tracked in slot order")
	check_eq(_host.input_coop_device_for(0), -1, "slot 1 has no pad")
	check_false(_lobby().is_open(), "lobby closed by the run")


# -------------------------------------------------------------- coop runs

func test_start_coop_two_players() -> void:
	_start_coop(2, ModeRules.Mode.MARATHON)
	check_eq(_host.state, _host.HostState.PLAYING, "coop starts playing")
	check_true(_host.coop != null, "coop core created")
	check_true(_host.core == null, "solo core unused")
	check_eq(_host.coop.player_count, 2, "two players")
	check_eq(_host.coop.mode, ModeRules.Mode.MARATHON, "marathon mode")
	check_eq(_host.coop.board.WIDTH, 20, "shared board width")
	check_eq(_host.input_coop_player_count(), 2, "input controller in coop mode")
	check_true(_host._field.visible, "playfield visible during the run")
	check_true(_host._hud.visible, "hud visible during the run")
	check_false(_host._board_renderer.visible, "solo board hidden during coop")
	check_eq(_host._coop_holds.size(), 2, "one hold panel per player")
	_host._process(0.5)
	check_true(_host.coop.elapsed > 0.0, "simulation advances while playing")


func test_coop_player_tags_carry_profile_names() -> void:
	var ids := _start_coop(2, ModeRules.Mode.MARATHON)
	var tag: String = _host._coop_tags[0].text
	check_true(tag.begins_with("P1 "), "tag prefixes the player index")
	check_true(tag.contains(_host.settings.profile_name(ids[0])), "tag shows the profile name")
	_lobby().close()


func test_start_coop_all_player_counts() -> void:
	for count in [1, 2, 3, 4]:
		_start_coop(count, ModeRules.Mode.MARATHON)
		check_eq(_host.coop.player_count, count, "%d-player run started" % count)
		check_eq(_host.coop.board.WIDTH, count * 10, "%d-player board width" % count)
		check_eq(_host._coop_holds.size(), count, "%d hold panels built" % count)
		check_eq(_host._coop_previews.size(), count, "%d preview groups built" % count)


func test_coop_devices_assigned_per_slot() -> void:
	_to_menu()
	var id: String = _host.settings.create_profile("PadOne")
	var id_b: String = _host.settings.create_profile("PadTwo")
	_host.cmd_start_coop([
		{"profile_id": id, "device": 5},
		{"profile_id": id_b, "device": 2},
	], ModeRules.Mode.MARATHON)
	check_eq(_host.input_coop_device_for(0), 5, "slot 1 polls device 5")
	check_eq(_host.input_coop_device_for(1), 2, "slot 2 polls device 2")
	check_false(_host.input_coop_profile_bindings(0).is_empty(), "slot 1 caches its profile controller bindings")
	# Disconnected devices read as unpressed and never crash polling.
	_host.input_process_once(0.1)
	check_eq(_host.state, _host.HostState.PLAYING, "polling without connected pads is safe")


func _press_input_key(code: int) -> void:
	# Synthetic key state for the input controller's polling loop.
	var ev := InputEventKey.new()
	ev.physical_keycode = code
	ev.pressed = true
	Input.parse_input_event(ev)
	Input.flush_buffered_events()


func _release_input_key(code: int) -> void:
	var ev := InputEventKey.new()
	ev.physical_keycode = code
	ev.pressed = false
	Input.parse_input_event(ev)
	Input.flush_buffered_events()


func test_coop_keyboard_routing_follows_profile_bindings() -> void:
	# Local coop polls each slot's own profile keyboard records directly:
	# a key bound only in one profile drives only that slot, and the global
	# InputMap (the active profile's mapping) is irrelevant for routing.
	var ids := _start_coop(2, ModeRules.Mode.MARATHON)
	var defaults := DefaultBindings.default_keyboard_profile()
	var kb_a := defaults.duplicate(true)
	kb_a["move_left"] = [DefaultBindings.key_record(KEY_F5)]
	kb_a["hold"] = [DefaultBindings.key_record(KEY_F6)]
	var kb_b := defaults.duplicate(true)
	kb_b["move_left"] = [DefaultBindings.key_record(KEY_F7)]
	kb_b["hold"] = [DefaultBindings.key_record(KEY_F8)]
	check_true(_host.cmd_keyboard_bindings_captured(ids[0], kb_a), "profile A keyboard committed")
	check_true(_host.cmd_keyboard_bindings_captured(ids[1], kb_b), "profile B keyboard committed")
	var controller: Node = _host.input_controller()
	check_eq(DefaultBindings.action_for_record(_host.input_coop_keyboard_bindings(0), DefaultBindings.key_record(KEY_F5)), "move_left", "slot 0 caches profile A keyboard")
	check_eq(DefaultBindings.action_for_record(_host.input_coop_keyboard_bindings(1), DefaultBindings.key_record(KEY_F7)), "move_left", "slot 1 caches profile B keyboard")
	# Held movement polls only through the owning profile's records.
	var x_a: int = _host.coop.players[0].piece_x
	var x_b: int = _host.coop.players[1].piece_x
	_press_input_key(KEY_F7)
	controller._process(0.0)
	check_eq(_host.coop.players[1].piece_x, x_b - 1, "player B moved left through its own profile binding")
	check_eq(_host.coop.players[0].piece_x, x_a, "player A untouched by B's key")
	_release_input_key(KEY_F7)
	controller._process(0.0)
	check_eq(_host.coop.players[0].piece_x, x_a, "release does not disturb player A")
	# Single-fire events route per profile too (raw record matching).
	var ev := InputEventKey.new()
	ev.physical_keycode = KEY_F8
	ev.pressed = true
	controller._coop_event(ev)
	check_true(_host.coop.players[1].hold_used, "player B held through its own profile binding")
	check_false(_host.coop.players[0].hold_used, "player A untouched by B's hold key")
	# Pause stays a shared action: any slot's own pause mapping fires it.
	var esc := InputEventKey.new()
	esc.physical_keycode = KEY_ESCAPE
	esc.pressed = true
	controller._coop_event(esc)
	check_eq(_host.state, _host.HostState.PAUSED, "pause fires from a slot's keyboard bindings")
	_host.action_pause()
	check_eq(_host.state, _host.HostState.PLAYING, "resume returns to play")


func test_coop_shared_keyboard_conflict_warns() -> void:
	_to_menu()
	_host.cmd_open_coop_setup()
	var id_a: String = _host.settings.create_profile("SameKeysA")
	var id_b: String = _host.settings.create_profile("SameKeysB")
	# Two profiles sharing one keyboard is a local configuration hazard:
	# the lobby surfaces it instead of silently changing bindings.
	_lobby().slots[0] = {"profile_id": id_a, "device": -1}
	_lobby().slots[1] = {"profile_id": id_b, "device": -1}
	_lobby()._refresh()
	check_true(_lobby()._pads.text.contains("WARNING"), "shared keyboard warning surfaced")
	check_true(_lobby()._pads.text.contains("P1 and P2"), "warning names both slots")
	_lobby().slots[1] = {}
	_lobby()._refresh()
	check_false(_lobby()._pads.text.contains("WARNING"), "warning clears with the conflict")
	_lobby().close()


func test_coop_game_over_and_retry() -> void:
	_start_coop(2, ModeRules.Mode.SPRINT)
	_host.coop.phase = CoopGame.Phase.GAME_OVER
	_host._process(0.0)
	check_eq(_host.state, _host.HostState.GAME_OVER, "game over state")
	check_true(_host._menu.is_open(), "results overlay shown")
	_host.cmd_restart_run()
	check_eq(_host.state, _host.HostState.PLAYING, "retry restarts the run")
	check_eq(_host.coop.player_count, 2, "retry keeps the player count")
	check_eq(_host.coop.mode, ModeRules.Mode.SPRINT, "retry keeps the mode")
	check_eq(_host.coop.phase, CoopGame.Phase.ACTIVE, "fresh run is active")


func test_coop_team_results_recorded_for_every_profile() -> void:
	var ids := _start_coop(2, ModeRules.Mode.MARATHON)
	_host.coop.score = 4321
	_host.coop.phase = CoopGame.Phase.GAME_OVER
	_host._process(0.0)
	for id in ids:
		var history: Array = _host.settings.profile_history(id, "coop_marathon")
		check_eq(history.size(), 1, "%s records the team result" % id)
		check_eq(history[0]["score"], 4321, "team score stored")
		check_eq(history[0]["players"], 2, "team player count stored")
	check_eq(_host._last_results["subtitle"], "2P Coop - Score 4321", "team subtitle stays team-focused")


func test_coop_sprint_finish_records_but_game_over_does_not() -> void:
	var ids := _start_coop(2, ModeRules.Mode.SPRINT)
	_host.coop.phase = CoopGame.Phase.GAME_OVER
	_host._process(0.0)
	check_eq(_host.settings.profile_history(ids[0], "coop_sprint").size(), 0, "abandoned coop sprint records nothing")
	check_eq(_host.settings.profile_history(ids[1], "coop_sprint").size(), 0, "no profile records an abandoned run")
	_host.cmd_restart_run()
	_host.coop.phase = CoopGame.Phase.FINISHED
	_host._process(0.0)
	check_eq(_host.settings.profile_history(ids[0], "coop_sprint").size(), 1, "finished coop sprint records")
	check_eq(_host.settings.profile_history(ids[1], "coop_sprint").size(), 1, "every profile records the finish")


func test_coop_finish_results() -> void:
	_start_coop(3, ModeRules.Mode.SPRINT)
	_host.coop.phase = CoopGame.Phase.FINISHED
	_host._process(0.0)
	check_eq(_host.state, _host.HostState.FINISHED, "finished state")
	_host.cmd_open_settings_from_results()
	_host.cmd_settings_back()
	check_eq(_host.state, _host.HostState.FINISHED, "settings returns to results")
	_host.cmd_return_to_menu()
	check_eq(_host.state, _host.HostState.MAIN_MENU, "menu return after finish")


func test_coop_pause_restart_preserves_session() -> void:
	_start_coop(4, ModeRules.Mode.MARATHON)
	_host._process(0.3)
	var elapsed: float = _host.coop.elapsed
	_host.action_pause()
	check_eq(_host.state, _host.HostState.PAUSED, "pause freezes the run")
	_host._process(1.0)
	check_eq(_host.coop.elapsed, elapsed, "timer frozen while paused")
	_host.cmd_restart_run()
	check_eq(_host.state, _host.HostState.PLAYING, "restart returns to playing")
	check_eq(_host.coop.player_count, 4, "restart keeps four players")
	check_eq(_host.input_coop_player_count(), 4, "input stays in four-player mode")


func test_coop_actions_gated() -> void:
	_to_menu()
	check_false(_host.action_coop_move(0, 1), "move rejected without a run")
	_start_coop(2, ModeRules.Mode.MARATHON)
	check_true(_host.action_coop_move(0, 1), "move works while playing")
	_host.action_pause()
	check_false(_host.action_coop_move(0, 1), "move rejected while paused")


func test_return_to_menu_clears_coop() -> void:
	_start_coop(2, ModeRules.Mode.MARATHON)
	_host.cmd_return_to_menu()
	check_eq(_host.state, _host.HostState.MAIN_MENU, "back to main menu")
	check_true(_host.coop == null, "coop core released")
	check_eq(_host.input_coop_player_count(), 0, "input controller back to solo mode")
	check_true(_host._coop_nodes.is_empty(), "coop presentation torn down")
	check_true(_host._field.visible == false, "playfield hidden again")
	check_true(_host._hud.visible == false, "hud hidden again")
	check_eq(_host._run_profile_ids, [], "run bookkeeping cleared")


func test_solo_run_after_coop() -> void:
	_start_coop(2, ModeRules.Mode.MARATHON)
	_host.cmd_return_to_menu()
	_host.cmd_start_marathon()
	check_true(_host._profile_screen.is_open(), "solo start opens the profile picker after coop")
	_host.cmd_solo_profile_selected(_host.settings.active_profile_id, ModeRules.Mode.MARATHON)
	check_true(_host.core != null, "solo core created")
	check_true(_host.coop == null, "coop core released")
	check_eq(_host.input_coop_player_count(), 0, "input controller in solo mode")
	check_true(_host._board_renderer.visible, "solo board visible again")
	check_eq(_host.core.mode, ModeRules.Mode.MARATHON, "solo mode selected")
	_host._process(0.5)
	check_true(_host.core.elapsed > 0.0, "solo simulation advances")


func test_main_menu_lists_local_multiplayer() -> void:
	_to_menu()
	var labels: Array = []
	for item in _host._menu._items:
		labels.append(item["label"])
	check(labels.has("LOCAL MULTIPLAYER"), "main menu has a local multiplayer entry")
	check(labels.has("SOLO"), "solo category present")
	check_false(labels.has("MARATHON"), "solo modes live behind the solo category")
