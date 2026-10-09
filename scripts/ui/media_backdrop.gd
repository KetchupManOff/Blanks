extends Control
## Host-owned themed backdrop: a base color layer with optional media above
## it (image or looping muted video) plus fit/opacity/tint presentation.
## Backdrop precedence lives here as data application: valid video, then
## valid image, then the themed base color. Media lifecycle is owned by this
## control: applying new media stops and frees any previous video player
## first, so replaced videos never keep running behind the new backdrop.
## Visibility stays with the host (menu vs game backdrop timing).

const NO_MEDIA_TINT := Color(1.0, 1.0, 1.0, 0.0)

var _color: ColorRect = null
var _media_root: Control = null
var _image: TextureRect = null
var _video: VideoStreamPlayer = null
var _tint: ColorRect = null
var _fit := "cover"
var _opacity := 1.0
var _tint_color := NO_MEDIA_TINT
var _video_size := Vector2.ZERO


func _init() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	_color = ColorRect.new()
	_color.set_anchors_preset(Control.PRESET_FULL_RECT)
	_color.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_color)

	_media_root = Control.new()
	_media_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_media_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_media_root.visible = false
	add_child(_media_root)

	_image = TextureRect.new()
	_image.set_anchors_preset(Control.PRESET_FULL_RECT)
	_image.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_image.visible = false
	_media_root.add_child(_image)

	_tint = ColorRect.new()
	_tint.set_anchors_preset(Control.PRESET_FULL_RECT)
	_tint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_media_root.add_child(_tint)


## Applies one resolved backdrop spec from the theme manager:
## {color, texture, video_path, fit, opacity, tint}. Video wins over
## image when its path is valid; the image stays visible beneath the
## video as an instant/loading fallback, and the base color shows when
## neither media is present (or when a video fails to start).
func apply(spec: Dictionary) -> void:
	_teardown_video()
	_color.color = spec.get("color", Color.BLACK)
	_fit = spec.get("fit", "cover")
	_opacity = spec.get("opacity", 1.0)
	_tint_color = spec.get("tint", NO_MEDIA_TINT)
	var texture: Texture2D = spec.get("texture")
	var video_path: String = spec.get("video_path", "")
	_image.texture = texture
	_image.visible = texture != null
	if not video_path.is_empty():
		_setup_video(video_path)
	_media_root.visible = _image.visible or _video != null
	_apply_presentation()


func _apply_presentation() -> void:
	_media_root.modulate = Color(1.0, 1.0, 1.0, clampf(_opacity, 0.0, 1.0))
	_image.stretch_mode = (
		TextureRect.STRETCH_KEEP_ASPECT_COVERED
		if _fit == "cover"
		else TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	)
	_tint.color = _tint_color


func _setup_video(video_path: String) -> void:
	# Theora is the one supported container; the manager validated the
	# file. Builds without the playback class fall back to the image.
	if not ClassDB.class_exists("VideoStreamTheora"):
		return
	var stream: Object = ClassDB.instantiate("VideoStreamTheora")
	stream.set("file", video_path)
	_video = VideoStreamPlayer.new()
	_video.stream = stream
	_video.autoplay = true
	_video.loop = true
	_video.volume = 0.0
	_video.expand = true
	_video.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_video_size = Vector2.ZERO
	_media_root.add_child(_video)
	_layout_video_rect()
	set_process(true)


func _teardown_video() -> void:
	# Stop and free immediately (not queued) so theme switches and tests
	# can assert the old player is gone right after applying.
	if _video == null:
		return
	var old := _video
	_video = null
	_video_size = Vector2.ZERO
	set_process(false)
	old.stop()
	old.stream = null
	if old.get_parent() != null:
		old.get_parent().remove_child(old)
	old.free()


func _process(_delta: float) -> void:
	# Poll the video's native size until the first decoded frame exposes a
	# texture, then stop polling (resizes relayout via the notification).
	if _video == null or _video_size.x > 0.0:
		return
	var tex: Texture2D = _video.get_video_texture()
	if tex != null and tex.get_size().x > 0.0:
		_video_size = tex.get_size()
		_layout_video_rect()
		set_process(false)


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_layout_video_rect()


func _layout_video_rect() -> void:
	# Video covers or letterboxes the backdrop rect, keeping aspect. Before
	# the size is known the player fills the rect (headless/no frame yet).
	if _video == null:
		return
	var target := size
	if _video_size.x > 0.0 and size.x > 0.0 and size.y > 0.0:
		if _fit == "contain":
			target = _video_size * minf(size.x / _video_size.x, size.y / _video_size.y)
		else:
			target = _video_size * maxf(size.x / _video_size.x, size.y / _video_size.y)
	_video.position = (size - target) * 0.5
	_video.size = target
