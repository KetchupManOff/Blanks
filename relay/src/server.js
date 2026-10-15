// Process entry point: builds the relay from environment configuration
// (see .env.example / README.md), listens, and shuts down cleanly.

import { createRelayServer } from './relay.js';

function intEnv(name, fallback) {
	const raw = process.env[name];
	if (raw === undefined || raw === '') return fallback;
	const value = Number.parseInt(raw, 10);
	return Number.isFinite(value) ? value : fallback;
}

function floatEnv(name, fallback) {
	const raw = process.env[name];
	if (raw === undefined || raw === '') return fallback;
	const value = Number.parseFloat(raw);
	return Number.isFinite(value) ? value : fallback;
}

const config = {
	host: process.env.BIND_HOST || '0.0.0.0',
	port: intEnv('PORT', 8080),
	maxRoomPeers: intEnv('MAX_ROOM_PEERS', 4),
	codeLength: intEnv('CODE_LENGTH', 7),
	roomIdleTimeoutMs: intEnv('ROOM_IDLE_TIMEOUT_MS', 30 * 60 * 1000),
	sweepIntervalMs: intEnv('SWEEP_INTERVAL_MS', 15 * 1000),
	heartbeatIntervalMs: intEnv('HEARTBEAT_INTERVAL_MS', 30 * 1000),
	packetLimit: intEnv('PACKET_LIMIT', 65536),
	ratePerSecond: floatEnv('RATE_LIMIT_PER_SECOND', 120),
	rateBurst: floatEnv('RATE_BURST', 240),
	maxConnections: intEnv('MAX_CONNECTIONS', 256),
	maxConnectionsPerIp: intEnv('MAX_CONNECTIONS_PER_IP', 32),
	allowedOrigins: (process.env.ALLOWED_ORIGINS ?? '')
		.split(',')
		.map((entry) => entry.trim())
		.filter(Boolean),
};

const relay = createRelayServer(config);
relay.httpServer.listen(config.port, config.host, () => {
	console.log(`blanks-relay listening on ${config.host}:${config.port}`);
});

function shutdown() {
	console.log('blanks-relay shutting down');
	relay.close(() => process.exit(0));
	// Force-exit if some socket lingers past graceful close.
	setTimeout(() => process.exit(0), 2000).unref();
}

process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);
