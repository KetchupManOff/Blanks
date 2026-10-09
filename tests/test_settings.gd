extends "res://tests/test_lib.gd"
## Settings model tests: schema v2 defaults, atomic persistence, versioned
## loading, v1 migration, unknown-field preservation, volume/volume-key
## edge cases, keyboard-binding sanitation, player profile management, and
## per-profile five-best result histories. Uses an isolated settings file;
## the real user://settings.json is moved aside by the runner.

const SettingsClass = preload("res://scripts/persistence/settings.gd")
const DefaultBindings = preload("res://scripts/input/default_bindings.gd")
const ModeRules = preload("res://scripts/core/mode_rules.gd")

const PATH := "user://test_settings_unit.json"


func teardown() -> void:
	if FileAccess.file_exists(PATH):
		DirAccess.remove_absolute(PATH)


func _make_record(score: int, elapsed: float, completed: int, players: int = 1, mode := "solo_marathon") -> Dictionary:
	return {"score": score, "elapsed": elapsed, "completed_at": completed, "players": players, "mode": mode}


# ---------------------------------------------------------------- defaults

func test_defaults() -> void:
	var s := SettingsClass.new()
	check_eq(s.SCHEMA_VERSION, 2, "schema version is 2")
	check_eq(s.keyboard_bindings, DefaultBindings.default_keyboard_profile(), "shared keyboard profile defaults")
	for action in DefaultBindings.ACTION_NAMES:
		check(s.keyboard_bindings.has(action), "keyboard profile covers %s" % action)
		check(s.keyboard_bindings[action].size() >= 1, "every action has a keyboard default: %s" % action)
	check_eq(s.profiles.size(), 1, "one default profile")
	var p: Dictionary = s.profiles[0]
	check_eq(p["name"], "Player 1", "default profile name")
	check_eq(p["controller_bindings"], DefaultBindings.default_controller_profile(), "default profile ships the default controller mapping")
	check_eq(s.active_profile_id, p["id"], "active profile points at the default profile")
	check_true(s.active_profile_name() == "Player 1", "active profile name")


func test_default_controller_profile_is_controller_only() -> void:
	var controller := DefaultBindings.default_controller_profile()
	for action in DefaultBindings.ACTION_NAMES:
		check(controller.has(action), "controller profile covers %s" % action)
		for record in controller[action]:
			check_eq(DefaultBindings.device_category(record), "controller", "%s record is controller-only" % action)


func test_profile_result_containers_start_empty() -> void:
	var s := SettingsClass.new()
	var p: Dictionary = s.profiles[0]
	check_eq(p["results"].size(), 0, "no results on a fresh profile")
	check_eq(s.profile_history(p["id"], "solo_marathon"), [], "history query on a fresh profile is empty")


# ------------------------------------------------------------------ loading

func test_missing_file_leaves_defaults() -> void:
	# Earlier tests in this suite may have written PATH; the suite teardown
	# only runs once at the end.
	if FileAccess.file_exists(PATH):
		DirAccess.remove_absolute(PATH)
	var s := SettingsClass.new()
	check_false(s.load(PATH), "missing file reports not-loaded")
	check_eq(s.window_scale, 1, "defaults intact")


func test_malformed_json_falls_back() -> void:
	var f := FileAccess.open(PATH, FileAccess.WRITE)
	f.store_string("this is not json")
	f.close()
	var s := SettingsClass.new()
	check_false(s.load(PATH), "garbage reports not-loaded")
	check_eq(s.profiles.size(), 1, "defaults restored")
	check_eq(s.profiles[0]["name"], "Player 1", "default profile recovered")


func test_unknown_version_rejected() -> void:
	var f := FileAccess.open(PATH, FileAccess.WRITE)
	f.store_string(JSON.stringify({"version": 99, "display": {"fullscreen": true}}))
	f.close()
	var s := SettingsClass.new()
	check_false(s.load(PATH), "future version rejected")
	check_false(s.fullscreen, "display not applied from an unknown version")


func test_roundtrip() -> void:
	var s := SettingsClass.new()
	s.fullscreen = true
	s.window_scale = 3
	s.master_volume = 0.25
	s.theme_id = "builtin:retro_crt"
	check_true(s.save(PATH), "save succeeds")
	var loaded := SettingsClass.new()
	check_true(loaded.load(PATH), "load succeeds")
	check_eq(loaded.fullscreen, true, "fullscreen round trips")
	check_eq(loaded.window_scale, 3, "window scale round trips")
	check_true(is_equal_approx(loaded.master_volume, 0.25), "volumes round trip")
	check_eq(loaded.theme_id, "builtin:retro_crt", "theme id round trips")
	check_eq(loaded.keyboard_bindings, s.keyboard_bindings, "keyboard profile round trips")
	check_eq(loaded.profiles, s.profiles, "profiles round trip")
	check_eq(loaded.active_profile_id, s.active_profile_id, "active id round trips")


func test_atomic_save_leaves_no_tmp() -> void:
	var s := SettingsClass.new()
	check_true(s.save(PATH), "save succeeds")
	check_false(FileAccess.file_exists(PATH + ".tmp"), "no temp file remains")


func test_unknown_top_level_fields_preserved() -> void:
	var s := SettingsClass.new()
	s.extra_fields = {"custom_thing": 42}
	s.save(PATH)
	var loaded := SettingsClass.new()
	loaded.load(PATH)
	check_eq(loaded.extra_fields.get("custom_thing", null), 42, "unknown top-level field preserved")


func test_unknown_top_level_fields_from_disk() -> void:
	# Written by an unknown-future variant of this game: this version keeps
	# fields it does not own instead of dropping them.
	var payload := {
		"version": 2,
		"display": {"fullscreen": true},
		"keyboard_bindings": {"move_left": [{"device": "keyboard", "code": 4150722}]},
		"profiles": [{"id": "px", "name": "X", "controller_bindings": {}, "results": {}}],
		"active_profile_id": "px",
		"future_field": {"nested": [1, 2, 3]},
	}
	var f := FileAccess.open(PATH, FileAccess.WRITE)
	f.store_string(JSON.stringify(payload))
	f.close()
	var s := SettingsClass.new()
	check_true(s.load(PATH), "payload applies")
	check_eq(s.extra_fields.get("future_field", {}).get("nested", []), [1.0, 2.0, 3.0], "future top-level field kept as extra")
	check_eq(s.keyboard_bindings["move_left"][0]["code"], 4150722, "keyboard record applies")


# --------------------------------------------------------------- migration

func test_v1_migrates_to_v2() -> void:
	# A pre-profile settings file: the mixed global bindings split into the
	# shared keyboard profile plus a "Player 1" controller profile.
	var old_mixed := {
		"move_left": [
			DefaultBindings.key_record(KEY_A),
			DefaultBindings.joy_button_record(13),
		],
		"move_right": [DefaultBindings.key_record(KEY_D)],
		"hard_drop": [
			DefaultBindings.key_record(KEY_SPACE),
			DefaultBindings.joy_button_record(1),
		],
		"pause": [DefaultBindings.key_record(KEY_ESCAPE)],
	}
	var payload := {
		"version": 1,
		"display": {"fullscreen": true, "window_scale": 2},
		"audio": {"master_volume": 0.5},
		"bindings": old_mixed,
	}
	var f := FileAccess.open(PATH, FileAccess.WRITE)
	f.store_string(JSON.stringify(payload))
	f.close()
	var s := SettingsClass.new()
	check_true(s.load(PATH), "v1 file loads through migration")
	check_eq(s.SCHEMA_VERSION, 2, "model reports v2 after migration")
	check_eq(s.fullscreen, true, "display section preserved")
	check_eq(s.window_scale, 2, "display scale preserved")
	check_true(is_equal_approx(s.master_volume, 0.5), "audio preserved")
	check_eq(s.keyboard_bindings["move_left"], [DefaultBindings.key_record(KEY_A)], "keyboard category moved to the shared keyboard profile")
	check_eq(s.keyboard_bindings["hard_drop"], [DefaultBindings.key_record(KEY_SPACE)], "keyboard hard drop migrated")
	var controller: Dictionary = s.controller_bindings_for(s.active_profile_id)
	check_eq(controller["move_left"], [DefaultBindings.joy_button_record(13)], "controller category seeded the Player 1 profile")
	check_eq(controller["hard_drop"], [DefaultBindings.joy_button_record(1)], "controller hard drop migrated")
	check_eq(s.profiles.size(), 1, "one migrated profile")
	check_eq(s.profiles[0]["name"], "Player 1", "migrated profile named")
	check_eq(s.active_profile_id, s.profiles[0]["id"], "active profile is the migrated one")


func test_v1_without_bindings_uses_defaults() -> void:
	var payload := {"version": 1, "display": {"fullscreen": true}}
	var f := FileAccess.open(PATH, FileAccess.WRITE)
	f.store_string(JSON.stringify(payload))
	f.close()
	var s := SettingsClass.new()
	check_true(s.load(PATH), "v1 payload without bindings loads")
	check_eq(s.keyboard_bindings, DefaultBindings.default_keyboard_profile(), "default keyboard profile")
	check_eq(s.controller_bindings_for(s.active_profile_id), DefaultBindings.default_controller_profile(), "default controller profile")
	check_eq(s.fullscreen, true, "display still applied")


func test_corrupt_profiles_recover_player_one() -> void:
	# Missing or unusable profile sections recover to a usable Player 1
	# without losing unrelated settings.
	var payload := {
		"version": 2,
		"display": {"fullscreen": true},
		"profiles": "not an array",
	}
	var f := FileAccess.open(PATH, FileAccess.WRITE)
	f.store_string(JSON.stringify(payload))
	f.close()
	var s := SettingsClass.new()
	check_true(s.load(PATH), "payload applies")
	check_eq(s.profiles.size(), 1, "single recovery profile")
	check_eq(s.profiles[0]["name"], "Player 1", "recovered as Player 1")
	check_eq(s.active_profile_id, s.profiles[0]["id"], "active id repaired")
	check_eq(s.fullscreen, true, "unrelated display settings survive")


func test_active_profile_id_recovery() -> void:
	var payload := {
		"version": 2,
		"profiles": [
			{"id": "pa", "name": "A", "controller_bindings": {}, "results": {}},
			{"id": "pb", "name": "B", "controller_bindings": {}, "results": {}},
		],
		"active_profile_id": "ghost",
	}
	var f := FileAccess.open(PATH, FileAccess.WRITE)
	f.store_string(JSON.stringify(payload))
	f.close()
	var s := SettingsClass.new()
	check_true(s.load(PATH), "payload applies")
	check_eq(s.active_profile_id, "pa", "unknown active id recovers to the first profile")


func test_idless_profile_entry_recovers_with_fresh_id() -> void:
	var payload := {
		"version": 2,
		"profiles": [{"name": "Keeper", "controller_bindings": {}, "results": {"solo_marathon": [_make_record(900, 30.0, 7)]}}],
	}
	var f := FileAccess.open(PATH, FileAccess.WRITE)
	f.store_string(JSON.stringify(payload))
	f.close()
	var s := SettingsClass.new()
	check_true(s.load(PATH), "payload applies")
	check_eq(s.profiles.size(), 1, "idless entry kept instead of dropped")
	check_false(String(s.profiles[0]["id"]).is_empty(), "recovered entry gets an id")
	check_eq(s.profiles[0]["name"], "Keeper", "recovered entry keeps its name")
	check_eq(s.profile_history(s.profiles[0]["id"], "solo_marathon").size(), 1, "recovered entry keeps its results")


# ------------------------------------------------------------ display/audio

func test_display_volume_clamping() -> void:
	var s := SettingsClass.new()
	var f := FileAccess.open(PATH, FileAccess.WRITE)
	f.store_string(JSON.stringify({
		"version": 2,
		"display": {"fullscreen": "yes", "window_scale": 9},
		"audio": {"master_volume": 1.7, "music_volume": "loud", "sfx_volume": -0.5},
	}))
	f.close()
	check_true(s.load(PATH), "payload applies")
	check_eq(s.fullscreen, false, "non-bool fullscreen keeps default")
	check_eq(s.window_scale, 1, "unsupported window scale keeps default")
	check_eq(s.master_volume, 1.0, "over-range volume clamps")
	check_eq(s.music_volume, 0.8, "non-numeric volume keeps default")
	check_eq(s.sfx_volume, 0.0, "negative volume clamps to zero")


func test_float_keycodes_normalized() -> void:
	# JSON numbers parse as floats; integral floats must normalize to int
	# keycodes so events compare equal.
	var f := FileAccess.open(PATH, FileAccess.WRITE)
	f.store_string(JSON.stringify({
		"version": 2,
		"keyboard_bindings": {
			"move_left": [{"device": "keyboard", "code": float(KEY_LEFT)}],
		},
	}))
	f.close()
	var s := SettingsClass.new()
	check_true(s.load(PATH), "payload applies")
	var records: Array = s.keyboard_bindings["move_left"]
	check_eq(records[0]["code"], KEY_LEFT, "float keycode normalized to int")
	check_eq(records[0], DefaultBindings.key_record(KEY_LEFT), "record equal to the canonical key record")


func test_reset_to_defaults() -> void:
	var s := SettingsClass.new()
	s.fullscreen = true
	s.master_volume = 0.1
	s.keyboard_bindings["move_left"] = []
	var id := s.create_profile("Second")
	check_true(id != "", "second profile created")
	s.set_active_profile(id)
	s.reset_to_defaults()
	check_eq(s.fullscreen, false, "display reset")
	check_eq(s.master_volume, 1.0, "audio reset")
	check_eq(s.keyboard_bindings, DefaultBindings.default_keyboard_profile(), "keyboard profile reset")
	check_eq(s.profiles.size(), 1, "profiles reset to the default Player 1")
	check_eq(s.profiles[0]["results"].size(), 0, "results reset with profiles")


# ------------------------------------------------- keyboard binding storage

func test_intentionally_empty_keyboard_action_stays_empty() -> void:
	# Sanitation must not reintroduce default bindings for an action the
	# user deliberately cleared.
	var s := SettingsClass.new()
	s.keyboard_bindings["hold"] = []
	s.save(PATH)
	var loaded := SettingsClass.new()
	loaded.load(PATH)
	check_eq(loaded.keyboard_bindings["hold"], [], "cleared keyboard action stays cleared")
	check_eq(loaded.keyboard_bindings["move_left"], DefaultBindings.default_keyboard_profile()["move_left"], "other actions keep their records")


func test_invalid_binding_records_ignored() -> void:
	var f := FileAccess.open(PATH, FileAccess.WRITE)
	f.store_string(JSON.stringify({
		"version": 2,
		"keyboard_bindings": {
			"move_left": [
				{"device": "keyboard", "code": KEY_A},
				{"device": "controller", "code": 3},
				"nonsense",
				{"device": "joypad_button", "index": 4},
				{"device": "keyboard", "code": -6},
			],
		},
	}))
	f.close()
	var s := SettingsClass.new()
	check_true(s.load(PATH), "payload applies")
	check_eq(s.keyboard_bindings["move_left"], [DefaultBindings.key_record(KEY_A)], "only the valid keyboard record kept")


func test_foreign_category_records_dropped_from_profiles() -> void:
	var s := SettingsClass.new()
	var id := s.active_profile_id
	s.find_profile(id)["controller_bindings"]["hold"] = [DefaultBindings.key_record(KEY_C)]
	s.save(PATH)
	var loaded := SettingsClass.new()
	loaded.load(PATH)
	check_eq(loaded.controller_bindings_for(id)["hold"], [], "keyboard records rejected inside controller profiles")


# ------------------------------------------------------------------ profiles

func test_create_and_rename_profiles() -> void:
	var s := SettingsClass.new()
	var id_a := s.create_profile("  Alice \n Quin ")
	check_true(id_a != "", "profile created")
	check_eq(s.find_profile(id_a)["name"], "Alice Quin", "name trimmed and single-lined")
	var id_b := s.create_profile("Alice Quin")
	check_eq(id_b, "", "duplicate name rejected")
	check_false(s.rename_profile(id_a, "player 1"), "rename rejected when it duplicates another profile")
	check_true(s.rename_profile(id_a, "  Bobby  "), "rename succeeds")
	check_eq(s.find_profile(id_a)["name"], "Bobby", "rename applied and trimmed")
	check_eq(s.create_profile(""), "", "blank name rejected")
	check_false(s.rename_profile("ghost", "X"), "rename of a missing profile fails")


func test_profile_name_length_cap() -> void:
	var long_name := "AB".repeat(30)
	var s := SettingsClass.new()
	var id := s.create_profile(long_name)
	check_true(id != "", "long-named profile created")
	check_eq(s.find_profile(id)["name"].length(), SettingsClass.MAX_NAME_LENGTH, "name capped to the maximum length")


func test_profile_names_unique_case_insensitive() -> void:
	var s := SettingsClass.new()
	check_true(s.create_profile("RIVER") != "", "profile created")
	check_eq(s.create_profile("river"), "", "case-insensitive duplicate rejected")
	check_true(s.create_profile("river2") != "", "different name accepted")
	check_true(s.profile_name_taken("RIVER"), "taken check is case-insensitive")


func test_profile_name_taken_exclude() -> void:
	var s := SettingsClass.new()
	var id := s.create_profile("Delta")
	check_true(s.profile_name_taken("Delta"), "taken without exclusion")
	check_false(s.profile_name_taken("Delta", id), "own name excluded")


func test_set_active_profile() -> void:
	var s := SettingsClass.new()
	var id := s.create_profile("Second")
	check_true(s.set_active_profile(id), "active set to an existing profile")
	check_eq(s.active_profile_id, id, "active id updated")
	check_false(s.set_active_profile("ghost"), "missing profile rejected")
	check_eq(s.active_profile_id, id, "active unchanged by the failed set")
	check_eq(s.active_profile_name(), "Second", "active name follows")


func test_fresh_profile_ids_stable_and_unique() -> void:
	check_eq(SettingsClass.fresh_profile_id([]), "p1", "first id")
	check_eq(SettingsClass.fresh_profile_id(["p1"]), "p2", "second id")
	check_eq(SettingsClass.fresh_profile_id(["p1", "p2"]), "p3", "third id")
	check_eq(SettingsClass.fresh_profile_id(["p2", "p3"]), "p1", "gaps reused")


# ------------------------------------------------------------------- results

func test_append_result_orders_score_desc() -> void:
	var s := SettingsClass.new()
	var id := s.active_profile_id
	var key := "solo_marathon"
	check_eq(s.append_result(id, key, _make_record(900, 10.0, 1), true), 1, "first result places first")
	check_eq(s.append_result(id, key, _make_record(1500, 20.0, 2), true), 1, "higher score takes the top")
	check_eq(s.append_result(id, key, _make_record(1000, 30.0, 3), true), 2, "middle score places second")
	var history: Array = s.profile_history(id, key)
	check_eq([history[0]["score"], history[1]["score"], history[2]["score"]], [1500, 1000, 900], "score-descending order")


func test_append_result_orders_time_asc() -> void:
	var s := SettingsClass.new()
	var id := s.active_profile_id
	var key := "solo_sprint"
	s.append_result(id, key, _make_record(100, 95.0, 1, 1, "solo_sprint"), false)
	s.append_result(id, key, _make_record(100, 80.0, 2, 1, "solo_sprint"), false)
	var history: Array = s.profile_history(id, key)
	check_eq([history[0]["elapsed"], history[1]["elapsed"]], [80.0, 95.0], "time-ascending order")
	check_eq(history[0]["mode"], "solo_sprint", "mode key stored on the record")
	check_eq(history[0]["players"], 1, "player count stored on the record")


func test_append_result_trims_to_five() -> void:
	var s := SettingsClass.new()
	var id := s.active_profile_id
	for i in 7:
		s.append_result(id, "coop_marathon", _make_record(100 + i, 5.0, i), true)
	var history: Array = s.profile_history(id, "coop_marathon")
	check_eq(history.size(), 5, "history capped at five records")
	check_eq(history[0]["score"], 106, "best five kept, worst dropped")


func test_append_result_stable_for_equal_scores() -> void:
	var s := SettingsClass.new()
	var id := s.active_profile_id
	s.append_result(id, "solo_marathon", _make_record(500, 10.0, 100), true)
	var place := s.append_result(id, "solo_marathon", _make_record(500, 20.0, 200), true)
	check_eq(place, 2, "equal score appends after the earlier record")


func test_append_result_rejections() -> void:
	var s := SettingsClass.new()
	var id := s.active_profile_id
	check_eq(s.append_result("ghost", "solo_marathon", _make_record(1, 1.0, 1), true), 0, "missing profile rejected")
	check_eq(s.append_result(id, "", _make_record(1, 1.0, 1), true), 0, "empty mode key rejected")
	check_eq(s.append_result(id, "solo_marathon", {"score": -5, "elapsed": 1.0, "completed_at": 1}, true), 0, "negative score rejected")
	check_eq(s.append_result(id, "solo_marathon", {"score": 5, "elapsed": -1.0, "completed_at": 1}, true), 0, "negative time rejected")
	check_eq(s.profile_history(id, "solo_marathon"), [], "rejected results never stored")


func test_unknown_future_mode_keys_preserved() -> void:
	# A future version may record results under keys this version does not
	# know: they must survive a save/load round trip untouched.
	var s := SettingsClass.new()
	var id := s.active_profile_id
	s.append_result(id, "future_blitz", _make_record(1234, 42.0, 9, 2, "future_blitz"), true)
	check_true(s.save(PATH), "save succeeds")
	var loaded := SettingsClass.new()
	loaded.load(PATH)
	var history: Array = loaded.profile_history(id, "future_blitz")
	check_eq(history.size(), 1, "unknown mode key preserved")
	check_eq(history[0]["score"], 1234, "unknown-mode record intact")
	check_eq(history[0]["players"], 2, "metadata intact on unknown keys")


func test_malformed_results_sanitized() -> void:
	var payload := {
		"version": 2,
		"profiles": [{
			"id": "px",
			"name": "X",
			"controller_bindings": {},
			"results": {
				"solo_marathon": ["junk", {"score": 10, "elapsed": 5.0}, {"score": -1, "elapsed": 2.0, "completed_at": 3}],
				"": [_make_record(1, 1.0, 1)],
			},
		}],
	}
	var f := FileAccess.open(PATH, FileAccess.WRITE)
	f.store_string(JSON.stringify(payload))
	f.close()
	var s := SettingsClass.new()
	check_true(s.load(PATH), "payload applies")
	var history: Array = s.profile_history("px", "solo_marathon")
	check_eq(history.size(), 1, "only the structurally valid result kept")
	check_eq(history[0]["completed_at"], 0, "missing timestamp defaults to zero")
	check_false(s.profiles[0]["results"].has(""), "empty mode key dropped")


func test_results_trimmed_on_load() -> void:
	var big: Array = []
	for i in 8:
		big.append(_make_record(100 + i, 5.0, i))
	var payload := {
		"version": 2,
		"profiles": [{"id": "px", "name": "X", "controller_bindings": {}, "results": {"solo_marathon": big}}],
	}
	var f := FileAccess.open(PATH, FileAccess.WRITE)
	f.store_string(JSON.stringify(payload))
	f.close()
	var s := SettingsClass.new()
	check_true(s.load(PATH), "payload applies")
	var history: Array = s.profile_history("px", "solo_marathon")
	check_eq(history.size(), SettingsClass.MAX_RESULTS_PER_MODE, "overlong history trimmed on load")
	check_eq(history[0]["score"], 107, "the best five retained")
