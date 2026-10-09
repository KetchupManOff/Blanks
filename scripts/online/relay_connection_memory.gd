extends "res://scripts/online/relay_connection.gd"
## In-memory relay transport for headless tests ONLY: routes through a
## shared relay_memory.gd hub so paired OnlineService instances exercise
## the same room create/join/forward/notify semantics the deployed relay
## implements, deterministically and without a network. Sends land in
## the receiver's inbox synchronously; each poll() drains the local
## inbox, so tests advance the protocol frame by frame by polling both
## services. No heartbeat is simulated: nothing can drop silently.


var _hub: RefCounted = null  # relay_memory.gd
var _sock: RefCounted = null  # hub Sock


func _init(hub) -> void:
	_hub = hub


func is_active() -> bool:
	return _sock != null and not _sock.closed


func create_room(_url: String) -> bool:
	if is_active():
		return false
	_sock = _hub.make_socket()
	var result: Dictionary = _hub.create_room_for(_sock)
	if not bool(result.get("ok")):
		_room_failed(String(result.get("error", "internal")))
		return false
	_enter_room(String(result.get("code", "")), 1)
	return true


func join_room(_url: String, code: String) -> bool:
	if is_active():
		return false
	_sock = _hub.make_socket()
	var result: Dictionary = _hub.join_room_with(_sock, code)
	if not bool(result.get("ok")):
		_room_failed(String(result.get("error", "internal")))
		return false
	_enter_room(String(result.get("code", "")), int(result.get("peer_id", 0)))
	return true


func send(payload: PackedByteArray) -> bool:
	if not is_active():
		return false
	return _hub.route_binary(_sock, payload) == ""


func poll(_delta: float) -> void:
	if _sock == null:
		return
	# A closed socket still drains whatever the relay queued before the
	# close: room_closed is delivered exactly this way.
	while not _sock.inbox.is_empty():
		var item = _sock.inbox.pop_front()
		if item is Dictionary and item.has("sender"):
			frame_received.emit(int(item["sender"]), item["data"])
		elif item is Dictionary and item.has("op"):
			_handle_note(item)
		if _sock.closed:
			# The close note ends this socket; nothing after it matters.
			return


func close() -> void:
	if _sock == null:
		return
	var sock: RefCounted = _sock
	_sock = null
	if sock.peer_id == 1 and sock.room != null:
		# Host: prompt teardown mirrors the relay's close op (members get
		# room_closed); the hub also marks this socket closed.
		_hub.close_room_by_host(sock)
		sock.closed = true
	else:
		_hub.close_socket(sock)
	room_code = ""
	peer_id = 0
	closed.emit("local")


func _enter_room(code: String, id: int) -> void:
	room_code = code
	peer_id = id
	room_ready.emit(code, id)


func _room_failed(error_code: String) -> void:
	## The in-memory relay rejected the flow; error codes match the
	## deployed relay (see relay/src/relay.js).
	room_failed.emit(error_code, error_code)


func _handle_note(note: Dictionary) -> void:
	match String(note.get("op", "")):
		"peer_joined":
			peer_joined.emit(int(note.get("peer_id", 0)))
		"peer_left":
			peer_left.emit(int(note.get("peer_id", 0)))
		"room_closed":
			room_closed.emit(String(note.get("reason", "closed")))
		_:
			pass
