#!/usr/bin/env bash
# Builds the relay at the checked-out commit and runs it on this host. Rolls back to the image that was running
# before if the new one doesn't report live data within 90 s. Run from anywhere in the repo; see deploy/README.md.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$(git rev-parse --show-toplevel)"

export RELAY_ENV_FILE="${RELAY_ENV_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/bridgewatch/relay.env}"
export RELAY_HOST_PORT="${RELAY_HOST_PORT:-8095}"
container=boat-ar-relay-relay-1
repo=bridgewatch-relay
keep=5
compose=(docker compose -f deploy/relay/compose.yaml)

if [ ! -r "$RELAY_ENV_FILE" ]; then
  echo "error: $RELAY_ENV_FILE is missing (deploy/README.md, One-time setup)" >&2
  exit 1
fi

revision=$(git rev-parse HEAD)
image="$repo:${revision:0:12}"
subject=$(git log -1 --format=%s)
previous=$(docker inspect --format '{{.Config.Image}}' "$container" 2>/dev/null || true)

echo "building $image"
docker build --label "org.opencontainers.image.revision=$revision" -t "$image" relay

# Healthy means live AIS data, not just a running server: /healthz says ok right after start. Reads both report
# shapes, per-source (.sources.aisstream) and the one before sources (.upstream), so a rollback is checked too.
live_ais='.ok and ((.sources.aisstream // .upstream) | .connected and ((.lastDataAgeSeconds // .lastFrameAgeSeconds) != null))'
wait_for_data() {
  local body=""
  for _ in $(seq 1 45); do
    body=$(curl -s -m 3 "http://127.0.0.1:$RELAY_HOST_PORT/healthz" || true)
    if jq -e "$live_ais" >/dev/null 2>&1 <<<"$body"; then
      echo "healthy: $body"
      return 0
    fi
    sleep 2
  done
  echo "no live data after 90 s; last /healthz: ${body:-no response}" >&2
  return 1
}

# A deploy receipt is optional. A host that wants one defines notify() in host.sh next to this script (not part of
# the public repo); without it, notify does nothing. A missing receipt never fails or rolls back a deploy.
notify() { :; }
if [ -r "$here/host.sh" ]; then
  # shellcheck source=/dev/null
  . "$here/host.sh"
fi

echo "deploying $image (was ${previous:-nothing})"
if ! RELAY_IMAGE="$image" "${compose[@]}" up -d --wait --wait-timeout 60 relay || ! wait_for_data; then
  RELAY_IMAGE="$image" "${compose[@]}" logs --tail 50 relay || true
  outcome="nothing to roll back to"
  if [ -n "$previous" ] && [ "$previous" != "$image" ]; then
    echo "rolling back to $previous" >&2
    RELAY_IMAGE="$previous" "${compose[@]}" up -d relay
    if wait_for_data; then outcome="rolled back to $previous"; else outcome="rolled back to $previous, which has no live data either"; fi
  fi
  notify ":x: bridgewatch relay deploy of ${revision:0:12} (${subject}) failed: no live AIS data within 90 s; ${outcome}"
  exit 1
fi
notify ":white_check_mark: bridgewatch relay deployed ${revision:0:12} (${subject}): $(curl -s -m 3 "http://127.0.0.1:$RELAY_HOST_PORT/healthz" \
  | jq -r '"\(.targets) targets, sources " + ([.sources // {} | to_entries[] | "\(.key) \(if .value.ok then "ok" else "NOT ok" end)"] | join(", "))' 2>/dev/null || echo "health unreadable")"

# Keep the newest few images for rollbacks; images in use can't be removed and are skipped.
docker images "$repo" --format '{{.Tag}}' | tail -n +$((keep + 1)) | while read -r tag; do
  docker rmi "$repo:$tag" >/dev/null 2>&1 || true
done
