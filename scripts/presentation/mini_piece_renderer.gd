extends Node2D
## Draws a single small tetromino (hold slot or one next-preview).
## Colors come from the resolved theme tokens (piece colors are
## contrast-validated per piece) and media (per-piece skins, dither).
## Dither input is the piece-local cell position and the piece kind:
## stable across frames, so previews never flicker. Previews receive
## dither but stay outside the playfield bloom by design.

const TetrominoData = preload("res://scripts/core/tetromino_data.gd")
const ThemeProfile = preload("res://scripts/ui/theme_profile.gd")
const CellDither = preload("res://scripts/presentation/cell_dither.gd")

const CELL: float = 20.0
const BOX: float = 96.0

const KIND_LETTERS := ThemeProfile.KIND_LETTERS

var piece_kind: int = TetrominoData.EMPTY
var dimmed: bool = false
var _piece_colors: Dictionary = ThemeProfile.piece_colors(ThemeProfile.default_tokens())
var _skins: Dictionary = {}
var _dither := "none"
var _dither_strength := 0.0


## Push refreshed theme tokens and media from the host and redraw.
func apply_theme(_tokens: Dictionary, media: Dictionary) -> void:
	_piece_colors = ThemeProfile.piece_colors(_tokens)
	_skins = media.get("skins", {})
	_dither = media.get("dither", "none")
	_dither_strength = media.get("dither_strength", 0.0)
	queue_redraw()


func set_piece(kind: int, dim: bool = false) -> void:
	if piece_kind == kind and dimmed == dim:
		return
	piece_kind = kind
	dimmed = dim
	queue_redraw()


func _draw() -> void:
	if piece_kind == TetrominoData.EMPTY:
		return
	var cells: Array = TetrominoData.cells(piece_kind, 0)
	var min_x: int = 3
	var max_x: int = -1
	var min_y: int = 3
	var max_y: int = -1
	for c in cells:
		min_x = mini(min_x, c.x)
		max_x = maxi(max_x, c.x)
		min_y = mini(min_y, c.y)
		max_y = maxi(max_y, c.y)
	var piece_w: float = (max_x - min_x + 1) * CELL
	var piece_h: float = (max_y - min_y + 1) * CELL
	var origin := Vector2((BOX - piece_w) * 0.5 - min_x * CELL, (BOX - piece_h) * 0.5 - min_y * CELL)
	var color: Color = _piece_colors[KIND_LETTERS[piece_kind]]
	if dimmed:
		color = Color(color, 0.35)
	for c in cells:
		var rect := Rect2(origin.x + c.x * CELL, origin.y + c.y * CELL, CELL, CELL)
		_draw_themed_cell(rect, c, piece_kind, color)


## One solid preview cell: the piece skin texture when the theme provides
## a valid one (dimmed slots draw the skin at the dimmed alpha), else the
## piece color; the shared dither ink overlay between the fill and the
## border.
func _draw_themed_cell(rect: Rect2, cell: Vector2i, kind: int, base: Color) -> void:
	var letter: String = KIND_LETTERS[kind]
	var skin: Texture2D = _skins.get(letter)
	if skin != null:
		draw_texture_rect(skin, rect, false, Color(1.0, 1.0, 1.0, base.a))
	else:
		draw_rect(rect, base)
	CellDither.draw(self, rect, cell, kind, _dither, _dither_strength, base.a)
	draw_rect(rect, Color(0.0, 0.0, 0.0, 0.18), false, 2.0)
