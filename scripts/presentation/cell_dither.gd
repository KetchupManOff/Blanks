extends RefCounted
## Procedural 16-bit-inspired piece-cell dither patterns shared by the
## board, co-op board, and preview renderers. Every pattern is a pure
## deterministic function of (mode, piece kind, local sample indices), so
## dithered pieces never flicker between frames. The shared draw paints a
## translucent dark ink overlay over each cell, shading color fills and
## skin textures alike, and snaps the pattern grid to integer pixel edges
## for every board cell size.

const MODES := ["none", "bayer", "hatch", "scanline", "stipple"]

## Logical pattern samples per cell edge: an 8x8 grid per cell gives a
## finer, more detailed texture than the old 4x4 blocks on every cell
## size (32 solo, 28/26/20 co-op and previews).
const GRID := 8
const SAMPLES := GRID * GRID

## Hatch rank levels: two "/" strokes lead, then two "\" strokes complete
## the cross-hatch; rank HATCH_RANKS itself never darkens.
const HATCH_RANKS := 4

## Ink overlay depth at full strength, matching the retired 60-percent
## darkened shade; `base_alpha` (the cell's resolved alpha) scales it so
## dimmed previews shade consistently.
const INK := Color(0.0, 0.0, 0.0)
const INK_ALPHA_MAX := 0.6

## Standard 8x8 ordered Bayer threshold matrix (ranks 0-63): classic
## console palette blending with smooth, regular density ramps. Rows are
## grid j, columns are grid i.
const BAYER8 := [
	[0, 32, 8, 40, 2, 34, 10, 42],
	[48, 16, 56, 24, 50, 18, 58, 26],
	[12, 44, 4, 36, 14, 46, 6, 38],
	[60, 28, 52, 20, 62, 30, 54, 22],
	[3, 35, 11, 43, 1, 33, 9, 41],
	[51, 19, 59, 27, 49, 17, 57, 25],
	[15, 47, 7, 39, 13, 45, 5, 37],
	[63, 31, 55, 23, 61, 29, 53, 21],
]

## Clustered-dot stipple threshold map (ranks 0-63): 2x2-sample dot
## clusters ordered by an embedded 4x4 Bayer sequence, so dots appear as
## spaced clusters instead of the retired hash noise. Rows are grid j,
## columns are grid i.
const STIPPLE8 := [
	[0, 2, 32, 34, 8, 10, 40, 42],
	[3, 1, 35, 33, 11, 9, 43, 41],
	[48, 50, 16, 18, 56, 58, 24, 26],
	[51, 49, 19, 17, 59, 57, 27, 25],
	[12, 14, 44, 46, 4, 6, 36, 38],
	[15, 13, 47, 45, 7, 5, 39, 37],
	[60, 62, 28, 30, 52, 54, 20, 22],
	[63, 61, 31, 29, 55, 53, 23, 21],
]


## Stable per-piece stipple phase: each tetromino kind shifts the map
## lookup by a fixed offset, so piece types differ without any
## per-frame randomness and every kind keeps a deterministic lattice.
static func stipple_phase(kind: int) -> Vector2i:
	return Vector2i(posmod(kind * 3, GRID), posmod(kind * 5, GRID))


## Ordered rank of local sample (i, j) for `mode` and piece `kind`: lower
## ranks darken first as strength rises. Hatch non-stroke samples return
## HATCH_RANKS, the never-dark rank; unknown modes never darken.
static func sample_rank(mode: String, kind: int, i: int, j: int) -> int:
	match mode:
		"bayer":
			return BAYER8[posmod(j, GRID)][posmod(i, GRID)]
		"stipple":
			var phase := stipple_phase(kind)
			return STIPPLE8[posmod(j + phase.y, GRID)][posmod(i + phase.x, GRID)]
		"hatch":
			# Ranked diagonal/cross-hatch strokes with a board-stable
			# phase: two "/" strokes lead (ranks 0-1), then two "\"
			# strokes complete the cross-hatch (ranks 2-3), so strength
			# ramps from sparse diagonal shading to the full cross-hatch.
			# Lines continue across cell boundaries because the stroke
			# phases tile with the local grid.
			var slash := posmod(i + j, GRID)
			var back := posmod(i - j, GRID)
			if slash == 0:
				return 0
			if slash == 4:
				return 1
			if back == 0:
				return 2
			if back == 4:
				return 3
			return HATCH_RANKS
	return HATCH_RANKS


## True when local sample (i, j) darkens for `mode` at `strength`: ranked
## modes compare against a strength-scaled ordered threshold, scanlines
## shade alternating grid rows with a fixed band parity.
static func sample_dark(mode: String, kind: int, i: int, j: int, strength: float) -> bool:
	match mode:
		"scanline":
			return posmod(j, 2) == 0
		"bayer", "stipple", "hatch":
			var ranks: int = HATCH_RANKS if mode == "hatch" else SAMPLES
			return sample_rank(mode, kind, i, j) < clampf(strength, 0.0, 1.0) * ranks
	return false


## Ink overlay alpha for `mode` at `strength`: 0.0 stays visually off and
## 1.0 reaches the full designed treatment. Ranked modes ramp ordered
## coverage and ink opacity together; scanlines ramp only their band
## opacity.
static func ink_alpha(mode: String, strength: float) -> float:
	if not MODES.has(mode) or mode == "none":
		return 0.0
	return INK_ALPHA_MAX * clampf(strength, 0.0, 1.0)


## Paints the dither overlay for one solid cell into `target`: the 8x8
## pattern grid snaps to integer pixel edges for the cell's size, keeping
## the texture crisp at 32/28/26/20 px with no fractional raster seams.
## `cell` and `kind` are the stable inputs keeping the pattern
## deterministic; `base_alpha` (the cell's resolved alpha) scales the ink.
static func draw(target: CanvasItem, rect: Rect2, cell: Vector2i, kind: int, mode: String, strength: float, base_alpha: float) -> void:
	var alpha := ink_alpha(mode, strength)
	if alpha <= 0.0 or base_alpha <= 0.0:
		return
	var ink := Color(INK, alpha * base_alpha)
	if mode == "scanline":
		# Fine continuous raster bands: one full-width rect per dark grid
		# row, aligned across cells because band parity is cell-local.
		var j := 0
		while j < GRID:
			var top := rect.position.y + floorf(j * rect.size.y / float(GRID))
			var bottom := rect.position.y + floorf((j + 1) * rect.size.y / float(GRID))
			if bottom > top:
				target.draw_rect(Rect2(rect.position.x, top, rect.size.x, bottom - top), ink)
			j += 2
		return
	# Ranked modes: one snapped rect per dark sample of the ordered grid.
	var x0 := rect.position.x
	var y0 := rect.position.y
	for i in GRID:
		var left := x0 + floorf(i * rect.size.x / float(GRID))
		var right := x0 + floorf((i + 1) * rect.size.x / float(GRID))
		if right <= left:
			continue
		for j in GRID:
			if not sample_dark(mode, kind, i, j, strength):
				continue
			var top := y0 + floorf(j * rect.size.y / float(GRID))
			var bottom := y0 + floorf((j + 1) * rect.size.y / float(GRID))
			if bottom > top:
				target.draw_rect(Rect2(left, top, right - left, bottom - top), ink)
