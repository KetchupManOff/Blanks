extends Node2D
## Draws the shared coop playfield: locked cells, every player's active and
## ghost pieces, per-section ownership tints, section boundaries, and the
## line-clear flash. Cell size and position are set by the host from the
## player count. Pure view: reads session state, never mutates it. Colors
## come from the resolved theme tokens (piece colors contrast-validated
## per piece) and media (per-piece skins, dither). Ghost pieces stay
## color-only; skins and dither apply to solid cells only.
##
## Online clients render a snapshot-driven twin: the host pushes render
## interpolation samples (previous/current piece positions plus receive
## timestamps) after every applied snapshot, and the active-piece position
## and flash clock smoothly catch up between the two samples. Everything
## else - locks, clears, geometry, gameplay decisions - stays snapped to
## the current authoritative state, and local runs draw the live
## simulation directly (no samples).

const TetrominoData = preload("res://scripts/core/tetromino_data.gd")
const ThemeProfile = preload("res://scripts/ui/theme_profile.gd")
const CellDither = preload("res://scripts/presentation/cell_dither.gd")

const SECTION_WIDTH: int = 10

const KIND_LETTERS := ThemeProfile.KIND_LETTERS

var session: RefCounted = null
var cell: float = 28.0
var _hidden_rows: int = 2
## Latest render interpolation sample pushed by the host (online clients
## only): {"t0", "t1" (msec), "snap_all", "prev"/"cur" (per-slot piece
## samples), "elapsed_prev"/"elapsed_cur"}. Empty = draw the live state.
var interpolation: Dictionary = {}

var _tokens: Dictionary = ThemeProfile.default_tokens()
var _piece_colors: Dictionary = ThemeProfile.piece_colors(_tokens)
var _skins: Dictionary = {}
var _dither := "none"
var _dither_strength := 0.0
var _player_accents: Array = [
	ThemeProfile.DEFAULT_TOKENS["players.p1"],
	ThemeProfile.DEFAULT_TOKENS["players.p2"],
	ThemeProfile.DEFAULT_TOKENS["players.p3"],
	ThemeProfile.DEFAULT_TOKENS["players.p4"],
]


## Push refreshed theme tokens and media from the host and redraw.
func apply_theme(tokens: Dictionary, media: Dictionary) -> void:
	_tokens = tokens
	_piece_colors = ThemeProfile.piece_colors(_tokens)
	_skins = media.get("skins", {})
	_dither = media.get("dither", "none")
	_dither_strength = media.get("dither_strength", 0.0)
	_player_accents = [
		tokens["players.p1"], tokens["players.p2"], tokens["players.p3"], tokens["players.p4"],
	]
	queue_redraw()


func _draw() -> void:
	if session == null:
		return
	var width: int = session.board.WIDTH
	var height: int = session.board.HEIGHT
	_hidden_rows = session.board.HIDDEN_ROWS
	var count: int = session.player_count
	var bg: Color = _tokens["board.bg"]
	var peek: Color = _tokens["board.peek"]
	var grid: Color = _tokens["board.grid"]
	var border: Color = _tokens["board.border"]
	var ghost_fill: Color = _tokens["board.ghost"]
	var ghost_line: Color = _tokens["board.ghost_line"]
	var flash: Color = _tokens["board.flash"]
	var section_line: Color = _tokens["board.section_line"]
	var tint_alpha: float = _tokens["board.section_tint_alpha"]

	# Backdrop behind the hidden spawn rows so pieces above the field read well.
	draw_rect(Rect2(0.0, 0.0, width * cell, _hidden_rows * cell), peek)
	# Visible playfield panel.
	var panel := Rect2(0.0, _hidden_rows * cell, width * cell, (height - _hidden_rows) * cell)
	draw_rect(panel, bg)

	# Subtle per-section ownership tint.
	for i in count:
		var tint := Rect2(
			i * SECTION_WIDTH * cell,
			_hidden_rows * cell,
			SECTION_WIDTH * cell,
			(height - _hidden_rows) * cell
		)
		draw_rect(tint, Color(_player_accents[i % _player_accents.size()], tint_alpha))

	# Subtle grid inside the visible field.
	for x in range(1, width):
		var gx: float = x * cell
		draw_line(Vector2(gx, panel.position.y), Vector2(gx, panel.position.y + panel.size.y), grid)
	for y in range(1, height - _hidden_rows):
		var gy: float = (_hidden_rows + y) * cell
		draw_line(Vector2(0.0, gy), Vector2(width * cell, gy), grid)
	draw_rect(panel, border, false, 2.0)

	# Section boundaries between players.
	for i in range(1, count):
		var bx: float = i * SECTION_WIDTH * cell
		draw_line(Vector2(bx, 0.0), Vector2(bx, height * cell), section_line, 2.0)

	# Locked cells.
	var clearing: Array[int] = session.clearing_rows()
	for y in height:
		for x in width:
			var value: int = session.board.get_cell(x, y)
			if value == TetrominoData.EMPTY:
				continue
			if clearing.has(y):
				continue
			_draw_themed_cell(Rect2(x * cell, y * cell, cell, cell), Vector2i(x, y), value)

	# Line-clear flash across the whole shared board (the flash clock
	# interpolates between authoritative samples on clients).
	var flash_elapsed := _interp_elapsed(session.elapsed)
	for y in clearing:
		var alpha: float = 0.55 + 0.45 * absf(sin(flash_elapsed * 24.0))
		draw_rect(Rect2(0.0, y * cell, width * cell, cell), Color(flash, alpha))

	# Ghost and active piece of every player with a piece in play.
	if session.phase == session.Phase.ACTIVE:
		for p in session.players:
			if p.piece_kind == TetrominoData.EMPTY:
				continue
			for c in session.ghost_cells(p.index):
				if c.y >= 0:
					draw_rect(Rect2(c.x * cell, c.y * cell, cell, cell), ghost_fill)
					draw_rect(Rect2(c.x * cell, c.y * cell, cell, cell), ghost_line, false, 2.0)
			# The active piece interpolates between authoritative samples;
			# the ghost stays snapped to its target position.
			var offset := _interp_offset(p.index) * cell
			for c in session.current_cells(p.index):
				if c.y >= 0:
					_draw_themed_cell(Rect2(c.x * cell + offset.x, c.y * cell + offset.y, cell, cell), c, p.piece_kind)


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


## Float-cell draw offset for one player's active piece: interpolated
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
## one, else the contrast-validated piece color; the shared dither ink
## overlay between the fill and the border; the border always last.
func _draw_themed_cell(rect: Rect2, cell_pos: Vector2i, kind: int) -> void:
	var letter: String = KIND_LETTERS[kind]
	var base: Color = _piece_colors[letter]
	var skin: Texture2D = _skins.get(letter)
	if skin != null:
		draw_texture_rect(skin, rect, false, Color(1.0, 1.0, 1.0, base.a))
	else:
		draw_rect(rect, base)
	CellDither.draw(self, rect, cell_pos, kind, _dither, _dither_strength, base.a)
	draw_rect(rect, Color(0.0, 0.0, 0.0, 0.18), false, 2.0)
