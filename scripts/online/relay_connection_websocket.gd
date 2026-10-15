extends "res://scripts/online/relay_connection.gd"
## Production relay transport over Godot's built-in WebSocketPeer.
##
## One WebSocket to the game relay (relay/): JSON text frames carry the
## room control protocol (create/join/ping plus relay notifications),
## binary frames carry game envelopes behind a relay-stamped sender
## header. An application-level heartbeat keeps the room from idling
## out and ends the session promptly when the relay stops answering,
## so the UI can never hang on a dead socket.


const CONNECT_TIMEOUT: float = 12.0
const PING_INTERVAL: float = 10.0
const PONG_TIMEOUT: float = 25.0

const MODE_IDLE: int = 0
const MODE_CREATING: int = 1
const MODE_JOINING: int = 2
const MODE_ROOM: int = 3

var _sock := WebSocketPeer.new()
var _mode: int = MODE_IDLE
var _pending_op: Dictionary = {}
var _connect_deadline_msec: int = 0
var _local_closed: bool = false
var _ping_acc: float = 0.0
var _last_pong_msec: int = 0


func is_active() -> bool:
	if _local_closed:
		return false
	return _sock.get_ready_state() in [WebSocketPeer.STATE_CONNECTING, WebSocketPeer.STATE_OPEN]


func create_room(url: String) -> bool:
	return _start(url, {"op": "create"}, MODE_CREATING)


func join_room(url: String, code: String) -> bool:
	return _start(url, {"op": "join", "code": code}, MODE_JOINING)


func send(payload: PackedByteArray) -> bool:
	if _mode != MODE_ROOM or _sock.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return false
	return _sock.put_packet(payload) == OK


func poll(_delta: float) -> void:
	if _local_closed and _sock.get_ready_state() == WebSocketPeer.STATE_CLOSED:
		return
	_sock.poll()
	match _sock.get_ready_state():
		WebSocketPeer.STATE_CONNECTING:
			if Time.get_ticks_msec() > _connect_deadline_msec:
				_fail("timeout", "Relay connection timed out")
		WebSocketPeer.STATE_OPEN:
			if not _pending_op.is_empty():
				_send_json(_pending_op)
				_pending_op = {}
			_drain_packets()
			if _mode == MODE_ROOM:
				_heartbeat(_delta)
		WebSocketPeer.STATE_CLOSED:
			_handle_closed()


func close() -> void:
	if _local_closed:
		return
	if _mode == MODE_ROOM and peer_id == 1 and _sock.get_ready_state() == WebSocketPeer.STATE_OPEN:
		# Host: prompt the relay to notify members and delete the room
		# promptly instead of waiting for our socket close to be noticed.
		_send_json({"op": "close"})
	_local_closed = true
	_mode = MODE_IDLE
	room_code = ""
	peer_id = 0
	if _sock.get_ready_state() in [WebSocketPeer.STATE_CONNECTING, WebSocketPeer.STATE_OPEN]:
		_sock.close()
	closed.emit("local")


func _start(url: String, op: Dictionary, mode: int) -> bool:
	if _local_closed or is_active():
		return false
	var err := _sock.connect_to_url(url)
	if err != OK:
		room_failed.emit("unreachable", "Cannot connect to the relay")
		return false
	_mode = mode
	_pending_op = op
	_connect_deadline_msec = Time.get_ticks_msec() + int(CONNECT_TIMEOUT * 1000.0)
	_last_pong_msec = Time.get_ticks_msec()
	_ping_acc = 0.0
	return true


func _drain_packets() -> void:
	while _sock.get_available_packet_count() > 0:
		var bytes := _sock.get_packet()
		if _sock.was_string_packet():
			_handle_text(String(bytes.get_string_from_utf8()))
		else:
			_handle_binary(bytes)


func _handle_text(text: String) -> void:
	var msg = JSON.parse_string(text)
	if msg is not Dictionary:
		return  # malformed relay control frame: ignore
	match String(msg.get("op", "")):
		"created":
			_enter_room(String(msg.get("code", "")), int(msg.get("peer_id", 1)))
		"joined":
			_enter_room(String(msg.get("code", "")), int(msg.get("peer_id", 0)))
		"error":
			_fail(String(msg.get("code", "error")), String(msg.get("message", "")))
		"peer_joined":
			peer_joined.emit(int(msg.get("peer_id", 0)))
		"peer_left":
			peer_left.emit(int(msg.get("peer_id", 0)))
		"room_closed":
			_accept_room_closed(String(msg.get("reason", "closed")))
		"pong":
			_last_pong_msec = Time.get_ticks_msec()
		_:
			pass  # unknown relay op: ignore (forward compatible)


func _handle_binary(bytes: PackedByteArray) -> void:
	if bytes.size() < 4:
		return  # malformed relay frame: no sender header
	var sender := int(bytes[0]) | (int(bytes[1]) << 8) | (int(bytes[2]) << 16) | (int(bytes[3]) << 24)
	if sender <= 0:
		return
	frame_received.emit(sender, bytes.slice(4))


func _enter_room(code: String, id: int) -> void:
	if code.is_empty() or id <= 0:
		_fail("bad_room", "Relay sent an invalid room")
		return
	room_code = code
	peer_id = id
	_mode = MODE_ROOM
	_ping_acc = 0.0
	_last_pong_msec = Time.get_ticks_msec()
	room_ready.emit(code, id)


func _fail(error_code: String, message: String) -> void:
	## The flow cannot continue: close locally (the socket is single-use)
	## and surface exactly one failure signal.
	_mode = MODE_IDLE
	_local_closed = true
	if _sock.get_ready_state() in [WebSocketPeer.STATE_CONNECTING, WebSocketPeer.STATE_OPEN]:
		_sock.close()
	room_failed.emit(error_code, message)


func _accept_room_closed(reason: String) -> void:
	_mode = MODE_IDLE
	_local_closed = true
	room_code = ""
	peer_id = 0
	if _sock.get_ready_state() in [WebSocketPeer.STATE_CONNECTING, WebSocketPeer.STATE_OPEN]:
		_sock.close()
	room_closed.emit(reason)


func _handle_closed() -> void:
	var was_room: bool = _mode == MODE_ROOM
	var was_flow: bool = _mode in [MODE_CREATING, MODE_JOINING]
	_mode = MODE_IDLE
	if _local_closed:
		return  # expected close (leave, relay rejection, or room_closed)
	_local_closed = true
	if was_room:
		room_closed.emit("socket_closed")
	elif was_flow:
		room_failed.emit("disconnected", "Relay connection lost")
	else:
		closed.emit("socket_closed")


func _heartbeat(delta: float) -> void:
	_ping_acc += delta
	if _ping_acc >= PING_INTERVAL:
		_ping_acc = 0.0
		_send_json({"op": "ping"})
	if Time.get_ticks_msec() - _last_pong_msec > int(PONG_TIMEOUT * 1000.0):
		# No pong for a full window: treat the room as lost rather than
		# letting the session hang on a dead socket.
		_accept_room_closed("heartbeat_timeout")


func _send_json(obj: Dictionary) -> bool:
	if _sock.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return false
	return _sock.send_text(JSON.stringify(obj)) == OK
