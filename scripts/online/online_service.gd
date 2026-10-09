extends Node
## Online session manager: the whole relay/room/match lifecycle lives
## here, separate from GameHost. GameHost delegates every online action
## to this service and receives match callbacks back; UI screens read
## state and call host commands, never touching transport internals.
##
## Typed state machine:
##   OFFLINE -> READY (relay endpoint configured)
##   READY -> CREATING_LOBBY -> LOBBY (room created; this peer is 1)
##   READY/ERROR -> JOINING -> CONNECTING -> LOBBY (joined + rostered)
##   LOBBY -> IN_MATCH (host start / client match_started envelope)
##   IN_MATCH -> LOBBY (host return_to_lobby)
##   any session state -> LEAVING -> READY/OFFLINE
##
## Transport: the deployed WebSocket relay (relay/) - private rooms
## behind high-entropy codes, frames forwarded clients->host and
## host->clients only, sender identity stamped by the relay (see
## relay_connection.gd; the in-memory hub in relay_memory.gd drives the
## same semantics headlessly in tests). The host creates the room,
## becomes relay peer 1, and validates every client hello before
## rostering it; clients join by code and apply only host state.
##
## Security model: only the host mutates the authoritative CoopGame.
## Clients submit bounded input intents; the host validates relay sender
## identity, slot ownership, phase, sequence numbers, and rate
## (input_intent.gd) before applying, and broadcasts state snapshots
## clients render read-only. WebSocket delivery is ordered and
## reliable, so snapshot chunking is defensive (bounded frames) and
## stale periodic snapshots are superseded during reassembly instead of
## being retransmitted.

const InputIntent = preload("res://scripts/online/input_intent.gd")
const NetScript = preload("res://scripts/online/online_net.gd")
const RelayContract = preload("res://scripts/online/relay_connection.gd")
const RelayWebSocket = preload("res://scripts/online/relay_connection_websocket.gd")
const RelayMemory = preload("res://scripts/online/relay_connection_memory.gd")

signal status_changed(text: String)
signal state_changed()
signal lobby_changed()

enum State {
	OFFLINE,  # no usable relay endpoint configured
	READY,  # endpoint configured: rooms can be created or joined
	CREATING_LOBBY,  # relay connect + create in flight
	JOINING,  # relay connect + join in flight
	CONNECTING,  # joined; awaiting the host's roster assignment
	LOBBY,
	IN_MATCH,
	LEAVING,
	ERROR,  # last create/join attempt failed (retryable)
}

# Wire protocol identity. Every peer rejects a different protocol
# before any match traffic flows (envelope version + match config).
const PROTOCOL_VERSION: int = 1
const MAX_PLAYERS: int = 4

# Product relay endpoint - one non-secret setting, no credentials: the
# project setting is the release default (set it before exporting; it
# must be wss://), and the TYE_RELAY_URL environment variable overrides
# it for development and staging (ws:// is accepted only in debug
# builds; releases require TLS).
const PROJECT_RELAY_URL: String = "online/relay_url"
const RELAY_URL_ENV: String = "TYE_RELAY_URL"

# Transport-safe snapshot chunking: bounds every forwarded frame well
# below the relay packet limit.
const SNAPSHOT_CHUNK_BYTES: int = 1024
# Periodic snapshot cadence driven by the host's frame loop.
const SNAPSHOT_INTERVAL: float = 0.05
# Bounded room/handshake waits (checked in _process): a lost relay
# response can never strand the UI. The lifecycle is signal-driven with
# no async continuations, so closing the transport cancels everything
# a late response could have touched.
const ROOM_FLOW_TIMEOUT: float = 12.0
const HANDSHAKE_TIMEOUT: float = 20.0

var state: int = State.OFFLINE
var status_text: String = ""
var game_host: Node = null

# Local identity: the active profile's display name (no accounts).
var display_name: String = ""

# Current room bookkeeping.
var room_code: String = ""
var lobby_mode: int = 0  # ModeRules.Mode.*
var lobby_phase: String = "lobby"  # "lobby" | "match"
var is_host: bool = false

# Roster: one entry per connected, handshaked peer. The host builds it
# authoritatively; clients keep the copy the host broadcasts.
# Entry: {"peer_id": int, "name": String, "ready": bool, "slot": int,
#         "connected": bool}
var roster: Array = []

# Host-side per-peer intent validation state.
var _intent_guards: Dictionary = {}  # peer_id -> InputIntent.IntentGuard

# Client-side outbound intent sequence and assigned slot.
var _intent_seq: int = 0
var own_slot: int = -1

# Snapshot stream bookkeeping.
var _snap_id: int = 0
var _snapshot_acc: float = 0.0
var _rx_snap_id: int = -1
var _rx_parts: Dictionary = {}  # part -> PackedByteArray for _rx_snap_id

var _net: Node = null
var _relay: RelayContract = null
var _memory_hub: RefCounted = null  # test-only (use_memory_relay)
var _flow_timer: float = 0.0
var _handshake_timer: float = 0.0
var _shutting_down: bool = false


func _ready() -> void:
	set_process(true)
	_net = NetScript.new()
	_net.name = "Net"
	_net.setup(self)
	add_child(_net)


# ------------------------------------------------------------- availability

func relay_url() -> String:
	## The relay endpoint in use: environment override first (dev and
	## staging), then the project setting (release default).
	var override_url := String(OS.get_environment(RELAY_URL_ENV)).strip_edges()
	if not override_url.is_empty():
		return override_url
	return String(ProjectSettings.get_setting(PROJECT_RELAY_URL, ""))


func transport_available() -> bool:
	## True when a relay endpoint is configured with an allowed scheme.
	return _memory_hub != null or _relay_url_usable()


func is_in_session() -> bool:
	## True while a room/match session owns the transport.
	return state in [
		State.CREATING_LOBBY,
		State.JOINING,
		State.CONNECTING,
		State.LOBBY,
		State.IN_MATCH,
	]


## Relay peer id of this machine (host is 1); 0 while not in a room.
func local_peer_id() -> int:
	if _relay != null:
		return int(_relay.peer_id)
	return 0


## What the host shares so others can join: the opaque room code.
func session_code() -> String:
	return room_code


func use_memory_relay(hub: RefCounted) -> void:
	## Test-only: route create/join through an in-memory relay hub
	## (relay_memory.gd) so headless tests run the full session protocol
	## without a network. Production code never calls this.
	_memory_hub = hub


func _relay_url_usable() -> bool:
	var url := relay_url()
	if url.is_empty():
		return false
	if url.begins_with("wss://"):
		return true
	# Plain ws:// is a local debug convenience only; releases require TLS.
	if url.begins_with("ws://"):
		return OS.is_debug_build() or OS.has_feature("editor")
	return false


func _connect_url() -> String:
	if _memory_hub != null:
		return "memory://local"
	return relay_url()


# ------------------------------------------------------------ session setup

## Entry point for the online menu. Returns true when the service is
## READY to create or join rooms. Relay readiness is just endpoint
## availability - there is no login, so this never blocks.
func ensure_ready() -> bool:
	if state == State.READY:
		return true
	if state in [State.CREATING_LOBBY, State.JOINING, State.CONNECTING, State.LOBBY, State.IN_MATCH, State.LEAVING]:
		return false  # a session flow is already in flight
	if not transport_available():
		_set_state(State.OFFLINE)
		if String(relay_url()).is_empty():
			_status("Online unavailable: no relay configured (see ONLINE_SETUP.md)")
		else:
			_status("Online unavailable: the relay URL must be wss:// (ws:// only in debug builds)")
		return false
	display_name = _local_display_name()
	_set_state(State.READY)
	_status("Ready - create or join a room")
	return true


func _local_display_name() -> String:
	if game_host != null and game_host.has_method("active_profile_name"):
		var profile_name: String = game_host.active_profile_name()
		if not profile_name.is_empty():
			return profile_name
	return "Player" + String.num(OS.get_process_id() % 1000)


# ------------------------------------------------------------------- lobby

## Host: create a private relay room. Returns true when the flow
## started; completion arrives via status/state signals (the in-memory
## test transport completes synchronously).
func create_lobby() -> bool:
	if state != State.READY:
		return false
	is_host = true
	own_slot = 0
	roster = []
	_intent_guards = {}
	room_code = ""
	_flow_timer = 0.0
	_set_state(State.CREATING_LOBBY)
	_status("Creating room...")
	var relay := _connect_relay()
	if not relay.create_room(_connect_url()):
		# Failed synchronously (busy connection/unreachable endpoint);
		# room_failed already reported it.
		return false
	return true


## Client: join a room by code. The code is normalized and shape-checked
## locally; the relay stays authoritative on whether the room exists.
func join_lobby(code: String) -> void:
	if is_in_session() or state in [State.LEAVING]:
		return
	var normalized := RelayContract.normalize_room_code(code)
	if not RelayContract.is_valid_room_code(normalized):
		_fail_flow("Invalid room code")
		return
	is_host = false
	roster = []
	own_slot = -1
	room_code = ""
	_flow_timer = 0.0
	_set_state(State.JOINING)
	_status("Joining room...")
	var relay := _connect_relay()
	relay.join_room(_connect_url(), normalized)


## Client: ready toggle (the host cannot start until every client is
## ready). The host's own roster entry is implicitly ready.
func set_ready(ready: bool) -> void:
	if state != State.LOBBY:
		return
	if is_host:
		_roster_set_ready(local_peer_id(), ready)
		_broadcast_lobby_state()
		lobby_changed.emit()
	else:
		_send_envelope(_net.MSG_SET_READY, {"ready": ready})


func _roster_set_ready(peer_id: int, ready: bool) -> void:
	for entry in roster:
		if int(entry["peer_id"]) == peer_id:
			entry["ready"] = ready


func _net_set_ready(sender: int, data) -> void:
	## Host side of the client ready toggle: mark the SENDER's roster
	## entry (never the host's own) and rebroadcast.
	if not is_host or state != State.LOBBY:
		return
	if data is not Dictionary:
		return
	if not _slot_of_peer().has(sender):
		return  # sender never completed the handshake
	_roster_set_ready(sender, bool(data.get("ready", false)))
	_broadcast_lobby_state()
	lobby_changed.emit()


## Host-only: change the lobby mode; broadcast to the room.
func set_mode(mode: int) -> void:
	if not is_host or state != State.LOBBY:
		return
	lobby_mode = mode
	_broadcast_lobby_state()
	lobby_changed.emit()


## Host: start the round for the current roster. Requires every client
## ready.
func start_round() -> bool:
	if not is_host or state != State.LOBBY:
		return false
	if roster.is_empty():
		return false
	for entry in roster:
		if not bool(entry["ready"]):
			return false
	var config := {
		"protocol": PROTOCOL_VERSION,
		"mode": lobby_mode,
		"seed": randi(),
		"player_count": roster.size(),
		"roster": _roster_wire(),
	}
	lobby_phase = "match"
	_intent_guards = {}
	for entry in roster:
		var peer_id := int(entry["peer_id"])
		if peer_id != 1:
			_intent_guards[peer_id] = InputIntent.make_guard()
	_send_envelope(_net.MSG_MATCH_STARTED, config)
	_set_state(State.IN_MATCH)
	_status("Match starting")
	if game_host != null and game_host.has_method("online_begin_host_match"):
		game_host.online_begin_host_match(config)
	return true


func _roster_wire() -> Array:
	var out: Array = []
	for entry in roster:
		out.append({
			"slot": int(entry["slot"]),
			"peer_id": int(entry["peer_id"]),
			"name": String(entry["name"]),
			"ready": bool(entry["ready"]),
		})
	return out


# ------------------------------------------------------------ match traffic

## Client: submit one input intent for the own slot.
func submit_intent(slot: int, action: String, arg: int) -> void:
	if state != State.IN_MATCH or is_host or slot != own_slot:
		return
	_intent_seq += 1
	_send_envelope(_net.MSG_INTENT, {
		"slot": slot,
		"seq": _intent_seq,
		"action": action,
		"arg": arg,
	})


## Host: called by GameHost's frame loop. Structural frames (match
## start, lock events, phase transitions) go out immediately; the rest
## ride the periodic snapshot cadence.
func host_match_frame(delta: float, structural: bool) -> void:
	if state != State.IN_MATCH or not is_host or game_host == null:
		return
	if structural:
		send_snapshot(true)
		return
	_snapshot_acc += delta
	if _snapshot_acc >= SNAPSHOT_INTERVAL:
		_snapshot_acc = 0.0
		send_snapshot(false)


## Host: capture the authoritative snapshot and broadcast it in
## bounded chunks. The `reliable` label distinguishes structural frames
## (sent immediately) from periodic ones (cadenced by host_match_frame);
## WebSocket delivery itself is ordered and reliable, so both ride the
## same channel and a slow client supersedes stale periodic frames
## during reassembly rather than accumulating them.
func send_snapshot(reliable: bool) -> void:
	if state != State.IN_MATCH or not is_host or game_host == null:
		return
	if reliable:
		_snapshot_acc = 0.0
	var snapshot: Dictionary = game_host.online_snapshot()
	_snap_id += 1
	var chunks: Array = _chunk(var_to_bytes(snapshot))
	for i in chunks.size():
		_send_envelope(_net.MSG_SNAPSHOT, {
			"id": _snap_id,
			"part": i,
			"count": chunks.size(),
			"bytes": chunks[i],
		})


func _chunk(data: PackedByteArray) -> Array:
	var out: Array = []
	if data.size() <= SNAPSHOT_CHUNK_BYTES:
		out.append(data)
		return out
	var offset := 0
	while offset < data.size():
		var end := mini(offset + SNAPSHOT_CHUNK_BYTES, data.size())
		out.append(data.slice(offset, end))
		offset = end
	return out


## Host: terminal phase reached - final reliable snapshot, then the result.
func host_round_finished(result: Dictionary) -> void:
	if not is_host or state != State.IN_MATCH:
		return
	send_snapshot(true)
	_send_envelope(_net.MSG_ROUND_FINISHED, result)
	lobby_phase = "lobby"
	# Ready flags reset for the next round; membership and transport stay.
	for entry in roster:
		entry["ready"] = int(entry["peer_id"]) == 1
	_set_state(State.LOBBY)
	_status("Round over - back in lobby")
	lobby_changed.emit()


## Host: send everyone (and apply locally) a return to the online lobby.
func host_return_to_lobby() -> void:
	if not is_host:
		return
	_send_envelope(_net.MSG_RETURN_TO_LOBBY, {})
	_online_return_to_lobby()


# ------------------------------------------------------------------ leaving

func leave_session() -> void:
	## Leave room + transport; return to the entry state. The lifecycle
	## has no async continuations, so closing the transport is the whole
	## cancellation: late relay responses have no handler left to hit.
	_shutting_down = true
	var was_in_match: bool = state == State.IN_MATCH
	_set_state(State.LEAVING)
	# Transport down first: no further inbound traffic.
	if _relay != null:
		_relay.close()
	room_code = ""
	roster = []
	_intent_guards = {}
	_intent_seq = 0
	_rx_parts = {}
	_rx_snap_id = -1
	own_slot = -1
	is_host = false
	lobby_phase = "lobby"
	_flow_timer = 0.0
	_handshake_timer = 0.0
	_snapshot_acc = 0.0
	_shutting_down = false
	if game_host != null and game_host.has_method("online_leave_session"):
		game_host.online_leave_session(was_in_match)
	var ready_again: bool = transport_available()
	_set_state(State.READY if ready_again else State.OFFLINE)
	_status("Ready - create or join a room" if ready_again else "Offline (no relay configured)")
	lobby_changed.emit()


func shutdown() -> void:
	## App-quit path: best-effort room leave (the relay owns cleanup).
	leave_session()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		shutdown()


# ------------------------------------------------------ transport plumbing

func _connect_relay() -> RelayContract:
	## Fresh connection (signals bound once per connection) whenever the
	## previous one is closed; the service polls it from _process.
	if _relay != null and _relay.is_active():
		return _relay
	_relay = _make_relay_connection()
	_relay.room_ready.connect(_on_relay_room_ready)
	_relay.room_failed.connect(_on_relay_room_failed)
	_relay.peer_joined.connect(_on_relay_peer_joined)
	_relay.peer_left.connect(_on_relay_peer_left)
	_relay.room_closed.connect(_on_relay_room_closed)
	_relay.frame_received.connect(_on_relay_frame)
	_relay.closed.connect(_on_relay_closed)
	return _relay


func _make_relay_connection() -> RelayContract:
	## Production uses the WebSocket transport; tests inject an
	## in-memory hub that mirrors the deployed relay's semantics.
	if _memory_hub != null:
		return RelayMemory.new(_memory_hub)
	return RelayWebSocket.new()


func _fail_flow(message: String) -> void:
	## A create/join/handshake attempt cannot continue: close the
	## transport, surface an actionable status, and return to a state
	## where the player can retry.
	if _relay != null:
		_relay.close()
	room_code = ""
	is_host = false
	own_slot = -1
	roster = []
	_intent_guards = {}
	_flow_timer = 0.0
	_handshake_timer = 0.0
	_set_state(State.ERROR)
	_status(message)
	lobby_changed.emit()


# ---------------------------------------------------------- transport events

func _on_relay_room_ready(code: String, _peer_id: int) -> void:
	room_code = code
	if is_host:
		# The host itself is roster slot 0 (relay peer 1) and implicitly
		# ready.
		_roster_add(1, display_name, true)
		lobby_phase = "lobby"
		_set_state(State.LOBBY)
		_status("Room created - code: %s" % code)
		_broadcast_lobby_state()
		lobby_changed.emit()
	else:
		# Client: introduce ourselves; the host rosters us and its next
		# lobby_state moves this state machine to LOBBY.
		_set_state(State.CONNECTING)
		_status("Connecting to host...")
		_handshake_timer = 0.0
		_send_envelope(_net.MSG_CLIENT_HELLO, {"name": display_name})


func _on_relay_room_failed(error_code: String, _message: String) -> void:
	var text := "Room unavailable"
	match error_code:
		"invalid_code":
			text = "Invalid room code"
		"not_found":
			text = "Room not found (expired or closed)"
		"full":
			text = "Room is full"
		"already_in_room":
			text = "Already in a room"
		"unreachable", "disconnected", "timeout":
			text = "Cannot reach the relay - check the connection and try again"
	_fail_flow(text)


func _on_relay_peer_joined(_peer_id: int) -> void:
	# Informational only: the host rosters a peer only after its client
	# hello completes the handshake (_net_client_hello).
	pass


func _on_relay_peer_left(peer_id: int) -> void:
	if _shutting_down or not is_host:
		return
	# Host: drop the roster entry and rebroadcast; the match continues
	# with the remaining players (the abandoned slot simply stops
	# moving).
	var kept: Array = []
	for entry in roster:
		if int(entry["peer_id"]) != peer_id:
			kept.append(entry)
	if kept.size() != roster.size():
		roster = kept
		_intent_guards.erase(peer_id)
		_broadcast_lobby_state()
		_status("Player left")
		lobby_changed.emit()


func _on_relay_room_closed(_reason: String) -> void:
	if _shutting_down:
		return
	if not is_host:
		# Losing the host ends the match/session for this client; host
		# migration is out of scope. Voluntary leaves already cleared the
		# session and ignore stragglers via _shutting_down.
		var in_match: bool = state == State.IN_MATCH
		if in_match and game_host != null and game_host.has_method("online_session_error"):
			game_host.online_session_error("HOST DISCONNECTED - match abandoned")
		leave_session()
		_status("Host disconnected")
		return
	# Host: the relay closed the room (idle expiry or relay shutdown).
	var was_in_match: bool = state == State.IN_MATCH
	leave_session()
	_status("Room closed by the relay (idle)" if was_in_match else "Room closed by the relay")


func _on_relay_frame(sender_id: int, payload: PackedByteArray) -> void:
	if _shutting_down:
		return
	_net.receive(sender_id, payload)


func _on_relay_closed(_reason: String) -> void:
	# Unexpected socket-level close outside the room lifecycle (those
	# arrive as room_closed/room_failed); defensive teardown in case a
	# session is still tracked.
	if _shutting_down or not is_in_session():
		return
	leave_session()


# ------------------------------------------------------------- net handlers
# Every handler validates its sender. Hosts only accept rostered peers;
# clients only accept the host (relay peer 1). The sender id is the
# relay-stamped one from the transport, never payload content.

func _net_client_hello(sender: int, data) -> void:
	if not is_host:
		return
	if state == State.IN_MATCH:
		return  # no mid-match joins; the relay should have refused them
	if roster.size() >= MAX_PLAYERS:
		return  # roster full; ignoring the hello is the whole rejection
	if sender == 1:
		return  # the host never rosters itself as a client
	for entry in roster:
		if int(entry["peer_id"]) == sender:
			return  # duplicate hello: idempotent
	var name := "P%d" % sender
	if data is Dictionary:
		name = String(data.get("name", name)).strip_edges().substr(0, 16)
	if name.is_empty():
		name = "P%d" % sender
	_roster_add(sender, name, false)
	_intent_guards[sender] = InputIntent.make_guard()
	_broadcast_lobby_state()
	lobby_changed.emit()


func _net_lobby_state(sender: int, wire) -> void:
	if is_host or sender != 1:
		return  # host-only broadcast
	if wire is not Dictionary:
		return
	lobby_mode = int(wire.get("mode", lobby_mode))
	lobby_phase = String(wire.get("phase", lobby_phase))
	var mine := local_peer_id()
	var new_roster: Array = []
	var entries = wire.get("roster", [])
	if entries is Array:
		for entry in entries:
			if entry is Dictionary:
				var peer_id := int(entry.get("peer_id", 0))
				new_roster.append({
					"peer_id": peer_id,
					"name": String(entry.get("name", "")),
					"ready": bool(entry.get("ready", false)),
					"slot": int(entry.get("slot", -1)),
					"connected": true,
				})
				if peer_id == mine:
					own_slot = int(entry.get("slot", -1))
	roster = new_roster
	if state == State.CONNECTING and own_slot >= 0:
		_set_state(State.LOBBY)
		_status("Joined room")
	lobby_changed.emit()


func _net_match_started(sender: int, config) -> void:
	if is_host or sender != 1:
		return  # host-only broadcast
	if config is not Dictionary:
		return
	if own_slot < 0:
		# Never rostered by the host (a race the host-side ready gate
		# makes impossible): refuse the match instead of desyncing.
		push_warning("online: match_started before a roster assignment; ignoring")
		return
	lobby_phase = "match"
	_set_state(State.IN_MATCH)
	_status("Match starting")
	if game_host != null and game_host.has_method("online_begin_client_match"):
		config["own_slot"] = own_slot
		game_host.online_begin_client_match(config)


func _net_round_finished(sender: int, result) -> void:
	if is_host or sender != 1:
		return  # host-only broadcast
	lobby_phase = "lobby"
	if result is Dictionary and game_host != null and game_host.has_method("online_show_results"):
		game_host.online_show_results(result)


func _net_return_to_lobby(sender: int) -> void:
	if is_host or sender != 1:
		return  # host-only broadcast
	_online_return_to_lobby()


func _online_return_to_lobby() -> void:
	lobby_phase = "lobby"
	if game_host != null and game_host.has_method("online_return_to_lobby"):
		game_host.online_return_to_lobby()
	if state == State.IN_MATCH:
		_set_state(State.LOBBY)
		_status("Back in lobby")
	lobby_changed.emit()


func _net_submit_intent(sender: int, data) -> void:
	if not is_host or state != State.IN_MATCH or game_host == null:
		return
	if data is not Dictionary:
		return
	var guard = _intent_guards.get(sender)
	if guard == null:
		return  # sender never completed the handshake
	var slot := int(data.get("slot", -1))
	var seq := int(data.get("seq", 0))
	var action := String(data.get("action", ""))
	var arg := int(data.get("arg", 0))
	var verdict: int = InputIntent.validate(
		guard,
		sender,
		_slot_of_peer(),
		slot,
		seq,
		action,
		arg,
		game_host.online_phase_active(),
		Time.get_ticks_msec()
	)
	if verdict != InputIntent.Verdict.OK:
		if verdict in [InputIntent.Verdict.WRONG_SLOT, InputIntent.Verdict.NOT_ROSTERED]:
			push_warning("online: rejected intent from peer %d (%s)" % [sender, InputIntent.verdict_text(verdict)])
		return
	game_host.online_apply_intent(slot, action, arg)


func _net_snapshot(sender: int, data) -> void:
	if is_host or sender != 1 or game_host == null:
		return  # host-only broadcast
	if data is not Dictionary:
		return
	var bytes = data.get("bytes")
	if bytes is not PackedByteArray:
		return
	var snap_id := int(data.get("id", 0))
	var part := int(data.get("part", -1))
	var count := int(data.get("count", 0))
	if snap_id < _rx_snap_id or count <= 0 or count >= 16 or part < 0 or part >= count:
		return  # stale frame or malformed chunk header
	if snap_id != _rx_snap_id:
		_rx_snap_id = snap_id
		_rx_parts = {}
	_rx_parts[part] = bytes
	if _rx_parts.size() < count:
		return  # frame incomplete; a newer snapshot id supersedes losses
	var data_bytes := PackedByteArray()
	for i in count:
		var piece = _rx_parts.get(i)
		if piece == null:
			return
		data_bytes.append_array(piece)
	_rx_parts = {}
	var snapshot = bytes_to_var(data_bytes)
	if game_host.has_method("online_apply_snapshot"):
		game_host.online_apply_snapshot(snapshot)


# ------------------------------------------------------------------ helpers

func _roster_add(peer_id: int, name: String, ready: bool) -> void:
	roster.append({
		"peer_id": peer_id,
		"name": name,
		"ready": ready,
		"slot": roster.size(),
		"connected": true,
	})


func _broadcast_lobby_state() -> void:
	if not is_host:
		return
	_send_envelope(_net.MSG_LOBBY_STATE, {
		"mode": lobby_mode,
		"phase": lobby_phase,
		"roster": _roster_wire(),
	})


func _send_envelope(msg_type: String, data: Variant) -> bool:
	## Encode + send one game envelope. Returns false when disconnected
	## or when the payload exceeds the client-side frame bound (the
	## relay would refuse it anyway).
	if _relay == null or not _relay.is_active():
		return false
	var payload: PackedByteArray = _net.encode(msg_type, PROTOCOL_VERSION, data)
	if payload.size() > _net.MAX_ENVELOPE_BYTES:
		push_warning("online: refusing to send a %d-byte %s envelope" % [payload.size(), msg_type])
		return false
	return _relay.send(payload)


func _slot_of_peer() -> Dictionary:
	var out: Dictionary = {}
	for entry in roster:
		out[int(entry["peer_id"])] = int(entry["slot"])
	return out


func _set_state(next: int) -> void:
	if state == next:
		return
	state = next
	state_changed.emit()


func _status(text: String) -> void:
	status_text = text
	status_changed.emit(text)


func _process(delta: float) -> void:
	# Poll the transport: every relay event (room lifecycle, inbound
	# frames) dispatches from here, so handlers always run on the main
	# loop with current state.
	if _relay != null:
		_relay.poll(delta)
	# Bounded waits: a lost relay response can never strand the UI.
	match state:
		State.CREATING_LOBBY, State.JOINING:
			_flow_timer += delta
			if _flow_timer >= ROOM_FLOW_TIMEOUT:
				_fail_flow("Room connection timed out")
		State.CONNECTING:
			_handshake_timer += delta
			if _handshake_timer >= HANDSHAKE_TIMEOUT:
				leave_session()
				_status("Connection timed out")
