// Forwarding-only WebSocket relay for BLANKS online co-op.
//
// The relay never decodes gameplay payloads: it creates private rooms
// addressed by high-entropy codes, assigns relay peer ids (host 1,
// clients 2..MAX_ROOM_PEERS), and forwards binary frames with the
// sender id stamped into a 4-byte little-endian header so a payload can
// never claim a sender. Rooms are unlisted; the host leaving closes the
// room; idle rooms expire. All limits are configurable through the
// environment (see .env.example) and contain no credentials.

import crypto from 'node:crypto';
import http from 'node:http';
import { WebSocketServer } from 'ws';

export const CODE_ALPHABET = 'ABCDEFGHJKLMNPQRSTVWXYZ'; // 25 chars: no I, O, U

export const DEFAULT_CONFIG = {
	maxRoomPeers: 4, // host + 3 players (the game's four-slot roster)
	codeLength: 7, // 25^7 ~= 6e9 codes
	roomIdleTimeoutMs: 30 * 60 * 1000,
	sweepIntervalMs: 15 * 1000,
	heartbeatIntervalMs: 30 * 1000, // protocol-level pings; loss closes the socket
	packetLimit: 65536, // per forwarded frame, sender header included
	ratePerSecond: 120, // sustained messages per socket
	rateBurst: 240, // token bucket capacity per socket
	maxConnections: 256,
	maxConnectionsPerIp: 32,
	allowedOrigins: [], // empty: any origin (native game clients send none)
};

export function normalizeCode(raw) {
	return String(raw ?? '')
		.trim()
		.toUpperCase()
		.replace(/[\s-]+/g, '');
}

export function isValidCode(code) {
	return code.length >= 4 && code.length <= 16 && /^[A-HJ-NP-TV-Z]+$/.test(code);
}

function senderHeader(peerId) {
	const header = Buffer.alloc(4);
	header.writeInt32LE(peerId >>> 0, 0);
	return header;
}

export function createRelayServer(overrides = {}) {
	const config = { ...DEFAULT_CONFIG, ...overrides };
	const rooms = new Map(); // code -> room { code, host, clients: Map(peerId -> ws), lastActivity }
	const connectionsByIp = new Map();
	let connectionCount = 0;

	const httpServer = http.createServer((req, res) => {
		if (req.method === 'GET' && (req.url ?? '').split('?')[0] === '/healthz') {
			res.writeHead(200, { 'content-type': 'text/plain' });
			res.end('ok');
			return;
		}
		res.writeHead(404, { 'content-type': 'text/plain' });
		res.end('not found');
	});

	const wss = new WebSocketServer({
		server: httpServer,
		perMessageDeflate: false,
		heartbeatInterval: config.heartbeatIntervalMs,
	});

	function sendJson(ws, obj) {
		if (ws.readyState === ws.OPEN) ws.send(JSON.stringify(obj));
	}

	function sendError(ws, code, message) {
		sendJson(ws, { op: 'error', code, message });
	}

	function touch(room) {
		if (room) room.lastActivity = Date.now();
	}

	function generateCode() {
		for (;;) {
			const bytes = crypto.randomBytes(config.codeLength);
			let code = '';
			for (const b of bytes) code += CODE_ALPHABET[b % CODE_ALPHABET.length];
			if (!rooms.has(code)) return code;
		}
	}

	// Token bucket: capacity = rateBurst, refill = ratePerSecond/s.
	// Overflowing sockets are dropped (and closed when far past the cap).
	function consumeRate(ws) {
		const st = ws.relay;
		const now = Date.now();
		st.tokens = Math.min(
			config.rateBurst,
			st.tokens + ((now - st.lastRefillMs) / 1000) * config.ratePerSecond
		);
		st.lastRefillMs = now;
		if (st.tokens < 1) {
			st.rateDebt += 1;
			if (st.rateDebt > config.rateBurst * 2) ws.close(1008, 'rate_limited');
			return false;
		}
		st.tokens -= 1;
		st.rateDebt = 0;
		return true;
	}

	function handleBinary(ws, data) {
		const st = ws.relay;
		const room = st.room;
		if (!room) {
			sendError(ws, 'not_in_room', 'game frames require a room');
			return;
		}
		if (data.length + 4 > config.packetLimit) {
			sendError(ws, 'too_large', 'frame exceeds packet limit');
			ws.close(1009, 'too_large');
			return;
		}
		if (st.peerId === 1) {
			// Host -> every client. Only the host socket may reach here.
			const frame = Buffer.concat([senderHeader(1), data]);
			for (const client of room.clients.values()) {
				if (client.readyState === client.OPEN) client.send(frame);
			}
		} else {
			// Client -> host only.
			if (room.host && room.host.readyState === room.host.OPEN) {
				room.host.send(Buffer.concat([senderHeader(st.peerId), data]));
			}
		}
	}

	function handleCreate(ws) {
		const st = ws.relay;
		if (st.room) {
			sendError(ws, 'already_in_room', 'socket already owns or joined a room');
			return;
		}
		const code = generateCode();
		const room = { code, host: ws, clients: new Map(), lastActivity: Date.now() };
		st.room = room;
		st.peerId = 1;
		rooms.set(code, room);
		sendJson(ws, { op: 'created', code, peer_id: 1 });
	}

	function handleJoin(ws, rawCode) {
		const st = ws.relay;
		if (st.room) {
			sendError(ws, 'already_in_room', 'socket already owns or joined a room');
			return;
		}
		const code = normalizeCode(rawCode);
		if (!isValidCode(code)) {
			sendError(ws, 'invalid_code', 'room codes use letters only (no I, O, U)');
			return;
		}
		const room = rooms.get(code);
		if (!room || !room.host || room.host.readyState !== room.host.OPEN) {
			sendError(ws, 'not_found', 'no such room');
			return;
		}
		// Lowest free client id in 2..maxRoomPeers; the room total
		// (host + clients) never exceeds maxRoomPeers.
		let peerId = -1;
		for (let id = 2; id <= config.maxRoomPeers; id += 1) {
			if (!room.clients.has(id)) {
				peerId = id;
				break;
			}
		}
		if (peerId < 0) {
			sendError(ws, 'full', 'room is full');
			return;
		}
		st.room = room;
		st.peerId = peerId;
		room.clients.set(peerId, ws);
		touch(room);
		const note = JSON.stringify({ op: 'peer_joined', peer_id: peerId });
		if (room.host.readyState === room.host.OPEN) room.host.send(note);
		for (const [id, client] of room.clients) {
			if (id !== peerId && client.readyState === client.OPEN) client.send(note);
		}
		sendJson(ws, { op: 'joined', code, peer_id: peerId });
	}

	function closeRoom(room, reason) {
		rooms.delete(room.code);
		const note = JSON.stringify({ op: 'room_closed', reason });
		for (const client of room.clients.values()) {
			if (client.readyState === client.OPEN) {
				client.send(note);
				client.close(1000, reason);
			}
		}
		if (room.host && room.host.readyState === room.host.OPEN) {
			room.host.send(note);
			room.host.close(1000, reason);
		}
		room.clients.clear();
		room.host = null;
	}

	function handleHostClose(ws) {
		const st = ws.relay;
		const room = st.room;
		if (!room) {
			sendError(ws, 'not_in_room', 'no room to close');
			return;
		}
		if (st.peerId !== 1) {
			sendError(ws, 'not_host', 'only the host may close the room');
			return;
		}
		closeRoom(room, 'closed');
	}

	function handleText(ws, data) {
		let msg;
		try {
			msg = JSON.parse(data.toString('utf8'));
		} catch {
			sendError(ws, 'bad_op', 'malformed control message');
			return;
		}
		if (msg === null || typeof msg !== 'object' || typeof msg.op !== 'string') {
			sendError(ws, 'bad_op', 'control message needs a string op');
			return;
		}
		switch (msg.op) {
			case 'create':
				handleCreate(ws);
				break;
			case 'join':
				handleJoin(ws, msg.code);
				break;
			case 'ping':
				sendJson(ws, { op: 'pong' });
				break;
			case 'close':
				handleHostClose(ws);
				break;
			default:
				sendError(ws, 'bad_op', `unknown op ${msg.op}`);
		}
	}

	wss.on('connection', (ws, req) => {
		const ip = req.socket.remoteAddress || 'unknown';
		connectionCount += 1;
		connectionsByIp.set(ip, (connectionsByIp.get(ip) ?? 0) + 1);
		ws.relay = { room: null, peerId: 0, tokens: config.rateBurst, lastRefillMs: Date.now(), rateDebt: 0, ip };
		ws.on('close', () => {
			connectionCount -= 1;
			const perIp = (connectionsByIp.get(ip) ?? 1) - 1;
			if (perIp <= 0) connectionsByIp.delete(ip);
			else connectionsByIp.set(ip, perIp);
			handleSocketClosed(ws);
		});
		if (
			connectionCount > config.maxConnections ||
			connectionsByIp.get(ip) > config.maxConnectionsPerIp
		) {
			ws.close(1013, 'busy');
			return;
		}
		if (config.allowedOrigins.length > 0) {
			const origin = req.headers.origin;
			// Native game clients send no Origin header and always pass.
			if (origin && !config.allowedOrigins.includes(origin)) {
				ws.close(1008, 'origin');
				return;
			}
		}
		ws.on('message', (data, isBinary) => {
			touch(ws.relay.room);
			try {
				if (!consumeRate(ws)) {
					// Rejected control messages answer with an error; binary
					// floods are dropped silently (closing on debt is done
					// inside consumeRate).
					if (!isBinary) sendError(ws, 'rate_limited', 'too many messages');
					return;
				}
				if (isBinary) handleBinary(ws, data);
				else handleText(ws, data);
			} catch (err) {
				// Aggregate operator log only: never room payloads or player data.
				console.error('relay: message handling error:', err && err.message ? err.message : err);
				sendError(ws, 'internal', 'internal relay error');
			}
		});
	});

	function handleSocketClosed(ws) {
		const st = ws.relay;
		if (!st || !st.room) return;
		const room = st.room;
		st.room = null;
		if (st.peerId === 1) {
			// Host loss: the room is over for every member; notify + delete.
			if (rooms.get(room.code) === room) {
				rooms.delete(room.code);
				const note = JSON.stringify({ op: 'room_closed', reason: 'host_left' });
				for (const client of room.clients.values()) {
					if (client.readyState === client.OPEN) {
						client.send(note);
						client.close(1000, 'host_left');
					}
				}
				room.clients.clear();
			}
		} else {
			// Client loss: the host updates its roster; the room continues.
			room.clients.delete(st.peerId);
			if (
				rooms.get(room.code) === room &&
				room.host &&
				room.host.readyState === room.host.OPEN
			) {
				room.host.send(JSON.stringify({ op: 'peer_left', peer_id: st.peerId }));
			}
		}
	}

	// Periodically expire idle rooms; cleared on shutdown.
	const sweeper = setInterval(() => {
		const now = Date.now();
		for (const room of [...rooms.values()]) {
			if (now - room.lastActivity > config.roomIdleTimeoutMs) closeRoom(room, 'idle');
		}
	}, config.sweepIntervalMs);

	function close(callback) {
		clearInterval(sweeper);
		for (const room of [...rooms.values()]) closeRoom(room, 'shutdown');
		for (const client of wss.clients) client.terminate();
		wss.close();
		httpServer.close(callback);
	}

	return { httpServer, wss, rooms, config, close };
}
