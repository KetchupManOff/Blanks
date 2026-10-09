extends Node
## Online session manager: the whole EOS/transport/lobby/match lifecycle
## lives here, separate from GameHost. GameHost delegates every online
## action to this service and receives match callbacks back; UI screens
## read state and call host commands, never touching transport internals.
##
## Typed state machine:
##   OFFLINE -> INITIALIZING -> AUTHENTICATING -> READY
##   READY -> CREATING_LOBBY -> LOBBY
##   READY -> BROWSING (search results shown)
##   READY -> JOINING -> CONNECTING -> LOBBY
##   LOBBY -> IN_MATCH (host start / client match_started RPC)
##   IN_MATCH -> LOBBY (host return_to_lobby)
##   any -> LEAVING -> READY/OFFLINE
##
## Transports, tried in order when available:
##   * the project's own EOS-backed GDExtension ("EOSMultiplayerPeer"),
##     built against the same EOS SDK as EOSG - see addons/eos-transport;
##   * the EOSG addon's "EOSGMultiplayerPeer" (EOS P2P MultiplayerPeerExtension);
##   * ENet over 127.0.0.1 in debug/editor builds only (dev harness, no EOS).
##
## Everything EOS-specific goes through scripts/online/eosg_bridge.gd, which
## is loaded ONLY when the EOSG addon is installed; this script never
## references EOSG classes directly so the game runs without the addon.
##
## Security model: only the host mutates the authoritative CoopGame.
## Clients submit bounded input intents; the host validates sender/slot
## ownership, phase, sequence numbers, and rate (input_intent.gd) before
## applying, and broadcasts state snapshots clients render read-only.

const Credentials = preload("res://scripts/online/online_credentials.gd")
const InputIntent = preload("res://scripts/online/input_intent.gd")
const NetScript = preload("res://scripts/online/online_net.gd")

signal status_changed(text: String)
signal state_changed()
signal lobby_changed()
signal browse_done(ok: bool, message: String)

enum State {
	OFFLINE,
	INITIALIZING,
	AUTHENTICATING,
	READY,
	CREATING_LOBBY,
	BROWSING,
	JOINING,
	CONNECTING,
	LOBBY,
	IN_MATCH,
	LEAVING,
	ERROR,
}

enum TransportKind { NONE, CUSTOM_EOS, EOSG, ENET_DEV }

# Wire protocol identity. Every peer rejects a different protocol before
# any match traffic flows (lobby attribute + handshake + match config).
const PROTOCOL_VERSION: int = 1
const MAX_PLAYERS: int = 4
const SOCKET_ID: String = "tyecoopv1"
const BUCKET_ID: String = "tyecoop"

# EOS lobby attribute keys (public; used for browser filtering too).
const ATTR_PROTOCOL: String = "tye_protocol"
const ATTR_BUILD: String = "tye_build"
const ATTR_NAME: String = "tye_name"
const ATTR_MODE: String = "tye_mode"
const ATTR_PHASE: String = "tye_phase"
const ATTR_JOINABLE: String = "tye_joinable"
const ATTR_MEMBER_NAME: String = "tye_member_name"

# Transport-safe snapshot chunking: EOS P2P caps a packet well below the
# size of a 4-player board snapshot, so every snapshot is split.
const SNAPSHOT_CHUNK_BYTES: int = 1024
# Periodic unreliable snapshot cadence driven by the host's frame loop.
const SNAPSHOT_INTERVAL: float = 0.05
const CONNECT_TIMEOUT: float = 20.0

var state: int = State.OFFLINE
var transport_kind: int = TransportKind.NONE
var status_text: String = ""
var game_host: Node = null

# Auth/session identity (no secrets are ever stored in these).
var credentials: Dictionary = {}
var display_name: String = ""
var product_user_id: String = ""

# EOS-facing bridge (null when the addon is absent).
var bridge: Node = null

# Current lobby bookkeeping.
var lobby_id: String = ""
var lobby_mode: int = 0  # ModeRules.Mode.*
var lobby_phase: String = "lobby"  # "lobby" | "match"
var is_host: bool = false

# Roster: one entry per connected, handshaked peer. The host builds it
# authoritatively; clients keep the copy the host broadcasts.
# Entry: {"peer_id": int, "puid": String, "name": String, "ready": bool,
#         "slot": int, "connected": bool}
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

# Operation token: every async continuation captures it and aborts when a
# leave/cancel/error bumped the token in between - a late EOS callback can
# never revive a cancelled operation or a destroyed screen.
var _op_token: int = 0

# Dev ENet transport endpoint (what joining players type).
var dev_lobby_address: String = ""

# Latest browse results (refreshed by browse()).
var browse_results: Array = []

var _net: Node = null
var _signals_bound: bool = false
var _connect_timer: float = 0.0
var _connect_timed_out: bool = false
var _shutting_down: bool = false


func _ready() -> void:
	set_process(true)
	_net = NetScript.new()
	_net.name = "Net"
	_net.setup(self)
	add_child(_net)
	_load_bridge()


# ------------------------------------------------------------- availability

## Global classes the EOSG addon contributes (eos.gd declares class EOS,
## hcredentials.gd declares HCredentials, base_class.gd declares BaseClass,
## hlog.gd declares HLog). HPlatform/HAuth/HLobbies/HP2P are plain autoload
## scripts there, loaded by path in the bridge - they are not global classes.
const EOSG_GLOBAL_CLASSES := ["EOS", "HCredentials", "BaseClass", "HLog"]

## H* node scripts the bridge instantiates (paths must exist).
const EOSG_SCRIPT_PATHS := [
	"res://addons/epic-online-services-godot/heos/hplatform.gd",
	"res://addons/epic-online-services-godot/heos/hauth.gd",
	"res://addons/epic-online-services-godot/heos/hlobbies.gd",
	"res://addons/epic-online-services-godot/heos/hp2p.gd",
]


static func eosg_installed() -> bool:
	## File-level check only: are all the addon scripts we load present?
	for path in EOSG_SCRIPT_PATHS:
		if not ResourceLoader.exists(path):
			return false
	return true


static func dev_transport_allowed() -> bool:
	## The ENet harness exists so the full session protocol stays testable
	## without EOS; it is intentionally unavailable in release builds.
	return OS.has_feature("editor") or OS.is_debug_build()


func _load_bridge() -> void:
	if not eosg_installed():
		_status("EOSG addon not installed - online runs in dev mode (debug builds)")
		return
	# The bridge script references EOSG global classes (EOS, HCredentials,
	# ...), which only exist after the editor has scanned the addon once
	# (global class cache). Loading it earlier would hard-crash the game.
	var global_classes: Array = []
	for entry in ProjectSettings.get_global_class_list():
		if entry is Dictionary:
			global_classes.append(String((entry as Dictionary).get("class", "")))
	for cls in EOSG_GLOBAL_CLASSES:
		if not global_classes.has(cls):
			_status("EOSG addon found but its classes are not registered - open the project in the Godot editor once, then restart")
			return
	var BridgeScript = load("res://scripts/online/eosg_bridge.gd")
	bridge = BridgeScript.new()
	bridge.kicked.connect(_on_bridge_kicked)
	add_child(bridge)


func _on_bridge_kicked() -> void:
	# Kicked/destroyed from the EOS lobby: the session is over for us.
	var in_match: bool = state == State.IN_MATCH
	if in_match and game_host != null and game_host.has_method("online_session_error"):
		game_host.online_session_error("REMOVED FROM LOBBY - match abandoned")
	leave_session()
	_status("Removed from lobby")


func transport_available() -> bool:
	return bridge != null or dev_transport_allowed()


func is_in_session() -> bool:
	## True while a lobby/match session owns the transport.
	return state in [State.LOBBY, State.IN_MATCH] or multiplayer.multiplayer_peer != null


func transport_name() -> String:
	match transport_kind:
		TransportKind.CUSTOM_EOS: return "EOS P2P (EOSMultiplayerPeer)"
		TransportKind.EOSG: return "EOS P2P (EOSGMultiplayerPeer)"
		TransportKind.ENET_DEV: return "ENet (dev harness)"
		_: return "unavailable"


## What the host shares so others can join: the opaque EOS lobby id, or
## the dev harness address. Display/copy only.
func session_code() -> String:
	if bridge != null:
		return lobby_id
	return dev_lobby_address


# ------------------------------------------------------------ session setup

## Async entry point for the online menu. Returns true when the session is
## READY (initialized + authenticated). Safe to call repeatedly.
func ensure_ready() -> bool:
	if state == State.READY:
		return true
	if state in [State.INITIALIZING, State.AUTHENTICATING]:
		return false  # already in flight; UI refreshes from status_changed
	if not transport_available():
		_status("Online unavailable: install the EOSG addon (see ONLINE_SETUP.md)")
		return false
	if bridge == null:
		# Dev harness: no EOS identity, but a usable transport for testing.
		display_name = _local_display_name()
		_set_state(State.READY)
		_status("Dev mode ready (no EOS identity)")
		return true

	var token := _op_token
	credentials = Credentials.load_credentials()
	if not Credentials.is_configured(credentials):
		_set_state(State.ERROR)
		_status("EOS credentials missing - copy eos_credentials.example.cfg to eos_credentials.cfg")
		return false

	_set_state(State.INITIALIZING)
	_status("Initializing EOS...")
	if not await bridge.setup_eos_async(credentials):
		if token != _op_token:
			return false
		_set_state(State.ERROR)
		_status("EOS initialization failed - see logs")
		return false
	if token != _op_token:
		return false

	_set_state(State.AUTHENTICATING)
	_status("Authenticating...")
	var ok: bool
	if _auth_mode() == "devtool":
		ok = await bridge.login_dev_async(
			String(credentials.get("devtool_url", "localhost:4545")),
			String(credentials.get("devtool_credential", "PlayerOne"))
		)
	else:
		# Release: anonymous Device ID. Identity is device-local and not a
		# recoverable account - the entry screen shows this disclosure.
		ok = await bridge.login_device_async(_local_display_name())
	if token != _op_token:
		return false
	if not ok:
		_set_state(State.ERROR)
		_status("EOS login failed - see logs")
		return false
	product_user_id = String(bridge.get("product_user_id"))
	display_name = String(bridge.get("display_name"))
	if display_name.is_empty():
		display_name = _local_display_name()
	_set_state(State.READY)
	_status("Signed in as %s" % display_name)
	return true


func _auth_mode() -> String:
	var configured := String(credentials.get("auth_mode", "")).strip_edges()
	if not configured.is_empty():
		return configured
	# Debug/development builds use the Dev Auth Tool; release builds create
	# and log in with an anonymous Device ID.
	return "devtool" if (OS.has_feature("editor") or OS.is_debug_build()) else "device"


func _local_display_name() -> String:
	if game_host != null and game_host.has_method("active_profile_name"):
		var profile_name: String = game_host.active_profile_name()
		if not profile_name.is_empty():
			return profile_name
	return "Player" + String.num(OS.get_process_id() % 1000)


# ------------------------------------------------------------------- lobby

## Host: create a public, joinable EOS lobby (or bind the dev ENet server).
func create_lobby() -> bool:
	if state != State.READY:
		return false
	_op_token += 1
	var token := _op_token
	_set_state(State.CREATING_LOBBY)
	_status("Creating lobby...")
	is_host = true
	own_slot = 0
	roster = []
	_intent_guards = {}
	if bridge != null:
		var info: Dictionary = await bridge.create_lobby_async(MAX_PLAYERS, {
			ATTR_PROTOCOL: PROTOCOL_VERSION,
			ATTR_BUILD: String(credentials.get("product_version", "1.0.0")),
			ATTR_NAME: display_name,
			ATTR_MODE: lobby_mode,
			ATTR_PHASE: "lobby",
			ATTR_JOINABLE: true,
		})
		if token != _op_token:
			return false
		if info.is_empty():
			_set_state(State.ERROR)
			_status("Failed to create lobby - see logs")
			is_host = false
			return false
		lobby_id = String(info.get("lobby_id", ""))
	if not _start_transport(true, ""):
		if token != _op_token:
			return false
		leave_session()
		return false
	# The host itself is roster slot 0 (peer 1) and implicitly ready.
	_roster_add(1, product_user_id, display_name, true)
	lobby_phase = "lobby"
	_set_state(State.LOBBY)
	_status("Lobby created - share code: %s" % session_code())
	_broadcast_lobby_state()
	lobby_changed.emit()
	return true


## Search public lobbies matching this protocol/build. Results arrive via
## `browse_done` and stay in `browse_results` until the next search.
func browse() -> void:
	if state != State.READY or bridge == null:
		browse_done.emit(false, "Browsing requires the EOSG addon")
		return
	_op_token += 1
	var token := _op_token
	_set_state(State.BROWSING)
	_status("Searching for lobbies...")
	var entries: Array = await bridge.search_lobbies_async(PROTOCOL_VERSION)
	if token != _op_token:
		return
	browse_results = entries
	_set_state(State.READY)
	_status("Found %d lobbies" % entries.size())
	browse_done.emit(true, "Found %d lobbies" % entries.size())


## Join by EOS lobby id (host shares the opaque id) or dev address.
func join_lobby(address: String) -> void:
	if state != State.READY:
		return
	_op_token += 1
	var token := _op_token
	lobby_id = ""
	is_host = false
	roster = []
	own_slot = -1
	var host_target := ""
	if bridge != null:
		_set_state(State.JOINING)
		_status("Joining lobby...")
		var info: Dictionary = await bridge.join_lobby_by_id_async(address)
		if token != _op_token:
			return
		if info.is_empty():
			_set_state(State.ERROR)
			_status("Lobby unavailable (missing, full, or incompatible)")
			return
		lobby_id = String(info.get("lobby_id", ""))
		host_target = String(info.get("owner_puid", ""))
		if host_target.is_empty():
			leave_session()
			_status("Lobby owner unknown - cannot connect")
			return
		bridge.set_member_name(display_name)
	else:
		host_target = address
		_set_state(State.JOINING)
	if not _start_transport(false, host_target):
		if token != _op_token:
			return
		leave_session()
		_status("Failed to connect - see logs")
		return
	_set_state(State.CONNECTING)
	_status("Connecting to host...")
	_connect_timer = 0.0
	_connect_timed_out = false


## Client: ready toggle (the host cannot start until every client is ready).
func set_ready(ready: bool) -> void:
	if state != State.LOBBY:
		return
	if is_host:
		_roster_set_ready(multiplayer.get_unique_id(), ready)
		_broadcast_lobby_state()
		lobby_changed.emit()
	else:
		_net.send_set_ready(ready)


func _roster_set_ready(peer_id: int, ready: bool) -> void:
	for entry in roster:
		if int(entry["peer_id"]) == peer_id:
			entry["ready"] = ready


func _net_set_ready(sender: int, ready: bool) -> void:
	## Host side of the client ready toggle: mark the SENDER's roster entry
	## (never the host's own) and rebroadcast.
	if not is_host:
		return
	if _slot_of_peer().has(sender):
		_roster_set_ready(sender, ready)
		_broadcast_lobby_state()
		lobby_changed.emit()


## Host-only: change the lobby mode; broadcast + publish the attribute.
func set_mode(mode: int) -> void:
	if not is_host or state != State.LOBBY:
		return
	lobby_mode = mode
	if bridge != null and lobby_id != "":
		bridge.update_lobby_attributes({ATTR_MODE: lobby_mode})
	_broadcast_lobby_state()
	lobby_changed.emit()


## Host: start the round for the current roster. Requires every client ready.
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
		"build": String(credentials.get("product_version", "1.0.0")),
		"mode": lobby_mode,
		"seed": randi(),
		"player_count": roster.size(),
		"roster": _roster_wire(),
	}
	lobby_phase = "match"
	if bridge != null and lobby_id != "":
		bridge.update_lobby_attributes({
			ATTR_PHASE: "match",
			ATTR_JOINABLE: false,
			ATTR_MODE: lobby_mode,
		})
	_intent_guards = {}
	for entry in roster:
		var peer_id := int(entry["peer_id"])
		if peer_id != 1:
			_intent_guards[peer_id] = InputIntent.make_guard()
	_net.send_match_started(config)
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
			"puid": String(entry["puid"]),
			"ready": bool(entry["ready"]),
		})
	return out


# ------------------------------------------------------------ match traffic

## Client: submit one input intent for the own slot (reliable RPC).
func submit_intent(slot: int, action: String, arg: int) -> void:
	if state != State.IN_MATCH or is_host or slot != own_slot:
		return
	_intent_seq += 1
	_net.send_intent(slot, _intent_seq, action, arg)


## Host: called by GameHost's frame loop. Structural frames (match start,
## lock events, phase transitions) are sent reliably; the rest ride the
## periodic unreliable cadence.
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


## Host: capture the authoritative snapshot and broadcast it.
func send_snapshot(reliable: bool) -> void:
	if state != State.IN_MATCH or not is_host or game_host == null:
		return
	var snapshot: Dictionary = game_host.online_snapshot()
	_snap_id += 1
	_net.send_snapshot(
		"rpc_snapshot_r" if reliable else "rpc_snapshot_u",
		_snap_id,
		_chunk(var_to_bytes(snapshot))
	)


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
	_net.send_round_finished(result)
	lobby_phase = "lobby"
	if bridge != null and lobby_id != "":
		bridge.update_lobby_attributes({
			ATTR_PHASE: "lobby",
			ATTR_JOINABLE: true,
		})
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
	_net.send_return_to_lobby()
	_online_return_to_lobby()


# ------------------------------------------------------------------ leaving

func leave_session() -> void:
	## Leave lobby + transport; return to the entry state (stay signed in).
	_op_token += 1
	_shutting_down = true
	var was_in_match: bool = state == State.IN_MATCH
	_set_state(State.LEAVING)
	# Transport down first: no further inbound traffic.
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer.close()
		multiplayer.multiplayer_peer = null
	if bridge != null and lobby_id != "":
		bridge.leave_lobby_async(is_host)
	lobby_id = ""
	roster = []
	_intent_guards = {}
	_rx_parts = {}
	_rx_snap_id = -1
	own_slot = -1
	is_host = false
	lobby_phase = "lobby"
	transport_kind = TransportKind.NONE
	_shutting_down = false
	if game_host != null and game_host.has_method("online_leave_session"):
		game_host.online_leave_session(was_in_match)
	_set_state(State.READY if bridge != null else State.OFFLINE)
	_status("Ready" if bridge != null else "Offline (dev mode)")
	lobby_changed.emit()


func shutdown() -> void:
	## App-quit path: best-effort leave + EOS teardown.
	leave_session()
	if bridge != null and bridge.has_method("shutdown_eos"):
		bridge.shutdown_eos()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		shutdown()


# -------------------------------------------------------- transport plumbing

func _bind_multiplayer_signals() -> void:
	## Bound lazily (after the effective MultiplayerAPI is in place - in
	## tests each service instance gets a custom per-path multiplayer).
	if _signals_bound:
		return
	_signals_bound = true
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)


func _start_transport(host: bool, host_target: String) -> bool:
	## Create + install the transport peer. EOS paths go through the bridge
	## (it owns all EOSG identifiers); the dev harness uses ENet locally.
	_bind_multiplayer_signals()
	if bridge != null:
		var kind: int = bridge.select_transport_kind()
		var peer = bridge.create_transport(kind, SOCKET_ID, product_user_id, host_target, MAX_PLAYERS)
		if peer == null:
			return false
		transport_kind = kind
		multiplayer.multiplayer_peer = peer
		return true
	if not dev_transport_allowed():
		return false
	# Dev harness over ENet loopback.
	var peer := ENetMultiplayerPeer.new()
	var err: int
	if host:
		var port := 17777 + (Time.get_ticks_msec() % 512)
		err = peer.create_server(port, MAX_PLAYERS)
		if err == OK:
			dev_lobby_address = "127.0.0.1:%d" % port
	else:
		var parts := host_target.split(":")
		if parts.size() < 2:
			push_error("online: dev join expects address:port")
			return false
		err = peer.create_client(parts[0], int(parts[1]))
	if err != OK:
		push_error("online: ENet transport failed (err %d)" % err)
		return false
	transport_kind = TransportKind.ENET_DEV
	multiplayer.multiplayer_peer = peer
	return true


func _on_peer_connected(peer_id: int) -> void:
	# Client: the connection to the host just completed - run the hello.
	if not is_host and peer_id == 1:
		_net.send_client_hello(PROTOCOL_VERSION, display_name)
	_status("Connected: peer %d" % peer_id)


func _on_peer_disconnected(peer_id: int) -> void:
	if _shutting_down:
		return
	if not is_host:
		# Losing the host ends the match/session for this client; host
		# migration is out of scope for this implementation. Voluntary
		# leaves already cleared the session - ignore stragglers.
		if peer_id != 1 or not (state == State.IN_MATCH or state == State.LOBBY):
			return
		var in_match: bool = state == State.IN_MATCH
		if in_match and game_host != null and game_host.has_method("online_session_error"):
			game_host.online_session_error("HOST DISCONNECTED - match abandoned")
		leave_session()
		_status("Host disconnected")
		return
	# Host: drop the roster entry and rebroadcast; the match continues with
	# the remaining players (the abandoned slot simply stops moving).
	var kept: Array = []
	for entry in roster:
		if int(entry["peer_id"]) != peer_id:
			kept.append(entry)
	if kept.size() != roster.size():
		roster = kept
		_intent_guards.erase(peer_id)
		_broadcast_lobby_state()
		lobby_changed.emit()


# ------------------------------------------------------------- net handlers
# Every handler validates its sender. Hosts only accept rostered peers;
# clients only accept the host (peer 1 / multiplayer authority).

func _net_client_hello(sender: int, protocol: int, name: String) -> void:
	if not is_host:
		return
	if protocol != PROTOCOL_VERSION:
		push_warning("online: rejecting peer with protocol %d" % protocol)
		_disconnect_peer(sender)
		return
	if state == State.IN_MATCH:
		# No mid-match joins; the transport accept filter should have
		# refused this before a handshake completed.
		_disconnect_peer(sender)
		return
	if roster.size() >= MAX_PLAYERS:
		_disconnect_peer(sender)
		return
	for entry in roster:
		if int(entry["peer_id"]) == sender:
			return  # duplicate hello: idempotent
	var puid := _peer_puid(sender)
	if bridge != null and lobby_id != "" and not bridge.lobby_has_member(puid):
		# Not a lobby member: reject before it enters the roster.
		push_warning("online: rejecting non-lobby peer %s" % puid)
		_disconnect_peer(sender)
		return
	var name_clean := String(name).strip_edges().substr(0, 16)
	if name_clean.is_empty():
		name_clean = "P%d" % sender
	_roster_add(sender, puid, name_clean, false)
	_intent_guards[sender] = InputIntent.make_guard()
	_broadcast_lobby_state()
	lobby_changed.emit()


func _net_lobby_state(sender: int, wire: Dictionary) -> void:
	if is_host or sender != 1:
		return
	if int(wire.get("protocol", -1)) != PROTOCOL_VERSION:
		push_warning("online: lobby state with wrong protocol; ignoring")
		return
	lobby_id = String(wire.get("lobby_id", lobby_id))
	lobby_mode = int(wire.get("mode", lobby_mode))
	lobby_phase = String(wire.get("phase", lobby_phase))
	var new_roster: Array = []
	var entries = wire.get("roster", [])
	if entries is Array:
		for entry in entries:
			if entry is Dictionary:
				new_roster.append({
					"peer_id": int(entry.get("peer_id", 0)),
					"puid": String(entry.get("puid", "")),
					"name": String(entry.get("name", "")),
					"ready": bool(entry.get("ready", false)),
					"slot": int(entry.get("slot", -1)),
					"connected": true,
				})
	roster = new_roster
	var mine := multiplayer.get_unique_id()
	for entry in roster:
		if int(entry["peer_id"]) == mine:
			own_slot = int(entry["slot"])
	if state == State.CONNECTING and own_slot >= 0:
		_set_state(State.LOBBY)
		_status("Joined lobby")
		lobby_changed.emit()
	else:
		lobby_changed.emit()


func _net_match_started(sender: int, config: Dictionary) -> void:
	if is_host or sender != 1:
		return
	if int(config.get("protocol", -1)) != PROTOCOL_VERSION:
		leave_session()
		_status("Host protocol mismatch - left lobby")
		return
	if own_slot < 0:
		# Never rostered by the host (a race the host-side ready gate makes
		# impossible): refuse the match instead of desyncing.
		push_warning("online: match_started before a roster assignment; ignoring")
		return
	lobby_phase = "match"
	_set_state(State.IN_MATCH)
	_status("Match starting")
	if game_host != null and game_host.has_method("online_begin_client_match"):
		config["own_slot"] = own_slot
		game_host.online_begin_client_match(config)


func _net_round_finished(sender: int, result: Dictionary) -> void:
	if is_host or sender != 1:
		return
	lobby_phase = "lobby"
	if game_host != null and game_host.has_method("online_show_results"):
		game_host.online_show_results(result)


func _net_return_to_lobby(sender: int) -> void:
	if is_host or sender != 1:
		return
	_online_return_to_lobby()


func _online_return_to_lobby() -> void:
	lobby_phase = "lobby"
	if game_host != null and game_host.has_method("online_return_to_lobby"):
		game_host.online_return_to_lobby()
	if state == State.IN_MATCH:
		_set_state(State.LOBBY)
		_status("Back in lobby")
	lobby_changed.emit()


func _net_submit_intent(sender: int, slot: int, seq: int, action: String, arg: int) -> void:
	if not is_host or state != State.IN_MATCH or game_host == null:
		return
	var guard = _intent_guards.get(sender)
	if guard == null:
		return  # sender never completed the handshake
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


func _net_snapshot(sender: int, snap_id: int, part: int, count: int, bytes: PackedByteArray) -> void:
	if is_host or sender != 1 or game_host == null:
		return
	if snap_id < _rx_snap_id or count <= 0 or count >= 16 or part < 0 or part >= count:
		return  # stale frame or malformed chunk header
	if snap_id != _rx_snap_id:
		_rx_snap_id = snap_id
		_rx_parts = {}
	_rx_parts[part] = bytes
	if _rx_parts.size() < count:
		return  # frame incomplete; a newer snapshot id supersedes losses
	var data := PackedByteArray()
	for i in count:
		var piece = _rx_parts.get(i)
		if piece == null:
			return
		data.append_array(piece)
	_rx_parts = {}
	var snapshot = bytes_to_var(data)
	if game_host.has_method("online_apply_snapshot"):
		game_host.online_apply_snapshot(snapshot)


# ------------------------------------------------------------------ helpers

func _roster_add(peer_id: int, puid: String, name: String, ready: bool) -> void:
	roster.append({
		"peer_id": peer_id,
		"puid": puid,
		"name": name,
		"ready": ready,
		"slot": roster.size(),
		"connected": true,
	})


func _broadcast_lobby_state() -> void:
	if not is_host:
		return
	_net.send_lobby_state({
		"protocol": PROTOCOL_VERSION,
		"lobby_id": lobby_id,
		"mode": lobby_mode,
		"phase": lobby_phase,
		"roster": _roster_wire(),
	})


func _slot_of_peer() -> Dictionary:
	var out: Dictionary = {}
	for entry in roster:
		out[int(entry["peer_id"])] = int(entry["slot"])
	return out


func _peer_puid(peer_id: int) -> String:
	## EOS transports expose a peer -> product user id mapping.
	if multiplayer.multiplayer_peer == null:
		return ""
	var peer = multiplayer.multiplayer_peer
	if peer.has_method("get_peer_user_id"):
		return String(peer.get_peer_user_id(peer_id))
	return ""


func _disconnect_peer(peer_id: int) -> void:
	if multiplayer.multiplayer_peer == null:
		return
	multiplayer.multiplayer_peer.disconnect_peer(peer_id, true)


func _set_state(next: int) -> void:
	if state == next:
		return
	state = next
	state_changed.emit()


func _status(text: String) -> void:
	status_text = text
	status_changed.emit(text)


func _process(delta: float) -> void:
	# Client connect timeout: EOS relay negotiation can take a while, but
	# an unbounded CONNECTING state would strand the UI. The state itself
	# clears when the host's lobby_state (after the hello round trip) lands.
	if state == State.CONNECTING and not _connect_timed_out:
		_connect_timer += delta
		if _connect_timer >= CONNECT_TIMEOUT:
			_connect_timed_out = true
			leave_session()
			_status("Connection timed out")