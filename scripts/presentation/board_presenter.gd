extends Node2D
## Board presenter: renders the active playfield (solo or co-op) either
## directly into the field or through a board-sized off-screen SubViewport,
## compositing the theme's general piece bloom (a thresholded additive
## glow over the sharp source) without ever touching HUD, preview, or
## backdrop pixels. Sampling the render target instead of the screen keeps
## the effect bounded to the playfield rectangle. The host owns board
## lifetimes and visibility; this node owns the render target, the
## presenting sprite, and which slot the installed board draws into.

const BLOOM_SHADER := preload("res://scripts/presentation/board_bloom.gdshader")

## Schema maximum for `pieces.bloom`; intensities are clamped to it.
const BLOOM_MAX := 2.0

var _board_root: Node2D = null
var _viewport: SubViewport = null
var _viewport_board: Node2D = null
var _display: Sprite2D = null
var _bloom_material: ShaderMaterial = null
var _installed: Node2D = null
var _size := Vector2.ZERO
var _bloom_intensity := 0.0
var _bloom_effective := false
var _presenting := false


func _init() -> void:
	# Direct-draw slot: the installed board draws straight into the field,
	# byte-for-byte like the pre-presenter setup, whenever the effect is off.
	_board_root = Node2D.new()
	add_child(_board_root)

	# Board-bounded off-screen target; a transparent background preserves
	# the spawn-row peek's alpha so it still blends with the game backdrop.
	_viewport = SubViewport.new()
	_viewport.transparent_bg = true
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(_viewport)
	_viewport_board = Node2D.new()
	_viewport.add_child(_viewport_board)

	# Presents the render target at the board's field position with nearest
	# sampling, so the unfiltered source stays pixel-identical to direct
	# drawing and the bloom shader adds only its restrained highlight.
	_display = Sprite2D.new()
	_display.centered = false
	_display.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_display.visible = false
	add_child(_display)


## Output placement: this node sits at the board's field position and the
## render target covers the board bounds (hidden spawn rows included).
func set_layout(board_position: Vector2, board_size: Vector2) -> void:
	position = board_position
	_size = board_size
	if board_size.x > 0.0 and board_size.y > 0.0:
		_viewport.size = Vector2i(board_size)
	_refresh_state()


## Installs the board to present. A previously installed board is parked in
## the direct slot; the host keeps owning its visibility and lifetime, so a
## parked board stays out of the frame until the host shows it again.
func install(board: Node2D) -> void:
	if board == null:
		return
	if _installed != null and _installed != board:
		_reseat(_installed, _board_root)
	_installed = board
	_refresh_state()


## Drops the installed board reference and hides the render-target output;
## the caller frees the board itself. Co-op teardown uses this so no stale
## viewport texture can stay visible.
func clear() -> void:
	_installed = null
	_refresh_state()


## Theme-driven gate for the off-screen bloom pass: every positive
## intensity enables it, zero draws the board directly.
func set_bloom_intensity(intensity: float) -> void:
	var clamped := clampf(intensity, 0.0, BLOOM_MAX)
	if is_equal_approx(_bloom_intensity, clamped):
		return
	_bloom_intensity = clamped
	_refresh_state()


## Whether a run is showing the field: render-target updates (and the
## extra render pass) run only then, including pause/results overlays.
func set_presenting(presenting: bool) -> void:
	if _presenting == presenting:
		return
	_presenting = presenting
	_refresh_state()


func bloom_intensity() -> float:
	return _bloom_intensity


func bloom_active() -> bool:
	return _bloom_effective


func installed_board() -> Node2D:
	return _installed


func board_size() -> Vector2:
	return _size


## True when the installed board draws through the off-screen viewport
## (the bloom path) instead of the direct field slot.
func board_in_viewport() -> bool:
	return _installed != null and _installed.get_parent() == _viewport_board


func is_presenting() -> bool:
	return _presenting


## Re-applies the effective state: seats the installed board into the
## active slot, refreshes the presenting sprite, syncs the material's
## intensity uniform to the requested value, and enables the render pass
## only while the effect, a board, a valid layout, and a visible run are
## all present.
func _refresh_state() -> void:
	if _installed != null and not is_instance_valid(_installed):
		_installed = null
	_bloom_effective = _bloom_intensity > 0.0 and _size.x > 0.0 and _size.y > 0.0
	if _bloom_effective and _bloom_material == null:
		_bloom_material = ShaderMaterial.new()
		_bloom_material.shader = BLOOM_SHADER
	if _bloom_material != null:
		# The resolved theme value is the shader's intensity multiplier.
		_bloom_material.set_shader_parameter("intensity", _bloom_intensity)
	if _installed != null:
		_reseat(_installed, _viewport_board if _bloom_effective else _board_root)
	var output: bool = _bloom_effective and _installed != null
	_display.visible = output
	_display.texture = _viewport.get_texture() if output else null
	_display.material = _bloom_material if output else null
	_viewport.render_target_update_mode = (
		SubViewport.UPDATE_ALWAYS if output and _presenting
		else SubViewport.UPDATE_DISABLED
	)


## Moves a board between slots at local origin; a board inside a viewport
## slot shares no canvas space with the field, so the position resets
## instead of being preserved across the move.
func _reseat(board: Node2D, slot: Node) -> void:
	if board.get_parent() == slot:
		board.position = Vector2.ZERO
		return
	if board.get_parent() != null:
		board.get_parent().remove_child(board)
	slot.add_child(board)
	board.position = Vector2.ZERO
