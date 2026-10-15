extends "res://tests/test_lib.gd"
## Audio tests: settings music fields, manager library scanning and
## sanitization, playback modes (single/playlist/shuffle), preview, pause,
## SFX no-op/pool behavior, and host wiring for gameplay and menu sounds.
## Playback checks are structural (current track, playing state) so they
## work under the headless dummy audio driver.

const SettingsClass = preload("res://scripts/persistence/settings.gd")
const DefaultBindings = preload("res://scripts/input/default_bindings.gd")
const AudioManagerScript = preload("res://scripts/audio/audio_manager.gd")
const CoreGame = preload("res://scripts/core/game.gd")
const CoopGame = preload("res://scripts/core/coop_game.gd")
const ModeRules = preload("res://scripts/core/mode_rules.gd")
const Scoring = preload("res://scripts/core/scoring.gd")
const TetrominoData = preload("res://scripts/core/tetromino_data.gd")

const TEST_DIR := "user://test_audio_music"
const TEST_BUILTIN_DIR := "user://test_audio_builtin"
const TEST_PORTABLE_DIR := "user://test_audio_portable"
const TEST_SFX_DIR := "user://test_audio_sfx"
const TEST_PORTABLE_SFX_DIR := "user://test_audio_portable_sfx"
const TEST_CACHE := "user://test_audio_normalization.json"
const SETTINGS_PATH := "user://settings.json"

const K = TetrominoData.Kind

var _managers: Array = []
var _host: Node = null
var _settings_backup: PackedByteArray = PackedByteArray()
var _settings_existed: bool = false


func setup() -> void:
	_clean_test_dir()
	_clean_test_cache()
	_backup_settings()


func teardown() -> void:
	for manager in _managers:
		manager.free()
	_managers = []
	if _host != null:
		_host.free()
		_host = null
	_restore_settings()
	_clean_test_dir()
	_clean_test_cache()


# ------------------------------------------------------------------ helpers

func _clean_test_dir() -> void:
	for path in [TEST_DIR, TEST_BUILTIN_DIR, TEST_PORTABLE_DIR, TEST_SFX_DIR, TEST_PORTABLE_SFX_DIR]:
		if DirAccess.dir_exists_absolute(path):
			var dir := DirAccess.open(path)
			if dir != null:
				dir.list_dir_begin()
				var file := dir.get_next()
				while not file.is_empty():
					if not dir.current_is_dir():
						dir.remove(file)
					file = dir.get_next()
				dir.list_dir_end()
				DirAccess.remove_absolute(path)


func _clean_test_cache() -> void:
	for path in [TEST_CACHE, TEST_CACHE + ".tmp"]:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)


func _backup_settings() -> void:
	# Host music commands persist settings immediately; keep the real file
	# untouched across the suite.
	_settings_existed = FileAccess.file_exists(SETTINGS_PATH)
	if _settings_existed:
		var f := FileAccess.open(SETTINGS_PATH, FileAccess.READ)
		_settings_backup = f.get_buffer(f.get_length())
		f.close()


func _restore_settings() -> void:
	if _settings_existed:
		var f := FileAccess.open(SETTINGS_PATH, FileAccess.WRITE)
		f.store_buffer(_settings_backup)
		f.close()
	elif FileAccess.file_exists(SETTINGS_PATH):
		DirAccess.remove_absolute(SETTINGS_PATH)


func _make_host() -> Node:
	var scene: PackedScene = load("res://scenes/main.tscn")
	var host: Node = scene.instantiate()
	tree.root.add_child(host)
	host.settings = SettingsClass.new()
	if host._hud == null:
		# Deferred-_ready flow: drive the host's setup manually.
		host._build_scene()
		host._hud._ready()
		host._menu._ready()
		host._coop_setup._ready()
		host._pause_menu._ready()
		host._settings_screen._ready()
		host._profile_screen._ready()
		host._osk._ready()
	else:
		# Live tree: add_child already ran the real _ready against the
		# persisted settings file. The audio manager takes the settings
		# object per call, so swapping the fresh one in and re-applying
		# is enough to isolate every test.
		host._apply_display_settings()
		DefaultBindings.apply_keyboard_profile(host.settings.active_keyboard_bindings())
	# Isolate the library from repo assets and the user's music folder so
	# library-dependent assertions stay deterministic. The normalization
	# cache is redirected the same way so analysis never reads or writes
	# the user's cache file.
	host._audio.normalization_cache_path = TEST_CACHE
	host._audio._norm_cache = {}
	host._audio.builtin_music_dir = ""
	host._audio.music_dir = ""
	host._audio.rescan_library(host.settings)
	host._show_main_menu()
	return host


func _fresh_host() -> Node:
	# The runner calls setup() once per suite, so every host test starts by
	# rebuilding an isolated host.
	if _host != null:
		_host.free()
	_host = _make_host()
	return _host


## Host flow helpers: solo games start through the profile picker, coop
## runs need per-player profile assignments.
func _start_host_solo(mode: int) -> void:
	_host.cmd_solo_profile_selected(_host.settings.active_profile_id, mode)


func _start_host_coop(count: int, mode: int) -> void:
	var assignments: Array = []
	for i in count:
		var id: String = _host.settings.create_profile("AudioCoop%d" % i)
		assignments.append({"profile_id": id, "device": -1})
	_host.cmd_start_coop(assignments, mode)


func _seed_host_library(count: int) -> void:
	# Point the current host's manager at a freshly seeded sandbox library.
	_seed_library(count)
	_host._audio.music_dir = TEST_DIR
	_host._audio.rescan_library(_host.settings)


func _make_manager(settings = null) -> Node:
	var manager: Node = AudioManagerScript.new()
	manager.music_dir = TEST_DIR
	manager.builtin_music_dir = ""
	manager.normalization_cache_path = TEST_CACHE
	tree.root.add_child(manager)
	_managers.append(manager)
	if settings == null:
		settings = SettingsClass.new()
	manager.initialize(settings)
	return manager


func _seed_library(count: int) -> void:
	# Deterministic set: a.wav, b.wav, c.wav in a freshly cleaned sandbox.
	_clean_test_dir()
	DirAccess.make_dir_recursive_absolute(TEST_DIR)
	for i in count:
		var letter: String = char(ord("a") + i)
		_write_wav(TEST_DIR + "/" + letter + ".wav")


func _write_wav(path: String, amplitude: float = 12000.0, seconds: float = 0.05, stereo: bool = false, sample_rate: int = 8000) -> void:
	var samples := int(sample_rate * seconds)  # a 220 Hz tone
	var channels := 2 if stereo else 1
	var bytes_per_frame := channels * 2
	var data := PackedByteArray()
	data.resize(samples * bytes_per_frame)
	for i in samples:
		var value := int(amplitude * sin(TAU * 220.0 * i / sample_rate))
		for c in channels:
			data.encode_s16(i * bytes_per_frame + c * 2, value)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("test wav write failed: %s (err %d)" % [path, FileAccess.get_open_error()])
		return
	f.store_buffer("RIFF".to_ascii_buffer())
	_store_u32(f, 36 + data.size())
	f.store_buffer("WAVE".to_ascii_buffer())
	f.store_buffer("fmt ".to_ascii_buffer())
	_store_u32(f, 16)
	_store_u16(f, 1)
	_store_u16(f, channels)
	_store_u32(f, sample_rate)
	_store_u32(f, sample_rate * bytes_per_frame)
	_store_u16(f, bytes_per_frame)
	_store_u16(f, 16)
	f.store_buffer("data".to_ascii_buffer())
	_store_u32(f, data.size())
	f.store_buffer(data)
	f.close()


static func _store_u16(f: FileAccess, value: int) -> void:
	var bytes := PackedByteArray()
	bytes.resize(2)
	bytes.encode_u16(0, value)
	f.store_buffer(bytes)


static func _store_u32(f: FileAccess, value: int) -> void:
	var bytes := PackedByteArray()
	bytes.resize(4)
	bytes.encode_u32(0, value)
	f.store_buffer(bytes)


func _request_count(node, name: String) -> int:
	return int(node.sfx_requests.get(name, 0))


static func _feq(a: float, b: float, tol: float = 0.01) -> bool:
	# Float equality with an explicit tolerance (global is_equal_approx
	# has no tolerance argument).
	return absf(a - b) <= tol


# ------------------------------------------------------- settings persistence

func test_settings_music_defaults() -> void:
	var s := SettingsClass.new()
	check_eq(s.music_mode, "single", "default music mode is single")
	check_eq(s.music_track, "", "default selected track is empty")
	check_eq(s.music_playlist.size(), 0, "default playlist is empty")


func test_settings_music_roundtrip() -> void:
	var s := SettingsClass.new()
	s.music_mode = "shuffle"
	s.music_track = "user://music/x.ogg"
	s.music_playlist = ["user://music/x.ogg", "user://music/y.wav"]
	check_true(s.save("user://test_audio_settings.json"), "save succeeds")
	var loaded := SettingsClass.new()
	check_true(loaded.load("user://test_audio_settings.json"), "load succeeds")
	check_eq(loaded.music_mode, "shuffle", "music mode round trips")
	check_eq(loaded.music_track, "user://music/x.ogg", "selected track round trips")
	check_eq(JSON.stringify(loaded.music_playlist), JSON.stringify(["user://music/x.ogg", "user://music/y.wav"]), "playlist order round trips")
	DirAccess.remove_absolute("user://test_audio_settings.json")


func test_settings_music_invalid_fields_discarded() -> void:
	var s := SettingsClass.new()
	check_true(
		s._apply_dict(
			{
				"version": 1,
				"audio": {
					"master_volume": 0.5,
					"music_mode": "loud",
					"music_track": 42,
					"music_playlist": [7, "user://music/x.ogg", "user://music/x.ogg", "", {"a": 1}],
				},
			}
		),
		"payload applies"
	)
	check_eq(s.master_volume, 0.5, "unrelated audio fields still load")
	check_eq(s.music_mode, "single", "invalid mode falls back to default")
	check_eq(s.music_track, "", "non-string track discarded")
	check_eq(JSON.stringify(s.music_playlist), JSON.stringify(["user://music/x.ogg"]), "playlist keeps unique strings only")


func test_settings_music_absent_keeps_defaults() -> void:
	# Older settings files without music fields must keep loading (the
	# additive-field migration path).
	var s := SettingsClass.new()
	check_true(s._apply_dict({"version": 1, "audio": {"music_volume": 0.4}}), "v1 payload applies")
	check_eq(s.music_volume, 0.4, "known audio field loads")
	check_eq(s.music_mode, "single", "missing music fields keep defaults")
	check_eq(s.music_playlist.size(), 0, "missing playlist keeps default")


# --------------------------------------------------------------- bus setup

func test_buses_created_and_idempotent() -> void:
	_make_manager()
	check(AudioServer.get_bus_index("Master") >= 0, "master bus exists")
	check(AudioServer.get_bus_index("Music") >= 0, "music bus created")
	check(AudioServer.get_bus_index("SFX") >= 0, "sfx bus created")
	var bus_count: int = AudioServer.bus_count
	_make_manager()
	check_eq(AudioServer.bus_count, bus_count, "second manager adds no duplicate buses")
	check_eq(AudioServer.get_bus_name(AudioServer.get_bus_index("Music")), "Music", "music bus reused")


func test_volumes_applied_to_buses() -> void:
	var manager := _make_manager()
	var settings := SettingsClass.new()
	settings.master_volume = 0.5
	settings.music_volume = 0.25
	settings.sfx_volume = 1.0
	manager.apply_volumes(settings)
	var music_index: int = AudioServer.get_bus_index("Music")
	check(is_equal_approx(AudioServer.get_bus_volume_db(music_index), linear_to_db(0.25)), "music bus volume follows settings")
	var sfx_index: int = AudioServer.get_bus_index("SFX")
	check(is_equal_approx(AudioServer.get_bus_volume_db(sfx_index), linear_to_db(1.0)), "sfx bus volume follows settings")
	settings.music_volume = 0.0
	manager.apply_volumes(settings)
	check(AudioServer.get_bus_volume_db(music_index) <= -80.0, "zero music volume silences the bus")


# ------------------------------------------------------------ library scan

func test_scan_finds_valid_and_skips_unloadable() -> void:
	_clean_test_dir()
	DirAccess.make_dir_recursive_absolute(TEST_DIR)
	_write_wav(TEST_DIR + "/song.wav")
	var f := FileAccess.open(TEST_DIR + "/broken.wav", FileAccess.WRITE)
	f.store_string("this is not audio data")
	f.close()
	f = FileAccess.open(TEST_DIR + "/notes.txt", FileAccess.WRITE)
	f.store_string("not music")
	f.close()
	var manager := _make_manager()
	check_eq(manager.track_count(), 1, "only the loadable file becomes a track")
	check_eq(manager.track_ids(), [TEST_DIR + "/song.wav"], "track id is the file path")
	check_eq(manager.track_title(TEST_DIR + "/song.wav"), "song", "custom track title is the filename")
	check_eq(manager.skipped_files(), [TEST_DIR + "/broken.wav"], "unloadable supported file is reported")
	check_eq(manager.skipped_files().size(), 1, "unsupported extensions are not attempted")


func test_scan_builtin_dir_is_safe() -> void:
	# Keep the real built-in directory enabled: whatever ships in the repo
	# must be loadable, titled, and never include non-audio files like the
	# README; an empty directory stays safe too.
	var manager: Node = AudioManagerScript.new()
	manager.music_dir = TEST_DIR
	manager.builtin_music_dir = "res://audio/music"
	manager.normalization_cache_path = TEST_CACHE
	tree.root.add_child(manager)
	_managers.append(manager)
	manager.initialize(SettingsClass.new())
	var builtin_count := 0
	for track_id in manager.track_ids():
		var id := String(track_id)
		if not id.begins_with("res://audio/music/"):
			continue
		builtin_count += 1
		check(["ogg", "mp3", "wav"].has(id.get_extension()), "built-in track is an audio file: " + id)
		check_false(id.ends_with(".md"), "documentation never becomes a track")
		check(manager.track_title(id) != "", "built-in track has a title: " + id)
	# Repo assets must load; user-dropped files that fail are skipped and
	# reported, never phantom tracks.
	check(manager.track_ids().has("res://audio/music/placeholder_loop.wav"), "shipped placeholder loop is in the library")
	check_false(manager.skipped_files().has("res://audio/music/placeholder_loop.wav"), "shipped placeholder loop loads")


func test_rescan_picks_up_new_files() -> void:
	_clean_test_dir()
	var manager := _make_manager()
	check_eq(manager.track_count(), 0, "sandbox starts empty")
	_seed_library(2)
	var settings := SettingsClass.new()
	manager.rescan_library(settings)
	check_eq(manager.track_count(), 2, "rescan discovers new files")
	check_eq(manager.track_ids(), [TEST_DIR + "/a.wav", TEST_DIR + "/b.wav"], "deterministic title sort order")


# ------------------------------------------- portable (loose) folder scans
# Exported builds ship music/ and sfx/ beside the executable as plain
# files: matching filenames replace packaged assets in place (kept ids),
# new files join the library, and everything stays safe when the folder is
# missing.

func test_portable_music_overrides_builtin_by_filename() -> void:
	# The sandbox "packaged" track is short; the loose copy is longer, so
	# the decoded byte count proves which file the entry streams.
	_clean_test_dir()
	DirAccess.make_dir_recursive_absolute(TEST_DIR)
	DirAccess.make_dir_recursive_absolute(TEST_PORTABLE_DIR)
	_write_wav(TEST_DIR + "/a.wav", 12000.0, 0.05)
	_write_wav(TEST_PORTABLE_DIR + "/a.wav", 9000.0, 0.3)
	var manager := _make_manager()
	manager.builtin_music_dir = TEST_DIR
	manager.music_dir = ""
	manager.portable_music_dir = TEST_PORTABLE_DIR
	manager.scan_library()
	var builtin_id := TEST_DIR + "/a.wav"
	check_true(manager.has_track(builtin_id), "override keeps the packaged track id")
	check_eq(manager.track_count(), 1, "override creates no duplicate track")
	var stream: AudioStreamWAV = manager._library[builtin_id]["stream"]
	check_eq(stream.data.size(), int(8000 * 0.3) * 2, "loose file replaced the packaged stream")


func test_portable_music_new_track_is_builtin_class() -> void:
	_clean_test_dir()
	DirAccess.make_dir_recursive_absolute(TEST_PORTABLE_DIR)
	_write_wav(TEST_PORTABLE_DIR + "/extra.wav")
	var manager := _make_manager()
	manager.builtin_music_dir = ""
	manager.music_dir = ""
	manager.portable_music_dir = TEST_PORTABLE_DIR
	manager.scan_library()
	var id := "portable:extra.wav"
	check_true(manager.has_track(id), "loose-only file discovered")
	check_eq(manager.track_title(id), "extra", "filename title")
	check_eq(manager.track_ids(), [id], "loose-only track listed")
	check_true(manager._library[id]["builtin"], "loose tracks are built-in class (no normalization)")


func test_portable_music_missing_dir_is_safe() -> void:
	_clean_test_dir()
	var manager := _make_manager()
	manager.builtin_music_dir = ""
	manager.music_dir = ""
	manager.portable_music_dir = "user://test_audio_portable_missing"
	manager.scan_library()
	check_eq(manager.track_count(), 0, "missing portable dir leaves an empty library")
	check_eq(manager.skipped_files().size(), 0, "missing portable dir reports nothing")


func test_portable_sfx_overrides_by_name() -> void:
	# Same proof shape as the music override: the loose sound is longer
	# than the packaged one, and a loose-only sound becomes playable.
	_clean_test_dir()
	DirAccess.make_dir_recursive_absolute(TEST_SFX_DIR)
	DirAccess.make_dir_recursive_absolute(TEST_PORTABLE_SFX_DIR)
	_write_wav(TEST_SFX_DIR + "/move.wav", 12000.0, 0.05)
	_write_wav(TEST_PORTABLE_SFX_DIR + "/move.wav", 9000.0, 0.3)
	_write_wav(TEST_PORTABLE_SFX_DIR + "/bonus.wav")
	var manager := _make_manager()
	manager.sfx_dir = TEST_SFX_DIR
	manager.portable_sfx_dir = TEST_PORTABLE_SFX_DIR
	manager._load_sfx()
	var replaced: AudioStreamWAV = manager._sfx["move"]
	check_eq(replaced.data.size(), int(8000 * 0.3) * 2, "loose move.wav replaced the packaged sound")
	check_true(manager.has_sfx("bonus"), "loose-only sound discovered")
	check_eq(manager._sfx.size(), 2, "no other sounds leak in from the sandbox")


# ------------------------------------------------------- selection sanitize

func test_sanitize_missing_track_falls_back() -> void:
	_seed_library(2)
	var settings := SettingsClass.new()
	settings.music_track = TEST_DIR + "/gone.wav"
	_make_manager(settings)
	check_eq(settings.music_track, TEST_DIR + "/a.wav", "missing selection falls back to first valid track")


func test_sanitize_empty_library_forces_off_behavior() -> void:
	_clean_test_dir()
	var settings := SettingsClass.new()
	settings.music_mode = "single"
	settings.music_track = TEST_DIR + "/gone.wav"
	var manager := _make_manager(settings)
	check_eq(manager.track_count(), 0, "library empty")
	check_false(manager.is_music_playing(), "no music without a library")
	manager.set_music_active(true)
	check_false(manager.is_music_playing(), "empty library forces off behavior")


func test_sanitize_playlist_drops_missing_and_fills_empty() -> void:
	_seed_library(3)
	var settings := SettingsClass.new()
	settings.music_mode = "playlist"
	settings.music_playlist = [TEST_DIR + "/b.wav", TEST_DIR + "/b.wav", TEST_DIR + "/gone.wav"]
	var manager := _make_manager(settings)
	check_eq(JSON.stringify(settings.music_playlist), JSON.stringify([TEST_DIR + "/b.wav"]), "duplicates and missing entries removed")
	settings.music_playlist = []
	manager.sanitize_selection(settings)
	check_eq(
		JSON.stringify(settings.music_playlist),
		JSON.stringify([TEST_DIR + "/a.wav", TEST_DIR + "/b.wav", TEST_DIR + "/c.wav"]),
		"empty playlist falls back to the full sorted library"
	)


# ------------------------------------------------------------- music modes

func test_mode_off_stays_silent() -> void:
	_seed_library(2)
	var settings := SettingsClass.new()
	settings.music_mode = "off"
	var manager := _make_manager(settings)
	manager.set_music_active(true)
	check_false(manager.is_music_playing(), "off mode never plays")


func test_single_mode_plays_and_loops_selected_track() -> void:
	_seed_library(2)
	var settings := SettingsClass.new()
	settings.music_mode = "single"
	settings.music_track = TEST_DIR + "/b.wav"
	var manager := _make_manager(settings)
	manager.set_music_active(true)
	check_true(manager.is_music_playing(), "single mode plays")
	check_eq(manager.current_track_id(), TEST_DIR + "/b.wav", "selected track plays")
	manager._on_music_finished()
	check_eq(manager.current_track_id(), TEST_DIR + "/b.wav", "single mode loops the same track")


func test_playlist_advances_and_wraps() -> void:
	_seed_library(2)
	var settings := SettingsClass.new()
	settings.music_mode = "playlist"
	settings.music_playlist = [TEST_DIR + "/b.wav", TEST_DIR + "/a.wav"]
	var manager := _make_manager(settings)
	manager.set_music_active(true)
	check_eq(manager.current_track_id(), TEST_DIR + "/b.wav", "playlist plays the first entry")
	manager._on_music_finished()
	check_eq(manager.current_track_id(), TEST_DIR + "/a.wav", "second entry follows the persisted order")
	manager._on_music_finished()
	check_eq(manager.current_track_id(), TEST_DIR + "/b.wav", "playlist wraps around")


func test_shuffle_avoids_immediate_repeat_and_is_seedable() -> void:
	_seed_library(3)
	var settings_a := SettingsClass.new()
	settings_a.music_mode = "shuffle"
	var settings_b := SettingsClass.new()
	settings_b.music_mode = "shuffle"
	var manager_a := _make_manager(settings_a)
	var manager_b := _make_manager(settings_b)
	manager_a.seed_shuffle(42)
	manager_b.seed_shuffle(42)
	var sequence_a: Array = []
	var sequence_b: Array = []
	for i in 6:
		manager_a._on_music_finished()
		sequence_a.append(manager_a.current_track_id())
		manager_b._on_music_finished()
		sequence_b.append(manager_b.current_track_id())
	check_eq(JSON.stringify(sequence_a), JSON.stringify(sequence_b), "seeded shuffle is deterministic")
	for i in range(1, sequence_a.size()):
		check(sequence_a[i] != sequence_a[i - 1], "shuffle never repeats the current track immediately")


func test_shuffle_single_track_repeats() -> void:
	_seed_library(1)
	var settings := SettingsClass.new()
	settings.music_mode = "shuffle"
	var manager := _make_manager(settings)
	manager.set_music_active(true)
	manager._on_music_finished()
	check_eq(manager.current_track_id(), TEST_DIR + "/a.wav", "single-track shuffle repeats the only track")


func test_pause_keeps_playback_paused() -> void:
	_seed_library(1)
	var settings := SettingsClass.new()
	settings.music_mode = "single"
	var manager := _make_manager(settings)
	manager.set_music_active(true)
	manager.set_music_paused(true)
	check_false(manager.is_music_playing(), "paused music is not playing")
	check(manager.is_stream_paused(), "player paused in place")
	manager.set_music_paused(false)
	check_true(manager.is_music_playing(), "unpause resumes playback")


func test_preview_auditions_and_restores() -> void:
	_seed_library(2)
	var settings := SettingsClass.new()
	settings.music_mode = "single"
	settings.music_track = TEST_DIR + "/a.wav"
	var manager := _make_manager(settings)
	manager.set_music_active(true)
	manager.preview_track(TEST_DIR + "/b.wav")
	check_true(manager.previewing(), "preview active")
	check_eq(manager.current_track_id(), TEST_DIR + "/b.wav", "preview plays the requested track")
	manager.stop_preview()
	check_false(manager.previewing(), "preview stopped")
	check_eq(manager.current_track_id(), TEST_DIR + "/a.wav", "previous track restored after preview")


func test_preview_with_mode_off_returns_to_silence() -> void:
	_seed_library(1)
	var settings := SettingsClass.new()
	settings.music_mode = "off"
	var manager := _make_manager(settings)
	manager.preview_track(TEST_DIR + "/a.wav")
	check_true(manager.previewing(), "preview works even with music off")
	manager.stop_preview()
	check_false(manager.is_music_playing(), "stopping the preview returns to silence")
	check_false(manager.previewing(), "preview state cleared")


func test_mode_change_restarts_music() -> void:
	_seed_library(2)
	var settings := SettingsClass.new()
	settings.music_mode = "single"
	settings.music_track = TEST_DIR + "/a.wav"
	var manager := _make_manager(settings)
	manager.set_music_active(true)
	settings.music_mode = "off"
	manager.apply_music_settings(settings)
	check_false(manager.is_music_playing(), "switching to off stops music")
	settings.music_mode = "single"
	settings.music_track = TEST_DIR + "/b.wav"
	manager.apply_music_settings(settings)
	check_true(manager.is_music_playing(), "switching tracks restarts music")
	check_eq(manager.current_track_id(), TEST_DIR + "/b.wav", "new selection plays")


# ----------------------------------------------------------------- sfx pool

func test_sfx_missing_asset_is_safe_noop() -> void:
	var manager := _make_manager()
	check_false(manager.has_sfx("__no_such_sound__"), "unknown names never resolve")
	manager.play_sfx("__no_such_sound__")
	check_eq(_request_count(manager, "__no_such_sound__"), 1, "requests counted for wiring checks")
	check_eq(manager.sfx_plays.size(), 0, "missing assets never play")


func test_sfx_pool_plays_overlapping_sounds() -> void:
	var manager := _make_manager()
	var tone := AudioStreamWAV.new()
	tone.format = AudioStreamWAV.FORMAT_16_BITS
	tone.mix_rate = 8000
	tone.stereo = false
	var data := PackedByteArray()
	data.resize(160)
	tone.data = data
	manager._sfx["move"] = tone
	manager._sfx["rotate"] = tone
	manager.play_sfx("move")
	manager.play_sfx("move")
	manager.play_sfx("rotate")
	check_eq(int(manager.sfx_plays.get("move", 0)), 2, "overlapping move sounds both play")
	check_eq(int(manager.sfx_plays.get("rotate", 0)), 1, "rotate sound plays")
	check_eq(manager._sfx_players.size(), 8, "pool has eight players")


# ------------------------------------------------------- host wiring: shell

func test_host_creates_audio_and_buses() -> void:
	_fresh_host()
	check(_host._audio != null, "host owns an audio manager")
	check(AudioServer.get_bus_index("Music") >= 0, "music bus present")
	check(AudioServer.get_bus_index("SFX") >= 0, "sfx bus present")
	check_eq(_host.audio_music_dir_hint(), ProjectSettings.globalize_path("user://music"), "settings shows the music folder path")


func test_host_gameplay_action_sfx_fire_once() -> void:
	_fresh_host()
	_start_host_solo(ModeRules.Mode.MARATHON)
	_host.action_move(1)
	check_eq(_request_count(_host._audio, "move"), 1, "successful move requests the move sound")
	_host.action_rotate_cw()
	check_eq(_request_count(_host._audio, "rotate"), 1, "successful rotation requests the rotate sound")
	_host.action_hold()
	check_eq(_request_count(_host._audio, "hold"), 1, "successful hold requests the hold sound")
	_host.action_soft_drop(true)
	_host.action_soft_drop(true)
	check_eq(_request_count(_host._audio, "soft_drop"), 1, "soft drop sounds once per press edge")
	_host.action_soft_drop(false)
	check_eq(_request_count(_host._audio, "soft_drop"), 1, "release does not sound again")


func test_host_hard_drop_covers_lock_sound() -> void:
	_fresh_host()
	_start_host_solo(ModeRules.Mode.MARATHON)
	_host.action_hard_drop()
	check_eq(_request_count(_host._audio, "hard_drop"), 1, "hard drop requests its sound")
	check_eq(_request_count(_host._audio, "lock"), 0, "hard drop suppresses the plain lock sound")


func test_host_natural_lock_sfx() -> void:
	_fresh_host()
	_start_host_solo(ModeRules.Mode.MARATHON)
	# A shelf row with one gap: the spawned T rests on it and locks through
	# the lock delay, producing exactly one natural lock sound and no clear
	# (the gap keeps the shelf row incomplete). The frame delta is capped,
	# so drive several frames of simulation.
	fill_row_except(_host.core, 20, [9], K.J)
	_host.core.debug_spawn_piece(K.T, 3, 18, 0)
	for i in 4:
		_host._process(0.25)
	check_eq(_request_count(_host._audio, "lock"), 1, "lock delay expiry requests the lock sound")


func test_host_line_clear_sfx() -> void:
	_fresh_host()
	_start_host_solo(ModeRules.Mode.MARATHON)
	fill_row_except(_host.core, 21, [5], K.I)
	_host.core.debug_spawn_piece(K.I, 3, 18, 1)
	_host.action_hard_drop()
	check_eq(_request_count(_host._audio, "hard_drop"), 1, "clearing drop still requests the drop sound")
	check_eq(_request_count(_host._audio, "line_clear"), 1, "line clear requests the clear sound")
	check_eq(_request_count(_host._audio, "lock"), 0, "clearing lock does not add the lock sound")


func test_host_tspin_dispatches_tspin_sound() -> void:
	_fresh_host()
	_start_host_solo(ModeRules.Mode.MARATHON)
	var event := Scoring.ClearEvent.new()
	event.lines = 0
	event.tspin = Scoring.TSpinGrade.FULL
	_host._emit_lock_sounds(event, false)
	check_eq(_request_count(_host._audio, "tspin"), 1, "t-spin lock requests the t-spin sound")
	check_eq(_request_count(_host._audio, "line_clear"), 0, "zero-line t-spin plays no clear sound")


func test_host_level_up_and_game_over_sfx_edge_triggered() -> void:
	_fresh_host()
	_start_host_solo(ModeRules.Mode.MARATHON)
	_host.core.level = 3
	_host._process(0.0)
	check_eq(_request_count(_host._audio, "level_up"), 1, "level rise requests the level-up sound")
	_host.core.level = 3
	_host._process(0.0)
	check_eq(_request_count(_host._audio, "level_up"), 1, "level sound does not repeat without a rise")

	_host.core.phase = CoreGame.Phase.GAME_OVER
	_host._process(0.0)
	check_eq(_request_count(_host._audio, "game_over"), 1, "game over requests the game-over sound")
	_host._process(0.0)
	check_eq(_request_count(_host._audio, "game_over"), 1, "game-over sound fires once per run end")


func test_host_sprint_finish_sfx() -> void:
	_fresh_host()
	_start_host_solo(ModeRules.Mode.SPRINT)
	_host.core.phase = CoreGame.Phase.FINISHED
	_host._process(0.0)
	check_eq(_request_count(_host._audio, "finish"), 1, "sprint finish requests the finish sound")


func test_host_pause_sfx_and_music_pause() -> void:
	_fresh_host()
	_start_host_solo(ModeRules.Mode.MARATHON)
	_host.action_pause()
	check_eq(_request_count(_host._audio, "pause"), 1, "pausing requests the pause sound")
	check_true(_host._audio.is_host_paused(), "music paused while the run is paused")
	_host.action_pause()
	check_false(_host._audio.is_host_paused(), "music resumes with the run")
	check_eq(_request_count(_host._audio, "pause"), 1, "resuming does not replay the pause sound")


# ------------------------------------------------------- host wiring: coop

func test_host_coop_action_sfx_and_shared_events() -> void:
	_fresh_host()
	_start_host_coop(2, ModeRules.Mode.MARATHON)
	check_true(_host.action_coop_move(0, 1), "coop move succeeds")
	check_eq(_request_count(_host._audio, "move"), 1, "coop move requests the move sound")
	_host.action_coop_hold(1)
	check_eq(_request_count(_host._audio, "hold"), 1, "coop hold requests the hold sound")

	# Shared phase changes fire exactly once for the whole team.
	_host.coop.phase = CoopGame.Phase.GAME_OVER
	_host._process(0.0)
	check_eq(_request_count(_host._audio, "game_over"), 1, "coop game over sounds once")
	_host._process(0.0)
	check_eq(_request_count(_host._audio, "game_over"), 1, "coop game over does not repeat")

	_host.cmd_restart_run()
	_host.coop.level = 4
	_host._process(0.0)
	check_eq(_request_count(_host._audio, "level_up"), 1, "shared level rise sounds once for the team")
	_host.coop.level = 4
	_host._process(0.0)
	check_eq(_request_count(_host._audio, "level_up"), 1, "coop level sound does not repeat")


func test_host_coop_hard_drop_events_dedupe() -> void:
	_fresh_host()
	_start_host_coop(2, ModeRules.Mode.MARATHON)
	_host.action_coop_hard_drop(0)
	_host.action_coop_hard_drop(1)
	# Both drops request their own hard-drop sound; the shared lock
	# detection processes each player's event exactly once, suppressed.
	check_eq(_request_count(_host._audio, "hard_drop"), 2, "each player's drop sounds")
	check_eq(_request_count(_host._audio, "lock"), 0, "hard-drop locks suppress the plain lock sound")
	check_eq(_request_count(_host._audio, "line_clear"), 0, "no accidental clear sounds on an empty board")


func test_replicated_snapshot_lock_edges_fire_once() -> void:
	## A snapshot-rebuilt twin lock event is identified by the host's
	## revision, not the local object: applying the identical snapshot
	## repeatedly never replays a sound, only a revision advance (a new
	## host event) emits exactly one additional edge, and a hard-drop
	## snapshot lock stays silent after its optimistic drop sound.
	_fresh_host()
	_start_host_coop(2, ModeRules.Mode.MARATHON)
	# Build real host-side lock events the way the authoritative run would.
	_host.coop.hard_drop(0)
	var snap: Dictionary = _host.coop.to_snapshot()
	_host.coop.hard_drop(1)
	var advanced: Dictionary = _host.coop.to_snapshot()
	# Identical snapshot re-applied per frame: the edge fires once (silently
	# - it is a hard-drop lock), never a replay.
	for i in 5:
		_host.coop.apply_snapshot(snap)
		_host._process(0.0)
	check_eq(_request_count(_host._audio, "lock"), 0, "identical snapshots never replay the lock sound")
	check_eq(_request_count(_host._audio, "line_clear"), 0, "identical snapshots never replay clear sounds")
	check_eq(_request_count(_host._audio, "tspin"), 0, "identical snapshots never replay t-spin sounds")
	# A newer host lock (advanced revision) also stays silent: its drop
	# sound already played optimistically on the client.
	_host.coop.apply_snapshot(advanced)
	_host._process(0.0)
	check_eq(_request_count(_host._audio, "lock"), 0, "hard-drop snapshot locks stay suppressed")
	# Advancing ONLY the revision with a natural (lock-delay) lock emits
	# exactly one plain lock sound - and never a second.
	var natural: Dictionary = advanced.duplicate(true)
	var players: Array = natural["players"]
	var event_snap: Dictionary = players[1]["event"]
	event_snap["rev"] = int(event_snap["rev"]) + 1
	event_snap["hard_drop"] = false
	_host.coop.apply_snapshot(natural)
	_host._process(0.0)
	check_eq(_request_count(_host._audio, "lock"), 1, "advancing only the revision emits exactly one lock sound")
	_host.coop.apply_snapshot(natural)
	_host._process(0.0)
	check_eq(_request_count(_host._audio, "lock"), 1, "the same revision never sounds twice")


func test_replicated_level_and_end_edges_fire_once() -> void:
	## Snapshot-driven level and end edges are tracked through the twin
	## state: applying the same snapshot repeatedly never re-fires.
	_fresh_host()
	_start_host_coop(2, ModeRules.Mode.MARATHON)
	var snap: Dictionary = _host.coop.to_snapshot()
	snap = snap.duplicate(true)
	snap["level"] = 3
	_host.coop.apply_snapshot(snap)
	_host._process(0.0)
	check_eq(_request_count(_host._audio, "level_up"), 1, "level rise from a snapshot sounds once")
	for i in 4:
		_host.coop.apply_snapshot(snap)
	_host._process(0.0)
	check_eq(_request_count(_host._audio, "level_up"), 1, "identical snapshots never replay the level sound")
	var finished: Dictionary = snap.duplicate(true)
	finished["phase"] = CoopGame.Phase.FINISHED
	_host.coop.apply_snapshot(finished)
	_host._process(0.0)
	check_eq(_request_count(_host._audio, "finish"), 1, "phase end from a snapshot sounds once")
	_host.coop.apply_snapshot(finished)
	_host._process(0.0)
	check_eq(_request_count(_host._audio, "finish"), 1, "identical snapshots never replay the finish sound")


# ------------------------------------------------------ host wiring: menus

func test_host_menu_navigation_sfx() -> void:
	_fresh_host()
	_host._menu._move(1)
	check_eq(_request_count(_host._audio, "menu_move"), 1, "menu movement requests menu move sound")
	_host._menu._move(-1)
	check_eq(_request_count(_host._audio, "menu_move"), 2, "menu movement keeps requesting the move sound")
	_host._menu._activate()
	check_eq(_request_count(_host._audio, "menu_confirm"), 1, "menu accept requests confirm sound")
	_host._menu._move(1)
	_host._menu._activate()
	check_eq(_request_count(_host._audio, "menu_confirm"), 2, "solo mode accept requests confirm sound")
	check_true(_host._profile_screen.is_open(), "menu activation opens the profile picker for the selected mode")
	_host.cmd_solo_profile_selected(_host.settings.active_profile_id, ModeRules.Mode.SPRINT)
	check_eq(_host.state, _host.HostState.PLAYING, "picking a profile starts the selected mode")

	_host.action_pause()
	_host._pause_menu._move(1)
	check_eq(_request_count(_host._audio, "menu_move"), 4, "pause menu movement sounds")


func test_host_coop_setup_menu_sfx() -> void:
	_fresh_host()
	_host.cmd_open_coop_setup()
	var setup: CanvasLayer = _host._coop_setup
	setup._move(1)
	check_eq(_request_count(_host._audio, "menu_move"), 1, "lobby navigation sounds")
	setup._selected = setup.ROW_MODE
	setup._adjust(1)
	check_eq(_request_count(_host._audio, "menu_move"), 2, "lobby mode change sounds")
	setup._back()
	check_eq(_request_count(_host._audio, "menu_back"), 1, "lobby back sounds")


func test_host_settings_screen_sfx_and_music_rows() -> void:
	_fresh_host()
	_seed_host_library(3)
	var screen: CanvasLayer = _host._settings_screen
	screen.open()
	screen._mode = "audio"
	screen._rebuild()
	screen._move(1)
	check_eq(_request_count(_host._audio, "menu_move"), 1, "settings navigation sounds")

	# The scan normalized the empty selection to the first track.
	check_eq(_host.settings.music_track, TEST_DIR + "/a.wav", "empty selection falls back to the first track")

	# Find the music mode row and cycle it.
	var mode_row := -1
	for i in screen._rows.size():
		if screen._rows[i].get("kind") == "music_mode":
			mode_row = i
			break
	check(mode_row >= 0, "music mode row exists")
	screen._selected = mode_row
	screen._activate()
	check_eq(_host.settings.music_mode, "playlist", "mode row cycles to playlist")
	check_eq(screen._row_value(screen._rows[mode_row]), "Playlist", "mode row shows the current mode")

	# Cycle the track row.
	var track_row := -1
	for i in screen._rows.size():
		if screen._rows[i].get("kind") == "music_track":
			track_row = i
			break
	screen._selected = track_row
	screen._adjust(1)
	check_eq(_host.settings.music_track, TEST_DIR + "/b.wav", "track row cycles to the next track")
	screen._adjust(1)
	check_eq(_host.settings.music_track, TEST_DIR + "/c.wav", "track row cycles again")


func test_host_playlist_editor_flow() -> void:
	_fresh_host()
	_seed_host_library(3)
	var screen: CanvasLayer = _host._settings_screen
	screen.open()
	screen._mode = "audio"
	screen._rebuild()
	screen._run_command("music_editor")
	check_eq(screen._mode, "playlist", "editor opens from the audio settings category")
	check_eq(_host.settings.music_playlist.size(), 0, "playlist stays empty outside playlist mode")

	# Add two library tracks; entries keep library order.
	var added: Array = []
	for row in screen._rows:
		if row.get("kind") == "library_track" and added.size() < 2:
			added.append(row["id"])
	check_eq(added.size(), 2, "library rows exist")
	screen._add_playlist_entry(added[0])
	check_eq(JSON.stringify(_host.settings.music_playlist), JSON.stringify([added[0]]), "first add appends")
	screen._add_playlist_entry(added[1])
	check_eq(JSON.stringify(_host.settings.music_playlist), JSON.stringify([added[0], added[1]]), "second add appends")

	# Move the first entry down, then remove it.
	screen._move_playlist_entry(0, 1)
	check_eq(JSON.stringify(_host.settings.music_playlist), JSON.stringify([added[1], added[0]]), "left/right reorders entries")
	screen._remove_playlist_entry(0)
	check_eq(JSON.stringify(_host.settings.music_playlist), JSON.stringify([added[0]]), "enter removes the selected entry")

	screen._back()
	check_eq(screen._mode, "audio", "back returns to the audio settings category")


func test_host_music_mode_off_persists_and_resets() -> void:
	_fresh_host()
	_host.cmd_music_mode_changed("off")
	check_eq(_host.settings.music_mode, "off", "mode change persists to settings")
	_host.cmd_reset_all_settings()
	check_eq(_host.settings.music_mode, "single", "reset restores the default music mode")
	check_eq(_host.settings.music_playlist.size(), 0, "reset clears the playlist")


func test_host_preview_stop_on_settings_close() -> void:
	_fresh_host()
	_seed_host_library(1)
	_host.cmd_music_track_selected(TEST_DIR + "/a.wav")
	_host.cmd_music_preview()
	check_true(_host.music_previewing(), "preview starts from the settings command")
	_host._settings_screen.close()
	check_false(_host.music_previewing(), "closing settings stops the preview")


func test_host_menu_music_separate_from_gameplay() -> void:
	_fresh_host()
	_seed_host_library(3)
	var a: String = TEST_DIR + "/a.wav"
	var b: String = TEST_DIR + "/b.wav"
	_host.cmd_music_track_selected(a)
	# No menu track: the menu follows the gameplay selection.
	check_true(_host._audio.is_menu_context(), "main menu uses the menu context")
	check_eq(_host._audio.current_track_id(), a, "menu follows the gameplay track when unset")

	# Select a distinct menu track; the menu switches immediately.
	_host.cmd_menu_music_selected(b)
	check_eq(_host.settings.menu_music_track, b, "menu track persisted in settings")
	check_eq(_host._audio.current_track_id(), b, "menu plays its own track")

	# Starting a run switches to the gameplay track without touching the
	# menu selection.
	_start_host_solo(ModeRules.Mode.MARATHON)
	check_false(_host._audio.is_menu_context(), "gameplay uses the gameplay context")
	check_eq(_host._audio.current_track_id(), a, "gameplay plays the gameplay track")

	# Returning to the menu restores the menu track.
	_host.cmd_return_to_menu()
	check_eq(_host._audio.current_track_id(), b, "menu music returns with the menu")

	# Clearing the selection makes the menu follow the gameplay music again.
	_host.cmd_menu_music_selected("")
	check_eq(_host._audio.current_track_id(), a, "empty menu track follows the gameplay music")


func test_host_menu_music_changed_during_preview_restores_freshly() -> void:
	_fresh_host()
	_seed_host_library(3)
	var a: String = TEST_DIR + "/a.wav"
	_host.cmd_music_track_selected(a)
	# Audition another track from the menu context, then pick a new menu
	# track while the preview plays: stopping the preview must land on the
	# new menu track, not the stale pre-preview track.
	_host.cmd_music_preview()
	check_true(_host.music_previewing(), "preview running")
	_host.cmd_menu_music_selected(TEST_DIR + "/c.wav")
	_host.cmd_music_preview_stop()
	check_false(_host.music_previewing(), "preview stopped")
	check_eq(_host._audio.current_track_id(), TEST_DIR + "/c.wav", "fresh menu track plays after the preview, not the stale one")


func test_host_menu_music_wins_over_off_mode() -> void:
	_fresh_host()
	_seed_host_library(3)
	_host.cmd_music_mode_changed("off")
	_host.cmd_menu_music_selected(TEST_DIR + "/c.wav")
	# The main menu loops its explicit selection even in "off" gameplay mode.
	check_eq(_host._audio.current_track_id(), TEST_DIR + "/c.wav", "menu track plays despite off mode")
	check_true(_host._audio.is_music_playing(), "menu music audible")
	# Gameplay stays silent as configured.
	_start_host_solo(ModeRules.Mode.MARATHON)
	check_eq(_host._audio.current_track_id(), "", "gameplay stays silent in off mode")


func test_host_menu_music_sanitize_and_settings_row() -> void:
	_fresh_host()
	_seed_host_library(3)
	var b: String = TEST_DIR + "/b.wav"
	_host.cmd_menu_music_selected(b)

	# A rescan after the file disappears falls the selection back to
	# "follow the gameplay music" without breaking anything.
	_clean_test_dir()
	_write_wav(TEST_DIR + "/a.wav")
	_host._audio.rescan_library(_host.settings)
	check_eq(_host.settings.menu_music_track, "", "removed menu track resets to follow")

	# The settings row cycles "" -> tracks and commits immediately.
	_seed_host_library(2)
	_host._audio.rescan_library(_host.settings)
	var screen: CanvasLayer = _host._settings_screen
	screen.open()
	screen._mode = "audio"
	screen._rebuild()
	var menu_row := -1
	for i in screen._rows.size():
		if screen._rows[i].get("kind") == "menu_music_track":
			menu_row = i
			break
	check(menu_row >= 0, "menu music row exists in the audio category")
	check_eq(screen._row_value(screen._rows[menu_row]), "Follow Game Music", "empty selection shows the follow label")
	screen._selected = menu_row
	screen._adjust(1)
	check_eq(_host.settings.menu_music_track, TEST_DIR + "/a.wav", "row cycles to the first track and commits")
	screen._adjust(1)
	check_eq(_host.settings.menu_music_track, TEST_DIR + "/b.wav", "row cycles to the next track")
	screen._adjust(1)
	check_eq(_host.settings.menu_music_track, "", "row wraps back to follow")


# ----------------------------------------------------------- normalization

func test_normalization_gain_math_pure() -> void:
	# Pure gain math: reference target, conservative clamps, and
	# silence/invalid unity fallbacks.
	check_eq(AudioManagerScript.normalization_gain_from_rms(0.0), 1.0, "digital silence keeps unity gain")
	check_eq(AudioManagerScript.normalization_gain_from_rms(-1.0), 1.0, "invalid rms keeps unity gain")
	check_eq(AudioManagerScript.normalization_gain_from_rms(0.0001), 1.0, "near-silence keeps unity gain")
	check(is_equal_approx(AudioManagerScript.normalization_gain_from_rms(db_to_linear(-16.0)), 1.0), "track at the target needs no correction")
	check(is_equal_approx(AudioManagerScript.normalization_gain_from_rms(db_to_linear(-40.0)), db_to_linear(9.0)), "quiet track boost clamps at +9 dB")
	check(is_equal_approx(AudioManagerScript.normalization_gain_from_rms(db_to_linear(-2.0)), db_to_linear(-12.0)), "loud track cut clamps at -12 dB")
	check(is_equal_approx(AudioManagerScript.normalization_gain_from_rms(db_to_linear(-20.0)), db_to_linear(4.0)), "moderately quiet track gets a modest boost")
	check(is_equal_approx(AudioManagerScript.normalization_gain_from_rms(db_to_linear(-8.0)), db_to_linear(-8.0)), "loud master is cut to the target")
	check_eq(AudioManagerScript.rms_from_stats(0.0, 0), 0.0, "no samples give zero rms")
	check(_feq(AudioManagerScript.rms_from_stats(0.75, 3), 0.5, 0.0001), "rms aggregates squared samples")


func test_normalization_first_play_measures_and_applies_gain() -> void:
	# WAV first use is measured synchronously through the direct PCM path:
	# playback starts immediately with the corrected gain, and the result
	# is cached so later plays start normalized.
	_clean_test_dir()
	DirAccess.make_dir_recursive_absolute(TEST_DIR)
	_write_wav(TEST_DIR + "/loud.wav", 12000.0)
	_write_wav(TEST_DIR + "/quiet.wav", 1500.0)
	var settings := SettingsClass.new()
	settings.music_mode = "single"
	settings.music_track = TEST_DIR + "/loud.wav"
	var manager := _make_manager(settings)
	manager.set_music_active(true)
	check_true(manager.is_music_playing(), "first use plays without a gap (synchronous WAV analysis)")
	check_false(manager.is_analysis_active(), "analysis finished synchronously")
	var loud_gain := AudioManagerScript.normalization_gain_from_rms(12000.0 / 32768.0 * sqrt(0.5))
	var loud_entry: Dictionary = manager._norm_cache.get(TEST_DIR + "/loud.wav", {})
	check_true(_feq(float(loud_entry.get("gain", 0.0)), loud_gain, 0.01), "measured gain matches the RMS math")
	check(_feq(manager._music_player.volume_db, linear_to_db(loud_gain), 0.1), "player volume follows the measured gain")

	# A different source level produces a different correction.
	settings.music_track = TEST_DIR + "/quiet.wav"
	manager.apply_music_settings(settings)
	var quiet_gain := AudioManagerScript.normalization_gain_from_rms(1500.0 / 32768.0 * sqrt(0.5))
	check(_feq(manager._music_player.volume_db, linear_to_db(quiet_gain), 0.1), "quieter source gets a stronger correction")
	check_true(quiet_gain > loud_gain, "quiet track gains more than the loud track")

	# Cached results apply immediately on later plays.
	settings.music_track = TEST_DIR + "/loud.wav"
	manager.apply_music_settings(settings)
	check(_feq(manager._music_player.volume_db, linear_to_db(loud_gain), 0.1), "later plays reuse the cached gain")
	check_eq(manager._norm_cache.size(), 2, "both played tracks are cached")


func test_normalization_silent_track_falls_back_to_unity() -> void:
	_clean_test_dir()
	DirAccess.make_dir_recursive_absolute(TEST_DIR)
	_write_wav(TEST_DIR + "/silent.wav", 0.0)
	var settings := SettingsClass.new()
	settings.music_mode = "single"
	settings.music_track = TEST_DIR + "/silent.wav"
	var manager := _make_manager(settings)
	manager.set_music_active(true)
	check_true(manager.is_music_playing(), "silent track still plays")
	check_eq(manager._music_player.volume_db, 0.0, "silent track keeps unity gain")
	check_eq(float(manager._norm_cache[TEST_DIR + "/silent.wav"]["gain"]), 1.0, "unity gain cached for silence")


func test_normalization_direct_analysis_handles_formats() -> void:
	# Stereo 16-bit and mono 8-bit PCM both measure the same tone.
	_clean_test_dir()
	DirAccess.make_dir_recursive_absolute(TEST_DIR)
	_write_wav(TEST_DIR + "/stereo.wav", 12000.0, 0.05, true)
	_write_wav_8bit(TEST_DIR + "/eight.wav", 90.0)
	var settings := SettingsClass.new()
	settings.music_mode = "single"
	settings.music_track = TEST_DIR + "/stereo.wav"
	var manager := _make_manager(settings)
	manager.set_music_active(true)
	var expected := AudioManagerScript.normalization_gain_from_rms(12000.0 / 32768.0 * sqrt(0.5))
	check(
		_feq(float(manager._norm_cache[TEST_DIR + "/stereo.wav"]["gain"]), expected, 0.01),
		"stereo PCM measured like mono"
	)
	settings.music_track = TEST_DIR + "/eight.wav"
	manager.apply_music_settings(settings)
	var expected_8bit := AudioManagerScript.normalization_gain_from_rms(90.0 / 128.0 * sqrt(0.5))
	check(
		_feq(float(manager._norm_cache.get(TEST_DIR + "/eight.wav", {}).get("gain", 0.0)), expected_8bit, 0.01),
		"8-bit PCM measured through the direct path"
	)


func test_normalization_builtin_and_toggle_use_unity() -> void:
	# Built-in tracks never normalize; the toggle returns the current
	# custom track to unity and re-enabling re-applies the cached gain.
	_clean_test_dir()
	DirAccess.make_dir_recursive_absolute(TEST_DIR)
	DirAccess.make_dir_recursive_absolute(TEST_BUILTIN_DIR)
	_write_wav(TEST_BUILTIN_DIR + "/theme.wav", 12000.0)
	_write_wav(TEST_DIR + "/custom.wav", 12000.0)
	var manager: Node = AudioManagerScript.new()
	manager.music_dir = TEST_DIR
	manager.builtin_music_dir = TEST_BUILTIN_DIR
	manager.normalization_cache_path = TEST_CACHE
	tree.root.add_child(manager)
	_managers.append(manager)
	var settings := SettingsClass.new()
	settings.music_mode = "single"
	manager.initialize(settings)
	manager.set_music_active(true)
	var builtin_id := TEST_BUILTIN_DIR + "/theme.wav"
	check(manager.track_ids().has(builtin_id), "built-in sandbox track scanned")
	check_eq(manager._music_player.volume_db, 0.0, "built-in tracks play at unity gain")
	check_false(manager._norm_cache.has(builtin_id), "built-in tracks never enter the cache")

	var custom_id := TEST_DIR + "/custom.wav"
	settings.music_track = custom_id
	manager.apply_music_settings(settings)
	var gain: float = float(manager._norm_cache.get(custom_id, {}).get("gain", 1.0))
	check(gain != 1.0, "custom track measured a correction")

	settings.normalize_custom_music = false
	manager.apply_normalization_setting(settings)
	check_eq(manager._music_player.volume_db, 0.0, "disabling returns the current track to unity")
	check_false(manager.is_analysis_active(), "no analysis runs while disabled")

	settings.normalize_custom_music = true
	manager.apply_normalization_setting(settings)
	check(_feq(manager._music_player.volume_db, linear_to_db(gain), 0.01), "re-enabling re-applies the cached gain")


func test_normalization_playlist_transition_applies_gain() -> void:
	# Transitions keep existing playback semantics: no hold between
	# tracks, and each track's measured gain is applied as it starts.
	_clean_test_dir()
	DirAccess.make_dir_recursive_absolute(TEST_DIR)
	_write_wav(TEST_DIR + "/loud.wav", 12000.0)
	_write_wav(TEST_DIR + "/quiet.wav", 1500.0)
	var loud_id := TEST_DIR + "/loud.wav"
	var quiet_id := TEST_DIR + "/quiet.wav"
	var settings := SettingsClass.new()
	settings.music_mode = "playlist"
	settings.music_playlist = [loud_id, quiet_id]
	var manager := _make_manager(settings)
	manager.set_music_active(true)
	check_true(manager.is_music_playing(), "playlist starts with the first entry")
	var loud_db: float = manager._music_player.volume_db
	manager._on_music_finished()
	check_eq(manager.current_track_id(), quiet_id, "playlist advances as before")
	check_true(manager.is_music_playing(), "transition stays gapless")
	check_true(manager._music_player.volume_db > loud_db + 3.0, "quieter track is boosted relative to the loud one")
	manager._on_music_finished()
	check_eq(manager.current_track_id(), loud_id, "playlist wraps as before")
	check(_feq(manager._music_player.volume_db, loud_db, 0.01), "cached gain reused on wrap")


func test_normalization_preview_uses_same_policy_and_restores() -> void:
	_seed_library(2)
	var settings := SettingsClass.new()
	settings.music_mode = "single"
	settings.music_track = TEST_DIR + "/a.wav"
	var manager := _make_manager(settings)
	manager.set_music_active(true)
	check_true(manager.is_music_playing(), "configured playback active")
	# Uncached preview target: the preview plays right away and its
	# measurement is cached; restore still returns to the configured
	# track exactly as before.
	manager.preview_track(TEST_DIR + "/b.wav")
	check_true(manager.previewing(), "preview active")
	check_eq(manager.current_track_id(), TEST_DIR + "/b.wav", "preview plays the requested track")
	check_true(manager._norm_cache.has(TEST_DIR + "/b.wav"), "preview measured its target")
	manager.stop_preview()
	check_false(manager.previewing(), "preview stopped")
	check_eq(manager.current_track_id(), TEST_DIR + "/a.wav", "configured track restored after preview")
	check_true(manager.is_music_playing(), "playback resumed after preview")


func test_normalization_capture_hold_and_stall_fallback() -> void:
	# Forced capture path (the one compressed formats take): a fresh start
	# holds audible playback while the silent analysis runs. When the
	# capture path cannot deliver (pumped with fake time, no real-time
	# frames), the watchdog fails safely, caches unity gain, and resumes
	# the held request - never blocking playback.
	_clean_test_dir()
	DirAccess.make_dir_recursive_absolute(TEST_DIR)
	_write_wav(TEST_DIR + "/long.wav", 12000.0, 30.0)
	var settings := SettingsClass.new()
	settings.music_mode = "single"
	settings.music_track = TEST_DIR + "/long.wav"
	var manager := _make_manager(settings)
	manager.analysis_force_capture = true
	manager.set_music_active(true)
	check_false(manager.is_music_playing(), "compressed first use holds playback during analysis")
	check_eq(manager.current_track_id(), TEST_DIR + "/long.wav", "held target is the logical current track")
	check_true(manager.is_analysis_active(), "analysis runs in flight")
	check_eq(manager._pending_hold_id, TEST_DIR + "/long.wav", "playback request pending")
	# Pump fake frames: captured audio lags wall time far past the stall
	# timeout, so the watchdog fails the analysis deterministically.
	for i in 160:
		manager._process_analysis(0.05)
	check_false(manager.is_analysis_active(), "stalled analysis finished")
	check_true(manager.is_music_playing(), "held playback resumes")
	check_eq(manager._music_player.volume_db, 0.0, "failed analysis falls back to unity gain")
	check_eq(float(manager._norm_cache[TEST_DIR + "/long.wav"]["gain"]), 1.0, "failure caches unity gain")
	check_true(manager._pending_hold_id.is_empty(), "pending request cleared")
	check(manager.normalization_status() != "", "fallback reported for the settings screen")


func test_normalization_track_switch_while_playing_starts_new_track() -> void:
	# Regression: switching to an uncached compressed track while music is
	# already playing must follow transition semantics - the new track
	# takes over immediately at unity (no hold on the old stream, no
	# pending hold), and its gain is applied when the analysis completes.
	_clean_test_dir()
	DirAccess.make_dir_recursive_absolute(TEST_DIR)
	_write_wav(TEST_DIR + "/long.wav", 12000.0, 30.0)
	_write_wav(TEST_DIR + "/other.wav", 1500.0, 30.0)
	var settings := SettingsClass.new()
	settings.music_mode = "single"
	settings.music_track = TEST_DIR + "/long.wav"
	var manager := _make_manager(settings)
	manager.analysis_force_capture = true
	manager.set_music_active(true)
	# Pump the fresh-start hold to completion (stall fallback -> unity).
	for i in 160:
		manager._process_analysis(0.05)
	check_true(manager.is_music_playing(), "first track playing after its analysis")

	settings.music_track = TEST_DIR + "/other.wav"
	manager.apply_music_settings(settings)
	check_true(manager.is_music_playing(), "music keeps playing through the switch")
	check_eq(manager.current_track_id(), TEST_DIR + "/other.wav", "selection changes the logical track")
	check(
		manager._music_player.stream == manager._library[TEST_DIR + "/other.wav"]["stream"],
		"the new track's stream takes over immediately"
	)
	check_eq(manager._music_player.volume_db, 0.0, "uncached switch plays at unity while analyzing")
	check_eq(manager._pending_hold_id, "", "no hold is created while music is playing")
	check_true(manager.is_analysis_active(), "the new track analyzes in the background")

	# Background analysis completes (stall fallback); the new track keeps
	# playing and stays current.
	for i in 160:
		manager._process_analysis(0.05)
	check_false(manager.is_analysis_active(), "background analysis finished")
	check_true(manager.is_music_playing(), "playback continues after the background analysis")
	check_eq(manager.current_track_id(), TEST_DIR + "/other.wav", "the switched track stays current")


func test_normalization_long_wav_chunks_across_frames() -> void:
	# A long WAV plays immediately (direct analysis never holds) and its
	# measured gain is applied seamlessly once the chunked walk completes.
	_clean_test_dir()
	DirAccess.make_dir_recursive_absolute(TEST_DIR)
	_write_wav(TEST_DIR + "/big.wav", 12000.0, 20.0, false, 16000)
	var settings := SettingsClass.new()
	settings.music_mode = "single"
	settings.music_track = TEST_DIR + "/big.wav"
	var manager := _make_manager(settings)
	manager.set_music_active(true)
	check_true(manager.is_music_playing(), "long WAV starts immediately at unity (no hold)")
	check_eq(manager._music_player.volume_db, 0.0, "uncached long WAV starts at unity")
	var iterations := 0
	while manager.is_analysis_active() and iterations < 1000:
		manager._process_analysis(0.016)
		iterations += 1
	check_false(manager.is_analysis_active(), "chunked analysis completes (pumps: %d)" % iterations)
	check_true(manager.is_music_playing(), "playback never interrupted by the analysis")
	var expected := AudioManagerScript.normalization_gain_from_rms(12000.0 / 32768.0 * sqrt(0.5))
	check(_feq(manager._music_player.volume_db, linear_to_db(expected), 0.1), "measured gain applied seamlessly")
	check_true(manager._norm_cache.has(TEST_DIR + "/big.wav"), "long WAV result cached")


func test_normalization_disabled_during_analysis_cancels() -> void:
	# Toggling normalization off while an analysis is pending cancels it
	# and resumes held playback at unity immediately.
	_clean_test_dir()
	DirAccess.make_dir_recursive_absolute(TEST_DIR)
	_write_wav(TEST_DIR + "/long.wav", 12000.0, 30.0)
	var settings := SettingsClass.new()
	settings.music_mode = "single"
	settings.music_track = TEST_DIR + "/long.wav"
	var manager := _make_manager(settings)
	manager.analysis_force_capture = true
	manager.set_music_active(true)
	check_true(manager.is_analysis_active(), "analysis in flight")
	check_false(manager.is_music_playing(), "playback held")
	settings.normalize_custom_music = false
	manager.apply_normalization_setting(settings)
	check_false(manager.is_analysis_active(), "disabling cancels the analysis")
	check_true(manager.is_music_playing(), "held playback resumes at unity immediately")
	check_eq(manager._music_player.volume_db, 0.0, "unity gain after cancel")
	check_true(manager._norm_cache.is_empty(), "canceled analysis caches nothing")


func test_normalization_stale_cache_invalidated() -> void:
	# Cache entries are keyed by path plus file size and modification
	# time: replaced files must re-measure, unchanged files stay cached.
	_seed_library(1)
	var manager := _make_manager()
	var id := TEST_DIR + "/a.wav"
	var stats: Dictionary = manager._file_stats(id)
	manager._norm_cache[id] = {"gain": 0.4, "size": int(stats["size"]) + 17, "mtime": int(stats["mtime"])}
	manager.rescan_library(SettingsClass.new())
	check_false(manager._norm_cache.has(id), "size-mismatched entry invalidated")
	manager._norm_cache[id] = {"gain": 0.4, "size": int(stats["size"]), "mtime": int(stats["mtime"]) + 1}
	manager.rescan_library(SettingsClass.new())
	check_false(manager._norm_cache.has(id), "mtime-mismatched entry invalidated")
	manager._norm_cache[id] = {"gain": 0.4, "size": int(stats["size"]), "mtime": int(stats["mtime"])}
	manager.rescan_library(SettingsClass.new())
	check_true(manager._norm_cache.has(id), "matching entry survives rescans")


func test_normalization_rescan_prunes_removed_tracks() -> void:
	_seed_library(2)
	var manager := _make_manager()
	var stats_a: Dictionary = manager._file_stats(TEST_DIR + "/a.wav")
	manager._norm_cache[TEST_DIR + "/a.wav"] = {"gain": 0.5, "size": int(stats_a["size"]), "mtime": int(stats_a["mtime"])}
	manager._norm_cache[TEST_DIR + "/b.wav"] = {"gain": 0.6, "size": 123, "mtime": 456}
	DirAccess.remove_absolute(TEST_DIR + "/b.wav")
	manager.rescan_library(SettingsClass.new())
	check_true(manager._norm_cache.has(TEST_DIR + "/a.wav"), "surviving track keeps its entry")
	check_false(manager._norm_cache.has(TEST_DIR + "/b.wav"), "removed track's entry pruned")
	# The prune is persisted so the cache file stays tidy.
	var f := FileAccess.open(TEST_CACHE, FileAccess.READ)
	check(f != null, "cache file written")
	if f != null:
		var parsed = JSON.parse_string(f.get_as_text())
		f.close()
		var entries: Dictionary = parsed.get("entries", {}) if parsed is Dictionary else {}
		check(entries.has(TEST_DIR + "/a.wav"), "surviving entry persisted")
		check_false(entries.has(TEST_DIR + "/b.wav"), "pruned entry not written back")


func test_normalization_cache_roundtrip_and_malformed() -> void:
	# Cache round trip plus safe recovery from every malformed shape.
	_seed_library(2)
	var manager := _make_manager()
	var stats_a: Dictionary = manager._file_stats(TEST_DIR + "/a.wav")
	var stats_b: Dictionary = manager._file_stats(TEST_DIR + "/b.wav")
	manager._norm_cache[TEST_DIR + "/a.wav"] = {"gain": 0.5, "size": int(stats_a["size"]), "mtime": int(stats_a["mtime"])}
	check_true(manager._save_normalization_cache(), "cache save succeeds")
	check_false(FileAccess.file_exists(TEST_CACHE + ".tmp"), "atomic save leaves no temp file")

	var second := _make_manager()
	check_true(second._norm_cache.has(TEST_DIR + "/a.wav"), "cache reloads across managers")
	check_eq(float(second._norm_cache[TEST_DIR + "/a.wav"]["gain"]), 0.5, "gain round trips")

	var f := FileAccess.open(TEST_CACHE, FileAccess.WRITE)
	f.store_string("{ this is not json !!!")
	f.close()
	check_eq(_make_manager()._norm_cache.size(), 0, "malformed cache ignored")

	f = FileAccess.open(TEST_CACHE, FileAccess.WRITE)
	f.store_string(JSON.stringify({"version": 1, "entries": [1, 2, 3]}))
	f.close()
	check_eq(_make_manager()._norm_cache.size(), 0, "non-dictionary entries ignored")

	f = FileAccess.open(TEST_CACHE, FileAccess.WRITE)
	f.store_string(JSON.stringify({"version": 99, "entries": {TEST_DIR + "/a.wav": {"gain": 0.5, "size": 1, "mtime": 2}}}))
	f.close()
	check_eq(_make_manager()._norm_cache.size(), 0, "wrong cache version ignored")

	f = FileAccess.open(TEST_CACHE, FileAccess.WRITE)
	f.store_string(
		JSON.stringify(
			{
				"version": 1,
				"entries": {
					TEST_DIR + "/a.wav": {"gain": "loud", "size": 1, "mtime": 2},
					TEST_DIR + "/b.wav": {"gain": 0.9, "size": int(stats_b["size"]), "mtime": int(stats_b["mtime"])},
					"garbage": {"gain": 0.9},
				},
			}
		)
	)
	f.close()
	var fourth := _make_manager()
	check_eq(fourth._norm_cache.size(), 1, "only the fully valid entry survives loading")
	check_true(fourth._norm_cache.has(TEST_DIR + "/b.wav"), "valid entry kept")


func test_normalization_never_touches_bus_or_sfx() -> void:
	# Gains live on the music player only: the Music bus keeps the user's
	# volume setting and SFX behavior is unaffected.
	_seed_library(1)
	var settings := SettingsClass.new()
	settings.music_mode = "single"
	settings.music_track = TEST_DIR + "/a.wav"
	settings.music_volume = 0.3
	var manager := _make_manager(settings)
	manager.apply_volumes(settings)
	manager.set_music_active(true)
	var music_index := AudioServer.get_bus_index("Music")
	check(_feq(AudioServer.get_bus_volume_db(music_index), linear_to_db(0.3), 0.001), "music bus keeps the user volume")
	check(manager._music_player.volume_db != 0.0, "player carries the normalization gain")
	manager.play_sfx("__no_such_sound__")
	check_eq(manager.sfx_plays.size(), 0, "normalization does not affect sfx")


func test_host_normalize_toggle_row_applies_and_persists() -> void:
	_fresh_host()
	_clean_test_dir()
	DirAccess.make_dir_recursive_absolute(TEST_DIR)
	_write_wav(TEST_DIR + "/long.wav", 12000.0, 30.0)
	_host._audio.music_dir = TEST_DIR
	_host._audio.rescan_library(_host.settings)
	# Let the first-use chunked measurement finish so the toggle's effects
	# on the playing track are observable.
	var pumps := 0
	while _host._audio.is_analysis_active() and pumps < 1000:
		_host._audio._process_analysis(0.016)
		pumps += 1
	check_false(_host._audio.is_analysis_active(), "first-use measurement completes")
	check(_host._audio._music_player.volume_db != 0.0, "measured gain applied to the playing track")

	var screen: CanvasLayer = _host._settings_screen
	screen.open()
	screen._mode = "audio"
	screen._rebuild()
	var row := -1
	for i in screen._rows.size():
		if screen._rows[i].get("kind") == "toggle" and screen._rows[i].get("field") == "normalize_custom_music":
			row = i
			break
	check(row >= 0, "normalize custom music row exists")
	check_eq(screen._row_value(screen._rows[row]), "ON", "row shows the enabled default")
	check_eq(screen._row_label(screen._rows[row]), "Normalize Custom Music", "row is labelled distinctly from rescan")
	screen._selected = row
	screen._activate()
	check_eq(_host.settings.normalize_custom_music, false, "activation flips the setting")
	check_false(_host._audio._normalize_enabled, "manager follows the toggle immediately")
	check_eq(_host._audio._music_player.volume_db, 0.0, "current track returns to unity")
	var saved := SettingsClass.new()
	check_true(saved.load(SETTINGS_PATH), "settings file readable")
	check_eq(saved.normalize_custom_music, false, "toggle persists through the settings commit path")
	screen._activate()
	check_eq(_host.settings.normalize_custom_music, true, "second activation re-enables")
	check_true(_host._audio._normalize_enabled, "manager follows the re-enable")
	check(_host._audio._music_player.volume_db != 0.0, "cached gain re-applied")


func _write_wav_8bit(path: String, amplitude: float) -> void:
	var sample_rate := 8000
	var samples := 400
	var data := PackedByteArray()
	data.resize(samples)
	for i in samples:
		data[i] = int(128.0 + amplitude * sin(TAU * 220.0 * i / sample_rate))
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer("RIFF".to_ascii_buffer())
	_store_u32(f, 36 + data.size())
	f.store_buffer("WAVE".to_ascii_buffer())
	f.store_buffer("fmt ".to_ascii_buffer())
	_store_u32(f, 16)
	_store_u16(f, 1)
	_store_u16(f, 1)
	_store_u32(f, sample_rate)
	_store_u32(f, sample_rate)
	_store_u16(f, 1)
	_store_u16(f, 8)
	f.store_buffer("data".to_ascii_buffer())
	_store_u32(f, data.size())
	f.store_buffer(data)
	f.close()
