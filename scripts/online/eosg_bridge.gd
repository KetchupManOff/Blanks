extends Node
## Bridge to the EOSG addon (https://github.com/3ddelano/epic-online-services-godot).
##
## IMPORTANT: this script statically references EOSG classes (EOS,
## HCredentials, HLog, BaseClass) and scripts (HPlatform, HAuth, HLobbies,
## HP2P, HLobby). It is ONLY ever load()-ed by OnlineService after the
## addon files exist AND the global classes are registered (the editor must
## have scanned the addon once). It must never be preloaded from a script
## that has to parse without the addon.
##
## The bridge keeps every EOSG identifier in one place:
##  * platform init + auth (Dev Auth Tool in debug, anonymous Device ID in release),
##  * EOS lobby create/search/join/leave + attribute publish,
##  * EOS P2P NAT/relay diagnostics,
##  * transport selection: the project's own "EOSMultiplayerPeer"
##    GDExtension first (addons/eos-transport), else EOSG's built-in
##    "EOSGMultiplayerPeer".
## It never touches gameplay code; OnlineService drives it and owns the
## state machine.

signal kicked
signal lobby_updated

const ServiceScript = preload("res://scripts/online/online_service.gd")
const HPlatformScript = preload("res://addons/epic-online-services-godot/heos/hplatform.gd")
const HAuthScript = preload("res://addons/epic-online-services-godot/heos/hauth.gd")
const HLobbiesScript = preload("res://addons/epic-online-services-godot/heos/hlobbies.gd")
const HP2PScript = preload("res://addons/epic-online-services-godot/heos/hp2p.gd")

const TransportKind = ServiceScript.TransportKind

# Lobby attribute keys shared with OnlineService (kept in sync manually:
# the bridge must not load OnlineService's runtime instance).
const ATTR_PROTOCOL := "tye_protocol"
const ATTR_BUILD := "tye_build"
const ATTR_NAME := "tye_name"
const ATTR_MODE := "tye_mode"
const ATTR_PHASE := "tye_phase"
const ATTR_JOINABLE := "tye_joinable"
const ATTR_MEMBER_NAME := "tye_member_name"
const BUCKET_ID := "tyecoop"

var _platform: Node = null
var _auth: Node = null
var _lobbies: Node = null
var _p2p: Node = null
var _lobby = null  # HLobby (untyped: keeps bridge parse independent of class cache details)

var product_user_id: String = ""
var display_name: String = ""


func _ready() -> void:
	set_process(true)
	_platform = HPlatformScript.new()
	_auth = HAuthScript.new()
	_lobbies = HLobbiesScript.new()
	_p2p = HP2PScript.new()
	add_child(_platform)
	add_child(_auth)
	add_child(_lobbies)
	add_child(_p2p)


func _process(_delta: float) -> void:
	# EOSG GDExtension requires a per-frame tick; it is registered as an
	# engine singleton by the extension itself (no autoload needed).
	var ieos = Engine.get_singleton("IEOS")
	if ieos != null:
		ieos.tick()


# ---------------------------------------------------------------- platform/auth

func setup_eos_async(creds: Dictionary) -> bool:
	var hcreds := HCredentials.new()
	hcreds.product_name = String(creds.get("product_name", ""))
	hcreds.product_version = String(creds.get("product_version", ""))
	hcreds.product_id = String(creds.get("product_id", ""))
	hcreds.sandbox_id = String(creds.get("sandbox_id", ""))
	hcreds.deployment_id = String(creds.get("deployment_id", ""))
	hcreds.client_id = String(creds.get("client_id", ""))
	hcreds.client_secret = String(creds.get("client_secret", ""))
	hcreds.encryption_key = String(creds.get("encryption_key", ""))
	return await _platform.setup_eos_async(hcreds)


func login_dev_async(url: String, credential: String) -> bool:
	var ok: bool = await _auth.login_devtool_async(url, credential)
	if ok:
		product_user_id = String(_auth.product_user_id)
		display_name = String(_auth.display_name)
	return ok


func login_device_async(display_name_arg: String) -> bool:
	var ok: bool = await _auth.login_anonymous_async(display_name_arg)
	if ok:
		product_user_id = String(_auth.product_user_id)
		display_name = String(_auth.display_name)
	return ok


func shutdown_eos() -> void:
	# App-quit teardown; release the platform and stop the SDK. Logout is
	# implicit: the platform release tears down the auth sessions.
	EOS.Platform.PlatformInterface.release()
	var result = EOS.Platform.PlatformInterface.shutdown()
	if not EOS.is_success(result):
		push_warning("eosg: EOS shutdown failed: %s" % EOS.result_str(result))


# --------------------------------------------------------------------- lobby

func create_lobby_async(max_members: int, attributes: Dictionary) -> Dictionary:
	## Host: create the public, joinable EOS lobby. Returns {"lobby_id",
	## "owner_puid"} or {} on failure.
	var opts := EOS.Lobby.CreateLobbyOptions.new()
	opts.max_lobby_members = max_members
	opts.permission_level = EOS.Lobby.LobbyPermissionLevel.PublicAdvertised
	opts.presence_enabled = false
	opts.allow_invites = true
	opts.bucket_id = BUCKET_ID
	opts.enable_rtc_room = false
	var lobby = await _lobbies.create_lobby_async(opts)
	if lobby == null:
		return {}
	_install_lobby(lobby)
	for key in attributes:
		_lobby.add_attribute(String(key), attributes[key])
	_lobby.add_current_member_attribute(ATTR_MEMBER_NAME, display_name)
	await _lobby.update_async()
	return {
		"lobby_id": String(_lobby.lobby_id),
		"owner_puid": String(_lobby.owner_product_user_id),
	}


func search_lobbies_async(protocol: int) -> Array:
	## Find public lobbies advertising this protocol version. Returns an
	## array of plain lobby summaries for the browser UI.
	var results = await _lobbies.search_by_attribute_async({
		"key": ATTR_PROTOCOL,
		"value": protocol,
		"comparison": EOS.ComparisonOp.Equal,
	})
	if results == null:
		return []
	var out: Array = []
	for lobby in results:
		if lobby == null or not lobby.is_valid():
			continue
		var summary := {
			"lobby_id": String(lobby.lobby_id),
			"owner_puid": String(lobby.owner_product_user_id),
			"members": int(lobby.members.size()),
			"max_members": int(lobby.max_members),
			"available_slots": int(lobby.available_slots),
		}
		for attr_key in [ATTR_NAME, ATTR_MODE, ATTR_PHASE, ATTR_JOINABLE, ATTR_BUILD]:
			var attr: Dictionary = lobby.get_attribute(attr_key)
			if not attr.is_empty():
				summary[attr_key] = attr.get("value")
		out.append(summary)
	return out


func join_lobby_by_id_async(lobby_id: String) -> Dictionary:
	## Join by the opaque EOS lobby id. Returns {"lobby_id", "owner_puid"}
	## or {} when the lobby is missing/full/incompatible.
	var lobby = await _lobbies.join_by_id_async(lobby_id)
	if lobby == null:
		return {}
	_install_lobby(lobby)
	_lobby.add_current_member_attribute(ATTR_MEMBER_NAME, display_name)
	_lobby.update_async()  # fire-and-forget: publish the member name
	return {
		"lobby_id": String(_lobby.lobby_id),
		"owner_puid": String(_lobby.owner_product_user_id),
	}


func _install_lobby(lobby) -> void:
	_lobby = lobby
	_lobby.lobby_updated.connect(func(): lobby_updated.emit())
	_lobby.kicked_from_lobby.connect(func(): _on_kicked())


func _on_kicked() -> void:
	_lobby = null
	kicked.emit()


func lobby_has_member(puid: String) -> bool:
	## Membership gate used by the host before accepting P2P connections
	## and hello handshakes: only current EOS lobby members may join the
	## match transport.
	if _lobby == null or not _lobby.is_valid() or puid.is_empty():
		return false
	for member in _lobby.members:
		if String(member.product_user_id) == puid:
			return true
	return false


func lobby_member_puids() -> PackedStringArray:
	var out := PackedStringArray()
	if _lobby == null or not _lobby.is_valid():
		return out
	for member in _lobby.members:
		out.append(String(member.product_user_id))
	return out


func lobby_owner_puid() -> String:
	if _lobby == null or not _lobby.is_valid():
		return ""
	return String(_lobby.owner_product_user_id)


func set_member_name(name: String) -> void:
	if _lobby != null and _lobby.is_valid():
		_lobby.add_current_member_attribute(ATTR_MEMBER_NAME, name)
		_lobby.update_async()


func update_lobby_attributes(attributes: Dictionary) -> void:
	## Host: publish lobby-level attributes (mode/phase/joinability) so the
	## browser stays fresh between rounds.
	if _lobby == null or not _lobby.is_valid():
		return
	for key in attributes:
		_lobby.add_attribute(String(key), attributes[key])
	_lobby.update_async()


func leave_lobby_async(destroy: bool) -> void:
	## Leave the current lobby (or destroy it when we are the owner).
	if _lobby == null:
		return
	var lobby = _lobby
	_lobby = null
	if not lobby.is_valid():
		return
	if destroy and lobby.is_owner():
		await lobby.destroy_async()
	else:
		await lobby.leave_async()


# ------------------------------------------------------------ P2P transport

func select_transport_kind() -> int:
	## Prefer the project's own EOS GDExtension transport; fall back to the
	## addon's EOSGMultiplayerPeer (also EOS-backed, same RPC contract).
	if ClassDB.class_exists("EOSMultiplayerPeer"):
		return TransportKind.CUSTOM_EOS
	if ClassDB.class_exists("EOSGMultiplayerPeer"):
		return TransportKind.EOSG
	return TransportKind.NONE


func create_transport(
	kind: int,
	socket_id: String,
	local_puid: String,
	host_puid: String,
	max_peers: int
) -> MultiplayerPeer:
	## Create a configured EOS-backed MultiplayerPeer. `host_puid` is empty
	## when hosting. Returns null on failure. The peer contract matches
	## Godot's MultiplayerPeer so the RPC layer stays transport-agnostic.
	match kind:
		TransportKind.CUSTOM_EOS:
			return _create_custom_transport(socket_id, local_puid, host_puid, max_peers)
		TransportKind.EOSG:
			return _create_eosg_transport(socket_id, local_puid, host_puid, max_peers)
		_:
			return null


func _create_custom_transport(
	socket_id: String,
	local_puid: String,
	host_puid: String,
	max_peers: int
) -> MultiplayerPeer:
	var peer = ClassDB.instantiate("EOSMultiplayerPeer")
	if peer == null:
		push_error("online: failed to instantiate EOSMultiplayerPeer")
		return null
	peer.configure(local_puid)
	if host_puid.is_empty():
		# Host: only peers that joined the EOS lobby may connect.
		peer.allow_peers(lobby_member_puids())
		var err: int = peer.create_server(socket_id)
		if err != OK:
			push_error("online: EOS transport create_server failed (%d)" % err)
			return null
	else:
		var err: int = peer.create_client(socket_id, host_puid)
		if err != OK:
			push_error("online: EOS transport create_client failed (%d)" % err)
			return null
	return peer


func _create_eosg_transport(
	socket_id: String,
	local_puid: String,
	host_puid: String,
	max_peers: int
) -> MultiplayerPeer:
	var peer = EOSGMultiplayerPeer.new()
	EOSGMultiplayerPeer.set_local_user_id(local_puid)
	if host_puid.is_empty():
		# Host: manual accept - connections outside the EOS lobby are denied.
		peer.set_auto_accept_connection_requests(false)
		peer.incoming_connection_request.connect(_on_incoming_connection_request.bind(peer))
		var err: int = peer.create_server(socket_id)
		if err != OK:
			push_error("online: EOSG transport create_server failed (%d)" % err)
			return null
	else:
		var err: int = peer.create_client(socket_id, host_puid)
		if err != OK:
			push_error("online: EOSG transport create_client failed (%d)" % err)
			return null
	return peer


func _on_incoming_connection_request(data: Dictionary, peer) -> void:
	## EOSG transport accept filter: accept only current EOS lobby members,
	## deny everyone else (full lobby, strangers, stale peers).
	var puid := String(data.get("remote_user_id", data.get("remote_user", "")))
	if puid.is_empty() or not lobby_has_member(puid):
		push_warning("online: denying P2P connection request from non-lobby user %s" % puid)
		peer.deny_connection_request(puid)
		return
	peer.accept_connection_request(puid)


# ------------------------------------------------------------- diagnostics

func nat_type_async() -> String:
	var nat: int = await _p2p.get_nat_type_async()
	var key = EOS.P2P.NATType.find_key(nat)
	return String(key) if key != null else "Unknown"


func packet_queue_info() -> Dictionary:
	return _p2p.get_packet_queue_info()


func allow_relay_fallback(allow: bool) -> void:
	# Relay control: allow the EOS relay as a fallback when NAT traversal
	# fails (disable only for privacy-tuned deployments).
	if not "AllowRelays" in EOS.P2P.RelayControl:
		return
	_p2p.set_relay_control(
		EOS.P2P.RelayControl.AllowRelays if allow else EOS.P2P.RelayControl.NoRelay
	)