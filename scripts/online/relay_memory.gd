extends RefCounted
## In-memory stand-in for the deployed Node relay (relay/), used ONLY
## by headless tests through relay_connection_memory.gd. It mirrors the
## relay's observable semantics: room codes from the shared alphabet,
## relay-stamped sender ids (host 1, clients 2..MAX_ROOM_PEERS), strict
## direction (client frames reach only the host; host frames reach all
## clients), member notifications, host-loss room teardown, and frame
## size bounds. Rate/heartbeat limits are transport-level and are
## covered by the relay's own Node test suite, not simulated here.


const MAX_ROOM_PEERS: int = 4
const CODE_LENGTH: int = 7
## Mirrors the relay's default PACKET_LIMIT (sender header included).
const MAX_FRAME_BYTES: int = 65536

const RelayContract = preload("res://scripts/online/relay_connection.gd")

var rooms: Dictionary = {}  # code -> Room


class Room:
	extends RefCounted
	var code: String = ""
	var host: RefCounted = null  # Sock
	var peers: Dictionary = {}  # peer_id -> Sock (clients only)


class Sock:
	extends RefCounted
	var hub: RefCounted = null
	var room: Room = null
	var peer_id: int = 0
	var inbox: Array = []  # control notes (Dictionary) or {"sender", "data"} frames
	var closed: bool = false


func make_socket() -> Sock:
	var sock := Sock.new()
	sock.hub = self
	return sock


func create_room_for(sock: Sock) -> Dictionary:
	## Returns {"ok": true, "code"} or {"ok": false, "error"}.
	if sock.room != null:
		return {"ok": false, "error": "already_in_room"}
	var code := _gen_code()
	if rooms.has(code):
		return {"ok": false, "error": "internal"}
	var room := Room.new()
	room.code = code
	room.host = sock
	sock.room = room
	sock.peer_id = 1
	rooms[code] = room
	return {"ok": true, "code": code}


func join_room_with(sock: Sock, raw_code: String) -> Dictionary:
	## Returns {"ok": true, "code", "peer_id"} or {"ok": false, "error"}.
	if sock.room != null:
		return {"ok": false, "error": "already_in_room"}
	var room: Room = rooms.get(raw_code)
	if room == null or room.host == null:
		return {"ok": false, "error": "not_found"}
	if room.peers.size() + 1 >= MAX_ROOM_PEERS:
		return {"ok": false, "error": "full"}
	var peer_id := -1
	for id in range(2, MAX_ROOM_PEERS + 1):
		if not room.peers.has(id):
			peer_id = id
			break
	if peer_id < 0:
		return {"ok": false, "error": "full"}
	sock.room = room
	sock.peer_id = peer_id
	room.peers[peer_id] = sock
	_notify_room(room, {"op": "peer_joined", "peer_id": peer_id}, sock)
	return {"ok": true, "code": room.code, "peer_id": peer_id}


func route_binary(sock: Sock, payload: PackedByteArray) -> String:
	## Forward one frame. Returns "" when delivered, else a relay error
	## code. The receiver's inbox gets the payload with the RELAY-STAMPED
	## sender id - never one taken from the payload.
	if sock.room == null:
		return "not_in_room"
	if payload.size() + 4 > MAX_FRAME_BYTES:
		return "too_large"
	if sock.peer_id == 1:
		for id in sock.room.peers:
			var target: Sock = sock.room.peers[id]
			if not target.closed:
				target.inbox.append({"sender": 1, "data": payload})
	else:
		var host: Sock = sock.room.host
		if host != null and not host.closed:
			host.inbox.append({"sender": sock.peer_id, "data": payload})
	return ""


func close_room_by_host(sock: Sock) -> void:
	## Host-requested prompt teardown (relay op "close").
	if sock.room == null or sock.peer_id != 1:
		return
	_delete_room(sock.room, "closed")
	sock.room = null


func close_socket(sock: Sock) -> void:
	if sock.closed:
		return
	sock.closed = true
	var room: Room = sock.room
	sock.room = null
	if room == null:
		return
	if sock.peer_id == 1:
		# Host loss: the room is over for every member.
		_delete_room(room, "host_left")
	else:
		# Client loss: the host updates its roster; the room continues.
		room.peers.erase(sock.peer_id)
		if not room.host.closed:
			room.host.inbox.append({"op": "peer_left", "peer_id": sock.peer_id})


func _delete_room(room: Room, reason: String) -> void:
	if rooms.get(room.code) != room:
		return
	rooms.erase(room.code)
	var note := {"op": "room_closed", "reason": reason}
	room.host.closed = true
	room.host.room = null
	room.host.inbox.append(note.duplicate())
	for id in room.peers:
		var client: Sock = room.peers[id]
		client.closed = true
		client.room = null
		client.inbox.append(note.duplicate())
	room.peers.clear()


func _notify_room(room: Room, note: Dictionary, exclude: Sock) -> void:
	if not room.host.closed and room.host != exclude:
		room.host.inbox.append(note.duplicate())
	for id in room.peers:
		var client: Sock = room.peers[id]
		if not client.closed and client != exclude:
			client.inbox.append(note.duplicate())


func _gen_code() -> String:
	var alphabet: String = RelayContract.ROOM_CODE_ALPHABET
	var bytes := Crypto.new().generate_random_bytes(CODE_LENGTH)
	var code := ""
	for b in bytes:
		code += alphabet[b % alphabet.length()]
	return code
