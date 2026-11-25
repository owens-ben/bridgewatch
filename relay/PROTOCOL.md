# Relay protocol

The relay is the only thing that talks to the upstream feeds (its sources: aisstream.io, MTA's subway feeds). The app
connects to the relay.

## Endpoints

- `GET /v2/targets` upgraded to WebSocket: every target from every source. See [/v2/targets](#v2targets).
- `GET /v1/vessels` upgraded to WebSocket: AIS vessels only, for app builds from before `/v2/targets`. Kept until
  every installed build uses `/v2/targets`. See [/v1/vessels](#v1vessels).
- `GET /healthz` (plain HTTP, for container health checks) returns JSON such as
  `{"ok":true,"sources":{"aisstream":{"ok":true,"connected":true,"lastDataAgeSeconds":2},"mta-subway":{"ok":true,"lastDataAgeSeconds":24}},"targets":41,"clients":1}`:
  status 200 when every source is `ok`, 503 otherwise. A source is not `ok` only when a restart could help: aisstream
  with no data for 600 seconds (counted from start until the first data), or mta-subway with no poll round finished in
  11.5 minutes (`STALLED_AFTER_MS`). On the production host, autoheal restarts the container when the health check fails.
  `lastDataAgeSeconds` (for mta-subway, the age of MTA's newest feed) is reported either way, for monitoring.

- `GET /metrics`: Prometheus metrics for monitoring (README, "Metrics").
- `GET /census`: the vessel census, for the operator only, not the public (see [Census](#census-get-census)).

Anything else returns 404 (a request too malformed to parse gets Node's 400 or 431). `/healthz`, `/metrics` and `/census` are for the operator only: see [Access](#access).

Text frames, one JSON object per frame. The relay never reads client frames.

## Access

The relay has two listeners:

- **Main** (`PORT`; in production the host's port 8095, reached over the local network): as before, plus a total cap. No
  token, all the endpoints above, at most `MAX_CLIENTS` (200) WebSockets in all and no cap per address. Builds from
  before tokens keep working. Belt and braces: a request that carries any proxy or forwarding header
  (`CF-Connecting-IP`, `CF-Ray`, `CDN-Loop`, `CF-IPCountry`, `X-Forwarded-For`, `X-Forwarded-Host`, `X-Real-IP`,
  `Forwarded`, `True-Client-IP`; present at all, even empty) is treated as public: its WebSocket upgrade needs the
  token, and `/healthz`, `/metrics` and `/census` answer it 404. The app sends none of these.
- **Public** (`PUBLIC_PORT`): for the Cloudflare Tunnel only (deploy/README.md, "Public edge"). It is never published
  on a host port; cloudflared reaches it over a Docker network. Every WebSocket upgrade needs the token, and it serves
  nothing else: any other request, whatever the method or path (`/healthz`, `/metrics` and `/census` included), is a 404. It is
  started only when `APP_TOKEN` holds a valid token; otherwise it stays off and the relay runs on (fail closed).

A refused WebSocket upgrade gets a plain HTTP response:

| Status | When | Headers | What a client does |
| --- | --- | --- | --- |
| 401 | A public upgrade without `Authorization: Bearer <token>`, or with the wrong one | `WWW-Authenticate: Bearer` | The build's token is wrong or missing: retrying won't help. Say so, retry rarely (an update may fix it) |
| 429 | Public listener: the client's address already has `PUBLIC_MAX_CLIENTS_PER_IP` (10) WebSockets open, both paths together | `Retry-After: 30` | Wait at least that long |
| 503 | The listener already has its cap open (`MAX_CLIENTS` or `PUBLIC_MAX_CLIENTS`, 200 each) | `Retry-After: 10` | Wait at least that long, then back off as for any failed connect |

- **Token:** a shared secret in the app build (`APP_TOKEN` accepts several, comma-separated, so one can be retired
  after a rotation; each at least 16 characters, compared in constant time, never logged). It ships inside the app, so
  it keeps scrapers and stray clients out; it does not stop someone who unpacks a build.
- **Address** (public listener): `CF-Connecting-IP` when it is a valid IP, else the socket's address; an IPv6 address
  counts by its /64. Addresses are never logged and never a metric label.
- **Slow clients:** a client that stops reading and leaves more than 256 KiB unsent is disconnected, at connect (if it
  can't take its snapshot) or at the next message. So is any client with unsent data while all clients together have
  more than 32 MiB unsent. It reconnects as after any drop: the new snapshot replaces everything it holds.
- Refusals and drops are counted in `/metrics` (`relay_client_rejections_total` by listener and reason,
  `relay_clients_dropped_total` by path); `relay_public_listener_up` is 1 while the public listener is open.

`npm run check-edge` (README) tests all of this against the public address.

## Census (`GET /census`)

Which vessels the relay has seen and on how many days, to decide which boats are worth a photo. Plain HTTP on the
**main listener only**, and only for a request with no forwarding header (the same rule as `/healthz`); the public
listener and forwarded requests get 404, as does a relay with no census. It is not part of the app's protocol and
nothing in the app reads it. The census is on in every run; it is kept in a file only when `CENSUS_FILE` is set.

```json
{"version":1,"generatedAt":"2026-11-10T14:12:00.000Z","vessels":[
  {"mmsi":367000001,"name":"HARBOR LARK","shipType":60,"length":30,"beam":9,"callSign":"WDC1234","imo":9123453,
   "firstSeen":"2026-11-08T09:14:02.000Z","lastSeen":"2026-11-10T14:11:00.999Z","daysSeen":3,"positions":4120,
   "lastDates":["2026-11-08","2026-11-09","2026-11-10"]}]}
```

- One record per MMSI, sorted by `daysSeen` descending, then `positions` descending, then `mmsi`. `?limit=N` returns
  the first N (default 500, at most 5000); a bad `limit` (not a positive integer) uses the default; other parameters
  are ignored. `Content-Type: application/json`.
- `name`, `shipType`, `length`, `beam`, `callSign` and `imo` are the latest the vessel sent (cleaned like `/v2/targets`;
  `imo` only when valid) and are omitted until heard. `firstSeen` and `lastSeen` are the times of its oldest and
  newest message; `daysSeen` is the number of distinct UTC dates with a message; `positions` the number of position
  reports. `lastDates` is the newest 60 of those dates, oldest first (`daysSeen` keeps counting past 60).
- Vessel identifiers and counts only: never a position or track, and nothing about people.
- At most 5000 records are held; past that the least recently seen vessel is dropped.
- The file (`CENSUS_FILE`) is the same JSON (`version`, `generatedAt`, every record), replaced atomically (temp file,
  then rename) at most every 5 minutes and only when something changed, and on shutdown. A missing, empty, corrupt or
  other-version file starts the census empty (logged once) and is replaced at the next write.

## /v2/targets

### Messages (relay -> app)

On connect, exactly one snapshot, then changes as they happen:

```json
{"type":"snapshot","targets":[Target, ...]}
{"type":"update","target":Target}
{"type":"remove","id":"vessel:367000001"}
```

- `snapshot.targets`: every current target, sorted by `id`.
- `update`: the target's full current state. It replaces whatever the client holds for that `id`; there is nothing to
  merge.
- `remove`: the target is gone (not heard from for too long, or its source dropped it). The relay sends one for every
  target that leaves while the client is connected, so a client keeps exactly the targets it was sent. After a
  reconnect, the new snapshot replaces everything.

Clients skip messages whose `type` they don't know and targets whose `kind` they don't know.

### Message size and liveness

- The app accepts messages up to 8 MiB (URLSession's default would be 1 MiB). The snapshot is the largest message,
  about 400 bytes per target; the relay logs a warning when one passes 512 KiB (`SNAPSHOT_WARN_BYTES`).
- The app pings every 15 s and closes a connection whose pong doesn't come within 10 s (WebSocket ping/pong, which
  `ws` answers by itself), and one that delivers no message it can decode within 20 s of opening (the snapshot comes
  first, at once). It has no idle timeout: nothing here promises a message cadence. Either way it reconnects with
  backoff, as after any drop.

### Target

| Key | Type | Notes |
| --- | --- | --- |
| `id` | string | `<kind>:<id within the kind>`, e.g. `vessel:367000001`. Stable while the object is tracked. The same object gets the same `id` from any source |
| `kind` | string | `vessel` or `train` (more come with new sources) |
| `source` | string | The relay source that sent this state, e.g. `aisstream` (see [Sources](#sources)). For attribution and debugging |
| `name` | string | Display name, e.g. a ship's name. Omitted if unknown, and for trains |
| `lat`, `lon` | number | Always present, WGS84 degrees |
| `altitude` | number | Meters above sea level. Omitted for objects on the water |
| `speed` | number | Knots over ground. Omitted if unknown |
| `course` | number | Direction of travel over ground, degrees true, [0, 360). Omitted if unknown |
| `heading` | number | Where the object points (a ship's bow), degrees true, [0, 360). Omitted if unknown |
| `timestamp` | string | ISO 8601 UTC with milliseconds: the time of the position |
| `vessel`, `train` | object | The one named after `kind`, see [Vessels](#vessels) and [Trains](#trains) |

Unknown keys are omitted, never `null`. Each kind's own fields live in an object named after the kind, so the shared
keys mean the same thing for every kind and a client can place and dead-reckon a target by them alone.

When two sources report the same `id`, the newer position wins; a source can only remove a target it sent.

### Vessels

`kind` `vessel`, `id` `vessel:<mmsi>`. `vessel` holds:

| Key | Type | Notes |
| --- | --- | --- |
| `mmsi` | integer | Always present |
| `shipType` | integer | AIS type code 1-99. Omitted if unknown |
| `imo` | integer | IMO number. Omitted when unknown (AIS 0) |
| `callSign` | string | Radio call sign, at most 7 characters. Omitted if empty |
| `destination` | string | Destination the crew typed in, at most 20 characters. Omitted if empty |
| `eta` | object | `{"month":1-12,"day":1-31,"hour":0-23,"minute":0-59}`, UTC, no year (AIS has none). Only when all four are valid: AIS sends 0 for month and day, 24 for hour and 60 for minute when not available |
| `length` | integer | Meters, AIS dimensions A + B (bow and stern to the antenna). Omitted when unknown or 0 |
| `beam` | integer | Meters, AIS dimensions C + D (port and starboard). Omitted when unknown or 0 |
| `draught` | number | Maximum static draught in meters, one decimal (AIS resolution 0.1 m, at most 25.5). Omitted when 0 or unknown |
| `navStatus` | integer | AIS navigational status 0-14 (0 under way using engine, 1 at anchor, 5 moored, 8 under way sailing, ...). Omitted when 15 (not defined) or out of range |

The keys come in the order of the table. Unknown keys are omitted, never `null`; older apps ignore the keys they don't
know. `callSign` and `destination` are typed in by the vessel's crew, so they are untrusted: the relay strips control
characters (newlines included) and bidirectional and other invisible format characters, collapses runs of whitespace,
trims `@` and space padding and caps the length, and drops the key when nothing is left. A client still shows them,
and `name`, as plain text only (never as markup, a link or a command).

A vessel target is the vessel's merged state under the [merge rules](#merge-rules-relay-snapshot-and-app-vesselregistry-must-agree)
(`speed` = `sog`, `course` = `cog`), with `timestamp` the time of its newest position. It's removed 600 s after the
vessel's newest message.

The details exist on `/v2/targets` only. `/v1/vessels` is unchanged: a `VesselUpdate` has none of these keys, and a
static message that has no name or ship type (only details) is not sent on `/v1/vessels` at all.

### Trains

`kind` `train`, `id` `train:nyct:<trip ID>` (NYCT's realtime trip ID, e.g. `train:nyct:101100_Q..S36R`, stable while
the trip runs). Every NYC subway train inside the app's area (`BOUNDING_BOXES`, relay/src/config.ts, the same area as
the boats), above ground and underground, plus the whole of the named above-ground stretches where they run on past
its edge (see [Levels](#levels)), with estimated positions: MTA's subway feeds carry no GPS (see
[Estimate](#estimate)). Trains anywhere else are never sent.

- `altitude`: track (rail) height, meters above sea level (NAVD88), negative where the track is below it. Car roofs are
  about 3.7 m higher: check the sightline to `altitude` + 3. Above ground it's measured from lidar (the Franklin Av
  shuttle's is estimated); underground it's modelled from each station's depth below the street and the river tubes'
  low points (see [Levels](#levels)). `train.altitudeEstimated` says which kind of figure it is.
- `course`: direction of travel along the track. No `heading`.
- `speed`: the average speed of the run between the two stations; 0 while standing at a station.
- `timestamp`: the time the position is estimated for (the relay's clock when it estimated it).

The relay re-estimates every train every 10 s and after each MTA poll, so a train on view gets an `update` at least
every 10 s. One that leaves the area or can no longer be placed gets a `remove`, and so does every train once the
relay hasn't re-estimated it for 30 s (it lost MTA). Between updates, dead-reckon along `course` at `speed` from
`timestamp`, as for boats, but for at most 15 s (the relay re-sends every 10 s, so that covers one missed update): the
track curves, trains stop at stations, and the track climbs or dives (about 4%, up to about 4.3% on the steepest runs) where a tunnel meets a stretch; at
30 s a stale train was carried about 450 m past a bridge portal while still drawn as elevated.

`train` holds:

| Key | Type | Notes |
| --- | --- | --- |
| `route` | string | Route ID from the feed. Every route with track in the area: `1` `2` `3` `4` `5` `6` `6X` `A` `B` `C` `D` `E` `F` `FS` `FX` `G` `J` `L` `M` `N` `Q` `R` `W` `Z`. `6X` is the 6 express (diamond 6), `FX` the F express (diamond F), `FS` the Franklin Av shuttle |
| `direction` | string | `N` or `S`: NYCT's railroad direction (the stop ID suffix), not a compass direction. On the Manhattan Bridge `S` heads to Brooklyn; on the Williamsburg Bridge J/Z `S` and M `N` head to Manhattan. Show `destination` and `course` instead |
| `destination` | string | Name of the trip's last stop, e.g. `Coney Island-Stillwell Av`. Omitted when unknown |
| `stretch` | string | The named above-ground stretch the train is on: `manhattan-bridge`, `williamsburg-bridge`, `culver-viaduct` or `franklin-av` (see [Levels](#levels)). Omitted when `underground` |
| `underground` | boolean | Always present. `true` for every train that is not on a stretch: in a tunnel, or standing at a station below ground |
| `altitudeEstimated` | boolean | Always present. `true` when the target's `altitude` follows rule-based figures (a default station depth, an estimated river tube low point, the Franklin Av shuttle's estimated heights), so the app can say "about"; `false` when every figure it follows is published or measured. It is decided per piece of track between two stations (and per stretch), by the nearest figures at its ends: a piece with a published station at one end and an estimated one at the other is `true`. In practice, today: `true` for every underground train (no piece of underground track has published figures at both ends) and on `franklin-av`; `false` only on the lidar-measured stretches (`manhattan-bridge`, `williamsburg-bridge`, `culver-viaduct`). Older apps ignore it |

#### Estimate

MTA's GTFS-realtime subway feeds report, per trip, the station the train last stood at (`VehiclePosition`,
`STOPPED_AT` with a time) and predicted times at the stations ahead (`TripUpdate`). While a train stands at a station
NYCT refreshes the report's time about every 30 s; once it leaves, the station drops out of the trip update and the
time stops changing, so it's about the departure time.

- **Between stations:** reported at a station no longer in the trip update. Placed along the track from that station
  to the next listed one in proportion to time, from the report's time (departure) to the predicted arrival.
  `speed` is the track length over that time.
- **In transit:** NYCT reports many running trains as `IN_TRANSIT_TO` (or `INCOMING_AT`) the next station instead,
  the vehicle's `stopId`, which the trip update lists with its predicted arrival. The station the train left isn't
  anywhere in the feed, so the extract has it: for each station, the stations trains come from into it and the
  scheduled run time (median of the static schedule's arrival there less departure from the one before), keyed by
  stopping pattern (the static shape ID ends the realtime trip ID, e.g. `101450_F..S54R`) and else by route and
  direction. The previous station is the most frequent one, if it carries at least 75% of the trips (`MIN_APPROACH_SHARE`),
  and the extract has track from it; otherwise the train isn't placed. The train left it at the predicted arrival
  less the scheduled run time, but no later than the report's time (a train in transit has left), and is placed along
  the track in proportion to time from then to the arrival, as between stations above. So it only moves forward as
  time passes, and never reaches the station before its predicted arrival. Unlike a train reported at a station,
  it is anchored to a prediction, so when NYCT revises the arrival the train moves with it. After the arrival, as
  below. A target station the trip update doesn't list isn't placed either.
- **At a station:** reported at a station still listed. It stays there, `speed` 0, until a newer feed says it left.
  NYCT can't predict departures either (for a train being held it keeps predicting "leaves now").
- **Later stops:** between polls, a train whose predicted arrival has passed waits there for 30 s (at most a third of
  the next run) and then moves on along the next run the same way.
- Only positions on the extract's track are sent (inside the area, or on a stretch), at stations and between them,
  above ground and underground. Not placed at
  all: trips that haven't left their terminal (reported `IN_TRANSIT_TO` with a future time), trains in transit whose
  previous station is unknown or ambiguous, reports older than 20 minutes, feeds older than 3 minutes, and station
  pairs the static schedule never runs (unusual reroutes): their track isn't in the extract.

Known weaknesses: positions are linear in time, but trains run fast across a bridge and then wait at junctions
(DeKalb Av) or behind other trains, and the predictions slide when that happens: expect errors of a few hundred meters
on the 3-4.5 km runs over the Manhattan Bridge. A train that leaves a station shows there until the next poll (up to
about a minute), then jumps ahead to where it is. A train in transit sits where its predicted arrival and the
schedule's run time put it: the schedule's median run time (all day, all service days) isn't this train's, and when
NYCT revises the arrival it jumps by the revision (30 s sooner, 30 s of track further on). The track comes from MTA's GTFS shapes, which draw long straight
runs (the whole Manhattan Bridge) as single chords: fine for a straight bridge, a few meters off on curves. Tunnels
are rougher still: the shapes are all there is, and underground the height is a model, not a measurement (see [Levels](#levels)).

#### Levels

The relay's static extract (`src/subway-data.ts`, generated by `npm run subway-extract` from MTA's static GTFS) holds,
for each pair of consecutive stations on any route's scheduled trips whose track runs inside the area or on a
stretch, the track length between the stations and the track's geometry, in parts: underground track clipped to the
area, the stretches whole (a viaduct or bridge is seen from inside the area, a tunnel isn't). A segment has several
parts when its track leaves the area and comes back, or changes level. Each part is on a named above-ground stretch
or underground:

- **Above ground:** the stretches below. Tunnel portals are hand-picked (OpenStreetMap was looked at for each stretch's
  two ends only, no tags imported); heights are hand-made control points (`STRETCHES` in
  `src/tools/subway-extract.ts`), linear in between: measured from airborne lidar for the bridges and the viaduct,
  about 1 m; for `franklin-av` estimated from USGS ground elevation plus a rule for the embankment, +-3 m
  (`altitudeEstimated` is `true` there; on the three measured stretches it is `false`).
- **Underground:** all other track in the area, at a modelled rail altitude (`src/tools/depth.ts`, baked into
  `src/subway-data.ts` by `npm run subway-extract`; the relay itself does no lookups):
  - Each station's rail altitude is the ground elevation there (USGS 3DEP bare earth via the Elevation Point Query
    Service, kept in `relay/data/elevation.json`) less its depth below the street: published for Clark St (24 m),
    High St (21 m), York St (24 m) and South Ferry (1 train, 15 m, the planned depth); 6 m for every other station, a cut-and-cover
    estimate.
  - A river tube is lowest in the middle of the water: -27.9 m (28.5 m below mean high water) for the Joralemon St
    tube (4 5, published) and -26.4 m for the Cranberry St tube (A C, published, 27 m below "the surface"); the same
    -27.9 m for the others (Rutgers St F, Clark St 2 3, Montague St R, the L's Canarsie tube), an estimate. A low
    point is raised where 4% from the stations couldn't reach it.
  - Between those control points the rail is linear in altitude, never above the ground less 3 m, and never steeper
    than 4%.
  - At a portal the rail ramps at up to 4% from the stretch's end height to the tunnel altitude, so `altitude` has no
    jump anywhere along a segment. Where a portal is too close to a station for 4% the track runs straight between them,
    steeper: Grand St to the Chrystie St portal (4.0%) and Delancey St-Essex St to the Williamsburg Bridge portal (4.2%).
  - Accuracy: about +-2 m where the figures are published, +-3 m at an ordinary station (the 6 m is a rule: some are
    deeper, two-level stations much deeper), +-5 m or worse in the river tubes and wherever the ground has changed
    since the lidar.

  The geometry is MTA's shapes, simplified to 2 m.

| `stretch` | Routes | Track in the area |
| --- | --- | --- |
| `manhattan-bridge` | B D N Q | From the Chrystie St (B D) and Canal St (N Q) tunnels over the bridge to the Flatbush Av Extension tunnel |
| `williamsburg-bridge` | J M Z | From the Delancey St tunnel (Essex St) over the bridge and along the Broadway el past Marcy Av to the area's edge |
| `culver-viaduct` | F G | From the portal south of Carroll St up the viaduct over the Gowanus Canal (its crest at Smith-9 Sts) and past 4 Av-9 St, back into the tunnel. Mostly just south of the area's edge, kept whole |
| `franklin-av` | FS | The Franklin Av shuttle from its terminal at Franklin Av (a raised station, no tunnel) south along the embankment and street bridges to Park Pl, 25 m past the area's edge, kept whole. About 670 m; heights estimated |

### Sources

The relay runs the sources named in its `SOURCES` setting (relay/README.md). Each publishes targets in the shape above.

| Source | Kinds | Area | Notes |
| --- | --- | --- | --- |
| `aisstream` | `vessel` | `BOUNDING_BOXES` (relay/src/config.ts) | aisstream.io's free AIS feed. [AIS](#ais-the-aisstream-source-both-endpoints) below |
| `mta-subway` | `train` | `BOUNDING_BOXES`, above and below ground | MTA's GTFS-realtime subway feeds (all seven NYCT feeds with routes in the area), polled every 30 s, no key. [Trains](#trains) |

## /v1/vessels

AIS vessels only, from the `aisstream` source (an empty snapshot and nothing more when it's off).

### Messages (relay -> app)

On connect, exactly one snapshot, then live updates:

```json
{"type":"snapshot","vessels":[VesselUpdate, ...]}
{"type":"update","vessel":VesselUpdate}
```

`snapshot.vessels` holds the merged state of every vessel seen in the last 10 minutes, sorted by `mmsi`.
Each `update` is one normalized upstream message (a position report or static data), not merged state.

### VesselUpdate

| Key | Type | Notes |
| --- | --- | --- |
| `mmsi` | integer | Always present |
| `name` | string | Static data only. Trimmed of AIS `@` padding and spaces; omitted if empty |
| `shipType` | integer | Static data only. AIS type code 1-99; omitted when 0 (not available) |
| `lat`, `lon` | number | Always present, WGS84 degrees |
| `sog` | number | Knots. Omitted when 102.3 (not available) |
| `cog` | number | Degrees. Omitted when >= 360 (not available) |
| `heading` | number | Degrees. Omitted when 511 (not available) |
| `timestamp` | string | ISO 8601 UTC with milliseconds, e.g. `2026-11-10T14:00:05.000Z` |

Unknown keys are omitted, never `null`.

## AIS (the `aisstream` source, both endpoints)

### Normalization

- Position report: `lat`/`lon`/`sog`/`cog`/`heading` from `Message.PositionReport`, and for `/v2/targets` its
  `NavigationalStatus`.
- Static data: `name`/`shipType` from `Message.ShipStaticData`, and for `/v2/targets` its `ImoNumber`, `CallSign`,
  `Destination`, `Eta` (`Month`, `Day`, `Hour`, `Minute`), `Dimension` (`A`, `B`, `C`, `D`, meters) and
  `MaximumStaticDraught` (meters), each checked as in the [Vessels](#vessels) table; `lat`/`lon` from `MetaData`
  (`latitude`/`longitude`, either casing). If `MetaData` has no usable position, the relay uses the vessel's
  last known position; if it has none yet, the static update is held and emitted right after the vessel's
  first position report, with that report's position.
- `timestamp` from `MetaData.time_utc` (aisstream format `2026-11-10 14:00:05.123456789 +0000 UTC`),
  falling back to the relay's receive time if missing or unparseable, or more than 60 s after the receive time (a bad
  clock or frame: under the merge rules below a far-future time would freeze the vessel). So a vessel's `timestamp` is
  never more than 60 s ahead of the relay's clock.
- Positions with latitude outside [-90, 90] or longitude outside [-180, 180] (AIS 91/181 = not available) are dropped,
  and so are positions outside `BOUNDING_BOXES` (relay/src/config.ts; edges count as inside): aisstream is asked for
  the boxes only, but a bad frame can carry any position. A static message whose `MetaData` position is outside them
  uses the vessel's last known position, as for no position. No boat outside the boxes is ever sent.
- Other message types (e.g. `SubscriptionConfirmation`) and malformed JSON are ignored.

### Merge rules (relay snapshot and app `VesselRegistry` must agree)

Per MMSI:
- `name`, `shipType`: replaced when the update has them.
- `lat`, `lon`, `sog`, `cog`, `heading`: replaced (each only when present in the update) if the update's
  `timestamp` is not older than the vessel's last position timestamp; an older update never moves a vessel.
- `lastSeen` = the newest `timestamp` seen.
- `/v2/targets` only: `imo`, `callSign`, `destination`, `eta`, `length`, `beam`, `draught` are replaced when the update
  has them; `navStatus` comes with positions, so it follows the position rule above (replaced by a position report
  that has it, kept otherwise). A known value is never cleared because a later message omits it. They expire with the
  vessel.
- A vessel is dropped when `now - lastSeen` is more than 600 seconds.
- In a snapshot, each vessel is one VesselUpdate with every known field and `timestamp` = `lastSeen`.

## Fixtures

- `relay/fixtures/subway/<time>-<feed>.pb`: synthetic NYCT-shaped GTFS-realtime feeds (`numbered` for `nyct/gtfs`,
  `ace`, `bdfm`, `g`, `jz`, `l`, `nqrw`), three rounds 30 s apart starting 2026-11-10 14:11:00 UTC. Nothing in them is
  recorded: `src/tools/subway-scenario.ts` lists about a hundred invented trips (trip IDs in NYCT's format, times,
  where each train last reported) and `src/tools/synthetic-gtfsrt.ts` encodes them, NYCT's extensions (field 1001)
  included. Only stop IDs, route IDs and shape IDs are real, the facts `subway-data.ts` already ships. Each trip says
  what the estimator should make of it (underground, on a named stretch, or not placed) and why: trains standing at
  a station, between stations, in transit and incoming, on the Manhattan and Williamsburg Bridges, the Culver
  Viaduct and the Franklin Av shuttle, in the East River tunnel, moving between underground and a stretch from
  round to round, and the odd ones (no vehicle report, a report in the future or over 20 minutes old, no route, trip
  or stop ID, no direction letter, stops outside the extract, a route with no track, a deleted entity, an orphan
  vehicle, a feed too old to use for one round). A relay test derives its counts and the trains' places from the
  scenario, not from the estimator's output.
- `relay/fixtures/subway/<time>-targets.json`: the `/v2/targets` snapshot of each round's trains, estimated at its
  newest feed time. Generated by `npm run fixtures`; a relay test fails if they, or the `.pb` files, drift from the
  scenario.

- `relay/fixtures/*.jsonl`: raw aisstream frames, one JSON message per line. `synthetic-sample.jsonl` is
  hand-written in aisstream's format (invented boats, MMSIs 3670000xx); no recording of aisstream's data is checked in.
  `synthetic-static.jsonl` is hand-written too: boats with every vessel detail, with AIS sentinel and invalid values,
  with dirty and over-long text, and with later messages that omit fields. `npm run fixtures` plays it through the
  relay's hub and aisstream source into `relay-v2-details-stream.json` (the empty snapshot, then every update) and
  `relay-v2-details-snapshot.json` (the state at `2026-11-10T14:12:00.000Z`), next to the other two; `/v1` never
  plays it, so the `/v1` updates and snapshot stay as they were.
- `Packages/BoatCore/Tests/BoatCoreTests/Fixtures/relay-v2-stream.json` and `relay-v2-snapshot.json` are what a
  `/v2/targets` client gets, generated by `npm run fixtures` through the relay's own hub and sources on a fixed clock
  (so the output is deterministic). The stream is a JSON array of messages: the snapshot on connect (the first subway
  round's trains), then the updates and removes while `synthetic-sample.jsonl` plays and the later subway rounds are
  published between its messages, ending with the hub's sweep at `2026-11-10T14:12:00.000Z`; the snapshot is what a
  client connecting then gets. (The subway rounds are timed at the end of the AIS sample's window, the last at the
  sweep: the hub's clock follows the AIS sample, and each round's trains expire 30 s after their own round, so none
  expires during the stream.) A relay test fails
  if they drift from the generator's output; the Swift tests feed the stream through `TargetRegistry` and expect the
  same snapshot.
