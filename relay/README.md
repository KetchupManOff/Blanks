# tye-relay

Forwarding-only WebSocket relay for Tetris Yank Edition online co-op.
The relay is an availability component, not an authority: it creates
private rooms addressed by high-entropy codes and moves frames between
the host and the room's clients. The game host stays authoritative
(simulation, input validation, snapshots); the relay never decodes
gameplay payloads, and sender identity is stamped by the relay into a
4-byte little-endian header on every forwarded frame.

## Running

```sh
npm install
npm start          # reads configuration from the environment
npm test           # node --test relay behavior suite
```

Node 20+ required. All settings are environment variables with
defaults (see `.env.example`); there are no credentials to configure.

## Docker

```sh
cp .env.example .env
docker compose up -d --build
curl http://127.0.0.1:8080/healthz   # -> ok
```

## TLS termination

Players connect over `wss://`, so something must terminate TLS in front
of the relay. The compose file ships a `tls` profile with Caddy:

```sh
# edit Caddyfile.example first (set your relay domain)
docker compose --profile tls up -d --build
# then remove the direct 8080 port mapping from compose for that host
```

Equivalent nginx site (WebSocket upgrade + long timeouts):

```nginx
server {
    listen 443 ssl;
    server_name relay.example.com;
    ssl_certificate     /etc/letsencrypt/live/relay.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/relay.example.com/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }
}
```

Operator requirements: one public host with ports 80/443 open (Caddy
needs 80 for the ACME challenge), and DNS for the relay domain pointed
at it. Players never open ports; they only connect out.

## Wire behavior (what the game expects)

- JSON control frames (text): `create`, `join` with a code, `ping`;
  replies `created`/`joined` (with `code` and relay-assigned `peer_id`),
  `pong`, `error` (with a `code` like `invalid_code`, `not_found`,
  `full`, `not_host`, `bad_op`, `already_in_room`, `not_in_room`,
  `too_large`, `rate_limited`).
- Relay-pushed notifications: `peer_joined`, `peer_left` (host's
  roster signal), `room_closed` (reason `host_left`, `idle`, `closed`,
  `shutdown`).
- Binary frames are game envelopes: clients send to the host only, the
  host broadcasts to every room client. The relay prepends the sender's
  relay peer id (host is always `1`, clients `2..MAX_ROOM_PEERS`) and
  enforces direction, frame size, per-socket rate, room capacity, and
  idle expiry. Host socket loss closes the room; client socket loss
  notifies the host.
