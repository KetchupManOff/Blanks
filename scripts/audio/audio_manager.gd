extends Node
## Host-owned audio orchestration: bus setup, the music library and its four
## playback modes (Off/Single/Playlist/Shuffle), settings preview, and a
## pooled SFX player. This is the only gameplay layer allowed to touch
## AudioServer or AudioStreamPlayer nodes: the rules cores and menus stay
## scene-tree independent and request sounds through the host.
##
## The Playlist mode plays the active named playlist (settings.
## active_music_playlist_id) and Shuffle draws from either the whole library
## or that playlist (settings.music_shuffle_source); broken sources repair
## themselves to Single during selection sanitation. F1 skip advances the
## current playback through skip_current_track().
##
## Every asset lookup is a safe no-op when the file is missing: startup and
## gameplay must never depend on audio assets existing.

const SettingsClass = preload("res://scripts/persistence/settings.gd")

const BUILTIN_MUSIC_DIR := "res://audio/music"
const SFX_DIR := "res://audio/sfx"
const SUPPORTED_EXTENSIONS := ["ogg", "mp3", "wav"]
const MUSIC_MODES := SettingsClass.MUSIC_MODES
const MUSIC_SHUFFLE_SOURCES := SettingsClass.MUSIC_SHUFFLE_SOURCES
## Friendly labels for built-in tracks whose filename does not speak for
## itself. Keys are plain filenames inside res://audio/music/.
const BUILTIN_LABELS := {
	"korobeiniki.ogg": "Korobeiniki (Theme A)",
	"brides.ogg": "Bride of the Princess (Theme B)",
	"katyusha.ogg": "Katyusha (Theme C)",
	"troika.ogg": "Troika (Theme D)",
	"tancov.ogg": "Dance of the Sugar Plum Fairy (Theme E)",
	"prelude.ogg": "Prelude in C# Minor (Theme G)",
	"menu_theme.ogg": "Main Menu Theme",
}

const BUS_MASTER := "Master"
const BUS_MUSIC := "Music"
const BUS_SFX := "SFX"
const BUS_ANALYSIS := "MusicAnalysis"
const BUS_ANALYSIS_MUTE := "MusicAnalysisMute"
const SFX_POOL_SIZE := 8
const SILENT_DB := -80.0

# --- Custom music normalization -------------------------------------------
# Non-destructive perceived-loudness matching for user-provided tracks:
# gains live on the music player, source files are never rewritten, and
# built-in tracks always stay at unity gain.
const NORMALIZATION_CACHE_PATH := "user://music_normalization.json"
const NORMALIZATION_CACHE_VERSION := 1
## Reference loudness for custom tracks: an RMS approximation of the
## common streaming loudness target (-14 LUFS).
const NORMALIZATION_TARGET_DB := -16.0
## Conservative correction limits; normalization is approximate, not
## mastering. Very quiet recordings are never boosted past +9 dB and loud
## masters never cut below -12 dB.
const NORMALIZATION_MAX_BOOST_DB := 9.0
const NORMALIZATION_MAX_CUT_DB := -12.0
## Tracks at or below this RMS (about -60 dBFS) count as silent and keep
## unity gain: amplifying a noise floor is pointless.
const NORMALIZATION_SILENCE_RMS := 0.001
## Bounded first-pass analysis window (seconds of audio inspected per
## track). Longer tracks are measured over their opening, not fully.
const ANALYSIS_WINDOW_SECONDS := 15.0
## Fail the analysis when captured audio falls this far behind wall time
## (dead capture path, missing mixer) and play at unity gain instead.
const ANALYSIS_STALL_TIMEOUT := 3.0
## Absolute wall-clock cap on a single analysis pass.
const ANALYSIS_HARD_TIMEOUT := 60.0
## Capture buffer length (seconds) and per-poll frame chunk for the
## real-time analysis path.
const ANALYSIS_CAPTURE_BUFFER := 1.0
const ANALYSIS_CHUNK_FRAMES := 8192
## Direct PCM analysis walks stream data in bounded byte chunks, sampling
## every Nth frame: RMS stays stable while the one-time cost drops. Each
## pump call consumes at most one chunk, so small windows finish inside the
## call that starts them and long ones spread across frames without ever
## stalling the main thread.
const ANALYSIS_DIRECT_CHUNK_BYTES := 65536
const ANALYSIS_DIRECT_STRIDE := 4

enum MusicMode { OFF, SINGLE, PLAYLIST, SHUFFLE }

## Custom music directory; overridable so tests can point it at a sandbox.
var music_dir: String = "user://music"
## Built-in music directory; overridable so tests can isolate from repo assets.
var builtin_music_dir: String = BUILTIN_MUSIC_DIR
## Portable music folder shipped beside the executable ("open files"
## install): a filename matching a packaged track replaces that track in
## place (kept id, so persisted selections keep working); any other
## supported file joins the library as a "portable:" track. Empty while
## developing, where the res:// source is used instead.
var portable_music_dir: String = ""
## Packaged SFX folder; overridable so tests can point it at a sandbox.
var sfx_dir: String = SFX_DIR
## Portable SFX folder shipped beside the executable: a sound replaces the
## packaged one by name; new names add new playable sounds.
var portable_sfx_dir: String = ""
## Normalization cache file; overridable so tests never touch user data.
var normalization_cache_path: String = NORMALIZATION_CACHE_PATH
## Test seam: force the real-time capture path even for WAVs, so hold and
## stall-fallback behavior can be exercised without compressed fixtures.
var analysis_force_capture: bool = false

var sfx_requests: Dictionary = {}  # name -> requested count (wiring proof)
var sfx_plays: Dictionary = {}  # name -> actually played count

var _music_player: AudioStreamPlayer = null
var _sfx_players: Array[AudioStreamPlayer] = []
var _sfx_next: int = 0
var _library: Dictionary = {}  # id -> {id, title, stream, builtin}
var _library_order: Array = []  # sorted track ids
var _sfx: Dictionary = {}  # name -> AudioStream
var _skipped: Array = []  # unloadable file paths from the last scan
var _mode: int = MusicMode.OFF
var _selected_id: String = ""
## Separate main-menu music: while the menu context is active and a valid
## menu track is configured, it loops regardless of the gameplay music
## mode. Empty selection follows the normal gameplay behavior.
var _menu_context: bool = false
var _menu_track_id: String = ""
var _playlist: Array = []
var _playlist_index: int = 0
## True while Shuffle draws from the active playlist instead of the whole
## library (mirrors settings.music_shuffle_source at apply time).
var _shuffle_playlist_source: bool = false
var _shuffle_order: Array = []
var _shuffle_index: int = 0
var _rng := RandomNumberGenerator.new()
var _music_active: bool = false
var _host_paused: bool = false
var _current_played_id: String = ""
var _previewing: bool = false
var _preview_restore: Dictionary = {}

# --- Normalization state ---------------------------------------------------
# Cache is keyed by the same full path IDs the library uses; every entry
# stores the file size and modification time it was measured against so
# replaced files re-analyze.
var _normalize_enabled: bool = true
var _norm_cache: Dictionary = {}  # id -> {"gain": float, "size": int, "mtime": int}
var _pending_hold_id: String = ""
var _analysis_id: String = ""
var _analysis_status: String = ""
var _analysis_direct: bool = false
var _analysis_data: PackedByteArray = PackedByteArray()
var _analysis_pos: int = 0
var _analysis_end: int = 0
var _analysis_frame_bytes: int = 2
var _analysis_stride_bytes: int = 2
var _analysis_is_8bit: bool = false
var _analysis_sq_sum: float = 0.0
var _analysis_samples: int = 0
var _analysis_frames: int = 0
var _analysis_frame_budget: int = 0
var _analysis_wall: float = 0.0
var _analysis_mix_rate: int = 44100
var _analysis_player: AudioStreamPlayer = null
var _analysis_capture = null  # AudioEffectCapture resource on the analysis bus


# ------------------------------------------------------------- lifecycle

func initialize(settings) -> bool:
	## Buses, players, library scan, normalization cache, SFX load, volume
	## application, and music settings. Returns true when the library scan
	## had to sanitize the persisted selection (the host should re-save
	## settings then).
	_ensure_bus(BUS_MUSIC)
	_ensure_bus(BUS_SFX)
	_build_players()
	DirAccess.make_dir_recursive_absolute(music_dir)
	_load_normalization_cache()
	scan_library()
	_prune_normalization_cache()
	_load_sfx()
	var changed: bool = sanitize_selection(settings)
	apply_volumes(settings)
	apply_music_settings(settings)
	return changed


func _process(delta: float) -> void:
	_process_analysis(delta)


func _ensure_bus(bus_name: String) -> void:
	_ensure_bus_chain(bus_name, BUS_MASTER, 0.0)


func _ensure_bus_chain(bus_name: String, send_to: String, volume_db: float) -> int:
	# Idempotent: Master always exists; other buses are created on first
	# use and reused afterwards.
	var existing: int = AudioServer.get_bus_index(bus_name)
	if existing >= 0:
		return existing
	AudioServer.add_bus()
	var index: int = AudioServer.bus_count - 1
	AudioServer.set_bus_name(index, bus_name)
	AudioServer.set_bus_send(index, send_to)
	AudioServer.set_bus_volume_db(index, volume_db)
	return index


func _build_players() -> void:
	if _music_player == null:
		_music_player = AudioStreamPlayer.new()
		_music_player.bus = BUS_MUSIC
		add_child(_music_player)
		_music_player.finished.connect(_on_music_finished)
	if _sfx_players.is_empty():
		for i in SFX_POOL_SIZE:
			var player := AudioStreamPlayer.new()
			player.bus = BUS_SFX
			add_child(player)
			_sfx_players.append(player)


# ----------------------------------------------------------------- volumes

func apply_volumes(settings) -> void:
	_set_bus_volume(BUS_MASTER, settings.master_volume)
	_set_bus_volume(BUS_MUSIC, settings.music_volume)
	_set_bus_volume(BUS_SFX, settings.sfx_volume)


func _set_bus_volume(bus_name: String, linear: float) -> void:
	var index: int = AudioServer.get_bus_index(bus_name)
	if index < 0:
		return
	var value := clampf(float(linear), 0.0, 1.0)
	AudioServer.set_bus_volume_db(index, linear_to_db(value) if value > 0.0 else SILENT_DB)


# ----------------------------------------------------------------- library

func scan_library() -> void:
	_library = {}
	_skipped = []
	_scan_music_dir(builtin_music_dir, true)
	_scan_portable_music_dir()
	_scan_music_dir(music_dir, false)
	_rebuild_library_order()


func rescan_library(settings) -> bool:
	## On-demand rescan used by the settings screen. Re-sanitizes the
	## selection, restores playback according to the (possibly updated)
	## settings, and prunes stale/removed normalization cache entries (a
	## user-initiated action also tidies the cache file). Returns true when
	## settings were changed.
	scan_library()
	if _prune_normalization_cache():
		_save_normalization_cache()
	var changed: bool = sanitize_selection(settings)
	apply_music_settings(settings)
	return changed


func _scan_music_dir(dir_path: String, builtin: bool) -> void:
	if not DirAccess.dir_exists_absolute(dir_path):
		return
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var file := dir.get_next()
	while not file.is_empty():
		if not dir.current_is_dir() and SUPPORTED_EXTENSIONS.has(file.get_extension().to_lower()):
			var path := dir_path.path_join(file)
			var stream = null
			if builtin:
				stream = load(path)
			if stream == null:
				stream = _load_stream_from_disk(path)
			if stream != null and stream is AudioStream:
				var id := path
				_library[id] = {
					"id": id,
					"title": _title_for(file, builtin),
					"stream": stream,
					"builtin": builtin,
				}
			else:
				_skipped.append(path)
		file = dir.get_next()
	dir.list_dir_end()


func _load_stream_from_disk(path: String):
	# Runtime decoding for user files (and built-in files that were never
	# imported). Invalid or unsupported files return null and are skipped.
	match path.get_extension().to_lower():
		"ogg":
			return AudioStreamOggVorbis.load_from_file(path)
		"mp3":
			return AudioStreamMP3.load_from_file(path)
		"wav":
			return AudioStreamWAV.load_from_file(path)
	return null


func _scan_portable_music_dir() -> void:
	# Loose folder shipped beside the executable: files are plain
	# (never imported), so they load straight from disk. A filename
	# matching a packaged track replaces it; other files become
	# built-in-class "portable:" tracks (friendly labels, unity gain).
	if portable_music_dir.is_empty() or not DirAccess.dir_exists_absolute(portable_music_dir):
		return
	var dir := DirAccess.open(portable_music_dir)
	if dir == null:
		return
	dir.list_dir_begin()
	var file := dir.get_next()
	while not file.is_empty():
		if not dir.current_is_dir() and SUPPORTED_EXTENSIONS.has(file.get_extension().to_lower()):
			var path := portable_music_dir.path_join(file)
			var stream = _load_stream_from_disk(path)
			if stream != null and stream is AudioStream:
				var builtin_id := builtin_music_dir.path_join(file)
				if _library.has(builtin_id):
					_library[builtin_id]["stream"] = stream
				else:
					var id := "portable:" + file
					_library[id] = {
						"id": id,
						"title": _title_for(file, true),
						"stream": stream,
						"builtin": true,
					}
			else:
				_skipped.append(path)
		file = dir.get_next()
	dir.list_dir_end()


func _title_for(file: String, builtin: bool) -> String:
	if builtin:
		return String(BUILTIN_LABELS.get(file, file.get_basename()))
	return file.get_basename()


func _rebuild_library_order() -> void:
	# Deterministic order: built-in tracks first, then custom files, each
	# group sorted by title (case-insensitive).
	_library_order = []
	for id in _library:
		_library_order.append(id)
	_library_order.sort_custom(
		func(a, b):
			var entry_a: Dictionary = _library[a]
			var entry_b: Dictionary = _library[b]
			if entry_a["builtin"] != entry_b["builtin"]:
				return entry_a["builtin"]
			return String(entry_a["title"]).to_lower() < String(entry_b["title"]).to_lower()
	)


func track_ids() -> Array:
	return _library_order.duplicate()


func track_title(id: String) -> String:
	if not _library.has(id):
		return ""
	return _library[id]["title"]


func has_track(id: String) -> bool:
	return _library.has(id)


func track_count() -> int:
	return _library.size()


func skipped_files() -> Array:
	return _skipped.duplicate()


func sanitize_selection(settings) -> bool:
	## Drops persisted references to tracks that no longer exist: the
	## selected/menu tracks repair as before, and every named playlist
	## loses its missing/duplicate ids while empty playlists stay valid
	## editing targets. Ordered playback or a playlist-scoped shuffle with
	## no usable active playlist falls back to Single (library shuffle
	## source), so a deleted or emptied active list never causes silence.
	## Returns true when something changed (the host should re-save).
	var changed := false
	if not MUSIC_MODES.has(settings.music_mode):
		settings.music_mode = "single"
		changed = true
	if not _library.has(settings.music_track):
		var fallback: String = _library_order[0] if not _library_order.is_empty() else ""
		if settings.music_track != fallback:
			settings.music_track = fallback
			changed = true
	# A removed menu track falls back to "follow the gameplay music" rather
	# than blocking the menu selection.
	if not settings.menu_music_track.is_empty() and not _library.has(settings.menu_music_track):
		settings.menu_music_track = ""
		changed = true
	for playlist in settings.music_playlists:
		var cleaned := _clean_track_list(playlist["tracks"])
		if not _track_lists_equal(cleaned, playlist["tracks"]):
			playlist["tracks"] = cleaned
			changed = true
	# An active pointer at a missing playlist clears; the playback-source
	# repair below then falls the mode back to Single.
	if not settings.active_music_playlist_id.is_empty() and settings.find_playlist(settings.active_music_playlist_id).is_empty():
		settings.active_music_playlist_id = ""
		changed = true
	if not MUSIC_SHUFFLE_SOURCES.has(settings.music_shuffle_source):
		settings.music_shuffle_source = "library"
		changed = true
	var ordered_broken: bool = settings.music_mode == "playlist" and settings.active_playlist_tracks().is_empty()
	var shuffle_broken: bool = (
		settings.music_mode == "shuffle"
		and settings.music_shuffle_source == "playlist"
		and settings.active_playlist_tracks().is_empty()
	)
	if ordered_broken or shuffle_broken:
		settings.music_mode = "single"
		settings.music_shuffle_source = "library"
		changed = true
	return changed


func _clean_track_list(tracks: Array) -> Array:
	# Library-aware structural cleanup of one playlist's tracks: keeps
	# existing ids in order, dropping duplicates and missing files. Empty
	# stays empty.
	var cleaned: Array = []
	var seen := {}
	for track_id in tracks:
		if typeof(track_id) == TYPE_STRING and _library.has(track_id) and not seen.has(track_id):
			cleaned.append(track_id)
			seen[track_id] = true
	return cleaned


func _track_lists_equal(left: Array, right: Array) -> bool:
	if left.size() != right.size():
		return false
	for i in left.size():
		if left[i] != right[i]:
			return false
	return true


# ------------------------------------------------------------------- music

func apply_music_settings(settings) -> void:
	_mode = _mode_from_string(settings.music_mode)
	_selected_id = settings.music_track
	_menu_track_id = settings.menu_music_track
	_playlist = settings.active_playlist_tracks()
	_shuffle_playlist_source = _mode == MusicMode.SHUFFLE and settings.music_shuffle_source == "playlist"
	# Keep the current track playing when an edit leaves it in the list;
	# otherwise start from the first entry.
	_playlist_index = _playlist.find(_current_played_id)
	if _playlist_index < 0:
		_playlist_index = 0
	if _mode == MusicMode.SHUFFLE:
		_reshuffle(_current_played_id)
		var position: int = _shuffle_order.find(_current_played_id)
		_shuffle_index = position if position >= 0 else 0
	_set_normalization_enabled(bool(settings.normalize_custom_music))
	_update_music_playback()


func set_music_active(active: bool) -> void:
	## Host context switch: menus and runs want music, nothing else forces
	## it. Already-playing music continues seamlessly.
	_music_active = active
	_update_music_playback()


func set_music_context(is_menu: bool) -> void:
	## Host context switch between the main menu and gameplay. In the menu
	## context a configured menu track loops regardless of the gameplay
	## music mode; without one the gameplay selection keeps playing.
	if _menu_context == is_menu:
		return
	_menu_context = is_menu
	_update_music_playback()


func is_menu_context() -> bool:
	return _menu_context


func _menu_override_active() -> bool:
	# True when the menu context should loop its own track: an explicit,
	# still-existing selection. This wins over every gameplay mode,
	# including "off" (choosing menu music means wanting it in the menu).
	return _menu_context and not _menu_track_id.is_empty() and _library.has(_menu_track_id)


func set_music_paused(paused: bool) -> void:
	## Pausing keeps the playback position; resuming continues from it.
	_host_paused = paused
	if _previewing:
		return
	if _music_player.playing:
		_music_player.stream_paused = paused
	elif not paused:
		_music_player.stream_paused = false


func is_music_playing() -> bool:
	return _music_player != null and _music_player.playing and not _music_player.stream_paused


func is_host_paused() -> bool:
	return _host_paused


func is_stream_paused() -> bool:
	return _music_player != null and _music_player.stream_paused


func current_track_id() -> String:
	return _current_played_id


func playback_mode() -> String:
	## The applied gameplay music mode as a settings string.
	match _mode:
		MusicMode.SINGLE:
			return "single"
		MusicMode.PLAYLIST:
			return "playlist"
		MusicMode.SHUFFLE:
			return "shuffle"
	return "off"


func skip_current_track() -> Dictionary:
	## F1 skip: advances the current playback by one track without
	## persisting any cursor. The menu override restarts its explicit
	## track; Single restarts the selected track; ordered playback
	## advances/wraps; Shuffle progresses its (library- or playlist-scoped)
	## order. Returns {"ok": bool, "reason": ""} with reasons "preview",
	## "inactive", "off", or "no_target"; the host maps them to feedback.
	if _previewing:
		# A settings preview owns the player; the restore snapshot must
		# stay valid.
		return {"ok": false, "reason": "preview"}
	if not _music_active:
		return {"ok": false, "reason": "inactive"}
	if _menu_override_active():
		_play_track(_menu_track_id)
		return {"ok": true, "reason": ""}
	if _library.is_empty():
		return {"ok": false, "reason": "no_target"}
	match _mode:
		MusicMode.OFF:
			return {"ok": false, "reason": "off"}
		MusicMode.SINGLE:
			var target := _current_track_id()
			if target.is_empty() or not _library.has(target):
				return {"ok": false, "reason": "no_target"}
			_play_track(target)
			return {"ok": true, "reason": ""}
		MusicMode.PLAYLIST:
			if _playlist.is_empty():
				return {"ok": false, "reason": "no_target"}
			_playlist_index = wrapi(_playlist_index + 1, 0, _playlist.size())
			_play_track(String(_playlist[_playlist_index]))
			return {"ok": true, "reason": ""}
		MusicMode.SHUFFLE:
			if _shuffle_order.is_empty():
				return {"ok": false, "reason": "no_target"}
			_play_track(_next_shuffle())
			return {"ok": true, "reason": ""}
	return {"ok": false, "reason": "no_target"}


func play_playlist_first_entry() -> void:
	## Explicit "Play In Order": start the active playlist from its first
	## entry (seamlessly when it already plays it). Edits keep the current
	## track via apply_music_settings; only this explicit playback request
	## rewinds to the top. The menu override keeps precedence: an explicit
	## menu track never gets preempted by a playlist command.
	if _mode != MusicMode.PLAYLIST or _playlist.is_empty() or _menu_override_active():
		return
	_playlist_index = 0
	if _current_played_id != String(_playlist[0]):
		_play_track(String(_playlist[0]))


func previewing() -> bool:
	return _previewing


func preview_track(id: String) -> void:
	## Audition a track from the settings screen without permanently
	## changing the configured playback; stop_preview() restores whatever
	## was happening before.
	if not _library.has(id):
		return
	if not _previewing:
		_preview_restore = {
			"id": _current_played_id,
			"position": _music_player.get_playback_position(),
			"paused": _music_player.stream_paused,
		}
		_previewing = true
	_play_track(id)


func stop_preview() -> void:
	if not _previewing:
		return
	_previewing = false
	var restore: Dictionary = _preview_restore
	_preview_restore = {}
	var restore_id: String = restore.get("id", "")
	# Settings may have changed while the preview played (track, mode, or
	# menu music); the captured id is stale then, so re-resolve from the
	# current settings instead of restoring the outdated track.
	if restore_id != _current_track_id():
		_update_music_playback()
		return
	if not restore_id.is_empty() and _library.has(restore_id) and (_mode != MusicMode.OFF or _menu_override_active()) and _music_active:
		_play_track(restore_id)
		_music_player.seek(float(restore.get("position", 0.0)))
		_music_player.stream_paused = bool(restore.get("paused", false))
	else:
		_update_music_playback()


func seed_shuffle(seed_value: int) -> void:
	## Deterministic shuffle for tests; also reshuffles immediately.
	_rng.seed = seed_value
	if _mode == MusicMode.SHUFFLE:
		_reshuffle(_current_played_id)


func _update_music_playback() -> void:
	if _previewing:
		return
	if not _music_active or (_mode == MusicMode.OFF and not _menu_override_active()) or _library.is_empty():
		_stop_music()
		return
	var target := _current_track_id()
	if target.is_empty() or not _library.has(target):
		_stop_music()
		return
	if _music_player.playing and _current_played_id == target:
		return
	# Fresh starts may hold playback for a first-use loudness analysis
	# (see _play_track); track transitions never do.
	_play_track(target, true)


func _current_track_id() -> String:
	if _menu_override_active():
		return _menu_track_id
	match _mode:
		MusicMode.SINGLE:
			if _library.has(_selected_id):
				return _selected_id
			return _library_order[0] if not _library_order.is_empty() else ""
		MusicMode.PLAYLIST:
			if _playlist.is_empty():
				return ""
			return String(_playlist[clampi(_playlist_index, 0, _playlist.size() - 1)])
		MusicMode.SHUFFLE:
			if _shuffle_order.is_empty():
				return ""
			return String(_shuffle_order[clampi(_shuffle_index, 0, _shuffle_order.size() - 1)])
	return ""


func _play_track(id: String, allow_hold: bool = false) -> void:
	if not _library.has(id):
		return
	# Already holding the first-use analysis for this exact track.
	if allow_hold and _pending_hold_id == id and _analysis_id == id:
		return
	if _needs_analysis(id):
		_start_analysis(id)
		if allow_hold and _analysis_id == id and not _analysis_direct and not _music_player.playing:
			# First use of a compressed custom track from silence: analyze
			# silently before audible playback. Fresh starts only - a
			# switch while music is already playing keeps the old track
			# until the new one takes over, preserving transition semantics.
			_current_played_id = id
			_pending_hold_id = id
			return
		# Transitions, previews, and any request while music is already
		# audible keep existing playback semantics: play now at unity gain;
		# the measured gain is applied seamlessly when the analysis
		# completes. Direct (WAV) analysis never holds - it finishes within
		# a few frames at most.
	_current_played_id = id
	_pending_hold_id = ""
	_music_player.stream = _library[id]["stream"]
	_music_player.volume_db = linear_to_db(_effective_gain(id))
	_music_player.play()
	# play() (and the stream assignment above) resets stream_paused, so the
	# pause state re-applies after starting the track: normal playback
	# resumes audible, a track started while the host is paused stays
	# paused (a hold resumed mid-pause, or an F1 skip during pause).
	# Previews always stay audible.
	_music_player.stream_paused = _host_paused and not _previewing


func _stop_music() -> void:
	if _music_player == null:
		return
	_music_player.stop()
	_music_player.stream = null
	_current_played_id = ""
	_pending_hold_id = ""


func _on_music_finished() -> void:
	if _previewing:
		return
	if _menu_override_active():
		# The menu loops its own selection until the context changes.
		_play_track(_menu_track_id)
		return
	match _mode:
		MusicMode.SINGLE:
			# Loop the single selected track.
			_play_track(_current_played_id)
		MusicMode.PLAYLIST:
			if not _playlist.is_empty():
				_playlist_index = wrapi(_playlist_index + 1, 0, _playlist.size())
				_play_track(String(_playlist[_playlist_index]))
		MusicMode.SHUFFLE:
			if not _shuffle_order.is_empty():
				_play_track(_next_shuffle())


func _next_shuffle() -> String:
	_shuffle_index += 1
	if _shuffle_index >= _shuffle_order.size():
		_reshuffle(String(_shuffle_order[_shuffle_order.size() - 1]))
	return String(_shuffle_order[clampi(_shuffle_index, 0, _shuffle_order.size() - 1)])


func _reshuffle(avoid_id: String = "") -> void:
	var ids := _shuffle_pool()
	if ids.size() > 1:
		for i in range(ids.size() - 1, 0, -1):
			var j: int = _rng.randi_range(0, i)
			var swapped = ids[i]
			ids[i] = ids[j]
			ids[j] = swapped
		# Avoid an immediate repeat across the wrap when possible.
		if String(ids[0]) == avoid_id:
			var swap_index: int = _rng.randi_range(1, ids.size() - 1)
			var head = ids[0]
			ids[0] = ids[swap_index]
			ids[swap_index] = head
	_shuffle_order = ids
	_shuffle_index = 0


func _shuffle_pool() -> Array:
	# The shuffle source's ids, copied: the full library, or the active
	# playlist's tracks while a playlist-scoped shuffle is applied.
	if _shuffle_playlist_source:
		return _playlist.duplicate()
	return _library_order.duplicate()


static func _mode_from_string(mode: String) -> int:
	match mode:
		"off":
			return MusicMode.OFF
		"single":
			return MusicMode.SINGLE
		"playlist":
			return MusicMode.PLAYLIST
		"shuffle":
			return MusicMode.SHUFFLE
	return MusicMode.OFF


# ----------------------------------------------------------- normalization

func apply_normalization_setting(settings) -> void:
	## Host path for the normalization toggle: applies the flag immediately
	## and re-evaluates playback (a disabled pending hold resumes at unity;
	## stopped music stays stopped). The host persists the value itself.
	var previous := _normalize_enabled
	_set_normalization_enabled(bool(settings.normalize_custom_music))
	if previous != _normalize_enabled:
		_update_music_playback()


func is_analysis_active() -> bool:
	return not _analysis_id.is_empty()


func normalization_status() -> String:
	## Concise state for the settings screen: what is being measured, or
	## how the last failure fell back. Empty when there is nothing to say.
	if not _analysis_id.is_empty():
		return "Analyzing loudness: %s" % _title_or_file(_analysis_id)
	return _analysis_status


static func normalization_clamp_gain(gain: float) -> float:
	## Single source of truth for acceptable linear gains: the engine's
	## own conservative dB limits. Applied wherever a gain is produced,
	## loaded from the cache, or applied to playback so ranges can never
	## drift apart.
	return clampf(gain, db_to_linear(NORMALIZATION_MAX_CUT_DB), db_to_linear(NORMALIZATION_MAX_BOOST_DB))


static func normalization_gain_from_rms(rms: float) -> float:
	## Perceived-loudness gain for a measured RMS: the dB distance from the
	## reference target, clamped conservatively. Silent or invalid input
	## keeps unity gain.
	if not is_finite(rms) or rms < NORMALIZATION_SILENCE_RMS:
		return 1.0
	var gain_db: float = clampf(
		NORMALIZATION_TARGET_DB - linear_to_db(rms),
		NORMALIZATION_MAX_CUT_DB,
		NORMALIZATION_MAX_BOOST_DB
	)
	return normalization_clamp_gain(db_to_linear(gain_db))


static func rms_from_stats(sum_sq: float, samples: int) -> float:
	if samples <= 0:
		return 0.0
	return sqrt(sum_sq / float(samples))


func _title_or_file(id: String) -> String:
	var title := track_title(id)
	return title if not title.is_empty() else id.get_file()


func _set_normalization_enabled(enabled: bool) -> void:
	if enabled == _normalize_enabled:
		return
	_normalize_enabled = enabled
	if not enabled:
		# Analysis is pointless while disabled: cancel it and drop any
		# pending first-use hold (playback resumes at unity gain).
		_cancel_analysis()
		_pending_hold_id = ""
	_apply_current_track_gain()


func _apply_current_track_gain() -> void:
	## Re-evaluates the gain of whatever is currently on the music player
	## after a policy change. Built-ins always resolve to unity gain.
	if _music_player == null or not _music_player.playing:
		return
	var id := _current_played_id
	if id.is_empty() or not _library.has(id):
		return
	if _needs_analysis(id):
		# Uncached custom track while enabled: measure in the background;
		# the gain is applied seamlessly when the result arrives.
		_start_analysis(id)
		return
	_music_player.volume_db = linear_to_db(_effective_gain(id))


func _needs_analysis(id: String) -> bool:
	# Pure policy check: custom track, normalization on, no cached gain.
	if not _normalize_enabled:
		return false
	if not _library.has(id):
		return false
	if _library[id]["builtin"]:
		return false
	return not _norm_cache.has(id)


func _effective_gain(id: String) -> float:
	if not _normalize_enabled or not _library.has(id):
		return 1.0
	if _library[id]["builtin"]:
		return 1.0
	var entry: Dictionary = _norm_cache.get(id, {})
	return normalization_clamp_gain(float(entry.get("gain", 1.0)))


func _start_analysis(id: String) -> void:
	## Begins loudness analysis for an uncached custom track. WAV streams
	## with accessible PCM data are measured synchronously in bounded
	## chunks; compressed streams play through the silent capture path and
	## are pumped by _process_analysis. Only one analysis runs at a time.
	if _analysis_id == id:
		return
	if not _analysis_id.is_empty():
		_cancel_analysis()
	_analysis_id = id
	_analysis_status = ""
	_analysis_sq_sum = 0.0
	_analysis_samples = 0
	_analysis_frames = 0
	_analysis_wall = 0.0
	var stream = _library[id]["stream"]
	if not analysis_force_capture and stream is AudioStreamWAV and _setup_direct_analysis(stream):
		# Bounded chunk walk: small windows finish inside this call; long
		# ones continue under the per-frame time budget in _process_analysis.
		_pump_direct_analysis()
		return
	if not _setup_capture_analysis(stream):
		_finish_analysis(false)


func _setup_direct_analysis(stream) -> bool:
	# Offline path for decodable PCM: deterministic, instant, and
	# independent of the audio driver. Anything not plain 8/16-bit PCM
	# falls back to the capture path.
	var data: PackedByteArray = stream.data
	if data.is_empty() or stream.mix_rate <= 0:
		return false
	var sample_bytes := 0
	if stream.format == AudioStreamWAV.FORMAT_16_BITS:
		sample_bytes = 2
	elif stream.format == AudioStreamWAV.FORMAT_8_BITS:
		sample_bytes = 1
	else:
		return false
	var channels: int = 2 if stream.stereo else 1
	_analysis_frame_bytes = channels * sample_bytes
	_analysis_stride_bytes = _analysis_frame_bytes * ANALYSIS_DIRECT_STRIDE
	_analysis_is_8bit = sample_bytes == 1
	_analysis_data = data
	_analysis_pos = 0
	var window_frames := int(ANALYSIS_WINDOW_SECONDS * stream.mix_rate)
	var byte_end: int = mini(data.size(), window_frames * _analysis_frame_bytes)
	_analysis_end = byte_end - (byte_end % _analysis_frame_bytes)
	_analysis_direct = true
	return _analysis_end > 0


func _pump_direct_analysis() -> void:
	# Walks one bounded chunk per call: no decoded copy is ever allocated,
	# only the running square-sum and sample count survive. Small windows
	# finish inside the starting call; long ones continue through
	# _process_analysis, one bounded chunk per frame.
	_process_direct_chunk(ANALYSIS_DIRECT_CHUNK_BYTES)
	if _analysis_pos >= _analysis_end:
		_finish_analysis(true)


func _process_direct_chunk(limit_bytes: int) -> void:
	var data := _analysis_data
	var end: int = mini(_analysis_end, _analysis_pos + limit_bytes)
	end -= end % _analysis_frame_bytes
	var pos := _analysis_pos
	var sq := _analysis_sq_sum
	var count := _analysis_samples
	if _analysis_is_8bit:
		while pos + _analysis_frame_bytes <= end:
			for c in _analysis_frame_bytes:
				# Godot stores 8-bit PCM data as signed two's complement
				# (loader-converted from the unsigned WAV representation).
				var b := int(data[pos + c])
				var s := b - 256 if b >= 128 else b
				var v := float(s) / 128.0
				sq += v * v
				count += 1
			pos += _analysis_stride_bytes
	else:
		while pos + _analysis_frame_bytes <= end:
			for c in range(0, _analysis_frame_bytes, 2):
				var v := float(data.decode_s16(pos + c)) / 32768.0
				sq += v * v
				count += 1
			pos += _analysis_stride_bytes
	_analysis_sq_sum = sq
	_analysis_samples = count
	_analysis_pos = pos


func _setup_capture_analysis(stream) -> bool:
	# Silent real-time path for compressed streams: a private player on
	# the analysis bus whose only audible destination is a muted dead end.
	if stream == null:
		return false
	_ensure_analysis_buses()
	if _analysis_player == null:
		_analysis_player = AudioStreamPlayer.new()
		_analysis_player.bus = BUS_ANALYSIS
		add_child(_analysis_player)
	var bus_index := AudioServer.get_bus_index(BUS_ANALYSIS)
	if bus_index < 0:
		return false
	if _analysis_capture == null:
		_analysis_capture = AudioServer.get_bus_effect(bus_index, 0)
	if _analysis_capture == null or not _analysis_capture.has_method("get_frames_available"):
		return false
	_analysis_capture.clear_buffer()
	_analysis_mix_rate = maxi(1, int(AudioServer.get_mix_rate()))
	_analysis_frame_budget = int(ANALYSIS_WINDOW_SECONDS * _analysis_mix_rate)
	_analysis_player.stream = stream
	_analysis_player.volume_db = 0.0
	_analysis_player.play()
	return _analysis_player.playing


func _ensure_analysis_buses() -> void:
	# Two-bus silent chain: MusicAnalysis (0 dB + capture effect) sends to
	# MusicAnalysisMute (-80 dB) which feeds Master. The capture effect
	# sees the full signal either side of its own fader, while the mute
	# fader guarantees nothing audible reaches Master.
	_ensure_bus_chain(BUS_ANALYSIS_MUTE, BUS_MASTER, SILENT_DB)
	var index: int = _ensure_bus_chain(BUS_ANALYSIS, BUS_ANALYSIS_MUTE, 0.0)
	if AudioServer.get_bus_effect_count(index) == 0:
		var capture := AudioEffectCapture.new()
		capture.buffer_length = ANALYSIS_CAPTURE_BUFFER
		AudioServer.add_bus_effect(index, capture)


func _process_analysis(delta: float) -> void:
	## Pumps the in-flight analysis: direct PCM walks continue under the
	## chunk time budget, capture playback is polled in bounded frame
	## chunks, and a stalled capture path falls back to unity gain.
	if _analysis_id.is_empty():
		return
	if _analysis_direct:
		_pump_direct_analysis()
		return
	_analysis_wall += clampf(delta, 0.0, 0.25)
	if _analysis_capture != null:
		var available: int = _analysis_capture.get_frames_available()
		if available > 0:
			var chunk: PackedVector2Array = _analysis_capture.get_buffer(mini(available, ANALYSIS_CHUNK_FRAMES))
			if not chunk.is_empty():
				for frame in chunk:
					var l: float = frame.x
					var r: float = frame.y
					_analysis_sq_sum += l * l + r * r
				_analysis_samples += chunk.size() * 2
				_analysis_frames += chunk.size()
	if _analysis_player != null and not _analysis_player.playing:
		# Stream ended before the window: the whole track was measured.
		_finish_analysis(true)
		return
	if _analysis_frames >= _analysis_frame_budget:
		_finish_analysis(true)
		return
	var captured_sec := float(_analysis_frames) / float(_analysis_mix_rate)
	if _analysis_wall - captured_sec >= ANALYSIS_STALL_TIMEOUT or _analysis_wall >= ANALYSIS_HARD_TIMEOUT:
		_finish_analysis(false)


func _finish_analysis(success: bool) -> void:
	## Completes or fails the in-flight analysis: derives the (unity) gain,
	## caches and persists valid results, applies the gain to a live
	## playback of the same track, and resumes a held first-play request.
	var id := _analysis_id
	var gain: float = 1.0
	if success:
		gain = normalization_gain_from_rms(rms_from_stats(_analysis_sq_sum, _analysis_samples))
	_teardown_analysis_playback()
	_analysis_id = ""
	if id.is_empty():
		return
	if not success:
		_analysis_status = "Normalization unavailable: %s plays at original volume" % _title_or_file(id)
	var stats := _file_stats(id)
	if not stats.is_empty():
		_norm_cache[id] = {"gain": gain, "size": int(stats["size"]), "mtime": int(stats["mtime"])}
		_save_normalization_cache()
	if id == _current_played_id and _music_player != null and _music_player.playing:
		_music_player.volume_db = linear_to_db(_effective_gain(id))
	if id == _pending_hold_id:
		_pending_hold_id = ""
		if not _previewing:
			_update_music_playback()


func _cancel_analysis() -> void:
	## Aborts the in-flight analysis without caching partial results.
	if _analysis_id.is_empty():
		return
	_teardown_analysis_playback()
	_analysis_id = ""


func _teardown_analysis_playback() -> void:
	if _analysis_player != null and _analysis_player.playing:
		_analysis_player.stop()
	if _analysis_capture != null and _analysis_capture.has_method("clear_buffer"):
		_analysis_capture.clear_buffer()
	_analysis_data = PackedByteArray()
	_analysis_pos = 0
	_analysis_end = 0
	_analysis_direct = false
	_analysis_sq_sum = 0.0
	_analysis_samples = 0
	_analysis_frames = 0


func _file_stats(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var size := int(f.get_length())
	f.close()
	return {"size": size, "mtime": int(FileAccess.get_modified_time(path))}


func _prune_normalization_cache() -> bool:
	## Drops entries whose file is gone or was replaced (path, size, or
	## modification time changed). Returns true when anything was dropped.
	var kept := {}
	for id in _library:
		var entry: Dictionary = _library[id]
		if entry["builtin"] or not _norm_cache.has(id):
			continue
		var cached: Dictionary = _norm_cache[id]
		var stats := _file_stats(id)
		if stats.is_empty():
			continue
		if int(cached.get("size", -1)) != int(stats["size"]) or int(cached.get("mtime", -1)) != int(stats["mtime"]):
			continue
		kept[id] = cached
	var changed: bool = kept.size() != _norm_cache.size()
	_norm_cache = kept
	return changed


func _load_normalization_cache() -> void:
	## Loads and sanitizes the separate normalization cache. Malformed,
	## stale-looking, or missing files simply leave an empty cache; cache
	## I/O never prevents startup.
	_norm_cache = {}
	if not FileAccess.file_exists(normalization_cache_path):
		return
	var f := FileAccess.open(normalization_cache_path, FileAccess.READ)
	if f == null:
		return
	var text := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(text)
	if parsed == null or not (parsed is Dictionary):
		return
	if int(parsed.get("version", -1)) != NORMALIZATION_CACHE_VERSION:
		return
	var entries = parsed.get("entries")
	if not (entries is Dictionary):
		return
	for key in entries:
		if typeof(key) != TYPE_STRING or key.is_empty():
			continue
		var entry = entries[key]
		if not (entry is Dictionary):
			continue
		var gain = entry.get("gain")
		if not (gain is float or gain is int):
			continue
		var size = entry.get("size")
		var mtime = entry.get("mtime")
		if not (size is float or size is int) or not (mtime is float or mtime is int):
			continue
		var gain_value := normalization_clamp_gain(float(gain))
		_norm_cache[key] = {"gain": gain_value, "size": int(size), "mtime": int(mtime)}


func _save_normalization_cache() -> bool:
	## Atomic write of valid results only; failures are ignored (the next
	## analysis simply re-measures).
	var entries := {}
	for id in _norm_cache:
		var e: Dictionary = _norm_cache[id]
		entries[id] = {"gain": float(e["gain"]), "size": int(e["size"]), "mtime": int(e["mtime"])}
	var payload := {"version": NORMALIZATION_CACHE_VERSION, "entries": entries}
	var tmp := normalization_cache_path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify(payload, "\t"))
	var write_error: int = f.get_error()
	f.close()
	if write_error != OK:
		return false
	if FileAccess.file_exists(normalization_cache_path):
		var rm_error := DirAccess.remove_absolute(normalization_cache_path)
		if rm_error != OK:
			return false
	return DirAccess.rename_absolute(tmp, normalization_cache_path) == OK


# -------------------------------------------------------------------- sfx

func _load_sfx() -> void:
	_sfx = {}
	_scan_sfx_dir(sfx_dir)
	_scan_sfx_portable()


func _scan_sfx_dir(dir_path: String) -> void:
	if not DirAccess.dir_exists_absolute(dir_path):
		return
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var file := dir.get_next()
	while not file.is_empty():
		if not dir.current_is_dir() and SUPPORTED_EXTENSIONS.has(file.get_extension().to_lower()):
			var path := dir_path.path_join(file)
			var stream = load(path)
			if stream == null:
				stream = _load_stream_from_disk(path)
			if stream != null and stream is AudioStream:
				_sfx[file.get_basename()] = stream
			else:
				_skipped.append(path)
		file = dir.get_next()
	dir.list_dir_end()


func _scan_sfx_portable() -> void:
	# Loose folder beside the executable: same name replaces the packaged
	# sound, new names add sounds playable by that name. Plain files load
	# straight from disk.
	if portable_sfx_dir.is_empty() or not DirAccess.dir_exists_absolute(portable_sfx_dir):
		return
	var dir := DirAccess.open(portable_sfx_dir)
	if dir == null:
		return
	dir.list_dir_begin()
	var file := dir.get_next()
	while not file.is_empty():
		if not dir.current_is_dir() and SUPPORTED_EXTENSIONS.has(file.get_extension().to_lower()):
			var path := portable_sfx_dir.path_join(file)
			var stream = _load_stream_from_disk(path)
			if stream != null and stream is AudioStream:
				_sfx[file.get_basename()] = stream
			else:
				_skipped.append(path)
		file = dir.get_next()
	dir.list_dir_end()


func play_sfx(name: String) -> void:
	## Safe no-op when the asset is missing: requests are still counted so
	## the wiring stays observable in headless tests.
	sfx_requests[name] = int(sfx_requests.get(name, 0)) + 1
	if not _sfx.has(name) or _sfx_players.is_empty():
		return
	var player: AudioStreamPlayer = _sfx_players[_sfx_next]
	_sfx_next = (_sfx_next + 1) % _sfx_players.size()
	player.stream = _sfx[name]
	player.play()
	sfx_plays[name] = int(sfx_plays.get(name, 0)) + 1


func has_sfx(name: String) -> bool:
	return _sfx.has(name)
