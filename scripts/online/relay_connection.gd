extends RefCounted
## Relay transport contract for the online session.
##
## One connection owns the local relay socket lifecycle: connect, room
## create/join, framed game traffic, and room notifications. Two
## implementations exist:
##   * relay_connection_websocket.gd - production traffic against the
##     Node.js relay (relay/) through Godot's built-in WebSocketPeer;
##   * relay_connection_memory.gd - an in-memory hub for headless tests.
##
## Sender identity is a transport guarantee: the relay stamps the
## forwarding peer id into a 4-byte header when it forwards a frame, so
## `frame_received` always reports the relay-assigned id of the actual
## sender and payloads can never claim one. Envelope contents are
## validated by OnlineService/online_net.gd, never trusted here.

signal room_ready(room_code: String, peer_id: int)
signal room_failed(error_code: String, message: String)
signal peer_joined(peer_id: int)
signal peer_left(peer_id: int)
signal room_closed(reason: String)
signal frame_received(sender_id: int, payload: PackedByteArray)
signal closed(reason: String)

## Room-code alphabet shared by the relay (relay/src/relay.js) and every
## transport: uppercase letters minus I/O/U so spoken/shared codes stay
## unambiguous. Keep in sync with CODE_ALPHABET there.
const ROOM_CODE_ALPHABET: String = "ABCDEFGHJKLMNPQRSTVWXYZ"

## Relay-assigned id once a room is established (host is always 1).
var peer_id: int = 0
## Room code once create/join succeeded (empty otherwise).
var room_code: String = ""


## Normalize player-entered codes: trim, uppercase, strip separators the
## relay also strips (spaces, dashes).
static func normalize_room_code(raw: String) -> String:
	return raw.strip_edges().to_upper().replace(" ", "").replace("-", "")


## Local shape check (the relay stays authoritative on exact codes):
## loose length bounds plus alphabet-only characters.
static func is_valid_room_code(code: String) -> bool:
	if code.length() < 4 or code.length() > 16:
		return false
	for ch in code:
		if ROOM_CODE_ALPHABET.find(ch) < 0:
			return false
	return true


## True while the local socket is connecting/open and not closed locally.
func is_active() -> bool:
	return false


## Begin connect + room create. Completion arrives asynchronously as
## room_ready or room_failed; returns false only when the flow cannot
## even start (already connecting/connected or an invalid endpoint).
func create_room(_url: String) -> bool:
	return false


## Begin connect + room join by code. Same completion contract as
## create_room; the code must already be normalized/validated by the
## caller (see OnlineService.normalize_room_code).
func join_room(_url: String, _code: String) -> bool:
	return false


## Send one game envelope payload. The payload must not contain a
## sender id: the relay stamps the sender when forwarding. Envelope
## size limits are enforced by the caller (online_net.gd).
func send(_payload: PackedByteArray) -> bool:
	return false


## Advance the transport. Called every OnlineService _process frame;
## lifecycle signals may fire synchronously from within poll.
func poll(_delta: float) -> void:
	pass


## Close the local socket. A host additionally asks the relay to close
## the room promptly (members receive room_closed); either way the
## relay owns room cleanup. Safe to call repeatedly.
func close() -> void:
	pass
