# Deploys

How the relay is run in production, with placeholders where a real deployment has its own hosts. The relay is one
Docker container on a Linux host; the app talks to it over a WebSocket. Secrets live on the host, outside the
repository.

- `relay/`: the compose file and `deploy.sh`, a health-gated deploy.
- `edge/`: a Cloudflare Tunnel connector, so the relay can be reached from outside the home network without opening a
  port.

## Relay

`deploy/relay/deploy.sh`, run on the host from a checkout of the commit to deploy:

1. Builds `bridgewatch-relay:<commit>` from `relay/`.
2. Replaces the running container (compose project `boat-ar-relay`, host port 8095 unless `RELAY_HOST_PORT` says
   otherwise).
3. Waits up to 90 s for `/healthz` to show live AIS data. A server that is merely running does not count: `/healthz`
   says ok right after start, so the script waits for a connected source that has delivered data.
4. If that does not happen, rolls back to the image that was running before, checks that one the same way, and exits 1.
5. Keeps the five newest images for rollbacks.

The settings live in `deploy/relay/compose.yaml` (port, memory limit, log rotation, health check) and the defaults at
the top of `deploy.sh`. The API key goes in `$XDG_CONFIG_HOME/bridgewatch/relay.env` on the host
(`AISSTREAM_API_KEY=...`, see `relay/.env.example`), mode 600.

A host that wants a receipt after each deploy (a chat message, say) defines a `notify()` function in
`deploy/relay/host.sh`. Without that file `notify` does nothing, and a missing receipt never fails or rolls back a
deploy.

The vessel census (relay/README.md, "Census") lives in the named volume `census`, mounted at `/data`, so it survives
deploys, rollbacks and restarts. `docker compose down -v` deletes the volume; a plain `down` or `up` does not. The
census holds vessel identifiers and counts only.

### Continuous deployment

The original setup ran the relay's tests and then `deploy.sh` from a GitHub Actions workflow on a self-hosted runner on
the host, on every push to `main` that touched `relay/` or `deploy/relay/`. That workflow is not part of this
repository (it names private runners). The pieces are all here: `npm test` in a `node:22` container, then
`deploy/relay/deploy.sh`.

## Public edge

For TestFlight testers outside the home network: `wss://relay.<your domain>`, then Cloudflare, then a tunnel connector
on the host (`deploy/edge/`), then the relay's public listener (`relay:8081` on the relay's Docker network). The
connector dials out to Cloudflare, so the host opens no inbound port, and Cloudflare gives the hostname its
certificate. The relay's side is in `relay/PROTOCOL.md`, "Access":

- The public listener (`PUBLIC_PORT`, 8081 in the container) is never published on a host port. It always asks for the
  app token, serves only `/v2/targets` and `/v1/vessels`, allows 10 WebSockets per address and 200 in all, and drops
  clients that stop reading. Without a valid `APP_TOKEN` it does not start (fail closed), and the log and the
  `relay_public_listener_up` metric say so.
- The main listener (host port 8095) asks no token. If a request carries `CF-Connecting-IP` or `X-Forwarded-For`, it is
  treated as public: token required, no `/healthz` or `/metrics`.

The token ships inside the app, so it keeps scrapers and stray clients out but does not stop someone who unpacks a
build. That is the right strength for a small TestFlight group, not for an App Store release.

Setup, in short: put `APP_TOKEN=<random>` in `relay.env` and recreate the container; create a tunnel in the
Cloudflare dashboard with one public hostname pointing at `http://relay:8081`, restricted to the path
`^/(v2/targets|v1/vessels)$`; put `TUNNEL_TOKEN=<token>` in `tunnel.env` (mode 600, next to `relay.env`); run
`deploy/edge/up.sh`. Then, from another machine, `cd relay && APP_TOKEN=<token> npm run check-edge -- https://relay.<your domain>`
checks that `/healthz`, `/metrics` and other spellings and methods get a 404, and that a missing or wrong token gets a
401 on the WebSocket paths.

Turning it off: stop the connector and the hostname answers 530 at once. No relay change is needed.

## Monitoring

The relay serves Prometheus metrics at `/metrics` (relay/README.md, "Metrics"): health per source, data age, targets,
clients, traffic, memory, CPU and event loop delay. The original setup scraped them into VictoriaMetrics with a Grafana
dashboard on a separate machine, so the dashboard still answers, and shows the gap, when the relay host is down. That
configuration holds real addresses and is not part of this repository.
