// EOSMultiplayerPeer - EOS P2P transport for Tetris Yank Edition co-op.
//
// Drop-in transport module for the EOSG addon's build (same binary, same
// EOS SDK instance - see addons/eos-transport/README.md). Implements the
// plan's transport contract:
//   * a Godot MultiplayerPeerExtension over EOS P2P (server + clients);
//   * host-assigned peer ids: server = 1, clients = 2..max_peers assigned
//     in accept order through an id-assignment handshake (no client-random
//     ids, so roster/slot mapping is deterministic);
//   * manual accept gating: only product user ids passed to allow_peers()
//     (the EOS lobby's members) may establish connections; duplicates and
//     over-capacity peers are refused;
//   * internal fragmentation/reassembly so MultiplayerAPI packets larger
//     than EOS_P2P_MAX_PACKET_SIZE still flow (fragment header + stream
//     reassembly), with reliable/unreliable EOS reliability per packet.
//
// Gameplay code never touches raw EOS packets: everything rides the
// standard MultiplayerPeer RPC contract.
//
// Adapted from EOSGMultiplayerPeer (MIT License, (c) Dallin Lovin aka
// LowFire, https://github.com/3ddelano/epic-online-services-godot).

#pragma once

#include "eos_p2p.h"
#include "godot_cpp/classes/multiplayer_peer_extension.hpp"
#include "godot_cpp/templates/hash_map.hpp"
#include "godot_cpp/templates/list.hpp"
#include "godot_cpp/variant/packed_byte_array.hpp"
#include "godot_cpp/variant/packed_string_array.hpp"
#include "ieos.h"
#include "utils.h"

#include <memory>
#include <vector>

namespace godot {

class EOSMultiplayerPeer : public MultiplayerPeerExtension {
	GDCLASS(EOSMultiplayerPeer, MultiplayerPeerExtension)

private:
	// Wire events (first byte of every EOS packet).
	enum Event : uint8_t {
		EVENT_DATA = 0,      // MultiplayerAPI payload (maybe fragmented).
		EVENT_ASSIGN_ID = 1, // Host -> client: your assigned peer id.
		EVENT_HELLO = 2,     // Client -> host: request an id (sender 0).
	};

	// Frame header: [event][sender(u32)][channel(u8)][stream(u32)]
	enum {
		INDEX_EVENT = 0,
		INDEX_SENDER = 1,
		INDEX_CHANNEL = 5,
		INDEX_STREAM = 6,
		HEADER_SIZE = 10,
	};

	// Fragment header after the frame header: [index(u16)][total(u16)]
	enum {
		INDEX_FRAG_INDEX = 10,
		INDEX_FRAG_TOTAL = 12,
		FRAG_HEADER_SIZE = 14,
	};

	enum Mode {
		MODE_NONE,
		MODE_SERVER,
		MODE_CLIENT,
	};

	// Largest payload we ever hand to EOS per packet (leave headroom under
	// EOS_P2P_MAX_PACKET_SIZE for the frame/fragment headers).
	static constexpr int MAX_CHUNK_PAYLOAD = 1024;

	// One fully reassembled MultiplayerAPI packet awaiting _get_packet().
	struct QueuedPacket {
		std::vector<uint8_t> payload;
		int32_t sender = 0;
		int32_t channel = 0;
		TransferMode mode = TRANSFER_MODE_RELIABLE;
	};

	// Per-sender fragment stream.
	struct FragStream {
		uint32_t total = 0;
		std::vector<std::vector<uint8_t>> parts;
	};

	// Per-remote-peer state.
	struct RemotePeer {
		EOS_ProductUserId user_id = nullptr;
		uint32_t peer_id = 0;
		HashMap<uint32_t, FragStream> streams;
	};

	// Pending (not yet established, allowed) connection requests.
	std::vector<EOS_ProductUserId> pending_requests;

	static EOS_ProductUserId s_local_user_id;

	EOS_P2P_SocketId socket_id{};
	Mode active_mode = MODE_NONE;
	ConnectionStatus connection_status = CONNECTION_DISCONNECTED;
	uint32_t unique_id = 0;
	int32_t target_peer = 0;
	int32_t transfer_channel = 0;
	TransferMode transfer_mode = TRANSFER_MODE_RELIABLE;
	uint32_t next_stream = 1;
	uint32_t next_assigned_peer_id = 2;
	int max_peers = 4;
	bool refusing_new_connections = false;
	bool allow_delayed_delivery = true;
	std::vector<uint8_t> rx_buffer;

	// Allow-list gate (product user ids, i.e. EOS lobby members).
	std::vector<EOS_ProductUserId> allowed_users;

	HashMap<uint32_t, RemotePeer> peers; // peer_id -> state
	HashMap<String, uint32_t> user_key_to_peer; // "puid string" -> peer_id
	List<QueuedPacket> packet_queue;

	EOS_NotificationId notify_request = 0;
	EOS_NotificationId notify_established = 0;
	EOS_NotificationId notify_closed = 0;

	_FORCE_INLINE_ bool _is_active() const { return active_mode != MODE_NONE; }

	Error _send_frame(EOS_ProductUserId remote, uint8_t event, uint32_t sender,
			uint8_t channel, uint32_t stream,
			const uint8_t *payload, uint32_t payload_size,
			EOS_EPacketReliability reliability);
	Error _broadcast_frame(uint8_t event, uint32_t sender, uint32_t stream,
			const uint8_t *payload, uint32_t payload_size);
	void _handle_rx_frame(EOS_ProductUserId remote, uint8_t channel, const uint8_t *data, uint32_t size);
	RemotePeer *_find_peer_by_user(EOS_ProductUserId user);
	bool _is_allowed(EOS_ProductUserId user) const;
	bool _at_capacity() const;
	void _drop_peer(uint32_t peer_id);
	void _assign_client(EOS_ProductUserId user);
	void _remove_notifications();

	static void _bind_methods();

	// EOS P2P notification callbacks (run on the EOS tick thread of the
	// IEOS singleton - the bridge ticks EOS on the main scene thread).
	static void _connection_request_cb(const EOS_P2P_OnIncomingConnectionRequestInfo *data, void *client_data);
	static void _connection_established_cb(const EOS_P2P_OnPeerConnectionEstablishedInfo *data, void *client_data);
	static void _connection_closed_cb(const EOS_P2P_OnRemoteConnectionClosedInfo *data, void *client_data);

public:
	// Set the local (logged-in) product user id. Must be called after EOSG
	// HAuth login and before create_server/create_client.
	void configure(const String &local_user_id);

	// Membership gate: only these product user ids may connect/keep a
	// connection (the host passes its EOS lobby's members here).
	void allow_peers(const PackedStringArray &puids);
	void clear_allowed_peers();

	// Server: listen on the socket; assigns client ids 2..max_peers.
	Error create_server(const String &socket_id);
	// Client: connect to the host's product user id; the host assigns our
	// id in the handshake.
	Error create_client(const String &socket_id, const String &host_puid);

	int get_active_mode() const;
	String get_socket() const;
	int get_max_peers() const;
	void set_max_peers(int max);
	String get_peer_user_id(int peer_id) const;
	int get_peer_id_from_user(const String &puid) const;
	bool has_peer(int peer_id) const;
	bool is_allowing_delayed_delivery() const;
	void set_allow_delayed_delivery(bool allow);

	// MultiplayerPeerExtension virtuals.
	virtual Error _get_packet(const uint8_t **r_buffer, int32_t *r_buffer_size) override;
	virtual Error _put_packet(const uint8_t *p_buffer, int32_t p_buffer_size) override;
	virtual int32_t _get_available_packet_count() const override;
	virtual int32_t _get_max_packet_size() const override;
	virtual int32_t _get_packet_channel() const override;
	virtual MultiplayerPeer::TransferMode _get_packet_mode() const override;
	virtual void _set_transfer_channel(int32_t p_channel) override;
	virtual int32_t _get_transfer_channel() const override;
	virtual void _set_transfer_mode(MultiplayerPeer::TransferMode p_mode) override;
	virtual MultiplayerPeer::TransferMode _get_transfer_mode() const override;
	virtual void _set_target_peer(int32_t p_peer) override;
	virtual int32_t _get_packet_peer() const override;
	virtual bool _is_server() const override;
	virtual void _poll() override;
	virtual void _close() override;
	virtual void _disconnect_peer(int32_t p_peer, bool p_force) override;
	virtual int32_t _get_unique_id() const override;
	virtual void _set_refuse_new_connections(bool p_enable) override;
	virtual bool _is_refusing_new_connections() const override;
	virtual bool _is_server_relay_supported() const override;
	virtual MultiplayerPeer::ConnectionStatus _get_connection_status() const override;

	EOSMultiplayerPeer() {}
	~EOSMultiplayerPeer();
};

} // namespace godot