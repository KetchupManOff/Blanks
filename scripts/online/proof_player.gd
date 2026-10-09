extends Node2D
## One spawned pawn in the P2P replication proof scene. The spawner names it
## after the owning peer id, so every peer derives identical authority:
## the owning peer moves it locally and the MultiplayerSynchronizer
## replicates position to everyone else (owner-authorised movement).

const MOVE_SPEED: float = 320.0

var _sync: MultiplayerSynchronizer = null
var _label: Label = null


func _enter_tree() -> void:
	# Authority must be identical on every peer BEFORE the synchronizer
	# starts (name == owning peer id, set by the spawner's spawn data).
	set_multiplayer_authority(clampi(String(name).to_int(), 1, 1 << 30))


func _ready() -> void:
	z_index = 10
	var body := ColorRect.new()
	body.color = Color(0.35, 0.75, 0.9)
	body.size = Vector2(48.0, 48.0)
	body.position = Vector2(-24.0, -24.0)
	add_child(body)

	_label = Label.new()
	_label.text = "P%s" % name
	_label.position = Vector2(-24.0, -46.0)
	_label.add_theme_font_size_override("font_size", 16)
	add_child(_label)

	_sync = MultiplayerSynchronizer.new()
	_sync.name = "Sync"
	_sync.root_path = NodePath(".")
	var config := SceneReplicationConfig.new()
	config.add_property(NodePath(".:position"))
	config.property_set_spawn(NodePath(".:position"), true)
	config.property_set_sync(NodePath(".:position"), true)
	_sync.replication_config = config
	add_child(_sync)

	position = Vector2(640.0, 400.0) + Vector2(80.0, 0.0) * float(get_multiplayer_authority() % 10)


func _process(delta: float) -> void:
	if not is_multiplayer_authority():
		return  # Only the owning peer moves its pawn.
	var dir := Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down")
	position += dir * MOVE_SPEED * delta