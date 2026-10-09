extends Node2D
## Debug/development-only P2P replication proof for the online transport
## (see the plan: verify native multiplayer BEFORE wiring gameplay).
##
## It uses the SAME transport the production session uses - whatever
## MultiplayerPeer OnlineService installed on the root multiplayer domain
## (EOS P2P in production, the ENet harness in dev builds) - and exercises
## a MultiplayerSpawner (spawned per-peer players) plus a
## MultiplayerSynchronizer (position replication) with owner-authorised
## movement. If the proof works here, transport-level replication is sound.
##
## Not part of normal gameplay: GameHost only instantiates it in
## debug/editor builds from the online lobby, and Esc closes it again.

const PlayerScene = preload("res://scenes/proof_player.tscn")

var _spawner: MultiplayerSpawner = null
var _players_root: Node2D = null
var _title: Label = null
var _status: Label = null
var _hint: Label = null

var _is_host: bool = false
var _connected_peers: Array = []


func _ready() -> void:
	_build()


func _build() -> void:
	_players_root = Node2D.new()
	_players_root.name = "Players"
	add_child(_players_root)

	_spawner = MultiplayerSpawner.new()
	_spawner.name = "Spawner"
	_spawner.spawn_path = _players_root.get_path()
	_spawner.spawn_function = Callable(self, "_spawn_player")
	add_child(_spawner)

	# Simple HUD: title/status/hint in screen space.
	var ui := CanvasLayer.new()
	ui.layer = 60
	add_child(ui)
	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_CENTER_TOP)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui.add_child(box)
	_title = Label.new()
	_title.text = "P2P REPLICATION PROOF"
	_title.add_theme_font_size_override("font_size", 26)
	box.add_child(_title)
	_status = Label.new()
	_status.text = ""
	_status.add_theme_font_size_override("font_size", 18)
	box.add_child(_status)
	_hint = Label.new()
	_hint.text = "Arrows/WASD: move your pawn (authority: your peer id)   ESC: close"
	_hint.add_theme_font_size_override("font_size", 14)
	box.add_child(_hint)

	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)


func _enter_tree() -> void:
	# Nodes join the tree before _ready; nothing to do, kept for symmetry
	# with the player authority hook.
	pass


func begin(host: bool, session_code: String) -> void:
	## Show the proof over the already-installed transport. The spawner's
	## spawn function must exist on every peer before any spawn call.
	_is_host = host
	_status.text = ("%s   code: %s   peer id: %d" % [
		"HOST" if host else "CLIENT",
		session_code,
		multiplayer.get_unique_id(),
	])
	if host:
		# One pawn per peer: the host's own (peer id 1) plus every already
		# connected client.
		_spawner.spawn(1)
		for peer_id in _connected_peers:
			_spawner.spawn(peer_id)


func _on_peer_connected(peer_id: int) -> void:
	_connected_peers.append(peer_id)
	_status.text = "peer connected: %d" % peer_id
	if _is_host and _spawner != null:
		# New client: spawn its pawn everywhere (identical name+authority
		# because the spawn data is the peer id).
		_spawner.spawn(peer_id)


func _on_peer_disconnected(peer_id: int) -> void:
	_connected_peers.erase(peer_id)
	if _players_root != null and _spawner != null:
		var pawn := _players_root.get_node_or_null(str(peer_id))
		if pawn != null:
			# Despawn on every peer through the spawner.
			_spawner.despawn(pawn)


func _spawn_player(data: Variant) -> Node:
	## Custom spawn: name and authority derive from the same spawn data on
	## every peer, so remote authority matches the owning peer exactly.
	var player := PlayerScene.instantiate()
	player.name = str(data)
	return player


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		close()


func close() -> void:
	if _players_root != null:
		for pawn in _players_root.get_children():
			_spawner.despawn(pawn)
	queue_free()