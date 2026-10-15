extends Node2D
## Draws one competitive player's independent board: locked cells (including
## versus garbage), active piece, ghost, line-clear flash, the hidden spawn
## rows peeking above the visible panel, and an elimination dim. Cell size
## is set by the host from the player count and re-scaled as Tower boards
## grow. Pure view: reads the match state for one player index, never
## mutates it. Colors come from the resolved theme tokens (piece colors
## contrast-validated per piece) and media (per-piece skins, dither). Ghost
## pieces stay color-only; skins and dither apply to solid cells only.
##
## Online clients render a snapshot-driven twin: the host pushes render
## interpolation samples after every applied snapshot and the active-piece
## position and flash clock catch up smoothly between the two samples;
## everything else stays snapped to the current authoritative state, and
## local runs draw the live simulation directly.

const TetrominoData = preload("res://scripts/core/tetromino_data.gd")
const ThemeProfile = preload("res://scripts/ui/theme_profile.gd")
const CellDither = preload("res://scripts/presentation/cell_dither.gd")

## Garbage rows carry no tetromino identity: a neutral gray that reads on
## every theme without joining the piece palette.
const GARBAGE_COLOR := Color(0.55, 0.56, 0.60)

const KIND_LETTERS := ThemeProfile.KIND_LETTERS

var session: RefCounted = null
var player_index: int = 0
var cell: float = 28.0
## Latest render interpolation sample pushed by the host (online clients
## only); see coop_board_renderer.gd for the shape. Empty = live drawing.
var interpolation: Dictionary = {}

var _tokens: Dictionary = ThemeProfile.default_tokens()
var _piece_colors: Dictionary = ThemeProfile.piece_colors(_tokens)
var _accent: Color = ThemeProfile.DEFAULT_TOKENS["players.p1"]
var _skins: Dictionary = {}
var _dither := "none"
var _dither_strength := 0.0


## Push refreshed theme tokens and media from the host and redraw.
func apply_theme(tokens: Dictionary, media: Dictionary, accent: Color) -> void:
	_tokens = tokens
	_piece_colors = ThemeProfile.piece_colors(_tokens)
	_skins = media.get("skins", {})
	_dither = media.get("dither", "none")
	_dither_strength = media.get("dither_strength", 0.0)
	_accent = accent
	queue_redraw()


func _draw() -> void:
	if session == null or player_index >= session.player_count:
		return
	var player = session.players[player_index]
	var board = player.board
	var width: int = board.WIDTH
	var height: int = board.HEIGHT
	var hidden_rows: int = board.HIDDEN_ROWS
	var bg: Color = _tokens["board.bg"]
	var peek: Color = _tokens["board.peek"]
	var grid: Color = _tokens["board.grid"]
	var ghost_fill: Color = _tokens["board.ghost"]
	var ghost_line: Color = _tokens["board.ghost_line"]
	var flash: Color = _tokens["board.flash"]

	# Backdrop behind the hidden spawn rows so pieces above the field read well.
	draw_rect(Rect2(0.0, 0.0, width * cell, hidden_rows * cell), peek)
	# Visible playfield panel; Tower growth lengthens it dynamically.
	var panel := Rect2(0.0, hidden_rows * cell, width * cell, (height - hidden_rows) * cell)
	draw_rect(panel, bg)

	# Subtle grid inside the visible field.
	for x in range(1, width):
		var gx: float = x * cell
		draw_line(Vector2(gx, panel.position.y), Vector2(gx, panel.position.y + panel.size.y), grid)
	for y in range(1, height - hidden_rows):
		var gy: float = (hidden_rows + y) * cell
		draw_line(Vector2(0.0, gy), Vector2(width * cell, gy), grid)
	draw_rect(panel, _accent, false, 2.0)

	# Locked cells.
	var clearing: Array[int] = session.clearing_rows(player_index)
	for y in height:
		for x in width:
			var value: int = board.get_cell(x, y)
			if value == TetrominoData.EMPTY:
				continue
			if clearing.has(y):
				continue
			_draw_cell(Rect2(x * cell, y * cell, cell, cell), Vector2i(x, y), value)

	# Line-clear flash (the flash clock interpolates between
	# authoritative samples on clients).
	var flash_elapsed := _interp_elapsed(session.elapsed)
	for y in clearing:
		var alpha: float = 0.55 + 0.45 * absf(sin(flash_elapsed * 24.0))
		draw_rect(Rect2(0.0, y * cell, width * cell, cell), Color(flash, alpha))

	# Ghost and active piece.
	if session.phase == session.Phase.ACTIVE and not player.eliminated:
		for c in session.ghost_cells(player_index):
			if c.y >= 0:
				draw_rect(Rect2(c.x * cell, c.y * cell, cell, cell), ghost_fill)
				draw_rect(Rect2(c.x * cell, c.y * cell, cell, cell), ghost_line, false, 2.0)
		# The active piece interpolates between authoritative samples; the
		# ghost stays snapped to its target position.
		var offset := _interp_offset(player_index) * cell
		for c in session.current_cells(player_index):
			if c.y >= 0:
				_draw_cell(Rect2(c.x * cell + offset.x, c.y * cell + offset.y, cell, cell), c, player.piece_kind)

	# Eliminated boards dim under the surviving play.
	if player.eliminated:
		draw_rect(Rect2(0.0, 0.0, width * cell, height * cell), Color(0.0, 0.0, 0.0, 0.55))


## Render alpha in [0,1]: how far the visual clock moved from the previous
## toward the current authoritative sample (1.0 = fully caught up).
func _interp_alpha() -> float:
	if interpolation.is_empty():
		return 1.0
	var t0 := float(interpolation.get("t0", 0.0))
	var t1 := float(interpolation.get("t1", t0))
	if t1 <= t0:
		return 1.0
	return clampf((float(Time.get_ticks_msec()) - t0) / (t1 - t0), 0.0, 1.0)


## Float-cell draw offset for this board's active piece: interpolated
## between the previous and current authoritative samples while the piece
## identity (kind/state) is unchanged; snapped to zero on any structural
## change, rotation, new piece, or missing sample.
func _interp_offset(player: int) -> Vector2:
	if interpolation.is_empty() or bool(interpolation.get("snap_all", true)):
		return Vector2.ZERO
	var alpha := _interp_alpha()
	if alpha >= 1.0:
		return Vector2.ZERO
	var prev: Dictionary = interpolation.get("prev", {})
	var cur: Dictionary = interpolation.get("cur", {})
	if not prev.has(player) or not cur.has(player):
		return Vector2.ZERO
	var a: Dictionary = prev[player]
	var b: Dictionary = cur[player]
	if a.get("kind") != b.get("kind") or a.get("state") != b.get("state"):
		return Vector2.ZERO
	var dx := (float(a.get("x", 0.0)) - float(b.get("x", 0.0))) * (1.0 - alpha)
	var dy := (float(a.get("y", 0.0)) - float(b.get("y", 0.0))) * (1.0 - alpha)
	return Vector2(dx, dy)


## Authoritative elapsed time for the flash clock: interpolated between
## the previous and current samples so the pulse stays smooth across
## snapshot steps.
func _interp_elapsed(live_elapsed: float) -> float:
	if interpolation.is_empty() or bool(interpolation.get("snap_all", true)):
		return live_elapsed
	var alpha := _interp_alpha()
	var a := float(interpolation.get("elapsed_prev", live_elapsed))
	var b := float(interpolation.get("elapsed_cur", live_elapsed))
	return lerpf(a, b, alpha)


## One solid cell: the piece skin texture when the theme provides a valid
## one, else the contrast-validated piece color (garbage keeps its neutral
## gray); the shared dither ink overlay between the fill and the border;
## the border always last.
func _draw_cell(rect: Rect2, cell_pos: Vector2i, kind: int) -> void:
	var base: Color
	var skin: Texture2D
	if kind == TetrominoData.GARBAGE:
		base = GARBAGE_COLOR
	else:
		var letter: String = KIND_LETTERS[kind]
		base = _piece_colors[letter]
		skin = _skins.get(letter)
	if skin != null:
		draw_texture_rect(skin, rect, false, Color(1.0, 1.0, 1.0, base.a))
	else:
		draw_rect(rect, base)
	CellDither.draw(self, rect, cell_pos, kind, _dither, _dither_strength, base.a)
	draw_rect(rect, Color(0.0, 0.0, 0.0, 0.18), false, 2.0)
