extends "res://tests/test_lib.gd"
## Settings model tests: schema v3 defaults (per-profile keyboard
## bindings), atomic persistence, versioned loading, v1/v2 migrations,
## unknown-field preservation, volume/volume-key edge cases,
## keyboard-binding sanitation, player profile management, per-profile
## keyboard independence, and per-profile five-best result histories.
## Uses an isolated settings file; the real user://settings.json is moved
## aside by the runner.

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
	check_eq(s.SCHEMA_VERSION, 4, "schema version is 4")
	check_eq(s.profiles.size(), 1, "one default profile")
	var p: Dictionary = s.profiles[0]
	check_eq(p["name"], "Player 1", "default profile name")
	check_eq(p["keyboard_bindings"], DefaultBindings.default_keyboard_profile(), "default profile ships the default keyboard mapping")
	for action in DefaultBindings.ACTION_NAMES:
		check((p["keyboard_bindings"] as Dictionary).has(action), "keyboard profile covers %s" % action)
		check((p["keyboard_bindings"] as Dictionary)[action].size() >= 1, "every action has a keyboard default: %s" % action)
	check_eq(p["controller_bindings"], DefaultBindings.default_controller_profile(), "default profile ships the default controller mapping")
	check_eq(s.active_profile_id, p["id"], "active profile points at the default profile")
	check_eq(s.keyboard_bindings_for(p["id"]), DefaultBindings.default_keyboard_profile(), "keyboard_bindings_for returns the profile mapping")
	check_eq(s.active_keyboard_bindings(), DefaultBindings.default_keyboard_profile(), "active keyboard mapping is the active profile's")
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
	check_eq(loaded.keyboard_bindings_for(loaded.active_profile_id), s.keyboard_bindings_for(s.active_profile_id), "per-profile keyboard mapping round trips")
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
		"version": 3,
		"display": {"fullscreen": true},
		"profiles": [{"id": "px", "name": "X", "keyboard_bindings": {"move_left": [{"device": "keyboard", "code": 4150722}]}, "controller_bindings": {}, "results": {}}],
		"active_profile_id": "px",
		"future_field": {"nested": [1, 2, 3]},
	}
	var f := FileAccess.open(PATH, FileAccess.WRITE)
	f.store_string(JSON.stringify(payload))
	f.close()
	var s := SettingsClass.new()
	check_true(s.load(PATH), "payload applies")
	check_eq(s.extra_fields.get("future_field", {}).get("nested", []), [1.0, 2.0, 3.0], "future top-level field kept as extra")
	check_eq(s.keyboard_bindings_for("px")["move_left"][0]["code"], 4150722, "per-profile keyboard record applies")


func test_stale_top_level_keyboard_not_resaved() -> void:
	# A v2 leftover top-level keyboard profile is consumed by the v3 load
	# (never resurfacing as an unknown field) and never re-saved.
	var payload := {
		"version": 3,
		"keyboard_bindings": {"move_left": [{"device": "keyboard", "code": 65}]},
		"profiles": [{"id": "px", "name": "X", "controller_bindings": {}, "results": {}}],
		"active_profile_id": "px",
	}
	var f := FileAccess.open(PATH, FileAccess.WRITE)
	f.store_string(JSON.stringify(payload))
	f.close()
	var s := SettingsClass.new()
	check_true(s.load(PATH), "payload applies")
	check_false(s.extra_fields.has("keyboard_bindings"), "stale top-level keyboard consumed, not preserved as extra")
	check_eq(s.keyboard_bindings_for("px")["move_left"], [], "profile mapping untouched by the stale field")
	check_true(s.save(PATH), "save succeeds")
	var raw := FileAccess.open(PATH, FileAccess.READ).get_as_text()
	check_false(JSON.parse_string(raw).has("keyboard_bindings"), "stale top-level keyboard dropped on save")


# --------------------------------------------------------------- migration

func test_v2_migrates_shared_keyboard_into_profiles() -> void:
	# v2's one shared keyboard profile deep-copies into every retained
	# profile; a save afterwards drops the shared field irreversibly.
	var shared := {
		"move_left": [DefaultBindings.key_record(KEY_A)],
		"hard_drop": [DefaultBindings.key_record(KEY_SPACE)],
	}
	var payload := {
		"version": 2,
		"display": {"fullscreen": true},
		"keyboard_bindings": shared,
		"profiles": [
			{"id": "pa", "name": "A", "controller_bindings": {}, "results": {}},
			{"id": "pb", "name": "B", "controller_bindings": {}, "results": {}},
		],
		"active_profile_id": "pa",
	}
	var f := FileAccess.open(PATH, FileAccess.WRITE)
	f.store_string(JSON.stringify(payload))
	f.close()
	var s := SettingsClass.new()
	check_true(s.load(PATH), "v2 file loads through migration")
	check_eq(s.SCHEMA_VERSION, 4, "model reports v4 after migration")
	check_eq(s.keyboard_bindings_for("pa")["move_left"], [DefaultBindings.key_record(KEY_A)], "shared keyboard copied into profile A")
	check_eq(s.keyboard_bindings_for("pb")["move_left"], [DefaultBindings.key_record(KEY_A)], "shared keyboard copied into profile B")
	check_eq(s.keyboard_bindings_for("pa")["hard_drop"], [DefaultBindings.key_record(KEY_SPACE)], "every action of the shared profile copied")
	check_true(s.save(PATH), "save succeeds")
	var raw := FileAccess.open(PATH, FileAccess.READ).get_as_text()
	check_false(JSON.parse_string(raw).has("keyboard_bindings"), "shared top-level field dropped after migration save")
	var reloaded := SettingsClass.new()
	check_true(reloaded.load(PATH), "migrated file reloads as v3")
	check_eq(reloaded.keyboard_bindings_for("pb")["move_left"], [DefaultBindings.key_record(KEY_A)], "per-profile keyboard survives the round trip")


func test_v2_migration_keeps_per_profile_keyboard() -> void:
	# A v2 file that already carries per-profile keyboard mappings (never
	# written by v2 code, but never wrong to honor) keeps them verbatim.
	var payload := {
		"version": 2,
		"keyboard_bindings": {"move_left": [DefaultBindings.key_record(KEY_A)]},
		"profiles": [
			{"id": "pa", "name": "A", "keyboard_bindings": {"move_left": [DefaultBindings.key_record(KEY_Z)]}, "controller_bindings": {}, "results": {}},
		],
		"active_profile_id": "pa",
	}
	var f := FileAccess.open(PATH, FileAccess.WRITE)
	f.store_string(JSON.stringify(payload))
	f.close()
	var s := SettingsClass.new()
	check_true(s.load(PATH), "payload loads")
	check_eq(s.keyboard_bindings_for("pa")["move_left"], [DefaultBindings.key_record(KEY_Z)], "existing per-profile keyboard kept")


func test_v1_migrates_to_v3() -> void:
	# A pre-profile settings file: the mixed global bindings split into the
	# migrated default profile's keyboard and controller mappings.
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
	check_eq(s.SCHEMA_VERSION, 4, "model reports v4 after migration")
	check_eq(s.fullscreen, true, "display section preserved")
	check_eq(s.window_scale, 2, "display scale preserved")
	check_true(is_equal_approx(s.master_volume, 0.5), "audio preserved")
	check_eq(s.keyboard_bindings_for(s.active_profile_id)["move_left"], [DefaultBindings.key_record(KEY_A)], "keyboard category moved into the migrated profile")
	check_eq(s.keyboard_bindings_for(s.active_profile_id)["hard_drop"], [DefaultBindings.key_record(KEY_SPACE)], "keyboard hard drop migrated")
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
	check_eq(s.active_keyboard_bindings(), DefaultBindings.default_keyboard_profile(), "default keyboard mapping")
	check_eq(s.controller_bindings_for(s.active_profile_id), DefaultBindings.default_controller_profile(), "default controller mapping")
	check_eq(s.fullscreen, true, "display still applied")


func test_corrupt_profiles_recover_player_one() -> void:
	# Missing or unusable profile sections recover to a usable Player 1
	# without losing unrelated settings.
	var payload := {
		"version": 3,
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
		"version": 3,
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
		"version": 3,
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
		"version": 3,
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
		"version": 3,
		"profiles": [{
			"id": "pa",
			"name": "A",
			"keyboard_bindings": {
				"move_left": [{"device": "keyboard", "code": float(KEY_LEFT)}],
			},
			"controller_bindings": {},
			"results": {},
		}],
		"active_profile_id": "pa",
	}))
	f.close()
	var s := SettingsClass.new()
	check_true(s.load(PATH), "payload applies")
	var records: Array = s.keyboard_bindings_for("pa")["move_left"]
	check_eq(records[0]["code"], KEY_LEFT, "float keycode normalized to int")
	check_eq(records[0], DefaultBindings.key_record(KEY_LEFT), "record equal to the canonical key record")


func test_reset_to_defaults() -> void:
	var s := SettingsClass.new()
	s.fullscreen = true
	s.master_volume = 0.1
	s.keyboard_bindings_for(s.active_profile_id)["move_left"] = []
	var id := s.create_profile("Second")
	check_true(id != "", "second profile created")
	s.set_active_profile(id)
	s.reset_to_defaults()
	check_eq(s.fullscreen, false, "display reset")
	check_eq(s.master_volume, 1.0, "audio reset")
	check_eq(s.active_keyboard_bindings(), DefaultBindings.default_keyboard_profile(), "keyboard mapping reset")
	check_eq(s.profiles.size(), 1, "profiles reset to the default Player 1")
	check_eq(s.profiles[0]["results"].size(), 0, "results reset with profiles")


# ------------------------------------------------- keyboard binding storage

func test_intentionally_empty_keyboard_action_stays_empty() -> void:
	# Sanitation must not reintroduce default bindings for an action the
	# user deliberately cleared.
	var s := SettingsClass.new()
	var id := s.active_profile_id
	s.find_profile(id)["keyboard_bindings"]["hold"] = []
	s.save(PATH)
	var loaded := SettingsClass.new()
	loaded.load(PATH)
	check_eq(loaded.keyboard_bindings_for(id)["hold"], [], "cleared keyboard action stays cleared")
	check_eq(loaded.keyboard_bindings_for(id)["move_left"], DefaultBindings.default_keyboard_profile()["move_left"], "other actions keep their records")


func test_invalid_binding_records_ignored() -> void:
	var f := FileAccess.open(PATH, FileAccess.WRITE)
	f.store_string(JSON.stringify({
		"version": 3,
		"profiles": [{
			"id": "pa",
			"name": "A",
			"keyboard_bindings": {
				"move_left": [
					{"device": "keyboard", "code": KEY_A},
					{"device": "controller", "code": 3},
					"nonsense",
					{"device": "joypad_button", "index": 4},
					{"device": "keyboard", "code": -6},
				],
			},
			"controller_bindings": {},
			"results": {},
		}],
		"active_profile_id": "pa",
	}))
	f.close()
	var s := SettingsClass.new()
	check_true(s.load(PATH), "payload applies")
	check_eq(s.keyboard_bindings_for("pa")["move_left"], [DefaultBindings.key_record(KEY_A)], "only the valid keyboard record kept")


func test_foreign_category_records_dropped_from_profiles() -> void:
	var s := SettingsClass.new()
	var id := s.active_profile_id
	s.find_profile(id)["controller_bindings"]["hold"] = [DefaultBindings.key_record(KEY_C)]
	s.find_profile(id)["keyboard_bindings"]["hold"] = [DefaultBindings.joy_button_record(2)]
	s.save(PATH)
	var loaded := SettingsClass.new()
	loaded.load(PATH)
	check_eq(loaded.controller_bindings_for(id)["hold"], [], "keyboard records rejected inside controller mappings")
	check_eq(loaded.keyboard_bindings_for(id)["hold"], [], "controller records rejected inside keyboard mappings")


# ------------------------------------------------------------ per-profile kb

func test_per_profile_keyboard_mappings_independent() -> void:
	# Two profiles may share the same physical keyboard locally (or sit on
	# separate machines online): editing one mapping never leaks into the
	# other, and duplicate records across profiles stay valid.
	var s := SettingsClass.new()
	var a := s.active_profile_id
	var b := s.create_profile("Second")
	check_true(b != "", "second profile created")
	var custom := DefaultBindings.default_keyboard_profile()
	custom["hold"] = [DefaultBindings.key_record(KEY_C)]
	custom["move_left"] = []
	check_true(s.set_keyboard_bindings(b, custom), "commit a custom mapping to profile B")
	check_eq(s.keyboard_bindings_for(b)["hold"], [DefaultBindings.key_record(KEY_C)], "profile B holds the custom record")
	check_eq(s.keyboard_bindings_for(b)["move_left"], [], "intentionally empty action stays empty on commit")
	check_eq(s.keyboard_bindings_for(a)["hold"], DefaultBindings.default_keyboard_profile()["hold"], "profile A keeps its own mapping")
	check_eq(s.keyboard_bindings_for(a)["move_left"], DefaultBindings.default_keyboard_profile()["move_left"], "profile A untouched by the commit")
	check_true(s.save(PATH), "save succeeds")
	var loaded := SettingsClass.new()
	loaded.load(PATH)
	check_eq(loaded.keyboard_bindings_for(b)["hold"], [DefaultBindings.key_record(KEY_C)], "independent mappings survive the round trip")
	check_eq(loaded.keyboard_bindings_for(a)["hold"], DefaultBindings.default_keyboard_profile()["hold"], "other mapping survives untouched")


func test_keyboard_reset_is_per_profile() -> void:
	var s := SettingsClass.new()
	var a := s.active_profile_id
	var b := s.create_profile("Second")
	var custom := DefaultBindings.default_keyboard_profile()
	custom["hold"] = [DefaultBindings.key_record(KEY_C)]
	check_true(s.set_keyboard_bindings(b, custom), "custom mapping committed")
	check_true(s.reset_keyboard_bindings(b), "reset targets profile B")
	check_eq(s.keyboard_bindings_for(b), DefaultBindings.default_keyboard_profile(), "profile B reset to defaults")
	check_eq(s.keyboard_bindings_for(b)["hold"], DefaultBindings.default_keyboard_profile()["hold"], "custom record gone")
	check_eq(s.keyboard_bindings_for(a), DefaultBindings.default_keyboard_profile(), "profile A still default-shaped")
	custom["hold"] = [DefaultBindings.key_record(KEY_T)]
	check_true(s.set_keyboard_bindings(a, custom), "profile A gets a custom record")
	check_true(s.reset_keyboard_bindings(a), "reset targets profile A")
	check_eq(s.keyboard_bindings_for(b)["hold"], DefaultBindings.default_keyboard_profile()["hold"], "profile B unaffected by A's reset")
	check_false(s.reset_keyboard_bindings("ghost"), "missing profile rejected")
	check_false(s.set_keyboard_bindings("ghost", {}), "missing profile commit rejected")


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
		"version": 3,
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
		"version": 3,
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


# -------------------------------------------------------------- playlists

func test_playlist_defaults_and_roundtrip() -> void:
	var s := SettingsClass.new()
	check_eq(s.music_playlists.size(), 0, "no playlists by default")
	check_eq(s.active_music_playlist_id, "", "no active playlist by default")
	check_eq(s.music_shuffle_source, "library", "shuffle draws from the library by default")
	var id := s.create_playlist("Chill")
	check_true(id != "", "playlist created")
	check_true(s.set_playlist_tracks(id, ["user://music/x.ogg", "user://music/y.wav"]), "tracks set")
	check_true(s.set_active_playlist(id), "playlist activated")
	s.music_shuffle_source = "playlist"
	check_true(s.save(PATH), "save succeeds")
	var loaded := SettingsClass.new()
	check_true(loaded.load(PATH), "load succeeds")
	check_eq(loaded.music_playlists.size(), 1, "playlist record round trips")
	check_eq(loaded.playlist_name(id), "Chill", "name round trips")
	check_eq(loaded.playlist_tracks(id), ["user://music/x.ogg", "user://music/y.wav"], "ordered tracks round trip")
	check_eq(loaded.active_music_playlist_id, id, "active id round trips")
	check_eq(loaded.music_shuffle_source, "playlist", "shuffle source round trips")


func test_playlist_empty_lists_stay_empty() -> void:
	var s := SettingsClass.new()
	var id := s.create_playlist("Empty")
	check_true(id != "", "empty playlist created")
	check_eq(s.playlist_tracks(id), [], "empty tracks stay empty")
	check_true(s.playlist_name_taken("Empty"), "empty playlist still owns its name")
	check_false(s.rename_playlist(id, "   "), "blank rename rejected")


func test_playlist_malformed_records_sanitized() -> void:
	var payload := {
		"version": 4,
		"audio": {"music_playlists": [
			"junk",
			{"name": "Alpha", "tracks": ["a.ogg", "a.ogg", 7, "", "b.ogg"]},
			{"id": "shared", "name": "Beta"},
			{"id": "shared", "tracks": "not an array"},
			{"tracks": ["c.ogg"]},
		]},
	}
	var f := FileAccess.open(PATH, FileAccess.WRITE)
	f.store_string(JSON.stringify(payload))
	f.close()
	var s := SettingsClass.new()
	check_true(s.load(PATH), "payload applies")
	check_eq(s.music_playlists.size(), 4, "junk record dropped, four survive")
	var alpha := s.find_playlist("playlist-1")
	check_eq(alpha["name"], "Alpha", "first record keeps its id")
	check_eq(alpha["tracks"], ["a.ogg", "b.ogg"], "duplicate/non-string tracks dropped in order")
	var beta := s.find_playlist("shared")
	check_eq(String(beta["name"]), "Beta", "existing id kept")
	check_false(s.find_playlist("playlist-1").is_empty(), "idless first record recovered with a fresh id")
	var recovered: Dictionary = s.music_playlists[3]
	check_eq(recovered["tracks"], ["c.ogg"], "duplicate-id record's tracks recovered")
	check_true(recovered["id"] != "shared", "duplicate id replaced with a fresh one")
	var names: Array = []
	var seen := {}
	var all_unique := true
	for playlist in s.music_playlists:
		var lower: String = String(playlist["name"]).to_lower()
		if seen.has(lower):
			all_unique = false
		seen[lower] = true
		names.append(lower)
	check_true(all_unique, "names unique case-insensitively")
	check_eq(names.size(), 4, "all recovered records named")


func test_playlist_naming_rules() -> void:
	var s := SettingsClass.new()
	check_eq(SettingsClass.sanitize_playlist_name("  Road  Trip \n Mix ", "fallback"), "Road Trip Mix", "trimmed, single line, collapsed whitespace")
	check_eq(SettingsClass.sanitize_playlist_name("AB".repeat(40), "fallback").length(), SettingsClass.MAX_PLAYLIST_NAME_LENGTH, "playlist names cap at 24 characters")
	check_eq(SettingsClass.sanitize_playlist_name("   ", "fallback"), "fallback", "blank names fall back")
	var id := s.create_playlist("Mix")
	check_true(id != "", "playlist created")
	check_eq(s.create_playlist("mix"), "", "duplicate name rejected case-insensitively")
	check_true(s.rename_playlist(id, "MIX"), "rename to the same (case-changed) own name succeeds")
	var other := s.create_playlist("Beta")
	check_true(other != "", "second playlist created")
	check_false(s.rename_playlist(id, "beta"), "rename rejected when it duplicates another playlist")
	check_eq(s.playlist_name_taken("MIX"), true, "taken check reads the renamed form")


func test_playlist_rename_delete_and_active_pointer() -> void:
	var s := SettingsClass.new()
	var id_a := s.create_playlist("Alpha")
	var id_b := s.create_playlist("Beta")
	check_true(id_a != "" and id_b != "", "two playlists created")
	check_true(s.set_active_playlist(id_a), "A activated")
	check_true(s.rename_playlist(id_a, "Gamma"), "rename succeeds")
	check_eq(s.playlist_name(id_a), "Gamma", "rename applied")
	check_false(s.rename_playlist(id_a, "beta"), "rename rejected when it duplicates another playlist")
	check_false(s.rename_playlist("ghost", "X"), "rename of a missing playlist fails")
	check_true(s.delete_playlist(id_a), "delete succeeds")
	check_eq(s.active_music_playlist_id, "", "deleting the active playlist clears the pointer")
	check_eq(s.music_playlists.size(), 1, "one playlist remains")
	check_true(s.set_active_playlist(id_b), "B can be activated")
	check_true(s.delete_playlist(id_b), "second delete succeeds")
	check_false(s.delete_playlist(id_b), "deleting a missing playlist fails")
	check_false(s.set_active_playlist("ghost"), "activating a missing playlist fails")


func test_playlist_ids_stable_and_unique() -> void:
	check_eq(SettingsClass.fresh_playlist_id([]), "playlist-1", "first id")
	check_eq(SettingsClass.fresh_playlist_id(["playlist-1"]), "playlist-2", "second id")
	check_eq(SettingsClass.fresh_playlist_id(["playlist-2", "playlist-3"]), "playlist-1", "gaps reused")
	var s := SettingsClass.new()
	s.create_playlist("One")
	var second := s.create_playlist("Two")
	check_eq(second, "playlist-2", "created ids follow the stable sequence")


func test_unique_playlist_name_suffixes() -> void:
	var s := SettingsClass.new()
	check_eq(s.unique_playlist_name("New Playlist"), "New Playlist", "first name is free")
	s.create_playlist("New Playlist")
	check_eq(s.unique_playlist_name("New Playlist"), "New Playlist 2", "first collision gets 2")
	s.create_playlist("New Playlist 2")
	check_eq(s.unique_playlist_name("New Playlist"), "New Playlist 3", "second collision gets 3")


func test_playlist_reset_clears_everything() -> void:
	var s := SettingsClass.new()
	var id := s.create_playlist("Gone")
	s.set_active_playlist(id)
	s.music_shuffle_source = "playlist"
	s.reset_to_defaults()
	check_eq(s.music_playlists.size(), 0, "reset clears playlists")
	check_eq(s.active_music_playlist_id, "", "reset clears the active id")
	check_eq(s.music_shuffle_source, "library", "reset restores the library shuffle source")


func test_v3_legacy_playlist_becomes_named_playlist() -> void:
	var payload := {
		"version": 3,
		"audio": {"music_playlist": ["user://music/z.wav", "user://music/a.wav", "user://music/a.wav"]},
	}
	var f := FileAccess.open(PATH, FileAccess.WRITE)
	f.store_string(JSON.stringify(payload))
	f.close()
	var s := SettingsClass.new()
	check_true(s.load(PATH), "v3 file loads through migration")
	check_eq(s.SCHEMA_VERSION, 4, "model reports v4 after migration")
	check_eq(s.music_playlists.size(), 1, "legacy playlist becomes one record")
	var playlist: Dictionary = s.music_playlists[0]
	check_eq(playlist["name"], "My Playlist", "migrated record named My Playlist")
	check_eq(playlist["tracks"], ["user://music/z.wav", "user://music/a.wav"], "legacy order preserved, duplicates dropped")
	check_eq(s.active_music_playlist_id, playlist["id"], "migrated playlist active")
	check_true(s.save(PATH), "save succeeds")
	var raw := FileAccess.open(PATH, FileAccess.READ).get_as_text()
	var saved: Dictionary = JSON.parse_string(raw)
	check_false((saved["audio"] as Dictionary).has("music_playlist"), "legacy flat array never re-serialized")
	check_true((saved["audio"] as Dictionary).has("music_playlists"), "named playlists serialized")
	var reloaded := SettingsClass.new()
	check_true(reloaded.load(PATH), "migrated file reloads as v4")


func test_v3_legacy_empty_playlist_starts_with_none() -> void:
	var payload := {"version": 3, "audio": {"music_playlist": []}}
	var f := FileAccess.open(PATH, FileAccess.WRITE)
	f.store_string(JSON.stringify(payload))
	f.close()
	var s := SettingsClass.new()
	check_true(s.load(PATH), "v3 file loads")
	check_eq(s.music_playlists.size(), 0, "empty legacy playlist starts with no playlists")
	check_eq(s.active_music_playlist_id, "", "no active playlist")


func test_v1_and_v2_legacy_playlists_migrate() -> void:
	var v1 := {
		"version": 1,
		"display": {"fullscreen": true},
		"audio": {"music_playlist": ["user://music/one.ogg", "user://music/two.ogg"]},
	}
	var f := FileAccess.open(PATH, FileAccess.WRITE)
	f.store_string(JSON.stringify(v1))
	f.close()
	var s := SettingsClass.new()
	check_true(s.load(PATH), "v1 file loads through migration")
	check_eq(s.music_playlists.size(), 1, "v1 legacy playlist becomes one record")
	check_eq(s.music_playlists[0]["tracks"], ["user://music/one.ogg", "user://music/two.ogg"], "v1 track order preserved")
	check_eq(s.active_music_playlist_id, s.music_playlists[0]["id"], "v1 migrated playlist active")
	var v2 := {
		"version": 2,
		"audio": {"music_playlist": ["user://music/three.mp3"]},
	}
	f = FileAccess.open(PATH, FileAccess.WRITE)
	f.store_string(JSON.stringify(v2))
	f.close()
	var s2 := SettingsClass.new()
	check_true(s2.load(PATH), "v2 file loads through migration")
	check_eq(s2.music_playlists[0]["tracks"], ["user://music/three.mp3"], "v2 legacy playlist migrated")
	check_eq(s2.active_music_playlist_id, s2.music_playlists[0]["id"], "v2 migrated playlist active")


func test_hybrid_file_prefers_named_playlists() -> void:
	# A file carrying both shapes (never written by real versions) prefers
	# the modern records and never merges the legacy array in.
	var payload := {
		"version": 4,
		"audio": {
			"music_playlists": [{"id": "p1", "name": "Modern", "tracks": ["a.ogg"]}],
			"music_playlist": ["legacy.ogg"],
		},
	}
	var f := FileAccess.open(PATH, FileAccess.WRITE)
	f.store_string(JSON.stringify(payload))
	f.close()
	var s := SettingsClass.new()
	check_true(s.load(PATH), "payload applies")
	check_eq(s.music_playlists.size(), 1, "modern records win")
	check_eq(s.music_playlists[0]["tracks"], ["a.ogg"], "legacy array ignored")


# -------------------------------------------------------- competitive records

func test_solo_tower_orders_height_asc_then_score_desc() -> void:
	var s := SettingsClass.new()
	var id := s.active_profile_id
	var key := "solo_tower"
	# The tower descriptor wins over the caller boolean: the ranking is
	# height ascending, then score descending, then insertion order.
	check_eq(s.append_result(id, key, _tower_record(5, 400, 1, key), true), 1, "first tower result")
	check_eq(s.append_result(id, key, _tower_record(3, 100, 2, key), true), 1, "lower height takes the top")
	check_eq(s.append_result(id, key, _tower_record(5, 900, 3, key), true), 2, "equal height falls back to score")
	check_eq(s.append_result(id, key, _tower_record(7, 5000, 4, key), true), 4, "taller stacks rank below")
	var history: Array = s.profile_history(id, key)
	check_eq(
		[[history[0]["height"], history[0]["score"]], [history[1]["height"], history[1]["score"]], [history[2]["height"], history[2]["score"]]],
		[[3, 100], [5, 900], [5, 400]],
		"height then score order"
	)
	check_eq(history[0]["mode"], key, "mode key stored")


func test_tower_history_survives_save_load_and_trims() -> void:
	var s := SettingsClass.new()
	var id := s.active_profile_id
	for i in 7:
		s.append_result(id, "solo_tower", _tower_record(10 - i, 100 * i, i, "solo_tower"), true)
	check_true(s.save(PATH), "save succeeds")
	var loaded := SettingsClass.new()
	check_true(loaded.load(PATH), "load succeeds")
	var history: Array = loaded.profile_history(id, "solo_tower")
	check_eq(history.size(), SettingsClass.MAX_RESULTS_PER_MODE, "trimmed to the best five")
	check_eq(history[0]["height"], 4, "lowest height ranks first after the round trip")
	for record in history:
		check_true(record.has("height"), "height field retained through sanitize")


func test_match_history_records_and_bounds() -> void:
	var s := SettingsClass.new()
	var id := s.active_profile_id
	check_true(s.append_match_result(id, {
		"mode": "classic_versus", "placement": 1, "won": true, "draw": false,
		"score": 3200, "height": 0, "duration": 95.0, "players": 2,
		"garbage": true, "completed_at": 17,
	}), "valid versus record stored")
	check_true(s.append_match_result(id, {
		"mode": "tower", "placement": 0, "draw": true, "score": 500,
		"height": 9, "duration": 180.0, "players": 2,
		"garbage": false, "completed_at": 18,
	}), "drawn tower record stored")
	var history: Array = s.profile_match_history(id)
	check_eq(history.size(), 2, "both records kept")
	check_eq(history[0]["mode"], "tower", "newest first")
	check_eq(history[0]["draw"], true, "draw flag stored")
	check_eq(history[0]["placement"], 0, "draws carry placement zero")
	check_eq(history[1]["won"], true, "win flag stored")
	check_eq(history[1]["garbage"], true, "garbage setting stored")
	# Bounded and sanitized.
	for i in 12:
		s.append_match_result(id, {
			"mode": "classic_versus", "placement": 2, "score": i,
			"height": 0, "duration": 60.0, "players": 2, "completed_at": 20 + i,
		})
	history = s.profile_match_history(id)
	check_eq(history.size(), SettingsClass.MAX_MATCH_HISTORY, "match history bounded")
	check_eq(history[0]["completed_at"], 31, "newest record first")
	check_eq(history[0]["placement"], 2, "placement retained")
	check_false(history[0]["won"], "second place is not a win")


func test_match_history_rejects_and_survives_round_trip() -> void:
	var s := SettingsClass.new()
	var id := s.active_profile_id
	check_false(s.append_match_result(id, {"mode": "solo_marathon", "score": 1, "height": 0, "duration": 1.0, "players": 1}), "non-competitive mode keys rejected")
	check_false(s.append_match_result(id, {"mode": "tower", "score": -1, "height": 0, "duration": 1.0, "players": 2}), "negative score rejected")
	check_false(s.append_match_result(id, {"mode": "tower", "score": 1, "height": -2, "duration": 1.0, "players": 2}), "negative height rejected")
	check_false(s.append_match_result("ghost", {"mode": "tower", "score": 1, "height": 1, "duration": 1.0, "players": 2}), "missing profile rejected")
	check_eq(s.profile_match_history(id), [], "rejected records never stored")
	# Additive persistence: files without the field load empty; records
	# survive the round trip.
	check_true(s.save(PATH), "save succeeds")
	var loaded := SettingsClass.new()
	check_true(loaded.load(PATH), "load succeeds")
	check_eq(loaded.profile_match_history(id), [], "no match history in the file loads empty")
	s.append_match_result(id, {"mode": "classic_versus", "placement": 3, "score": 50, "height": 0, "duration": 44.0, "players": 4, "garbage": false, "completed_at": 5})
	check_true(s.save(PATH), "save succeeds with matches")
	loaded = SettingsClass.new()
	loaded.load(PATH)
	var history: Array = loaded.profile_match_history(id)
	check_eq(history.size(), 1, "match record survives the round trip")
	if history.size() == 1:
		check_eq(history[0]["mode"], "classic_versus", "mode retained")
		check_eq(history[0]["players"], 4, "player count retained")
		check_eq(history[0]["garbage"], false, "garbage flag retained")


func _tower_record(height: int, score: int, completed: int, key: String) -> Dictionary:
	return {
		"score": score,
		"elapsed": 180.0,
		"completed_at": completed,
		"players": 1,
		"mode": key,
		"height": height,
	}
