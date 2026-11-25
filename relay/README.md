# Bridgewatch relay

WebSocket relay between the upstream feeds ([aisstream.io](https://aisstream.io) for boats, MTA's subway feeds for
trains) and the Bridgewatch iOS app. Each feed is a source plug-in; the relay holds the upstream connections, turns what they send into targets (one model for
boats, trains and planes), keeps the current set, and serves it to the app at `ws://<host>:8080/v2/targets`. App builds
from before that use `ws://<host>:8080/v1/vessels` (AIS only). Wire format and merge rules: [PROTOCOL.md](PROTOCOL.md).

aisstream forbids direct browser/client connections, so the API key lives only here, never in the app. MTA's subway
feeds need no key.

## Environment

| Var | Default | Notes |
| --- | --- | --- |
| `SOURCES` | `aisstream,mta-subway` | Comma-separated sources to run (see Sources) |
| `AISSTREAM_API_KEY` | none | Required for `record`, and for `start` when `SOURCES` has `aisstream` |
| `PORT` | `8080` | |
| `HOST` | `0.0.0.0` | |
| `RECORD_SECONDS` | `300` | `record` duration |
| `RELAY_HOST_PORT` | `8080` | Host port for `docker compose` (the container listens on 8080) |
| `MAX_CLIENTS` | `200` | WebSockets open at once on the main listener (`PORT`); more get a 503. No per-address cap there. A value that is not a positive integer is logged and the default used: a typo never stops the relay |
| `PUBLIC_PORT` | none | The public listener, for the Cloudflare Tunnel only: token always, WebSocket paths only. Never publish it on a host port. Unset: none. See PROTOCOL.md, "Access" |
| `APP_TOKEN` | none | App tokens (16+ characters each), comma-separated for a rotation. Without a valid one the public listener isn't started (an error in the log, `relay_public_listener_up` 0) and the relay runs on |
| `PUBLIC_MAX_CLIENTS` | `200` | WebSockets open at once on the public listener; more get a 503 |
| `PUBLIC_MAX_CLIENTS_PER_IP` | `10` | WebSockets open at once on the public listener from one address (an IPv6 /64); more get a 429 |
| `CENSUS_FILE` | none | Where the vessel census is kept between runs (see Census). Unset: the census lives in memory only and nothing is written to disk. Production: `/data/census.json` on a volume |

## Vessel details

Besides position, speed, course, heading, name and ship type, the `aisstream` source carries these optional vessel
details on `/v2/targets` (PROTOCOL.md, "Vessels"): IMO number, call sign, destination, ETA, length, beam, draught
(from `ShipStaticData`) and navigational status (from `PositionReport`). The normalizer returns them next to each
`VesselUpdate` (`Normalizer.normalizeAll`), never inside it, so `/v1/vessels` is byte for byte what it was; the
registry merges them per MMSI. Destination and call sign are typed in by the crew: the relay strips control and bidi
characters and padding and caps their length, and clients must still show them as plain text.

## Census

The relay keeps no history of its own, so `src/census.ts` counts which vessels it sees, to find the boats that recur
in the harbor (which are worth a photo). The `aisstream` source reports every normalized message to it: one record per
MMSI with its latest name, ship type, length, beam, call sign and IMO (only when valid), when it was first and last
heard, `daysSeen` (distinct UTC dates), `positions` (position reports) and its newest 60 dates. **Stored: vessel
identifiers and counts only. Never a position, a track, or anything about people.** At most 5000 vessels are held (the
least recently seen goes first), about 2 MB of JSON.

With `CENSUS_FILE` set it is loaded at start and written back (atomically: temp file, then rename) at most every five
minutes, only when changed, and on SIGTERM. A missing, empty, corrupt or other-version file starts it empty and is
logged once; a failed write is logged once per streak, counted (`relay_census_write_failures_total`) and never stops
the relay. `relay_census_vessels` is the number held. `GET /census` serves it on the main listener only (PROTOCOL.md,
"Census").

`npm run census -- <census.json | http://host:8095/census>` prints a table (rank, mmsi, name, type, length, days,
positions, last seen) and how many vessels there are, how many have a name, and how many make up 50%, 80% and 95% of
all position reports. On the host: `curl -s localhost:8095/census > census.json`, then run it on the file.

## Commands

- `npm test`: build, then run Jest on `dist/` (never touches aisstream).
- `npm start`: run the relay (after `npm run build`).
- `npm run record`: record raw frames for 5 minutes to `fixtures/aisstream-<UTC timestamp>.jsonl` (hits the live service).
- `npm run fixtures`: regenerate every fixture (see "Test data"): `fixtures/subway/*.pb` and `*-targets.json` from the
  subway scenario (`src/tools/subway-scenario.ts`), `Packages/BoatCore/Tests/BoatCoreTests/Fixtures/relay-v2-{stream,snapshot}.json`
  from `fixtures/synthetic-sample.jsonl` and the subway rounds, and `relay-v2-details-{stream,snapshot}.json` from
  `fixtures/synthetic-static.jsonl` (the vessel details: sentinels, dirty text, omissions; /v1 never plays it). A test
  fails if any of them drifts.
- `npm run subway-extract -- <dir>`: regenerate `src/subway-data.ts` (the track of every pair of consecutive stations
  inside the area, `BOUNDING_BOXES`: underground track clipped to it at the rail altitude of the depth model, and the
  above-ground stretches whole, with their heights) from MTA's static GTFS, downloaded from
  https://rrgtfsfeeds.s3.amazonaws.com/gtfs_subway.zip and unzipped into `<dir>`. Needed only when MTA changes the
  track shapes or routes, or the area, the stretches or the depth tables (`src/tools/depth.ts`) change. The depth
  model needs ground elevations, read from `data/elevation.json` (committed, from the USGS Elevation Point Query
  Service), so the run is offline and deterministic; a point the file lacks stops it, and `-- <dir> --fetch-elevation`
  asks USGS for the missing ones (a few hundred points, a few at a time, about 15 minutes; commit the file after). A route that gets track there must also be in
  `SUBWAY_FEED_ROUTES` (`src/subway-feed.ts`), which names the NYCT feeds the relay polls.
- `npm run census -- <census.json | url>`: the vessel census as a table with a summary (see Census). Read only.
- `docker compose up -d --build`: run in a container (copy `.env.example` to `.env` and set the key first).
- `APP_TOKEN=<token> npm run check-edge -- https://<public hostname>`: checks the public edge from outside: `/healthz`
  and `/metrics` (and other spellings and methods) 404, on both WebSocket paths a client without or with a wrong token
  refused and one with the token given the snapshot. The token is read only from `APP_TOKEN`, never printed. Run it
  from another machine after setting up the tunnel (deploy/README.md, "Public edge").

## Test data

Every fixture is synthetic: nothing in the repo is a recording of a provider's data (aisstream, MTA). The AIS frames
(`fixtures/synthetic-*.jsonl`) are hand-written, with invented boats. The subway feeds (`fixtures/subway/`) are built
from a scenario, `src/tools/subway-scenario.ts`: invented trips, trip IDs, train IDs and times, encoded as GTFS-realtime
(NYCT extensions included) by `src/tools/synthetic-gtfsrt.ts`; only stop, route and shape IDs are real, as facts from the
static GTFS that `src/subway-data.ts` already carries. The scenario says, trip by trip, where each train should end up
and why, and the tests check against that. To regenerate everything after changing it, run `npm run fixtures` (it
rewrites `fixtures/subway/`, then the four BoatCore fixtures `relay-v2-*.json`) and commit the result; a relay test fails
when a committed file differs from the generator's output. `npm run record` is for looking at the live AIS feed:
`fixtures/aisstream-*.jsonl` is git-ignored, and a recording is never to be committed.

## Health

aisstream can stop sending without closing the socket. If nothing (not even the open) arrives for 120 s
(`IDLE_TIMEOUT_MS` in `src/upstream.ts`), the relay drops the socket and reconnects with backoff. Each source reports
its part of `/healthz` (`health(now)`, `src/health.ts`, PROTOCOL.md): a stream fails after 600 s without data, as a
backstop, so the container gets restarted. A source fails only for what a restart can fix, never for an outage on the
feed's side.

## Failure handling

A bug in one source must not take the others, or the server, down with it (`src/guard.ts`). Guarded, so a throw is
logged and the next tick or frame carries on: each source's publishing (the MTA source from both the poll loop and its
10 s ticker), the subway poll loop (a round never rejects and the next one is always scheduled), the upstream frame
handler and each message it delivers, the AIS source's /v1 update and census (a failure in either still publishes the
boat on /v2), and the timers for the pruner and census writer in `src/index.ts` and the AIS source's own pruner. A
source that throws in `start()` is logged and the others still start. A hub subscriber that throws is skipped; the
others still get the event. The train estimator skips a trip whose estimate throws and publishes the rest.

These lines are rate limited, each kind on its own: the first failure is logged at once, then at most one line a minute,
carrying how many were left out (`(and N more since the last line)`). There is no "recovered" line. Text from the feeds
(error messages, trip IDs) is flattened to one line and capped before it is logged.

Behind that, at the process level: an unhandled rejection is logged (rate limited too) and the relay keeps serving (a
restart drops every client, and the vessel set takes minutes to rebuild from AIS); an uncaught exception is logged and
the process exits 1 (its state is unknown; Docker restarts the container). A port already in use at boot is fatal too.
None of this fails `/healthz`: a 503 gets the container restarted and would undo the isolation.

Not guarded yet: the upstream client's reconnect, watchdog and subscribe timers, the server's ping timer, and shutdown.
A throw there is still an uncaught exception, and the process exits.

## Metrics

`GET /metrics` serves Prometheus metrics (`src/metrics.ts`, written out by hand, no client library): `relay_up` and,
per source, `relay_source_up`, `relay_source_connected` and `relay_source_data_age_seconds` (the `/healthz` report as
numbers); `relay_targets` by source and kind; `relay_clients` by path; counters for client connections and messages
sent, and target updates and removals; and the process's memory, CPU time and event loop delay. Like `/healthz`, it's
for the operator only: the public listener serves only the WebSocket paths, and the main one hides both from any
request a proxy forwarded. For the edge: `relay_public_listener_up`, `relay_client_rejections_total` (by listener and
reason) and `relay_clients_dropped_total` (by path).

## Sources

A source is a plug-in in `src/sources/` that publishes targets (`src/targets.ts`) to the hub (`src/hub.ts`), which
serves them on `/v2/targets`. To add one:

1. Write `src/sources/<name>.ts` exporting a `SourcePlugin`: `configure(env)` checks its settings (throwing
   `ConfigError`) and returns a function that creates the running `Source` from its context.
2. Publish each object's full state with `sink.upsert(target, expiresAt)`, or the whole current list with
   `sink.replaceAll(targets)` for feeds that are polled as a list; `sink.remove(id)` when one goes.
3. Implement `health(now)` if it can get stuck in a way a restart fixes; report `lastDataAgeSeconds` either way.
4. Add it to `SOURCE_PLUGINS` in `src/sources/index.ts`, document its kind and source in PROTOCOL.md, and test it
   with fixtures (never the live service).

Then it's on wherever `SOURCES` names it.
