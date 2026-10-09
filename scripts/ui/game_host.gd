extends Node
## Game host: orchestration boundary. Loads and applies settings (display,
## audio, bindings), builds presentation and menu nodes, owns the run state
## machine, and exposes logical actions for the input controller. Menus
## request host commands; they never mutate the gameplay core directly.

const CoreGame = preload("res://scripts/core/game.gd")
const CoopGame = preload("res://scripts/core/coop_game.gd")
const BoardClass = preload("res://scripts/core/board.gd")
const ModeRules = preload("res://scripts/core/mode_rules.gd")
const TetrominoData = preload("res://scripts/core/tetromino_data.gd")
const PlayConfig = preload("res://scripts/core/constants.gd")
const Scoring = preload("res://scripts/core/scoring.gd")
const DefaultBindings = preload("res://scripts/input/default_bindings.gd")
const InputController = preload("res://scripts/input/input_controller.gd")
const BoardRenderer = preload("res://scripts/presentation/board_renderer.gd")
const CoopBoardRenderer = preload("res://scripts/presentation/coop_board_renderer.gd")
const MiniPieceRenderer = preload("res://scripts/presentation/mini_piece_renderer.gd")
const BoardPresenter = preload("res://scripts/presentation/board_presenter.gd")
const Hud = preload("res://scripts/ui/hud.gd")
const SettingsClass = preload("res://scripts/persistence/settings.gd")
const MenuController = preload("res://scripts/ui/menu_controller.gd")
const PauseMenu = preload("res://scripts/ui/pause_menu.gd")
const SettingsScreen = preload("res://scripts/ui/settings_screen.gd")
const CoopSetupMenu = preload("res://scripts/ui/coop_setup_menu.gd")
const ProfileScreen = preload("res://scripts/ui/profile_screen.gd")
const OnScreenKeyboard = preload("res://scripts/ui/on_screen_keyboard.gd")
const OnlineMenu = preload("res://scripts/ui/online_menu.gd")
const ProofScene = preload("res://scenes/network_p2p_proof.tscn")
const ThemeManager = preload("res://scripts/ui/theme_manager.gd")
const ThemeProfile = preload("res://scripts/ui/theme_profile.gd")
const MediaBackdrop = preload("res://scripts/ui/media_backdrop.gd")
const AudioManager = preload("res://scripts/audio/audio_manager.gd")

enum HostState { MAIN_MENU, PLAYING, PAUSED, GAME_OVER, FINISHED, SETTINGS }

## Role of this machine in an online round: LOCAL = offline/single
## authority, HOST = authoritative online simulation (also player 0),
## CLIENT = remote-authoritative renderer that submits input intents.
enum OnlineRole { LOCAL, HOST, CLIENT }

const BOARD_POS := Vector2(480.0, -24.0)  # cell (0,0); hidden rows peek above the panel
const HOLD_POS := Vector2(120.0, 96.0)
const PREVIEW_POS := Vector2(1060.0, 96.0)
const PREVIEW_SPACING := 104.0
const LOGICAL_VIEWPORT := Vector2i(1280, 720)

# --- Coop layout (computed from the player count) ---
const COOP_PREVIEW_SHOWN: int = 3
const COOP_BOARD_Y: float = 96.0
const COOP_STRIP_GAP: float = 8.0

var state: int = HostState.MAIN_MENU
var core: CoreGame = null
var coop: CoopGame = null
var settings: SettingsClass = null
var themes: Node = null

var _board_renderer: Node2D = null
var _board_presenter: BoardPresenter = null
var _hold_renderer: Node2D = null
var _previews: Array[Node2D] = []
var _solo_nodes: Array[Node] = []
var _backdrop_layer: CanvasLayer = null
var _backdrop_root: Control = null
# Layered backdrops on the negative canvas layer: the game backdrop
# (game.background/media) is the always-visible base behind gameplay,
# the menu backdrop (theme.background/media) shows only under
# menu/settings screens, never over an active or paused run.
var _game_backdrop: MediaBackdrop = null
var _menu_backdrop: MediaBackdrop = null
var _field: Node2D = null
var _hud: CanvasLayer = null
var _menu: CanvasLayer = null
var _pause_menu: CanvasLayer = null
var _settings_screen: CanvasLayer = null
var _coop_setup: CanvasLayer = null
var _profile_screen: CanvasLayer = null
var _osk: CanvasLayer = null
var _input: Node = null
var _audio: Node = null
var _accumulator: float = 0.0
var _settings_origin: int = HostState.MAIN_MENU

# --- Online session integration ---
# The OnlineService autoload owns every networking concern (auth, lobby,
# transport, RPC protocol, snapshot stream); GameHost keeps the run
# lifecycle and delegates. Null in tests and plain offline builds.
var online_role: int = OnlineRole.LOCAL
var _online_service: Node = null
var _online_menu: CanvasLayer = null
var _online_slot: int = -1  # this machine's roster slot while online
var _online_signature: int = -1  # last broadcast sim signature (host)
var _online_proof: Node = null  # debug P2P replication proof scene
# True while settings was opened from the profile screen: Back returns to
# the profile browser instead of the main menu.
var _settings_from_profiles: bool = false
var _last_results: Dictionary = {}

# --- Run bookkeeping for result recording ---
# Participating profile ids stored at start (never inferred later from
# connected devices) plus the ordered coop slot assignments for retry.
var _coop_assignments: Array = []
var _run_profile_ids: Array = []
var _run_result_recorded: bool = false

# Edge-detection state for one-shot gameplay SFX: each sound fires exactly
# once per core event, level change, or phase change.
var _solo_event_id: int = 0
var _solo_prev_phase: int = 0
var _solo_prev_level: int = 1
var _coop_event_id: int = 0
var _coop_event_player: int = -1
var _coop_prev_phase: int = 0
var _coop_prev_level: int = 1
# Soft-drop sound edges: one sound per press, never per held frame.
var _solo_soft_drop_active: bool = false
var _coop_soft_drop_active: Array[bool] = []

# Per-run coop presentation nodes (rebuilt for every player count).
var _coop_renderer: Node2D = null
var _coop_nodes: Array[Node] = []
var _coop_holds: Array[Node2D] = []
var _coop_previews: Array = []
var _coop_tags: Array[Label] = []
var _title_labels: Array[Label] = []


func _ready() -> void:
	settings = SettingsClass.new()
	settings.load()
	# Themes load after settings but before any UI is built so every
	# code-created node starts with the resolved tokens.
	_ensure_theme_manager()
	_apply_display_settings()
	DefaultBindings.apply_keyboard_profile(settings.keyboard_bindings)
	_build_scene()
	_show_main_menu()


func _ensure_theme_manager() -> void:
	# Idempotent: tests drive _build_scene() directly without _ready, so
	# this is the single entry point that guarantees a loaded manager.
	if themes != null:
		return
	themes = ThemeManager.new()
	add_child(themes)
	themes.setup("res://themes", "user://themes", _portable_dir("themes"))
	var applied: String = themes.select_valid(settings.theme_id)
	if applied != settings.theme_id:
		# Repair an unknown/stale persisted selection without blocking.
		settings.theme_id = applied
		settings.save()


# ------------------------------------------------------------- portable dirs
# Loose "open files" folders shipped beside the exported executable:
# themes/, music/, and sfx/ are scanned as first-class sources and
# override the packaged fallbacks, so players can edit content without
# touching the executable or its PCK. Running from the editor resolves the
# executable to the editor binary, so the folders are disabled during
# development and testing.

func _portable_dir(name: String) -> String:
	if OS.has_feature("editor"):
		return ""
	return OS.get_executable_path().get_base_dir().path_join(name)


func _build_scene() -> void:
	_ensure_theme_manager()
	# Audio manager first: every other layer may request sounds during
	# setup, and bus creation must happen before settings apply volumes.
	_audio = AudioManager.new()
	_audio.portable_music_dir = _portable_dir("music")
	_audio.portable_sfx_dir = _portable_dir("sfx")
	add_child(_audio)
	if _audio.initialize(settings):
		settings.save()
	_audio.set_music_active(true)

	# Full-viewport backdrops on a dedicated negative canvas layer, so they
	# draw behind the base canvas, the field, the HUD, and every menu
	# overlay without relying on sibling order under the plain root node.
	# The game backdrop (game.background + game media) is the always-on
	# base and is never hidden with the field, so the engine's default
	# clear color never shows through around the playfield. The menu
	# backdrop (theme.background + theme media) sits above it and is
	# shown only while no run is active (see _update_presentation), so
	# menu/settings screens keep their own backdrop while the game one
	# keeps showing behind runs and pause overlays.
	_backdrop_layer = CanvasLayer.new()
	_backdrop_layer.layer = -1
	_backdrop_root = Control.new()
	_backdrop_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_backdrop_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_backdrop_layer.add_child(_backdrop_root)
	_game_backdrop = MediaBackdrop.new()
	_backdrop_root.add_child(_game_backdrop)
	_menu_backdrop = MediaBackdrop.new()
	_backdrop_root.add_child(_menu_backdrop)
	add_child(_backdrop_layer)

	# Field layer holds everything that only exists during an active run.
	_field = Node2D.new()
	add_child(_field)

	# The active playfield (solo or co-op) presents through this wrapper:
	# direct field drawing when bloom is off, or a board-sized off-screen
	# render target compositing the theme's piece bloom over the sharp
	# source. First field child so the board still draws behind the
	# hold/preview strips and the co-op tags.
	_board_presenter = BoardPresenter.new()
	_board_presenter.set_layout(BOARD_POS, _solo_board_size())
	_field.add_child(_board_presenter)

	_board_renderer = BoardRenderer.new()
	_board_presenter.install(_board_renderer)
	_solo_nodes.append(_board_renderer)

	_hold_renderer = MiniPieceRenderer.new()
	_hold_renderer.position = HOLD_POS
	_field.add_child(_hold_renderer)
	_solo_nodes.append(_hold_renderer)

	for i in PlayConfig.PREVIEW_COUNT:
		var mini: Node2D = MiniPieceRenderer.new()
		mini.position = PREVIEW_POS + Vector2(0.0, PREVIEW_SPACING * i)
		_field.add_child(mini)
		_previews.append(mini)
		_solo_nodes.append(mini)

	_make_title("HOLD", HOLD_POS + Vector2(0.0, -34.0))
	_make_title("NEXT", PREVIEW_POS + Vector2(0.0, -34.0))

	_hud = Hud.new()
	add_child(_hud)

	_menu = MenuController.new()
	_menu.setup(self)
	add_child(_menu)

	_coop_setup = CoopSetupMenu.new()
	_coop_setup.setup(self)
	add_child(_coop_setup)

	_pause_menu = PauseMenu.new()
	_pause_menu.setup(self)
	add_child(_pause_menu)

	_settings_screen = SettingsScreen.new()
	_settings_screen.setup(self)
	add_child(_settings_screen)

	_profile_screen = ProfileScreen.new()
	_profile_screen.setup(self)
	add_child(_profile_screen)

	_osk = OnScreenKeyboard.new()
	_osk.setup(self)
	add_child(_osk)
	_osk.name_committed.connect(_on_name_committed)
	_osk.entry_cancelled.connect(_on_name_cancelled)

	# The online service autoload may be absent (tests, stripped builds):
	# every online command guards on it. Resolve it BEFORE the online menu
	# builds so the menu wires its service signals.
	_online_service = get_node_or_null("/root/OnlineService")
	if _online_service != null:
		_online_service.game_host = self

	_online_menu = OnlineMenu.new()
	_online_menu.setup(self)
	add_child(_online_menu)

	# Input controller goes last so every other node is initialized before it.
	_input = InputController.new(self)
	add_child(_input)

	_apply_theme()


func _make_title(text: String, pos: Vector2) -> void:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 18)
	label.add_theme_color_override("font_color", ThemeProfile.DEFAULT_TOKENS["theme.dim"])
	label.position = pos
	_field.add_child(label)
	_solo_nodes.append(label)
	_title_labels.append(label)


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		if settings != null:
			settings.save()


# ---------------------------------------------------------------- game flow

func _start_game(mode: int, profile_id: String = "") -> void:
	core = CoreGame.new(mode, randi())
	coop = null
	_coop_assignments = []
	_input.end_coop()
	_teardown_coop_scene()
	state = HostState.PLAYING
	_accumulator = 0.0
	_reset_solo_audio_edges()
	_hud.set_combo("")
	_menu.close()
	_coop_setup.close()
	_pause_menu.close()
	_settings_screen.close()
	_profile_screen.close()
	# The run's participating profile ids are captured here, never inferred
	# from connected devices later.
	_run_profile_ids = [] if profile_id.is_empty() else [profile_id]
	_run_result_recorded = false
	_input.begin_solo(profile_id, _first_connected_device())
	_audio.set_music_context(false)
	_audio.set_music_active(true)
	_audio.set_music_paused(false)
	_update_presentation()


func _first_connected_device() -> int:
	## The first connected pad routes to the solo profile; -1 means
	## keyboard-only input. Claim/session devices are never persisted.
	var pads: Array = Input.get_connected_joypads()
	if pads.is_empty():
		return -1
	return int(pads[0])


func _start_coop(assignments: Array, game_mode: int) -> void:
	## Each entry is {"profile_id": String, "device": int} in player order.
	var resolved: Array = []
	for assignment in assignments:
		if not (assignment is Dictionary):
			continue
		var profile_id := String(assignment.get("profile_id", ""))
		if profile_id.is_empty():
			continue
		resolved.append({
			"profile_id": profile_id,
			"device": int(assignment.get("device", -1)),
		})
	if resolved.is_empty():
		return
	core = null
	_teardown_coop_scene()
	coop = CoopGame.new(resolved.size(), game_mode, randi())
	state = HostState.PLAYING
	_accumulator = 0.0
	_reset_coop_audio_edges()
	_hud.set_combo("")
	_hud.set_event("", 0)
	_coop_assignments = resolved
	_run_profile_ids = _dedupe_profile_ids(resolved)
	_run_result_recorded = false
	_input.begin_coop(resolved)
	_build_coop_scene()
	_menu.close()
	_coop_setup.close()
	_pause_menu.close()
	_settings_screen.close()
	_profile_screen.close()
	_audio.set_music_context(false)
	_audio.set_music_active(true)
	_audio.set_music_paused(false)
	_update_presentation()


static func _dedupe_profile_ids(assignments: Array) -> Array:
	var ids: Array = []
	for assignment in assignments:
		var profile_id: String = assignment["profile_id"]
		if not ids.has(profile_id):
			ids.append(profile_id)
	return ids


func _show_main_menu() -> void:
	if _online_service != null and _online_service.is_in_session():
		# Leaving for the main menu exits any online lobby/match first; the
		# service calls back into online_leave_session for the run teardown.
		_online_service.leave_session()
	core = null
	coop = null
	_input.end_coop()
	_teardown_coop_scene()
	# Returning to the menu discards the run, including its recording
	# bookkeeping: an abandoned run never records a result.
	_run_profile_ids = []
	_coop_assignments = []
	_run_result_recorded = false
	state = HostState.MAIN_MENU
	_pause_menu.close()
	_settings_screen.close()
	# Main menu (and settings opened from it) uses the menu music context.
	_audio.set_music_context(true)
	_audio.set_music_active(true)
	_audio.set_music_paused(false)
	_coop_setup.close()
	_hud.hide_overlay()
	_hud.set_combo("")
	_hud.set_event("", 0)
	_menu.show_main_menu(self)
	_update_presentation()


func _show_results(title: String, subtitle: String) -> void:
	_last_results = {"title": title, "subtitle": subtitle}
	_menu.show_results(self, title, subtitle)


func _update_presentation() -> void:
	var in_run: bool = core != null or coop != null
	_field.visible = in_run
	_hud.visible = in_run
	if _board_presenter != null:
		# Render-target updates (and the bloom pass) run only while a run
		# shows the field: active, paused, or under its results overlay.
		_board_presenter.set_presenting(in_run)
	# Menu media only shows when the playfield is hidden: during a run
	# (including pause/results) the game backdrop stays behind everything
	# and the menu backdrop never peeks over the frozen field.
	_menu_backdrop.visible = not in_run
	var solo_visible: bool = core != null
	for node in _solo_nodes:
		node.visible = solo_visible
	if not in_run:
		_board_renderer.core = null
		_board_renderer.queue_redraw()
		for mini in _previews:
			mini.set_piece(TetrominoData.EMPTY, false)
		_hold_renderer.set_piece(TetrominoData.EMPTY, false)


# ------------------------------------------------------------ coop layout

func _coop_cell_size(player_count: int) -> float:
	match player_count:
		1, 2:
			return 28.0
		3:
			return 26.0
		_:
			return 20.0


## Solo render-target bounds: the full board including the hidden spawn
## rows, so the peek above the panel is processed consistently.
func _solo_board_size() -> Vector2:
	return Vector2(BoardClass.DEFAULT_WIDTH, BoardClass.HEIGHT) * BoardRenderer.CELL


# ---------------------------------------------------------------- theme
# The host is the theme application boundary: it pushes resolved tokens
# into every instantiated presentation node. Applying a theme never touches
# the gameplay core, timer, audio state, or bindings.

func _apply_theme() -> void:
	if themes == null:
		return
	var tokens: Dictionary = themes.tokens()
	var media: Dictionary = themes.media()
	# Backdrops apply their own media precedence (video, then image, then
	# the themed color) and own the previous video player's lifecycle.
	_game_backdrop.apply(media["game"])
	_menu_backdrop.apply(media["menu"])
	_board_renderer.apply_theme(tokens, media)
	_update_board_bloom(media)
	_hold_renderer.apply_theme(tokens, media)
	for mini in _previews:
		mini.apply_theme(tokens, media)
	var dim: Color = tokens["theme.dim"]
	var font: Font = media["font"]
	for label in _title_labels:
		label.add_theme_color_override("font_color", dim)
		_apply_font_override(label, font)
	_hud.apply_theme(tokens, media)
	_menu.apply_theme(tokens, media)
	_coop_setup.apply_theme(tokens, media)
	_settings_screen.apply_theme(tokens, media)
	_pause_menu.apply_theme(tokens, media)
	_profile_screen.apply_theme(tokens, media)
	_osk.apply_theme(tokens, media)
	_apply_coop_theme(tokens, media)


## Theme font override helper: null clears the override so the built-in
## font applies, non-null replaces it for that label only.
static func _apply_font_override(label: Label, font: Font) -> void:
	if font == null:
		label.remove_theme_font_override("font")
	else:
		label.add_theme_font_override("font", font)


func _apply_coop_theme(tokens: Dictionary, media: Dictionary) -> void:
	if _coop_renderer == null:
		return
	_coop_renderer.apply_theme(tokens, media)
	_update_board_bloom(media)
	var player_colors: Array = [
		tokens["players.p1"], tokens["players.p2"], tokens["players.p3"], tokens["players.p4"],
	]
	var font: Font = media["font"]
	for i in _coop_tags.size():
		if i < player_colors.size():
			_coop_tags[i].add_theme_color_override("font_color", player_colors[i])
		_apply_font_override(_coop_tags[i], font)
	for mini in _coop_holds:
		mini.apply_theme(tokens, media)
	for row in _coop_previews:
		for mini in row:
			mini.apply_theme(tokens, media)


## Board bloom control: the theme's numeric `pieces.bloom` intensity
## drives the presenter's off-screen pass for every solid-piece look -
## undithered, dithered, or skinned - independent of any dither setting.
## Presentation-only: the active core is never touched.
func _update_board_bloom(media: Dictionary) -> void:
	if _board_presenter == null:
		return
	var intensity: float = clampf(float(media.get("bloom", 0.0)), 0.0, ThemeProfile.MAX_BLOOM_INTENSITY)
	_board_presenter.set_bloom_intensity(intensity)


func _build_coop_scene() -> void:
	var count: int = coop.player_count
	var cell: float = _coop_cell_size(count)
	var board_w: float = cell * CoopGame.SECTION_WIDTH * count
	var board_x: float = (float(LOGICAL_VIEWPORT.x) - board_w) * 0.5

	# The shared board presents through the same wrapper, sized from the
	# dynamic geometry (total width, full height, current cell).
	_board_presenter.set_layout(Vector2(board_x, COOP_BOARD_Y), Vector2(board_w, cell * BoardClass.HEIGHT))

	_coop_renderer = CoopBoardRenderer.new()
	_coop_renderer.cell = cell
	_board_presenter.install(_coop_renderer)
	_coop_nodes.append(_coop_renderer)

	# Per-player strip above each section: player tag, hold, and next
	# previews, all sized to fit the section width.
	var box: float = clampf((cell * CoopGame.SECTION_WIDTH - 3.0 * COOP_STRIP_GAP) / 4.0, 36.0, 64.0)
	var mini_scale: float = box / 96.0
	for i in count:
		var section_center: float = board_x + (CoopGame.SECTION_WIDTH * i + CoopGame.SECTION_WIDTH * 0.5) * cell
		var group_w: float = box * 4.0 + 3.0 * COOP_STRIP_GAP
		var x0: float = section_center - group_w * 0.5

		var tag := Label.new()
		var profile_name := _coop_profile_display_name(i)
		tag.text = "P%d %s" % [i + 1, profile_name] if not profile_name.is_empty() else "P%d" % (i + 1)
		tag.add_theme_font_size_override("font_size", 16)
		tag.add_theme_color_override("font_color", _player_accent(i))
		tag.position = Vector2(x0, 2.0)
		_field.add_child(tag)
		_coop_nodes.append(tag)
		_coop_tags.append(tag)

		var hold_mini := MiniPieceRenderer.new()
		hold_mini.scale = Vector2(mini_scale, mini_scale)
		hold_mini.position = Vector2(x0, 22.0)
		_field.add_child(hold_mini)
		_coop_nodes.append(hold_mini)
		_coop_holds.append(hold_mini)

		var row: Array = []
		for j in COOP_PREVIEW_SHOWN:
			var mini := MiniPieceRenderer.new()
			mini.scale = Vector2(mini_scale, mini_scale)
			mini.position = Vector2(x0 + box + COOP_STRIP_GAP + j * (box + COOP_STRIP_GAP), 22.0)
			_field.add_child(mini)
			_coop_nodes.append(mini)
			row.append(mini)
		_coop_previews.append(row)
	_apply_coop_theme(themes.tokens(), themes.media())


func _player_accent(index: int) -> Color:
	var tokens: Dictionary = themes.tokens()
	match index:
		1: return tokens["players.p2"]
		2: return tokens["players.p3"]
		3: return tokens["players.p4"]
	return tokens["players.p1"]


## Co-op player label: "P# <profile name>" so profile ownership is visible
## during play; falls back to the bare player tag for untracked slots.
## Online assignments carry the peer's display name instead of a local
## profile id (EOS identities are anonymous/device-local).
func _coop_profile_display_name(player: int) -> String:
	if player < 0 or player >= _coop_assignments.size():
		return ""
	var assignment: Dictionary = _coop_assignments[player]
	var display := String(assignment.get("name", ""))
	if not display.is_empty():
		return display
	return settings.profile_name(String(assignment.get("profile_id", "")))


func _teardown_coop_scene() -> void:
	# Release the co-op board from the presenter before freeing it so no
	# stale render-target output can linger, then restore the solo board
	# and its layout as the presented field for whatever comes next.
	if _board_presenter != null:
		_board_presenter.clear()
	for node in _coop_nodes:
		node.visible = false
		node.queue_free()
	_coop_nodes = []
	_coop_holds = []
	_coop_previews = []
	_coop_tags = []
	_coop_renderer = null
	if _board_presenter != null and _board_renderer != null:
		_board_presenter.set_layout(BOARD_POS, _solo_board_size())
		_board_presenter.install(_board_renderer)


# ------------------------------------------------------------ host commands
# Requested by menu/settings/profile/lobby UI. These are the only way UI
# mutates flow.

func cmd_start_marathon() -> void:
	## Solo modes select a profile first; the pick screen starts the run.
	cmd_select_profile_for_solo(ModeRules.Mode.MARATHON)


func cmd_start_sprint() -> void:
	cmd_select_profile_for_solo(ModeRules.Mode.SPRINT)


func cmd_select_profile_for_solo(mode: int) -> void:
	if state != HostState.MAIN_MENU:
		return
	if core != null or coop != null:
		# Defensive: a lingering run is discarded before a new one starts.
		_show_main_menu()
	_menu.close()
	_profile_screen.open_solo_start(mode)


func cmd_open_profiles() -> void:
	if state != HostState.MAIN_MENU:
		return
	_menu.close()
	_profile_screen.open_manage()


func cmd_profile_screen_back() -> void:
	_profile_screen.close()
	if _coop_setup.is_open():
		# Opened for a lobby slot: free its pending claim and keep the
		# lobby running.
		_coop_setup.cancel_pending_claim()
		_coop_setup.refresh()
		return
	_show_main_menu()


func cmd_solo_profile_selected(profile_id: String, mode: int) -> void:
	## Starts a solo run with the picked profile; the first connected pad
	## routes to it (keyboard-only starts remain possible).
	if state != HostState.MAIN_MENU:
		return
	settings.set_active_profile(profile_id)
	_profile_screen.close()
	settings.save()
	_start_game(mode, profile_id)


func cmd_set_active_profile(profile_id: String) -> void:
	if settings.set_active_profile(profile_id):
		settings.save()
		_profile_screen.refresh()


func cmd_resume() -> void:
	if state == HostState.PAUSED:
		state = HostState.PLAYING
		_pause_menu.close()
		_audio.set_music_paused(false)


func cmd_restart_run() -> void:
	# Retry reuses the run's stored profile/device assignments and creates
	# a fresh run without recording anything for the previous attempt.
	if online_role != OnlineRole.LOCAL:
		# Online rounds restart through the lobby (a host command after the
		# round), never mid-session: a local restart would desync peers.
		return
	if coop != null:
		_start_coop(_coop_assignments, coop.mode)
	elif core != null:
		var solo_profile := String(_run_profile_ids[0]) if not _run_profile_ids.is_empty() else ""
		_start_game(core.mode, solo_profile)


func cmd_open_coop_setup() -> void:
	if state != HostState.MAIN_MENU:
		return
	_menu.close()
	_coop_setup.open()


func cmd_coop_setup_back() -> void:
	_coop_setup.close()
	_show_main_menu()


func cmd_lobby_open_profile_picker(slot: int) -> void:
	## The lobby asks for the join flow after a pad claim release or a
	## keyboard join on one slot.
	if not _coop_setup.is_open() or slot < 0 or slot >= _coop_setup.slots.size():
		return
	if not _coop_setup.slots[slot].is_empty() and not String(_coop_setup.slots[slot].get("profile_id", "")).is_empty():
		return
	_profile_screen.open_lobby_join(slot)


func lobby_taken_profile_ids(except_slot: int) -> Array:
	## Profiles already joined in other lobby slots (used to hide them from
	## the picker so duplicate joins are impossible).
	if not _coop_setup.is_open():
		return []
	return _coop_setup._taken_profile_ids(except_slot)


func cmd_lobby_join_profile(slot: int, profile_id: String) -> void:
	## Commits a lobby slot join: rejects taken profiles, missing slots,
	## and slots that already hold a profile.
	if not _coop_setup.is_open() or slot < 0 or slot >= _coop_setup.slots.size():
		return
	var slot_state: Dictionary = _coop_setup.slots[slot]
	if not slot_state.is_empty() and not String(slot_state.get("profile_id", "")).is_empty():
		return
	if settings.find_profile(profile_id).is_empty():
		return
	for other in _coop_setup.slots.size():
		if other == slot:
			continue
		var other_state: Dictionary = _coop_setup.slots[other]
		if not other_state.is_empty() and other_state.get("profile_id", "") == profile_id:
			return
	var device := int(slot_state.get("device", -1)) if not slot_state.is_empty() else -1
	_coop_setup.slots[slot] = {
		"profile_id": profile_id,
		"device": device,
		"name": settings.profile_name(profile_id),
	}
	settings.save()
	_profile_screen.close()
	_coop_setup.refresh()
	_coop_setup.resume_claims()


func cmd_start_coop(assignments: Array, game_mode: int) -> void:
	_start_coop(assignments, game_mode)


func cmd_quit() -> void:
	if _online_service != null:
		# Best-effort EOS teardown before the process exits.
		_online_service.shutdown()
	settings.save()
	get_tree().quit()


func cmd_confirm_return_to_menu() -> void:
	_pause_menu.show_return_confirm()


func cmd_return_to_menu() -> void:
	_show_main_menu()


# ------------------------------------------------------- profile management
# Requested by the profile screen and the on-screen keyboard. All profile
# mutations go through the settings helpers, then save.

## Context for the open name entry: purpose "create" (optionally for a
## lobby slot) or "rename" for one profile.
var _name_entry_context: Dictionary = {}


func cmd_open_name_create(lobby_slot: int = -1) -> void:
	_name_entry_context = {"purpose": "create", "lobby_slot": lobby_slot}
	_osk.open("", "NEW PROFILE NAME")


func cmd_open_name_rename(profile_id: String) -> void:
	var profile := settings.find_profile(profile_id)
	if profile.is_empty():
		return
	_name_entry_context = {"purpose": "rename", "profile_id": profile_id}
	_osk.open(String(profile["name"]), "RENAME PROFILE", profile_id)


func _on_name_committed(name: String) -> void:
	# The OSK validated blank/duplicate names before emitting.
	var context := _name_entry_context
	_name_entry_context = {}
	match String(context.get("purpose", "")):
		"create":
			var profile_id := settings.create_profile(name)
			if profile_id.is_empty():
				return
			settings.save()
			var lobby_slot := int(context.get("lobby_slot", -1))
			if lobby_slot >= 0 and _coop_setup.is_open():
				cmd_lobby_join_profile(lobby_slot, profile_id)
			else:
				_profile_screen.refresh()
		"rename":
			if settings.rename_profile(String(context.get("profile_id", "")), name):
				settings.save()
			_profile_screen.refresh()


func _on_name_cancelled() -> void:
	_name_entry_context = {}
	if not _profile_screen.is_open():
		return
	_profile_screen.refresh()


func cmd_profile_bind_controller(profile_id: String) -> void:
	## Opens the guided controller binding flow for one profile from the
	## profile browser; Back returns to the browser.
	if settings.find_profile(profile_id).is_empty():
		return
	_settings_from_profiles = true
	_settings_origin = HostState.MAIN_MENU
	state = HostState.SETTINGS
	_profile_screen.close()
	_audio.set_music_context(true)
	_settings_screen.open_controller_binding(profile_id)


func cmd_controller_bindings_captured(profile_id: String, records: Dictionary) -> bool:
	## Commits a completed guided sequence to the profile atomically. The
	## guided flow passes one record per action; wrap them into the
	## action->records profile shape before sanitizing.
	var profile := settings.find_profile(profile_id)
	if profile.is_empty() or records.is_empty():
		return false
	var by_action := {}
	for action in DefaultBindings.ACTION_NAMES:
		var value = records.get(action)
		if value is Array:
			by_action[action] = value
		elif value is Dictionary and not (value as Dictionary).is_empty():
			by_action[action] = [value]
		else:
			by_action[action] = []
	profile["controller_bindings"] = DefaultBindings.sanitize_category_profile(by_action, "controller")
	settings.save()
	# A run may hold this profile's assignment mid-pause: live-reload it.
	_input.refresh_profile(profile_id)
	return true


func cmd_reset_controller_bindings(profile_id: String) -> void:
	var profile := settings.find_profile(profile_id)
	if profile.is_empty():
		return
	profile["controller_bindings"] = DefaultBindings.default_controller_profile()
	settings.save()
	_input.refresh_profile(profile_id)


func profile_name(profile_id: String) -> String:
	return settings.profile_name(profile_id)


func active_profile_name() -> String:
	return settings.active_profile_name()


func profile_name_taken(name: String, exclude_id: String = "") -> bool:
	return settings.profile_name_taken(name, exclude_id)


func cmd_open_settings_from_pause() -> void:
	cmd_open_settings(HostState.PAUSED)


func cmd_open_settings_from_menu() -> void:
	cmd_open_settings(HostState.MAIN_MENU)


func cmd_open_settings_from_results() -> void:
	cmd_open_settings(_last_results_state())


func cmd_open_settings(origin: int) -> void:
	_settings_origin = origin
	_settings_from_profiles = false
	state = HostState.SETTINGS
	# Settings opened from the main menu keep the menu music context;
	# from pause/results the gameplay music keeps its context.
	_audio.set_music_context(origin == HostState.MAIN_MENU)
	_settings_screen.open()


func cmd_settings_back() -> void:
	_settings_screen.close()
	var return_to_profiles := _settings_from_profiles
	_settings_from_profiles = false
	if return_to_profiles:
		state = HostState.MAIN_MENU
		_profile_screen.open_manage()
		return
	match _settings_origin:
		HostState.PAUSED:
			state = HostState.PAUSED
			_pause_menu.show_pause()
			_audio.set_music_paused(true)
		HostState.GAME_OVER, HostState.FINISHED:
			state = _settings_origin
			_audio.set_music_active(true)
			_audio.set_music_paused(false)
			_show_results(_last_results["title"], _last_results["subtitle"])
		_:
			_show_main_menu()


func cmd_settings_changed() -> void:
	_apply_display_settings()
	_apply_audio_settings()
	settings.save()


func cmd_keyboard_bindings_changed() -> void:
	## The shared keyboard profile drives the global InputMap; profile
	## controller bindings are never installed globally.
	DefaultBindings.apply_keyboard_profile(settings.keyboard_bindings)
	settings.save()


func cmd_reset_all_settings() -> void:
	_audio.stop_preview()
	settings.reset_to_defaults()
	_audio.sanitize_selection(settings)
	_audio.apply_music_settings(settings)
	_apply_display_settings()
	_apply_audio_settings()
	DefaultBindings.apply_keyboard_profile(settings.keyboard_bindings)
	themes.select_valid(settings.theme_id)
	_apply_theme()
	settings.save()
	_settings_screen.refresh()


# ------------------------------------------------------------- theme setup
# Requested by the settings screen's display rows. Theme application only
# touches presentation nodes; the active core, timer, and audio state are
# never mutated.

func cmd_theme_selected(id: String) -> void:
	if not themes.select(id):
		return
	settings.theme_id = id
	_apply_theme()
	settings.save()


func cmd_themes_reload() -> Dictionary:
	themes.ensure_user_dir()
	var result: Dictionary = themes.reload()
	if result["repaired"]:
		# The selected file disappeared or became invalid: repair the
		# persisted selection and keep the current run intact.
		settings.theme_id = themes.selected_id
		settings.save()
	_apply_theme()
	return result


# Read-only theme accessors for the settings screen rows.

func theme_entries() -> Array:
	if themes == null:
		return []
	return themes.entries


func theme_selected_id() -> String:
	return themes.selected_id if themes != null else ""


func theme_invalid_entries() -> Array:
	if themes == null:
		return []
	return themes.invalid


func theme_user_dir_hint() -> String:
	return themes.user_dir_hint() if themes != null else ""


# ------------------------------------------------------------- music setup
# Requested by the settings screen's audio rows and playlist editor. All
# of them commit immediately, like every other settings change.

func cmd_music_mode_changed(mode: String) -> void:
	if not SettingsClass.MUSIC_MODES.has(mode):
		return
	settings.music_mode = mode
	settings.save()
	_audio.apply_music_settings(settings)


func cmd_music_track_selected(track_id: String) -> void:
	settings.music_track = track_id
	_audio.sanitize_selection(settings)
	settings.save()
	_audio.apply_music_settings(settings)
	if _audio.previewing():
		_audio.preview_track(settings.music_track)


func cmd_menu_music_selected(track_id: String) -> void:
	## Separate main-menu track: empty follows the gameplay music, any
	## library track loops in the menu regardless of the gameplay mode.
	if not track_id.is_empty() and not _audio.has_track(track_id):
		return
	settings.menu_music_track = track_id
	settings.save()
	_audio.apply_music_settings(settings)


func cmd_music_playlist_changed(playlist: Array) -> void:
	settings.music_playlist = playlist.duplicate()
	_audio.sanitize_selection(settings)
	settings.save()
	_audio.apply_music_settings(settings)


func cmd_music_rescan() -> void:
	if _audio.rescan_library(settings):
		settings.save()


func cmd_music_preview() -> void:
	_audio.preview_track(settings.music_track)


func cmd_music_preview_stop() -> void:
	_audio.stop_preview()


# Read-only audio accessors for the settings screen rows.

func audio_track_ids() -> Array:
	if _audio == null:
		return []
	return _audio.track_ids()


func audio_track_title(track_id: String) -> String:
	if _audio == null:
		return ""
	return _audio.track_title(track_id)


func audio_track_count() -> int:
	if _audio == null:
		return 0
	return _audio.track_count()


func audio_skipped_count() -> int:
	if _audio == null:
		return 0
	return _audio.skipped_files().size()


func audio_music_dir_hint() -> String:
	return ProjectSettings.globalize_path("user://music")


func music_previewing() -> bool:
	return _audio != null and _audio.previewing()


# Normalization state for the settings screen's audio rows. Read-only; all
# behavior changes flow through the settings commands above.

func audio_normalization_active() -> bool:
	return _audio != null and _audio.is_analysis_active()


func audio_normalization_status() -> String:
	return _audio.normalization_status() if _audio != null else ""


func play_ui_sfx(name: String) -> void:
	## Menu/navigation sound entry point for the UI layers.
	if _audio != null:
		_audio.play_sfx(name)


func _last_results_state() -> int:
	if core != null and core.phase == CoreGame.Phase.FINISHED:
		return HostState.FINISHED
	if coop != null and coop.phase == CoopGame.Phase.FINISHED:
		return HostState.FINISHED
	return HostState.GAME_OVER


# ---------------------------------------------------------------- settings

func _apply_display_settings() -> void:
	if DisplayServer.get_name() == "headless":
		return
	var window := get_window()
	if window == null:
		return
	if settings.fullscreen:
		window.mode = Window.MODE_FULLSCREEN
	else:
		window.mode = Window.MODE_WINDOWED
		var scale: int = settings.window_scale
		if scale >= 1 and scale <= 3:
			window.size = LOGICAL_VIEWPORT * scale


func _apply_audio_settings() -> void:
	if _audio == null:
		return
	_audio.apply_volumes(settings)
	_audio.apply_normalization_setting(settings)


# ------------------------------------------------------------- simulation

func _process(delta: float) -> void:
	if state == HostState.PLAYING and core != null:
		var capped: float = minf(delta, PlayConfig.MAX_FRAME_DELTA)
		_accumulator += capped
		while _accumulator >= PlayConfig.FIXED_STEP:
			_accumulator -= PlayConfig.FIXED_STEP
			core.tick(PlayConfig.FIXED_STEP)
		_check_solo_audio_events()
		if core.phase == CoreGame.Phase.GAME_OVER:
			state = HostState.GAME_OVER
			_show_results("GAME OVER", _solo_subtitle("Score %d" % core.score, ModeRules.records_on_game_over(core.mode)))
		elif core.phase == CoreGame.Phase.FINISHED:
			state = HostState.FINISHED
			_show_results("FINISHED!", _solo_subtitle("40 lines in %s" % ModeRules.format_time(core.elapsed), ModeRules.records_on_finish(core.mode)))
	if state == HostState.PLAYING and coop != null:
		var capped_coop: float = minf(delta, PlayConfig.MAX_FRAME_DELTA)
		_accumulator += capped_coop
		# A client's CoopGame is a host-authored twin: never ticked locally,
		# only rebuilt from snapshots (applied in OnlineService before
		# _sync_display below reads it).
		if online_role != OnlineRole.CLIENT:
			while _accumulator >= PlayConfig.FIXED_STEP:
				_accumulator -= PlayConfig.FIXED_STEP
				coop.tick(PlayConfig.FIXED_STEP)
		# Snapshot-driven lock/level sounds still fire on clients: each
		# host event rebuilds a fresh event object with a new instance id.
		_check_coop_audio_events()
		if online_role == OnlineRole.HOST and _online_service != null:
			# Structural changes (lock events, phase/level transitions) are
			# sent reliably; the rest ride the periodic unreliable cadence.
			var signature := _online_state_signature()
			_online_service.host_match_frame(capped_coop, signature != _online_signature)
			_online_signature = signature
		if online_role != OnlineRole.CLIENT and coop.phase == CoopGame.Phase.GAME_OVER:
			state = HostState.GAME_OVER
			var subtitle := "%dP Coop - Score %d%s" % [
				coop.player_count,
				coop.score,
				_coop_record_suffix(coop, ModeRules.records_on_game_over(coop.mode)),
			]
			if online_role == OnlineRole.HOST:
				_finish_online_round("GAME OVER", subtitle)
			else:
				_show_results("GAME OVER", subtitle)
		elif online_role != OnlineRole.CLIENT and coop.phase == CoopGame.Phase.FINISHED:
			state = HostState.FINISHED
			var subtitle := "40 lines in %s - %dP Coop%s" % [
				ModeRules.format_time(coop.elapsed),
				coop.player_count,
				_coop_record_suffix(coop, ModeRules.records_on_finish(coop.mode)),
			]
			if online_role == OnlineRole.HOST:
				_finish_online_round("FINISHED!", subtitle)
			else:
				_show_results("FINISHED!", subtitle)
	if core != null or coop != null:
		_sync_display()


func _sync_display() -> void:
	if coop != null:
		_sync_coop_display()
		return
	_board_renderer.core = core
	_board_renderer.queue_redraw()

	_hold_renderer.set_piece(core.hold_kind, core.hold_used)
	var previews: Array[int] = core.preview_kinds()
	for i in _previews.size():
		_previews[i].set_piece(previews[i])

	_hud.set_score(core.score)
	_hud.set_level(core.level)
	if core.mode == ModeRules.Mode.SPRINT:
		_hud.set_lines(maxi(0, PlayConfig.SPRINT_GOAL_LINES - core.lines))
	else:
		_hud.set_lines(core.lines)
	_hud.set_time(core.elapsed)

	var event = core.last_event
	if event == null:
		_hud.set_event("", 0)
		_hud.set_combo("")
	else:
		var label: String = event.label()
		if event.perfect_clear:
			label = (label + "  PERFECT CLEAR") if not label.is_empty() else "PERFECT CLEAR"
		_hud.set_event(label, event.total_points)
		_hud.set_combo(("COMBO x%d" % event.combo) if event.combo >= 1 else "")


func _sync_coop_display() -> void:
	_coop_renderer.session = coop
	_coop_renderer.queue_redraw()

	for i in coop.player_count:
		_coop_holds[i].set_piece(coop.players[i].hold_kind, coop.players[i].hold_used)
		var previews: Array[int] = coop.preview_kinds(i)
		for j in _coop_previews[i].size():
			_coop_previews[i][j].set_piece(previews[j])

	_hud.set_score(coop.score)
	_hud.set_level(coop.level)
	if coop.mode == ModeRules.Mode.SPRINT:
		_hud.set_lines(maxi(0, PlayConfig.SPRINT_GOAL_LINES - coop.lines))
	else:
		_hud.set_lines(coop.lines)
	_hud.set_time(coop.elapsed)

	# The most recent player event feeds the shared event/combo display.
	if coop.last_event_player < 0:
		_hud.set_event("", 0)
		_hud.set_combo("")
		return
	var event = coop.players[coop.last_event_player].last_event
	if event == null:
		_hud.set_event("", 0)
		_hud.set_combo("")
		return
	var label: String = event.label()
	if event.perfect_clear:
		label = (label + "  PERFECT CLEAR") if not label.is_empty() else "PERFECT CLEAR"
	if label.is_empty():
		_hud.set_event("", 0)
		_hud.set_combo("")
	else:
		_hud.set_event("P%d  %s" % [coop.last_event_player + 1, label], event.total_points)
		_hud.set_combo(("COMBO x%d" % event.combo) if event.combo >= 1 else "")


static func _format_time(value: float) -> String:
	return ModeRules.format_time(value)


# -------------------------------------------------------- result recording
# Eligible terminal transitions append exactly one record to every
# participating profile (deduplicated), saved once. Retry, return-to-menu,
# and abandoned runs never record. The guard survives _process observing
# an already-terminal core across frames.

func _solo_subtitle(base: String, eligible: bool) -> String:
	## Team-of-one result line with personal placement/best information.
	if not eligible:
		return base
	if core == null:
		return base
	var mode_key := ModeRules.mode_key(core.mode, false)
	var suffix := _record_run_result(core.score, core.elapsed, mode_key, 1, ModeRules.higher_score_wins(core.mode))
	return base + suffix


func _coop_record_suffix(coop_run, eligible: bool) -> String:
	## Team results are recorded for every participating profile; the
	## subtitle itself stays team-focused.
	if not eligible or coop_run == null:
		return ""
	_record_run_result(
		coop_run.score,
		coop_run.elapsed,
		ModeRules.mode_key(coop_run.mode, true),
		coop_run.player_count,
		ModeRules.higher_score_wins(coop_run.mode)
	)
	return ""


func _record_run_result(score: int, elapsed: float, mode_key: String, players: int, higher_is_better: bool) -> String:
	## Appends one result to each participating profile, saves once, and
	## returns a personal-best/placement suffix for solo display ("" for
	## team runs or when nothing was recorded).
	if _run_result_recorded:
		return ""
	_run_result_recorded = true
	if _run_profile_ids.is_empty():
		return ""
	var result := {
		"score": maxi(0, score),
		"elapsed": maxf(0.0, elapsed),
		"completed_at": int(Time.get_unix_time_from_system()),
		"players": clampi(players, 1, 4),
		"mode": mode_key,
	}
	var placement := 0
	var had_records := false
	for profile_id in _run_profile_ids:
		if not settings.profile_history(profile_id, mode_key).is_empty():
			had_records = true
		var place: int = settings.append_result(profile_id, mode_key, result, higher_is_better)
		if place > 0:
			placement = place
	settings.save()
	if players > 1 or placement <= 0:
		return ""
	if placement == 1:
		return " - NEW PERSONAL BEST!" if had_records else ""
	var history: Array = settings.profile_history(String(_run_profile_ids[0]), mode_key)
	if history.is_empty():
		return ""
	var best: Dictionary = history[0]
	if higher_is_better:
		return " - Best %d (this run #%d)" % [int(best["score"]), placement]
	return " - Best %s (this run #%d)" % [ModeRules.format_time(float(best["elapsed"])), placement]


# ------------------------------------------------------------ input actions

func is_playing() -> bool:
	return state == HostState.PLAYING


func is_gameplay_input_enabled() -> bool:
	## Menus are open outside PLAYING; single-fire input handling defers to
	## the UI then.
	return state == HostState.PLAYING


func action_move(dir: int) -> bool:
	if not is_playing() or core == null:
		return false
	if core.try_move(dir):
		_audio.play_sfx("move")
		return true
	return false


func action_rotate_cw() -> void:
	_rotate(1)


func action_rotate_ccw() -> void:
	_rotate(-1)


func _rotate(dir: int) -> void:
	if is_playing() and core != null and core.rotate(dir):
		_audio.play_sfx("rotate")


func action_soft_drop(active: bool) -> void:
	# Edge detection lives here as well as in the input controller so no
	# caller can produce a sound per held frame.
	var was: bool = _solo_soft_drop_active
	_solo_soft_drop_active = active
	if not (is_playing() and core != null):
		return
	core.set_soft_drop(active)
	if active and not was:
		_audio.play_sfx("soft_drop")


func action_hard_drop() -> void:
	if is_playing() and core != null:
		if core.hard_drop():
			_audio.play_sfx("hard_drop")
		# The drop sound covers the lock; clear/T-spin sounds still fire.
		_check_solo_audio_events(true)


func action_hold() -> void:
	if is_playing() and core != null and core.hold():
		_audio.play_sfx("hold")


# Coop variants route the same logical actions per player index. They are
# no-ops outside an active coop run so menus stay safe. Online, a CLIENT
# only ever acts on its OWN slot and converts local edges into intents for
# the host; a HOST only acts on its own slot locally (remote slots act
# through online_apply_intent after validation).

func _online_slot_guard(player: int) -> bool:
	## True when local input may not drive this slot online.
	return online_role != OnlineRole.LOCAL and player != _online_slot


func _online_submit(player: int, action: String, arg: int) -> bool:
	## Route one local edge to the host as an intent. Returns true when the
	## caller should stop here (submission replaced local application).
	if online_role != OnlineRole.CLIENT or _online_service == null:
		return false
	_online_service.submit_intent(player, action, arg)
	return true


func action_coop_move(player: int, dir: int) -> bool:
	if not is_playing() or coop == null:
		return false
	if _online_slot_guard(player):
		return false
	if _online_submit(player, "move", dir):
		_audio.play_sfx("move")
		# False stops the ARR-0 slam loop: clients may not know the wall, so
		# DAS repeats send one intent per ARR tick and the host slides.
		return false
	if coop.try_move(player, dir):
		_audio.play_sfx("move")
		return true
	return false


func action_coop_rotate(player: int, dir: int) -> void:
	if not is_playing() or coop == null:
		return
	if _online_slot_guard(player):
		return
	if _online_submit(player, "rotate", dir):
		_audio.play_sfx("rotate")
		return
	if coop.rotate(player, dir):
		_audio.play_sfx("rotate")


func action_coop_soft_drop(player: int, active: bool) -> void:
	var was := false
	if player >= 0 and player < _coop_soft_drop_active.size():
		was = _coop_soft_drop_active[player]
		_coop_soft_drop_active[player] = active
	if not (is_playing() and coop != null):
		return
	if _online_slot_guard(player):
		return
	if _online_submit(player, "soft_drop", 1 if active else 0):
		if active and not was:
			_audio.play_sfx("soft_drop")
		return
	coop.set_soft_drop(player, active)
	if active and not was:
		_audio.play_sfx("soft_drop")


func action_coop_hard_drop(player: int) -> void:
	if not (is_playing() and coop != null):
		return
	if _online_slot_guard(player):
		return
	if _online_submit(player, "hard_drop", 0):
		_audio.play_sfx("hard_drop")
		return
	if coop.hard_drop(player):
		_audio.play_sfx("hard_drop")
	_check_coop_audio_events(true)


func action_coop_hold(player: int) -> void:
	if not (is_playing() and coop != null):
		return
	if _online_slot_guard(player):
		return
	if _online_submit(player, "hold", 0):
		_audio.play_sfx("hold")
		return
	if coop.hold(player):
		_audio.play_sfx("hold")


func input_coop_player_count() -> int:
	# Test/inspection helper: how many players the input layer is polling.
	return _input._coop_player_count


func input_solo_profile_id() -> String:
	# Test/inspection helper: which profile the input layer polls for solo.
	return _input._solo_profile_id


func input_solo_device() -> int:
	# Test/inspection helper: which device is routed to the solo profile.
	return _input._solo_device


func input_solo_bindings() -> Dictionary:
	# Test/inspection helper: the cached controller bindings for solo.
	return _input._solo_bindings


func input_coop_device_for(player: int) -> int:
	# Test/inspection helper: the device assigned to a coop slot.
	return _input.coop_device_for(player)


func input_coop_profile_bindings(player: int) -> Dictionary:
	# Test/inspection helper: the controller bindings polled for a slot.
	return _input.coop_profile_bindings(player)


func input_process_once(delta: float) -> void:
	# Test/inspection helper: drive one input polling step headlessly.
	_input._process(delta)


func action_pause() -> void:
	match state:
		HostState.PLAYING:
			_audio.play_sfx("pause")
			state = HostState.PAUSED
			_pause_menu.show_pause()
			_audio.set_music_paused(true)
		HostState.PAUSED:
			state = HostState.PLAYING
			_pause_menu.close()
			_audio.set_music_paused(false)
		HostState.GAME_OVER, HostState.FINISHED:
			_show_main_menu()


func action_restart() -> void:
	if online_role != OnlineRole.LOCAL:
		# Online: the shared restart key never resets a networked round.
		return
	if coop != null and state in [HostState.PLAYING, HostState.PAUSED, HostState.GAME_OVER, HostState.FINISHED]:
		_start_coop(_coop_assignments, coop.mode)
	elif core != null and state in [HostState.PLAYING, HostState.PAUSED, HostState.GAME_OVER, HostState.FINISHED]:
		var solo_profile := String(_run_profile_ids[0]) if not _run_profile_ids.is_empty() else ""
		_start_game(core.mode, solo_profile)


func auto_pause_on_focus_loss() -> void:
	if state == HostState.PLAYING:
		action_pause()


# ------------------------------------------------------------------- online
# Online co-op over EOS P2P (see scripts/online/). GameHost remains the
# orchestration boundary: UI calls the cmd_* commands below, which delegate
# to the OnlineService autoload; the service calls back into the hooks in
# this section. The authoritative CoopGame lives on the host only - clients
# hold snapshot-driven twins - and all traffic flows through MultiplayerPeer
# RPCs, never raw EOS packets.

func online_is_local() -> bool:
	return online_role == OnlineRole.LOCAL


func online_is_host() -> bool:
	return online_role == OnlineRole.HOST


## The OnlineService autoload reference (read access for UI polling).
func online_service() -> Node:
	return _online_service


func cmd_open_online() -> void:
	if state != HostState.MAIN_MENU or _online_service == null:
		return
	_menu.close()
	_online_menu.open_entry()


func cmd_online_back() -> void:
	## Entry screen back: leave any lingering session, then main menu.
	if _online_service != null and _online_service.is_in_session():
		_online_service.leave_session()
	_online_menu.close()
	_show_main_menu()


func cmd_online_create() -> void:
	## Host path: create the lobby. The online menu polls the service
	## status/state while this runs.
	if _online_service == null:
		return
	await _online_service.ensure_ready()
	if _online_service.state == _online_service.State.READY:
		_online_service.create_lobby()
	else:
		_online_menu.refresh_status()


func cmd_online_browse() -> void:
	if _online_service == null:
		return
	await _online_service.ensure_ready()
	_online_service.browse()


func cmd_online_join_address_open() -> void:
	## Entry screen: open the direct id/address join field.
	_online_menu.open_address()


func cmd_online_join_address(address: String) -> void:
	## Address/lobby-id field submit. Empty input re-opens the entry screen.
	if _online_service == null or address.strip_edges().is_empty():
		_online_menu.open_entry()
		return
	await _online_service.ensure_ready()
	_online_service.join_lobby(address)


func cmd_online_browse_back() -> void:
	_online_menu.open_entry()


func cmd_online_toggle_ready() -> void:
	if _online_service == null:
		return
	_online_service.set_ready(not bool(_online_roster_self_ready()))


func _online_roster_self_ready() -> bool:
	if _online_service == null:
		return false
	var mine: int = _online_service.multiplayer.get_unique_id()
	var roster: Array = _online_service.roster
	for entry in roster:
		if int(entry["peer_id"]) == mine:
			return bool(entry["ready"])
	return false


func cmd_online_join_index(index: int) -> void:
	## Join one of the browsed lobbies by list index.
	if _online_service == null:
		return
	var results: Array = _online_service.browse_results
	if index < 0 or index >= results.size():
		return
	var lobby_id := String((results[index] as Dictionary).get("lobby_id", ""))
	if lobby_id.is_empty():
		return
	await _online_service.ensure_ready()
	_online_service.join_lobby(lobby_id)


func cmd_online_leave() -> void:
	## Lobby leave: back to the entry screen (stays signed in).
	if _online_service == null:
		return
	_online_service.leave_session()
	_online_menu.open_entry()


func cmd_online_set_ready(ready: bool) -> void:
	if _online_service != null:
		_online_service.set_ready(ready)


func cmd_online_mode_next() -> void:
	if _online_service != null:
		_online_service.set_mode(_online_mode_after(1))


func cmd_online_mode_prev() -> void:
	if _online_service != null:
		_online_service.set_mode(_online_mode_after(-1))


func _online_mode_after(delta: int) -> int:
	## Cycle the shared lobby mode across the playable co-op modes.
	var modes: Array = [
		ModeRules.Mode.MARATHON,
		ModeRules.Mode.SPRINT,
	]
	var current: int = _online_service.lobby_mode
	var idx := modes.find(current)
	if idx < 0:
		idx = 0
	idx = wrapi(idx + delta, 0, modes.size())
	return int(modes[idx])


func cmd_online_start_round() -> void:
	## Host: start the round for the current lobby roster.
	if _online_service == null:
		return
	if not _online_service.is_in_session():
		return
	_online_service.start_round()


func cmd_online_return_to_lobby() -> void:
	## Host results action: send everyone back to the lobby.
	if _online_service == null:
		return
	_online_service.host_return_to_lobby()


func cmd_online_open_proof() -> void:
	## Debug/editor builds only: native replication proof over the ACTIVE
	## session transport (EOS in production, the ENet harness in dev).
	## Requires a live session - the transport must already be installed.
	if not (OS.is_debug_build() or OS.has_feature("editor")):
		return
	if _online_service == null or not _online_service.is_in_session():
		return
	if _online_proof != null:
		return
	_online_proof = ProofScene.instantiate()
	add_child(_online_proof)
	_online_proof.begin(bool(_online_service.is_host), String(_online_service.session_code()))


func cmd_online_close_proof() -> void:
	if _online_proof != null:
		var proof := _online_proof
		_online_proof = null
		proof.close()


# ------------------------------------------------------- service callbacks

func online_begin_host_match(config: Dictionary) -> void:
	## Host: build the authoritative run for the roster in `config`.
	_begin_online_run(config, OnlineRole.HOST, 0)


func online_begin_client_match(config: Dictionary) -> void:
	## Client: build the snapshot-driven twin run; own slot comes from the
	## host's roster assignment.
	_begin_online_run(config, OnlineRole.CLIENT, int(config.get("own_slot", -1)))


func _begin_online_run(config: Dictionary, role: int, own_slot: int) -> void:
	var mode := int(config.get("mode", ModeRules.Mode.MARATHON))
	var seed := int(config.get("seed", 0))
	var player_count := clampi(int(config.get("player_count", 1)), 1, 4)
	if own_slot < 0 or own_slot >= player_count:
		push_error("host: online run rejected - own slot %d invalid for %d players" % [own_slot, player_count])
		return
	core = null
	_teardown_coop_scene()
	coop = CoopGame.new(player_count, mode, seed)
	state = HostState.PLAYING
	online_role = role
	_online_slot = own_slot
	_accumulator = 0.0
	_reset_coop_audio_edges()
	_hud.set_combo("")
	_hud.set_event("", 0)
	_coop_assignments = _online_roster_assignments(config.get("roster", []))
	# Online players carry anonymous EOS identities (Device ID logins are
	# not local profiles): online runs never append result records.
	_run_profile_ids = []
	_run_result_recorded = true
	var own_profile := String(settings.active_profile_id) if settings != null else ""
	_input.begin_online(own_slot, player_count, own_profile, _first_connected_device())
	_build_coop_scene()
	_menu.close()
	_coop_setup.close()
	_pause_menu.close()
	_settings_screen.close()
	_profile_screen.close()
	_online_menu.close()
	_audio.set_music_context(false)
	_audio.set_music_active(true)
	_audio.set_music_paused(false)
	_update_presentation()
	if role == OnlineRole.HOST:
		# Authoritative initial state goes out reliably once, immediately.
		_online_signature = _online_state_signature()
		if _online_service != null:
			_online_service.send_snapshot(true)


func _online_roster_assignments(roster) -> Array:
	var out: Array = []
	if roster is Array:
		for entry in roster:
			if entry is Dictionary:
				out.append({
					"profile_id": "",
					"device": -1,
					"name": String((entry as Dictionary).get("name", "")),
					"slot": int((entry as Dictionary).get("slot", out.size())),
				})
	return out


func _online_state_signature() -> int:
	## Cheap structural change detector: phase, last event, and level cover
	## every lock/clear/transition the reliable snapshot stream cares about.
	if coop == null:
		return -1
	var event_id := _event_id(_coop_last_event())
	return hash("%d|%d|%d|%d" % [coop.phase, coop.last_event_player, event_id, coop.level])


func _online_teardown_run() -> void:
	## Drop the run (any role) and clear online bookkeeping.
	online_role = OnlineRole.LOCAL
	_online_slot = -1
	core = null
	coop = null
	_input.end_coop()
	_teardown_coop_scene()
	_run_profile_ids = []
	_run_result_recorded = true
	state = HostState.MAIN_MENU
	_hud.hide_overlay()
	_hud.set_combo("")
	_hud.set_event("", 0)


func online_snapshot() -> Dictionary:
	## Service hook: capture the authoritative state (host only).
	if coop == null:
		return {}
	return coop.to_snapshot()


func online_phase_active() -> bool:
	## Service hook: gate inbound intents to the ACTIVE phase only.
	return coop != null and coop.phase == CoopGame.Phase.ACTIVE and state == HostState.PLAYING


func online_apply_intent(slot: int, action: String, arg: int) -> void:
	## Service hook: apply one fully validated client intent to the
	## authoritative simulation. Sounds play host-side so remote actions
	## are audible like local ones.
	if online_role != OnlineRole.HOST or coop == null:
		return
	if slot < 0 or slot >= coop.player_count:
		return
	match action:
		"move":
			if coop.try_move(slot, arg):
				_audio.play_sfx("move")
		"rotate":
			if coop.rotate(slot, arg):
				_audio.play_sfx("rotate")
		"soft_drop":
			coop.set_soft_drop(slot, arg != 0)
		"hard_drop":
			if coop.hard_drop(slot):
				_audio.play_sfx("hard_drop")
			_check_coop_audio_events(true)
		"hold":
			if coop.hold(slot):
				_audio.play_sfx("hold")


func online_apply_snapshot(snapshot) -> void:
	## Service hook (client): replace the twin simulation's state with the
	## host's snapshot. The normal _sync_display pass renders it read-only.
	if online_role != OnlineRole.CLIENT or coop == null:
		return
	if snapshot is Dictionary:
		coop.apply_snapshot(snapshot)


func online_show_results(result: Dictionary) -> void:
	## Service hook: host broadcast the terminal state - show the results
	## overlay with online items (host drives the return to the lobby).
	if online_role == OnlineRole.LOCAL:
		return
	_online_teardown_run()
	_last_results = {
		"title": String(result.get("title", "GAME OVER")),
		"subtitle": String(result.get("subtitle", "")),
	}
	_menu.show_online_results(
		self,
		String(result.get("title", "GAME OVER")),
		String(result.get("subtitle", ""))
	)
	_update_presentation()


func _finish_online_round(title: String, subtitle: String) -> void:
	## Host: broadcast the final reliable snapshot + result, then show the
	## online results overlay. The service returns itself to LOBBY (ready
	## flags reset) while this screen stays up.
	var result := {"title": title, "subtitle": subtitle}
	_last_results = result
	if _online_service != null:
		_online_service.host_round_finished(result)
	_menu.show_online_results(self, title, subtitle)


func online_return_to_lobby() -> void:
	## Service hook: host sent everyone back to the lobby (host action or
	## client receipt of the return RPC).
	_online_teardown_run()
	_pause_menu.close()
	_settings_screen.close()
	_menu.close()
	_online_menu.open_lobby()
	_audio.set_music_context(true)
	_audio.set_music_active(true)
	_audio.set_music_paused(false)
	_update_presentation()


func online_leave_session(_was_in_match: bool) -> void:
	## Service hook: transport/lobby is gone (leave/kick/disconnect).
	## Menu state is managed by the calling flow.
	_online_teardown_run()
	_settings_screen.close()
	cmd_online_close_proof()


func online_session_error(_text: String) -> void:
	## Service hook: fatal session error (host lost mid-match, kicked).
	## The teardown already happened; surface the status line on the entry
	## screen (the service status carries the actionable message).
	_online_teardown_run()
	_pause_menu.close()
	_settings_screen.close()
	_menu.close()
	_online_menu.open_entry()
	_audio.set_music_context(true)
	_update_presentation()


# ---------------------------------------------------------- gameplay sfx
# Edge-triggered observation of the pure cores: every lock produces a new
# last_event object, and phase/level changes are compared against the
# previous frame, so each sound fires exactly once per event.

func _reset_solo_audio_edges() -> void:
	_solo_event_id = _event_id(core.last_event)
	_solo_prev_phase = core.phase
	_solo_prev_level = core.level
	_solo_soft_drop_active = false


func _reset_coop_audio_edges() -> void:
	_coop_event_id = _event_id(_coop_last_event())
	_coop_event_player = coop.last_event_player
	_coop_prev_phase = coop.phase
	_coop_prev_level = coop.level
	_coop_soft_drop_active = []
	for i in coop.player_count:
		_coop_soft_drop_active.append(false)


func _check_solo_audio_events(suppress_lock: bool = false) -> void:
	if core == null or _audio == null:
		return
	var event = core.last_event
	var event_id := _event_id(event)
	if event != null and event_id != _solo_event_id:
		_solo_event_id = event_id
		_emit_lock_sounds(event, suppress_lock)
	if core.level > _solo_prev_level:
		_audio.play_sfx("level_up")
	_solo_prev_level = core.level
	if core.phase != _solo_prev_phase:
		if core.phase == CoreGame.Phase.GAME_OVER:
			_audio.play_sfx("game_over")
		elif core.phase == CoreGame.Phase.FINISHED:
			_audio.play_sfx("finish")
	_solo_prev_phase = core.phase


func _check_coop_audio_events(suppress_lock: bool = false) -> void:
	if coop == null or _audio == null:
		return
	# Shared results fire once: the last locker's event identifies the
	# whole team's clear, and shared phase/level edges are tracked once.
	var player: int = coop.last_event_player
	if player >= 0:
		var event = coop.players[player].last_event
		var event_id := _event_id(event)
		if event != null and (player != _coop_event_player or event_id != _coop_event_id):
			_coop_event_player = player
			_coop_event_id = event_id
			_emit_lock_sounds(event, suppress_lock)
	if coop.level > _coop_prev_level:
		_audio.play_sfx("level_up")
	_coop_prev_level = coop.level
	if coop.phase != _coop_prev_phase:
		if coop.phase == CoopGame.Phase.GAME_OVER:
			_audio.play_sfx("game_over")
		elif coop.phase == CoopGame.Phase.FINISHED:
			_audio.play_sfx("finish")
	_coop_prev_phase = coop.phase


func _emit_lock_sounds(event, suppress_lock: bool) -> void:
	if event.tspin != Scoring.TSpinGrade.NONE:
		# The T-spin sound covers T-spin locks, including line clears.
		_audio.play_sfx("tspin")
	elif event.lines >= 1:
		_audio.play_sfx("line_clear")
	elif not suppress_lock:
		_audio.play_sfx("lock")


func _coop_last_event():
	if coop == null or coop.last_event_player < 0:
		return null
	return coop.players[coop.last_event_player].last_event


static func _event_id(event) -> int:
	if event == null:
		return 0
	return event.get_instance_id()
