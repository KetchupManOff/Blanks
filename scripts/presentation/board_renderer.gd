extends Node2D
## Draws the playfield: locked cells, active piece, ghost, line-clear flash,
## and the hidden spawn rows peeking above the visible panel.
## Pure view: reads core state, never mutates it. Colors come from the
## resolved theme tokens (piece colors contrast-validated per piece) and
## media (per-piece skins, dither). Ghost pieces stay color-only; skins
## and dither apply to solid cells only.

const TetrominoData = preload("res://scripts/core/tetromino_data.gd")
const PlayConfig = preload("res://scripts/core/constants.gd")
const ThemeProfile = preload("res://scripts/ui/theme_profile.gd")
const CellDither = preload("res://scripts/presentation/cell_dither.gd")

const CELL: float = 32.0

const KIND_LETTERS := ThemeProfile.KIND_LETTERS

var core: RefCounted = null
var _hidden_rows: int = 2

var _tokens: Dictionary = ThemeProfile.default_tokens()
var _piece_colors: Dictionary = ThemeProfile.piece_colors(_tokens)
var _skins: Dictionary = {}
var _dither := "none"
var _dither_strength := 0.0


## Push refreshed theme tokens and media from the host and redraw.
func apply_theme(tokens: Dictionary, media: Dictionary) -> void:
	_tokens = tokens
	_piece_colors = ThemeProfile.piece_colors(_tokens)
	_skins = media.get("skins", {})
	_dither = media.get("dither", "none")
	_dither_strength = media.get("dither_strength", 0.0)
	queue_redraw()


func _draw() -> void:
	if core == null:
		return
	var width: int = core.board.WIDTH
	var height: int = core.board.HEIGHT
	_hidden_rows = core.board.HIDDEN_ROWS
	var bg: Color = _tokens["board.bg"]
	var peek: Color = _tokens["board.peek"]
	var grid: Color = _tokens["board.grid"]
	var border: Color = _tokens["board.border"]
	var ghost_fill: Color = _tokens["board.ghost"]
	var ghost_line: Color = _tokens["board.ghost_line"]
	var flash: Color = _tokens["board.flash"]

	# Backdrop behind the hidden spawn rows so pieces above the field read well.
	draw_rect(Rect2(0.0, 0.0, width * CELL, _hidden_rows * CELL), peek)
	# Visible playfield panel.
	var panel := Rect2(0.0, _hidden_rows * CELL, width * CELL, (height - _hidden_rows) * CELL)
	draw_rect(panel, bg)

	# Subtle grid inside the visible field.
	for x in range(1, width):
		var gx: float = x * CELL
		draw_line(Vector2(gx, panel.position.y), Vector2(gx, panel.position.y + panel.size.y), grid)
	for y in range(1, height - _hidden_rows):
		var gy: float = (_hidden_rows + y) * CELL
		draw_line(Vector2(0.0, gy), Vector2(width * CELL, gy), grid)
	draw_rect(panel, border, false, 2.0)

	# Locked cells.
	var clearing: Array[int] = core.clearing_rows()
	for y in height:
		for x in width:
			var value: int = core.board.get_cell(x, y)
			if value == TetrominoData.EMPTY:
				continue
			if clearing.has(y):
				continue
			_draw_themed_cell(Rect2(x * CELL, y * CELL, CELL, CELL), Vector2i(x, y), value)

	# Line-clear flash.
	for y in clearing:
		var alpha: float = 0.55 + 0.45 * absf(sin(core.elapsed * 24.0))
		draw_rect(Rect2(0.0, y * CELL, width * CELL, CELL), Color(flash, alpha))

	# Ghost and active piece.
	if core.phase == core.Phase.ACTIVE:
		for c in core.ghost_cells():
			if c.y >= 0:
				draw_rect(Rect2(c.x * CELL, c.y * CELL, CELL, CELL), ghost_fill)
				draw_rect(Rect2(c.x * CELL, c.y * CELL, CELL, CELL), ghost_line, false, 2.0)
		for c in core.current_cells():
			if c.y >= 0:
				_draw_themed_cell(Rect2(c.x * CELL, c.y * CELL, CELL, CELL), c, core.piece_kind)


## One solid cell: the piece skin texture when the theme provides a valid
## one, else the contrast-validated piece color; the shared dither ink
## overlay between the fill and the border; the border always last.
func _draw_themed_cell(rect: Rect2, cell: Vector2i, kind: int) -> void:
	var letter: String = KIND_LETTERS[kind]
	var base: Color = _piece_colors[letter]
	var skin: Texture2D = _skins.get(letter)
	if skin != null:
		draw_texture_rect(skin, rect, false, Color(1.0, 1.0, 1.0, base.a))
	else:
		draw_rect(rect, base)
	CellDither.draw(self, rect, cell, kind, _dither, _dither_strength, base.a)
	draw_rect(rect, Color(0.0, 0.0, 0.0, 0.18), false, 2.0)
