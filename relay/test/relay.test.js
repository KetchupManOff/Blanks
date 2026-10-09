// Relay behavior tests: room create/join, code validation, capacity,
// directional forwarding with relay-stamped sender ids, spoofing
// resistance, control-op authorization, disconnect cleanup, idle
// expiry, and packet/rate limits. Every test starts its relay on an
// ephemeral local port and never contacts any production endpoint.

import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { WebSocket } from 'ws';
import {
	createRelayServer,
	normalizeCode,
	isValidCode,
	CODE_ALPHABET,
} from '../src/relay.js';

async function startServer(overrides = {}) {
	const relay = createRelayServer(overrides);
	await new Promise((resolve) => relay.httpServer.listen(0, '127.0.0.1', resolve));
	const port = relay.httpServer.address().port;
	return { relay, url: `ws://127.0.0.1:${port}` };
}

function connect(url) {
	return new Promise((resolve, reject) => {
		const ws = new WebSocket(url);
		ws.on('open', () => resolve(ws));
		ws.on('error', reject);
	});
}

// Minimal client-side pump: every message lands in a queue; expect()
// scans for the first message with a matching op (other messages are
// consumed, which keeps the assertions in this suite order-tolerant).
function pump(ws) {
	const queue = [];
	ws.on('message', (data, isBinary) => {
		queue.push(isBinary ? { op: '__binary__', binary: data } : JSON.parse(data.toString()));
	});
	return {
		queue,
		async expect(op, timeoutMs = 3000) {
			const deadline = Date.now() + timeoutMs;
			for (;;) {
				const index = queue.findIndex((msg) => msg.op === op);
				if (index >= 0) return queue.splice(index, 1)[0];
				if (Date.now() > deadline) {
					throw new Error(`timeout waiting for op "${op}" (queue: ${JSON.stringify(queue)})`);
				}
				await new Promise((resolve) => setTimeout(resolve, 5));
			}
		},
	};
}

function closed(ws, timeoutMs = 3000) {
	return new Promise((resolve, reject) => {
		if (ws.readyState === ws.CLOSED) resolve();
		const timer = setTimeout(() => reject(new Error('timeout waiting for close')), timeoutMs);
		ws.on('close', () => {
			clearTimeout(timer);
			resolve();
		});
	});
}

function sendJson(ws, obj) {
	ws.send(JSON.stringify(obj));
}

async function createRoom(url) {
	const host = await connect(url);
	const hostPump = pump(host);
	sendJson(host, { op: 'create' });
	const created = await hostPump.expect('created');
	return { host, hostPump, code: created.code };
}

test('healthz responds ok', async (t) => {
	const { relay, url } = await startServer();
	t.after(() => relay.close());
	const base = url.replace('ws://', 'http://');
	const response = await new Promise((resolve, reject) => {
		http.get(`${base}/healthz`, (res) => {
			let body = '';
			res.on('data', (chunk) => (body += chunk));
			res.on('end', () => resolve({ status: res.statusCode, body }));
		}).on('error', reject);
	});
	assert.equal(response.status, 200);
	assert.equal(response.body, 'ok');
});

test('code helpers normalize and validate', () => {
	assert.equal(normalizeCode(' ab-cd ef '), 'ABCDEF');
	assert.equal(normalizeCode('x'), 'X');
	assert.ok(isValidCode('ABCDEFG'));
	assert.ok(isValidCode('ABCD'));
	assert.ok(!isValidCode('ABC'));
	assert.ok(!isValidCode('ABCDEFGHIJKLMNO'));
	assert.ok(!isValidCode('ABC1'));
	assert.ok(!isValidCode('ABCI'));
	assert.ok(!isValidCode('ABCO'));
	assert.ok(!isValidCode('ABCU'));
});

test('create assigns code and host peer id 1', async (t) => {
	const { relay, url } = await startServer();
	t.after(() => relay.close());
	const { host, hostPump, code } = await createRoom(url);
	assert.equal(typeof code, 'string');
	assert.equal(code.length, 7);
	for (const ch of code) assert.ok(CODE_ALPHABET.includes(ch));
	assert.ok(relay.rooms.has(code));
	// One socket hosts at most one room.
	sendJson(host, { op: 'create' });
	const error = await hostPump.expect('error');
	assert.equal(error.code, 'already_in_room');
	host.close();
});

test('join assigns client peer ids and notifies the room', async (t) => {
	const { relay, url } = await startServer();
	t.after(() => relay.close());
	const { host, hostPump, code } = await createRoom(url);

	const client = await connect(url);
	const clientPump = pump(client);
	sendJson(client, { op: 'join', code: code.toLowerCase() }); // case normalized
	const joined = await clientPump.expect('joined');
	assert.equal(joined.peer_id, 2);
	assert.equal(joined.code, code);
	const note = await hostPump.expect('peer_joined');
	assert.equal(note.peer_id, 2);

	const client2 = await connect(url);
	const client2Pump = pump(client2);
	sendJson(client2, { op: 'join', code });
	await client2Pump.expect('joined');
	// Existing members also hear about the newcomer.
	const note2 = await clientPump.expect('peer_joined');
	assert.equal(note2.peer_id, 3);

	host.close();
	client.close();
	client2.close();
});

test('join rejects invalid, unknown, and duplicate membership', async (t) => {
	const { relay, url } = await startServer();
	t.after(() => relay.close());
	const { host, hostPump, code } = await createRoom(url);

	const bad = await connect(url);
	const badPump = pump(bad);
	sendJson(bad, { op: 'join', code: '12!@' });
	assert.equal((await badPump.expect('error')).code, 'invalid_code');
	sendJson(bad, { op: 'join', code: 'ZZZZZZZ' });
	assert.equal((await badPump.expect('error')).code, 'not_found');
	sendJson(bad, { op: 'join', code });
	const joined = await badPump.expect('joined');
	assert.equal(joined.peer_id, 2);
	sendJson(bad, { op: 'join', code });
	assert.equal((await badPump.expect('error')).code, 'already_in_room');
	await hostPump.expect('peer_joined');

	bad.close();
	host.close();
});

test('room fills at maxRoomPeers and rejects the next join', async (t) => {
	const { relay, url } = await startServer({ maxRoomPeers: 4 });
	t.after(() => relay.close());
	const { host, code } = await createRoom(url);
	const clients = [];
	for (let i = 0; i < 3; i += 1) {
		const client = await connect(url);
		const clientPump = pump(client);
		sendJson(client, { op: 'join', code });
		const joined = await clientPump.expect('joined');
		assert.equal(joined.peer_id, 2 + i);
		clients.push(client);
	}
	const extra = await connect(url);
	const extraPump = pump(extra);
	sendJson(extra, { op: 'join', code });
	const error = await extraPump.expect('error');
	assert.equal(error.code, 'full');
	assert.equal(relay.rooms.get(code).clients.size, 3);
	extra.close();
	clients.forEach((client) => client.close());
	host.close();
});

test('frames forward client->host and host->clients with relay-stamped senders', async (t) => {
	const { relay, url } = await startServer();
	t.after(() => relay.close());
	const { host, hostPump, code } = await createRoom(url);
	const client = await connect(url);
	const clientPump = pump(client);
	sendJson(client, { op: 'join', code });
	await clientPump.expect('joined');
	await hostPump.expect('peer_joined');

	// Client -> host: relay stamps the sender (client peer id 2).
	client.send(Buffer.from([9, 9, 9]));
	const inbound = await hostPump.expect('__binary__');
	assert.equal(inbound.binary.length, 7); // 4-byte header + payload
	assert.equal(inbound.binary.readInt32LE(0), 2);
	assert.deepEqual([...inbound.binary.subarray(4)], [9, 9, 9]);

	// Host -> clients: relay stamps sender 1.
	host.send(Buffer.from([7]));
	const outbound = await clientPump.expect('__binary__');
	assert.equal(outbound.binary.readInt32LE(0), 1);
	assert.deepEqual([...outbound.binary.subarray(4)], [7]);

	client.close();
	host.close();
});

test('spoofed sender bytes in payloads are data, not identity', async (t) => {
	const { relay, url } = await startServer();
	t.after(() => relay.close());
	const { host, hostPump, code } = await createRoom(url);
	const client = await connect(url);
	const clientPump = pump(client);
	sendJson(client, { op: 'join', code });
	await clientPump.expect('joined');
	await hostPump.expect('peer_joined');

	// The client prepends a fake "peer 1" header into its payload: the
	// relay still stamps the real sender id, so the fake bytes survive
	// only as (envelope-invalid) payload content.
	const fake = Buffer.alloc(8);
	fake.writeInt32LE(1, 0);
	fake.set([1, 2, 3, 4], 4);
	client.send(fake);
	const inbound = await hostPump.expect('__binary__');
	assert.equal(inbound.binary.readInt32LE(0), 2); // relay's stamp wins
	assert.deepEqual([...inbound.binary.subarray(4)], [...fake]);

	client.close();
	host.close();
});

test('host disconnect closes the room and notifies members', async (t) => {
	const { relay, url } = await startServer();
	t.after(() => relay.close());
	const { host, code } = await createRoom(url);
	const client = await connect(url);
	const clientPump = pump(client);
	sendJson(client, { op: 'join', code });
	await clientPump.expect('joined');

	host.terminate(); // simulate crash: no close frame at all
	const note = await clientPump.expect('room_closed');
	assert.equal(note.reason, 'host_left');
	await closed(client);
	assert.ok(!relay.rooms.has(code));
});

test('client disconnect notifies the host and the room continues', async (t) => {
	const { relay, url } = await startServer();
	t.after(() => relay.close());
	const { host, hostPump, code } = await createRoom(url);
	const client = await connect(url);
	const clientPump = pump(client);
	sendJson(client, { op: 'join', code });
	await clientPump.expect('joined');
	await hostPump.expect('peer_joined');

	client.close();
	const note = await hostPump.expect('peer_left');
	assert.equal(note.peer_id, 2);
	assert.ok(relay.rooms.has(code));

	// The freed peer id can be reused by a later joiner.
	const client2 = await connect(url);
	const client2Pump = pump(client2);
	sendJson(client2, { op: 'join', code });
	const joined = await client2Pump.expect('joined');
	assert.equal(joined.peer_id, 2);
	client2.close();
	host.close();
});

test('host explicit close tears the room down promptly', async (t) => {
	const { relay, url } = await startServer();
	t.after(() => relay.close());
	const { host, hostPump, code } = await createRoom(url);
	const client = await connect(url);
	const clientPump = pump(client);
	sendJson(client, { op: 'join', code });
	await clientPump.expect('joined');
	await hostPump.expect('peer_joined');

	sendJson(host, { op: 'close' });
	assert.equal((await clientPump.expect('room_closed')).reason, 'closed');
	await hostPump.expect('room_closed');
	await closed(client);
	await closed(host);
	assert.ok(!relay.rooms.has(code));
});

test('non-host control actions are rejected', async (t) => {
	const { relay, url } = await startServer();
	t.after(() => relay.close());
	const { host, code } = await createRoom(url);
	const client = await connect(url);
	const clientPump = pump(client);
	sendJson(client, { op: 'join', code });
	await clientPump.expect('joined');

	sendJson(client, { op: 'close' });
	assert.equal((await clientPump.expect('error')).code, 'not_host');
	sendJson(client, { op: 'nothing' });
	assert.equal((await clientPump.expect('error')).code, 'bad_op');
	sendJson(client, 'not json at all');
	assert.equal((await clientPump.expect('error')).code, 'bad_op');
	sendJson(client, '{"op": 42}');
	assert.equal((await clientPump.expect('error')).code, 'bad_op');

	client.close();
	host.close();
});

test('binary frames before joining a room are rejected', async (t) => {
	const { relay, url } = await startServer();
	t.after(() => relay.close());
	const stray = await connect(url);
	const strayPump = pump(stray);
	stray.send(Buffer.from([1, 2, 3]));
	assert.equal((await strayPump.expect('error')).code, 'not_in_room');
	stray.close();
});

test('oversized frames are refused and the socket closed', async (t) => {
	const { relay, url } = await startServer({ packetLimit: 64 });
	t.after(() => relay.close());
	const { host, code } = await createRoom(url);
	const client = await connect(url);
	const clientPump = pump(client);
	sendJson(client, { op: 'join', code });
	await clientPump.expect('joined');

	client.send(Buffer.alloc(256));
	assert.equal((await clientPump.expect('error')).code, 'too_large');
	await closed(client);
	host.close();
});

test('per-socket rate limits throttle floods and close abusers', async (t) => {
	const { relay, url } = await startServer({ ratePerSecond: 1, rateBurst: 3 });
	t.after(() => relay.close());
	const client = await connect(url);
	const clientPump = pump(client);
	// 10 rapid control messages: the burst bucket allows ~3, the rest
	// answer rate_limited, and the debt past 2x burst closes the socket.
	for (let i = 0; i < 10; i += 1) sendJson(client, { op: 'ping' });
	await new Promise((resolve) => setTimeout(resolve, 300));
	const rejected = clientPump.queue.filter(
		(msg) => msg.op === 'error' && msg.code === 'rate_limited'
	).length;
	assert.ok(rejected >= 1, 'expected at least one rate_limited error');
	await closed(client);
});

test('heartbeat ping/pong keeps members alive', async (t) => {
	const { relay, url } = await startServer();
	t.after(() => relay.close());
	const { host } = await createRoom(url);
	const client = await connect(url);
	const clientPump = pump(client);
	sendJson(client, { op: 'ping' });
	await clientPump.expect('pong');
	sendJson(client, { op: 'ping' });
	await clientPump.expect('pong');
	client.close();
	host.close();
});

test('idle rooms expire and notify members', async (t) => {
	const { relay, url } = await startServer({ roomIdleTimeoutMs: 150, sweepIntervalMs: 40 });
	t.after(() => relay.close());
	const { host, hostPump, code } = await createRoom(url);
	const client = await connect(url);
	const clientPump = pump(client);
	sendJson(client, { op: 'join', code });
	await clientPump.expect('joined');
	await hostPump.expect('peer_joined');

	const note = await clientPump.expect('room_closed', 3000);
	assert.equal(note.reason, 'idle');
	await hostPump.expect('room_closed');
	await closed(client);
	await closed(host);
	assert.ok(!relay.rooms.has(code));
});

test('ping activity postpones idle expiry', async (t) => {
	const { relay, url } = await startServer({ roomIdleTimeoutMs: 400, sweepIntervalMs: 40 });
	t.after(() => relay.close());
	const { host, hostPump } = await createRoom(url);
	for (let i = 0; i < 4; i += 1) {
		sendJson(host, { op: 'ping' });
		await hostPump.expect('pong');
		await new Promise((resolve) => setTimeout(resolve, 150));
	}
	assert.equal(relay.rooms.size, 1); // still alive after 600ms of pings
	const note = await hostPump.expect('room_closed', 5000);
	assert.equal(note.reason, 'idle');
	await closed(host);
});

test('per-ip connection caps refuse extra sockets', async (t) => {
	const { relay, url } = await startServer({ maxConnectionsPerIp: 1 });
	t.after(() => relay.close());
	const first = await connect(url);
	// The upgrade completes before the cap check, so the extra socket
	// briefly opens and is then closed by the server (1013 busy).
	const second = await connect(url);
	await closed(second);
	first.close();
});

test('graceful shutdown closes rooms and notifies members', async (t) => {
	const { relay, url } = await startServer();
	t.after(() => relay.close());
	const { host, hostPump, code } = await createRoom(url);
	const client = await connect(url);
	const clientPump = pump(client);
	sendJson(client, { op: 'join', code });
	await clientPump.expect('joined');
	await hostPump.expect('peer_joined');

	relay.close();
	await clientPump.expect('room_closed');
	await closed(client);
	await closed(host);
	assert.ok(!relay.rooms.has(code));
});
