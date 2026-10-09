// EOSMultiplayerPeer implementation. See eos_multiplayer_peer.h for the
// transport contract and design notes.

#include "eos_multiplayer_peer.h"

#include "godot_cpp/core/class_db.hpp"

#include <algorithm>
#include <cstring>

using namespace godot;

EOS_ProductUserId EOSMultiplayerPeer::s_local_user_id = nullptr;

void EOSMultiplayerPeer::_bind_methods() {
	ClassDB::bind_method(D_METHOD("configure", "local_user_id"), &EOSMultiplayerPeer::configure);
	ClassDB::bind_method(D_METHOD("allow_peers", "puids"), &EOSMultiplayerPeer::allow_peers);
	ClassDB::bind_method(D_METHOD("clear_allowed_peers"), &EOSMultiplayerPeer::clear_allowed_peers);
	ClassDB::bind_method(D_METHOD("create_server", "socket_id"), &EOSMultiplayerPeer::create_server);
	ClassDB::bind_method(D_METHOD("create_client", "socket_id", "host_puid"), &EOSMultiplayerPeer::create_client);
	ClassDB::bind_method(D_METHOD("get_active_mode"), &EOSMultiplayerPeer::get_active_mode);
	ClassDB::bind_method(D_METHOD("get_socket"), &EOSMultiplayerPeer::get_socket);
	ClassDB::bind_method(D_METHOD("get_max_peers"), &EOSMultiplayerPeer::get_max_peers);
	ClassDB::bind_method(D_METHOD("set_max_peers", "max"), &EOSMultiplayerPeer::set_max_peers);
	ClassDB::bind_method(D_METHOD("get_peer_user_id", "peer_id"), &EOSMultiplayerPeer::get_peer_user_id);
	ClassDB::bind_method(D_METHOD("get_peer_id_from_user", "puid"), &EOSMultiplayerPeer::get_peer_id_from_user);
	ClassDB::bind_method(D_METHOD("has_peer", "peer_id"), &EOSMultiplayerPeer::has_peer);
	ClassDB::bind_method(D_METHOD("is_allowing_delayed_delivery"), &EOSMultiplayerPeer::is_allowing_delayed_delivery);
	ClassDB::bind_method(D_METHOD("set_allow_delayed_delivery", "allow"), &EOSMultiplayerPeer::set_allow_delayed_delivery);
}

// ------------------------------------------------------------------- setup

void EOSMultiplayerPeer::configure(const String &local_user_id) {
	CharString utf8 = local_user_id.utf8();
	s_local_user_id = eosg_string_to_product_user_id(utf8.get_data());
}

void EOSMultiplayerPeer::allow_peers(const PackedStringArray &puids) {
	allowed_users.clear();
	for (int i = 0; i < puids.size(); i++) {
		EOS_ProductUserId user = eosg_string_to_product_user_id(puids[i].utf8().get_data());
		if (user != nullptr) {
			allowed_users.push_back(user);
		}
	}
}

void EOSMultiplayerPeer::clear_allowed_peers() {
	allowed_users.clear();
}

int EOSMultiplayerPeer::get_max_peers() const {
	return max_peers;
}

void EOSMultiplayerPeer::set_max_peers(int max) {
	max_peers = CLAMP(max, 1, 255);
}

String EOSMultiplayerPeer::get_socket() const {
	return String(socket_id.SocketName);
}

int EOSMultiplayerPeer::get_active_mode() const {
	return static_cast<int>(active_mode);
}

String EOSMultiplayerPeer::get_peer_user_id(int peer_id) const {
	if (!peers.has(peer_id)) {
		return "";
	}
	return eosg_product_user_id_to_string(peers[peer_id].user_id);
}

int EOSMultiplayerPeer::get_peer_id_from_user(const String &puid) const {
	if (user_key_to_peer.has(puid)) {
		return user_key_to_peer[puid];
	}
	return 0;
}

bool EOSMultiplayerPeer::has_peer(int peer_id) const {
	return peers.has(peer_id);
}

bool EOSMultiplayerPeer::is_allowing_delayed_delivery() const {
	return allow_delayed_delivery;
}

void EOSMultiplayerPeer::set_allow_delayed_delivery(bool allow) {
	allow_delayed_delivery = allow;
}

Error EOSMultiplayerPeer::create_server(const String &socket_id_str) {
	ERR_FAIL_NULL_V_MSG(s_local_user_id, ERR_UNCONFIGURED, "Failed to create server. Local user id has not been set (call configure() after login).");
	ERR_FAIL_COND_V_MSG(_is_active(), ERR_ALREADY_IN_USE, "Failed to create server. Multiplayer instance is already active.");
	ERR_FAIL_COND_V_MSG(socket_id_str.is_empty() || socket_id_str.length() > EOS_P2P_SOCKETID_SOCKETNAME_SIZE, ERR_INVALID_PARAMETER, "Failed to create server. Invalid socket id.");

	memset(socket_id.SocketName, 0, sizeof(socket_id.SocketName));
	socket_id.ApiVersion = EOS_P2P_SOCKETID_API_LATEST;
	STRNCPY_S(socket_id.SocketName, EOS_P2P_SOCKETID_SOCKETNAME_SIZE, socket_id_str.utf8().get_data(), socket_id_str.length());

	unique_id = 1;
	active_mode = MODE_SERVER;
	connection_status = CONNECTION_CONNECTED;
	next_assigned_peer_id = 2;
	refusing_new_connections = false;

	// P2P notifications: accept-gated connection requests + lifecycle.
	{
		EOS_P2P_AddNotifyPeerConnectionRequestOptions opts{};
		opts.ApiVersion = EOS_P2P_ADDNOTIFYPEERCONNECTIONREQUEST_API_LATEST;
		opts.LocalUserId = s_local_user_id;
		opts.SocketId = &socket_id;
		opts.bAllowDelayedDelivery = EOS_TRUE;
		notify_request = IEOS::get_singleton()->_p2p_add_notify_peer_connection_request(&opts, _connection_request_cb, this);
	}
	{
		EOS_P2P_AddNotifyPeerConnectionEstablishedOptions opts{};
		opts.ApiVersion = EOS_P2P_ADDNOTIFYPEERCONNECTIONESTABLISHED_API_LATEST;
		opts.LocalUserId = s_local_user_id;
		opts.SocketId = &socket_id;
		notify_established = IEOS::get_singleton()->_p2p_add_notify_peer_connection_established(&opts, _connection_established_cb, this);
	}
	{
		EOS_P2P_AddNotifyPeerConnectionClosedOptions opts{};
		opts.ApiVersion = EOS_P2P_ADDNOTIFYPEERCONNECTIONCLOSED_API_LATEST;
		opts.LocalUserId = s_local_user_id;
		opts.SocketId = &socket_id;
		notify_closed = IEOS::get_singleton()->_p2p_add_notify_peer_connection_closed(&opts, _connection_closed_cb, this);
	}
	ERR_FAIL_COND_V_MSG(notify_request == EOS_INVALID_NOTIFICATIONID, ERR_CANT_CREATE, "Failed to create server. EOS P2P notification registration failed.");
	return OK;
}

Error EOSMultiplayerPeer::create_client(const String &socket_id_str, const String &host_puid) {
	ERR_FAIL_NULL_V_MSG(s_local_user_id, ERR_UNCONFIGURED, "Failed to create client. Local user id has not been set (call configure() after login).");
	ERR_FAIL_COND_V_MSG(_is_active(), ERR_ALREADY_IN_USE, "Failed to create client. Multiplayer instance is already active.");
	ERR_FAIL_COND_V_MSG(socket_id_str.is_empty() || socket_id_str.length() > EOS_P2P_SOCKETID_SOCKETNAME_SIZE, ERR_INVALID_PARAMETER, "Failed to create client. Invalid socket id.");

	EOS_ProductUserId host_user = eosg_string_to_product_user_id(host_puid.utf8().get_data());
	ERR_FAIL_NULL_V_MSG(host_user, ERR_INVALID_PARAMETER, "Failed to create client. Invalid host product user id.");

	memset(socket_id.SocketName, 0, sizeof(socket_id.SocketName));
	socket_id.ApiVersion = EOS_P2P_SOCKETID_API_LATEST;
	STRNCPY_S(socket_id.SocketName, EOS_P2P_SOCKETID_SOCKETNAME_SIZE, socket_id_str.utf8().get_data(), socket_id_str.length());

	active_mode = MODE_CLIENT;
	connection_status = CONNECTION_CONNECTING;
	// Temporary id: the host assigns the real one via EVENT_ASSIGN_ID.
	unique_id = 0;
	target_peer = 0;
	refusing_new_connections = false;

	{
		EOS_P2P_AddNotifyPeerConnectionEstablishedOptions opts{};
		opts.ApiVersion = EOS_P2P_ADDNOTIFYPEERCONNECTIONESTABLISHED_API_LATEST;
		opts.LocalUserId = s_local_user_id;
		opts.SocketId = &socket_id;
		notify_established = IEOS::get_singleton()->_p2p_add_notify_peer_connection_established(&opts, _connection_established_cb, this);
	}
	{
		EOS_P2P_AddNotifyPeerConnectionClosedOptions opts{};
		opts.ApiVersion = EOS_P2P_ADDNOTIFYPEERCONNECTIONCLOSED_API_LATEST;
		opts.LocalUserId = s_local_user_id;
		opts.SocketId = &socket_id;
		notify_closed = IEOS::get_singleton()->_p2p_add_notify_peer_connection_closed(&opts, _connection_closed_cb, this);
	}

	// Open the connection: a HELLO frame triggers the host's request
	// notification (allow-delayed delivery lets EOS queue it until the
	// host accepts).
	uint32_t stream = next_stream++;
	Error err = _send_frame(host_user, EVENT_HELLO, 0, 0, stream, nullptr, 0, EOS_EPacketReliability::EOS_PR_ReliableOrdered);
	if (err != OK) {
		_close();
		return err;
	}
	return OK;
}

// ------------------------------------------------------------ notifications

void EOSMultiplayerPeer::_connection_request_cb(const EOS_P2P_OnIncomingConnectionRequestInfo *data, void *client_data) {
	// Host side only. Gate: not refusing, allow-listed, under capacity.
	// Requests are accepted immediately when allowed (the EOS lobby
	// membership list IS the gate), refused otherwise.
	EOSMultiplayerPeer *self = static_cast<EOSMultiplayerPeer *>(client_data);
	ERR_FAIL_NULL(self);
	if (self->active_mode != MODE_SERVER || self->refusing_new_connections) {
		return;
	}
	bool allowed = self->_is_allowed(data->RemoteUserId);
	if (!allowed || self->_at_capacity()) {
		EOS_P2P_CloseConnectionOptions close{};
		close.ApiVersion = EOS_P2P_CLOSECONNECTION_API_LATEST;
		close.LocalUserId = self->s_local_user_id;
		close.RemoteUserId = data->RemoteUserId;
		close.SocketId = &self->socket_id;
		IEOS::get_singleton()->_p2p_close_connection(&close);
		return;
	}
	EOS_P2P_AcceptConnectionOptions accept{};
	accept.ApiVersion = EOS_P2P_ACCEPTCONNECTION_API_LATEST;
	accept.LocalUserId = self->s_local_user_id;
	accept.RemoteUserId = data->RemoteUserId;
	accept.SocketId = &self->socket_id;
	IEOS::get_singleton()->_p2p_accept_connection(&accept);
}

void EOSMultiplayerPeer::_connection_established_cb(const EOS_P2P_OnPeerConnectionEstablishedInfo *data, void *client_data) {
	EOSMultiplayerPeer *self = static_cast<EOSMultiplayerPeer *>(client_data);
	ERR_FAIL_NULL(self);
	if (!self->_is_active()) {
		return;
	}
	if (self->active_mode == MODE_SERVER) {
		// Host: accept was already gated; assign the next id and send it.
		self->_assign_client(data->RemoteUserId);
	} else if (self->active_mode == MODE_CLIENT && data->RemoteUserId != nullptr) {
		// Client: the host will send our assigned id; note the host peer.
		if (!self->peers.has(1)) {
			EOSMultiplayerPeer::RemotePeer peer{};
			peer.user_id = data->RemoteUserId;
			peer.peer_id = 1;
			self->peers.insert(1, peer);
			self->user_key_to_peer[eosg_product_user_id_to_string(data->RemoteUserId)] = 1;
		}
	}
}

void EOSMultiplayerPeer::_connection_closed_cb(const EOS_P2P_OnRemoteConnectionClosedInfo *data, void *client_data) {
	EOSMultiplayerPeer *self = static_cast<EOSMultiplayerPeer *>(client_data);
	ERR_FAIL_NULL(self);
	if (!self->_is_active()) {
		return;
	}
	RemotePeer *peer = self->_find_peer_by_user(data->RemoteUserId);
	if (peer != nullptr) {
		uint32_t id = peer->peer_id;
		self->peers.erase(id);
		self->user_key_to_peer.erase(eosg_product_user_id_to_string(data->RemoteUserId));
		self->emit_signal("peer_disconnected", (int64_t)id);
	}
	if (self->active_mode == MODE_CLIENT &&
			data->Reason != EOS_EConnectionClosedReason::EOS_CCR_ClosedByLocalUser) {
		// Lost the host: no host migration - tear the transport down.
		self->_close();
	}
}

void EOSMultiplayerPeer::_assign_client(EOS_ProductUserId user) {
	// Assign ids 2.. in accept order, bounded by capacity.
	ERR_FAIL_COND(active_mode != MODE_SERVER);
	ERR_FAIL_COND(!_is_allowed(user));
	ERR_FAIL_COND(_at_capacity());

	uint32_t assigned = next_assigned_peer_id++;
	RemotePeer peer{};
	peer.user_id = user;
	peer.peer_id = assigned;
	peers.insert(assigned, peer);
	user_key_to_peer[eosg_product_user_id_to_string(user)] = assigned;

	// Send the assignment (reliable, on the control stream).
	uint8_t payload[4];
	encode_uint32(assigned, payload);
	uint32_t stream = next_stream++;
	Error err = _send_frame(user, EVENT_ASSIGN_ID, 1, 0, stream, payload, sizeof(payload), EOS_EPacketReliability::EOS_PR_ReliableOrdered);
	if (err != OK) {
		_drop_peer(assigned);
		return;
	}
	emit_signal("peer_connected", (int64_t)assigned);
}

// ------------------------------------------------------------------- rx path

void EOSMultiplayerPeer::_poll() {
	if (!_is_active()) {
		return;
	}
	// Drain every waiting EOS packet into the queue (per socket). The EOS
	// state itself advances via IEOS.tick() from the GDScript bridge.
	while (true) {
		EOS_P2P_GetNextReceivedPacketSizeOptions size_opts{};
		size_opts.ApiVersion = EOS_P2P_GETNEXTRECEIVEDPACKETSIZE_API_LATEST;
		size_opts.LocalUserId = s_local_user_id;
		size_opts.SocketId = &socket_id;
		uint32_t next_size = 0;
		if (IEOS::get_singleton()->_p2p_get_next_packet_size(&size_opts, &next_size) != EOS_EResult::EOS_Success) {
			break;
		}
		if (rx_buffer.size() < (int)next_size) {
			rx_buffer.resize(next_size);
		}
		EOS_P2P_ReceivePacketOptions rx_opts{};
		rx_opts.ApiVersion = EOS_P2P_RECEIVEPACKET_API_LATEST;
		rx_opts.LocalUserId = s_local_user_id;
		rx_opts.MaxDataSizeBytes = next_size;
		rx_opts.SocketId = &socket_id;
		uint8_t channel = 0;
		EOS_ProductUserId remote = nullptr;
		EOS_P2P_SocketId socket{};
		uint32_t out_size = next_size;
		if (IEOS::get_singleton()->_p2p_receive_packet(&rx_opts, rx_buffer.data(), &out_size, &channel, &remote, &socket) != EOS_EResult::EOS_Success) {
			break;
		}
		if (out_size < HEADER_SIZE) {
			continue; // Malformed frame.
		}
		_handle_rx_frame(remote, channel, rx_buffer.data(), out_size);
	}
}

void EOSMultiplayerPeer::_handle_rx_frame(EOS_ProductUserId remote, uint8_t channel, const uint8_t *data, uint32_t size) {
	uint8_t event = data[INDEX_EVENT];
	uint32_t sender = decode_uint32(&data[INDEX_SENDER]);
	uint32_t stream = decode_uint32(&data[INDEX_STREAM]);

	if (event == EVENT_ASSIGN_ID) {
		// Client: adopt the host-assigned id, then surface the host peer.
		ERR_FAIL_COND(active_mode != MODE_CLIENT);
		if (size < HEADER_SIZE + 4) {
			return;
		}
		uint32_t assigned = decode_uint32(&data[HEADER_SIZE]);
		ERR_FAIL_COND_MSG(assigned == 0 || assigned == 1, "Host assigned an invalid peer id.");
		unique_id = assigned;
		connection_status = CONNECTION_CONNECTED;
		if (!peers.has(1)) {
			RemotePeer peer{};
			peer.user_id = remote;
			peer.peer_id = 1;
			peers.insert(1, peer);
			user_key_to_peer[eosg_product_user_id_to_string(remote)] = 1;
		}
		emit_signal("peer_connected", (int64_t)1);
		return;
	}
	if (event == EVENT_HELLO) {
		// Host: duplicate HELLO after assignment - idempotent, ignore.
		return;
	}
	if (event != EVENT_DATA) {
		return;
	}

	RemotePeer *peer = _find_peer_by_user(remote);
	if (peer == nullptr) {
		return; // Unknown/not-yet-assigned remote: drop.
	}
	if (size < FRAG_HEADER_SIZE) {
		return;
	}
	uint16_t index = decode_uint16(&data[INDEX_FRAG_INDEX]);
	uint16_t total = decode_uint16(&data[INDEX_FRAG_TOTAL]);
	if (total == 0 || index >= total) {
		return;
	}
	FragStream &frag = peer->streams[stream];
	if (frag.total == 0) {
		frag.total = total;
		frag.parts.assign(total, {});
	} else if (frag.total != total) {
		return; // Corrupt stream.
	}
	const uint8_t *payload = data + FRAG_HEADER_SIZE;
	uint32_t payload_size = size - FRAG_HEADER_SIZE;
	frag.parts[index].assign(payload, payload + payload_size);

	// Complete?
	bool complete = true;
	size_t total_size = 0;
	for (const auto &part : frag.parts) {
		if (part.empty()) {
			complete = false;
			break;
		}
		total_size += part.size();
	}
	if (!complete) {
		return;
	}
	// Reassemble and enqueue for the MultiplayerAPI.
	QueuedPacket packet;
	packet.payload.reserve(total_size);
	for (auto &part : frag.parts) {
		packet.payload.insert(packet.payload.end(), part.begin(), part.end());
	}
	packet.sender = peer->peer_id;
	packet.channel = channel > 0 ? channel - 1 : 0;
	packet.mode = TRANSFER_MODE_RELIABLE;
	peer->streams.erase(stream);
	packet_queue.push_back(packet);
}

// ------------------------------------------------------------------- tx path

Error EOSMultiplayerPeer::_put_packet(const uint8_t *p_buffer, int32_t p_buffer_size) {
	ERR_FAIL_COND_V_MSG(!_is_active(), ERR_UNCONFIGURED, "The multiplayer instance isn't currently active.");
	ERR_FAIL_COND_V_MSG(connection_status != CONNECTION_CONNECTED, ERR_UNCONFIGURED, "The multiplayer instance isn't currently connected.");
	ERR_FAIL_COND_V_MSG(active_mode == MODE_CLIENT && !peers.has(1), ERR_UNCONFIGURED, "Client is not connected to a host.");

	uint32_t stream = next_stream++;

	if (p_buffer_size <= MAX_CHUNK_PAYLOAD) {
		return _broadcast_frame(EVENT_DATA, unique_id, stream, p_buffer, (uint32_t)p_buffer_size);
	}

	// Fragment large MultiplayerAPI packets across EOS_P2P_MAX_PACKET_SIZE
	// frames; the receiver reassembles (see _handle_rx_frame).
	uint16_t total = (uint16_t)((p_buffer_size + MAX_CHUNK_PAYLOAD - 1) / MAX_CHUNK_PAYLOAD);
	int32_t offset = 0;
	uint16_t index = 0;
	while (offset < p_buffer_size) {
		int32_t end = MIN(offset + MAX_CHUNK_PAYLOAD, p_buffer_size);
		uint8_t frame[FRAG_HEADER_SIZE + MAX_CHUNK_PAYLOAD];
		encode_uint16(index, &frame[INDEX_FRAG_INDEX]);
		encode_uint16(total, &frame[INDEX_FRAG_TOTAL]);
		memcpy(frame + FRAG_HEADER_SIZE, p_buffer + offset, end - offset);
		Error err = _broadcast_frame(EVENT_DATA, unique_id, stream, frame,
				(uint32_t)(FRAG_HEADER_SIZE + (end - offset)));
		if (err != OK) {
			return err;
		}
		offset = end;
		index++;
	}
	return OK;
}

Error EOSMultiplayerPeer::_broadcast_frame(uint8_t event, uint32_t sender, uint32_t stream,
		const uint8_t *payload, uint32_t payload_size) {
	// Broadcast/target dispatch honoring target_peer semantics.
	Error err = OK;
	for (KeyValue<uint32_t, RemotePeer> &E : peers) {
		if (target_peer > 0 && E.key != (uint32_t)target_peer) {
			continue;
		}
		if (target_peer < 0 && E.key == (uint32_t)(-target_peer)) {
			continue;
		}
		err = _send_frame(E.value.user_id, event, sender, (uint8_t)(transfer_channel + 1), stream,
				payload, payload_size, EOS_EPacketReliability::EOS_PR_UnreliableUnordered);
		if (err != OK) {
			break;
		}
	}
	return err;
}

Error EOSMultiplayerPeer::_send_frame(EOS_ProductUserId remote, uint8_t event, uint32_t sender,
		uint8_t channel, uint32_t stream,
		const uint8_t *payload, uint32_t payload_size,
		EOS_EPacketReliability reliability) {
	ERR_FAIL_NULL_V(remote, ERR_INVALID_PARAMETER);
	uint32_t frame_size = HEADER_SIZE + payload_size;
	std::vector<uint8_t> frame(frame_size);
	frame[INDEX_EVENT] = event;
	encode_uint32(sender, &frame[INDEX_SENDER]);
	frame[INDEX_CHANNEL] = channel;
	encode_uint32(stream, &frame[INDEX_STREAM]);
	if (payload_size > 0) {
		memcpy(frame.data() + HEADER_SIZE, payload, payload_size);
	}

	EOS_P2P_SendPacketOptions options{};
	options.ApiVersion = EOS_P2P_SENDPACKET_API_LATEST;
	options.LocalUserId = s_local_user_id;
	options.RemoteUserId = remote;
	options.SocketId = &socket_id;
	options.Channel = channel;
	options.DataLengthBytes = frame_size;
	options.Data = frame.data();
	options.bAllowDelayedDelivery = allow_delayed_delivery ? EOS_TRUE : EOS_FALSE;
	options.Reliability = reliability;
	options.bDisableAutoAcceptConnection = EOS_TRUE;

	EOS_EResult result = IEOS::get_singleton()->_p2p_send_packet(&options);
	if (result == EOS_EResult::EOS_InvalidParameters) {
		return ERR_INVALID_PARAMETER;
	}
	if (result == EOS_EResult::EOS_LimitExceeded) {
		return ERR_OUT_OF_MEMORY;
	}
	if (result == EOS_EResult::EOS_NoConnection) {
		return ERR_CANT_CONNECT;
	}
	if (result != EOS_EResult::EOS_Success) {
		return FAILED;
	}
	return OK;
}

// ------------------------------------------------------- MultiplayerPeer API

Error EOSMultiplayerPeer::_get_packet(const uint8_t **r_buffer, int32_t *r_buffer_size) {
	if (packet_queue.size() == 0) {
		*r_buffer = nullptr;
		*r_buffer_size = 0;
		return ERR_UNAVAILABLE;
	}
	QueuedPacket front = packet_queue.front()->get();
	packet_queue.pop_front();
	*r_buffer = front.payload.data();
	*r_buffer_size = (int32_t)front.payload.size();
	return OK;
}

int32_t EOSMultiplayerPeer::_get_available_packet_count() const {
	return (int32_t)packet_queue.size();
}

int32_t EOSMultiplayerPeer::_get_max_packet_size() const {
	return INT32_MAX; // Fragmentation removes the EOS packet-size limit.
}

int32_t EOSMultiplayerPeer::_get_packet_channel() const {
	ERR_FAIL_COND_V_MSG(packet_queue.size() == 0, 0, "No packets available.");
	return packet_queue.front()->get().channel;
}

MultiplayerPeer::TransferMode EOSMultiplayerPeer::_get_packet_mode() const {
	ERR_FAIL_COND_V_MSG(packet_queue.size() == 0, TRANSFER_MODE_RELIABLE, "No packets available.");
	return packet_queue.front()->get().mode;
}

void EOSMultiplayerPeer::_set_transfer_channel(int32_t p_channel) {
	transfer_channel = p_channel;
}

int32_t EOSMultiplayerPeer::_get_transfer_channel() const {
	return transfer_channel;
}

void EOSMultiplayerPeer::_set_transfer_mode(MultiplayerPeer::TransferMode p_mode) {
	transfer_mode = p_mode;
}

MultiplayerPeer::TransferMode EOSMultiplayerPeer::_get_transfer_mode() const {
	return transfer_mode;
}

void EOSMultiplayerPeer::_set_target_peer(int32_t p_peer) {
	target_peer = p_peer;
}

int32_t EOSMultiplayerPeer::_get_packet_peer() const {
	ERR_FAIL_COND_V_MSG(packet_queue.size() == 0, 0, "No packets available.");
	return packet_queue.front()->get().sender;
}

bool EOSMultiplayerPeer::_is_server() const {
	return active_mode == MODE_SERVER;
}

void EOSMultiplayerPeer::_close() {
	if (!_is_active()) {
		return;
	}
	// Close every remote connection, drop notifications, reset state.
	for (KeyValue<uint32_t, RemotePeer> &E : peers) {
		EOS_P2P_CloseConnectionOptions close{};
		close.ApiVersion = EOS_P2P_CLOSECONNECTION_API_LATEST;
		close.LocalUserId = s_local_user_id;
		close.RemoteUserId = E.value.user_id;
		close.SocketId = &socket_id;
		IEOS::get_singleton()->_p2p_close_connection(&close);
	}
	_remove_notifications();
	peers.clear();
	user_key_to_peer.clear();
	packet_queue.clear();
	pending_requests.clear();
	active_mode = MODE_NONE;
	connection_status = CONNECTION_DISCONNECTED;
	unique_id = 0;
	target_peer = 0;
	next_stream = 1;
	next_assigned_peer_id = 2;
	refusing_new_connections = false;
}

void EOSMultiplayerPeer::_disconnect_peer(int32_t p_peer, bool p_force) {
	if (!_is_active() || !peers.has((uint32_t)p_peer)) {
		return;
	}
	_drop_peer(p_peer);
}

int32_t EOSMultiplayerPeer::_get_unique_id() const {
	return (int32_t)unique_id;
}

void EOSMultiplayerPeer::_set_refuse_new_connections(bool p_enable) {
	refusing_new_connections = p_enable;
}

bool EOSMultiplayerPeer::_is_refusing_new_connections() const {
	return refusing_new_connections;
}

bool EOSMultiplayerPeer::_is_server_relay_supported() const {
	// Server relays broadcasts; our protocol uses host-authoritative
	// broadcasts only, no client->client traffic.
	return active_mode == MODE_SERVER;
}

MultiplayerPeer::ConnectionStatus EOSMultiplayerPeer::_get_connection_status() const {
	return connection_status;
}

// ------------------------------------------------------------------- helpers

EOSMultiplayerPeer::RemotePeer *EOSMultiplayerPeer::_find_peer_by_user(EOS_ProductUserId user) {
	String key = eosg_product_user_id_to_string(user);
	if (user_key_to_peer.has(key)) {
		uint32_t id = user_key_to_peer[key];
		if (peers.has(id)) {
			return &peers[id];
		}
	}
	return nullptr;
}

bool EOSMultiplayerPeer::_is_allowed(EOS_ProductUserId user) const {
	for (const EOS_ProductUserId &allowed : allowed_users) {
		if (allowed != nullptr && EOS_IsSameProductUser(allowed, user)) {
			return true;
		}
	}
	return false;
}

bool EOSMultiplayerPeer::_at_capacity() const {
	// Server (id 1) + clients; ids 2..max_peers.
	return (int)peers.size() + 1 >= max_peers;
}

void EOSMultiplayerPeer::_drop_peer(uint32_t peer_id) {
	if (!peers.has(peer_id)) {
		return;
	}
	EOS_ProductUserId user = peers[peer_id].user_id;
	peers.erase(peer_id);
	user_key_to_peer.erase(eosg_product_user_id_to_string(user));
	emit_signal("peer_disconnected", (int64_t)peer_id);
}

void EOSMultiplayerPeer::_remove_notifications() {
	if (notify_request != EOS_INVALID_NOTIFICATIONID) {
		IEOS::get_singleton()->_p2p_remove_notify_peer_connection_request(notify_request);
		notify_request = EOS_INVALID_NOTIFICATIONID;
	}
	if (notify_established != EOS_INVALID_NOTIFICATIONID) {
		IEOS::get_singleton()->_p2p_remove_notify_peer_connection_established(notify_established);
		notify_established = EOS_INVALID_NOTIFICATIONID;
	}
	if (notify_closed != EOS_INVALID_NOTIFICATIONID) {
		IEOS::get_singleton()->_p2p_remove_notify_peer_connection_closed(notify_closed);
		notify_closed = EOS_INVALID_NOTIFICATIONID;
	}
}

EOSMultiplayerPeer::~EOSMultiplayerPeer() {
	_close();
}