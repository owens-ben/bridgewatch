#!/usr/bin/env bash
# Starts (or updates) the Cloudflare Tunnel connector on this host. Run it from anywhere in the repo, as the
# user who runs the relay; see deploy/README.md, "Public edge". Safe to run again.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

export TUNNEL_ENV_FILE="${TUNNEL_ENV_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/bridgewatch/tunnel.env}"
network=boat-ar-relay_default
compose=(docker compose -f deploy/edge/compose.yaml)

if [ ! -r "$TUNNEL_ENV_FILE" ]; then
  echo "error: $TUNNEL_ENV_FILE is missing (deploy/README.md, Public edge)" >&2
  exit 1
fi
# `stat -c` is GNU (Linux): this script runs on the Linux deploy host, not on a Mac.
if [ "$(stat -c %a "$TUNNEL_ENV_FILE")" != 600 ]; then
  echo "error: $TUNNEL_ENV_FILE must be mode 600 (chmod 600 it)" >&2
  exit 1
fi
if ! grep -Eq '^TUNNEL_TOKEN=.+' "$TUNNEL_ENV_FILE"; then
  echo "error: $TUNNEL_ENV_FILE has no TUNNEL_TOKEN=<token> line" >&2
  exit 1
fi
if ! docker network inspect "$network" >/dev/null 2>&1; then
  echo "error: no Docker network $network; deploy the relay first (deploy/relay/deploy.sh)" >&2
  exit 1
fi

"${compose[@]}" up -d
sleep 5
"${compose[@]}" ps
echo "recent connector log:"
"${compose[@]}" logs --tail 15 cloudflared
echo "Look for 'Registered tunnel connection' above. Then, from another machine:"
echo "  APP_TOKEN=<token> npm run check-edge -- https://<your hostname>"
