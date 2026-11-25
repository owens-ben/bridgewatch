import { feedName, SUBWAY_FEED_ROUTES, SUBWAY_FEEDS } from '../subway-feed';
import { encodeFeed, type FeedSpec, type StopSpec, type TripSpec, type VehicleStatus } from './synthetic-gtfsrt';

/**
 * The synthetic subway feeds behind relay/fixtures/subway: three rounds of NYCT-shaped GTFS-realtime feeds, 30 s
 * apart, built from the scenario below by `npm run fixtures`. Stop IDs, route IDs and shape IDs are facts the relay
 * already ships (subway-data.ts); trip IDs, train IDs, times and where each train is are invented.
 *
 * Every trip says what the estimator should make of it (`expect`) and why, so the scenario is the spec: the tests
 * (subway-fixtures.test.ts) derive their counts and positions from it, not from whatever the estimator prints.
 *
 * Times are seconds relative to ROUND_0 (the first round's clock). A trip's times stay as written in later rounds, so
 * a train in motion advances as the clock does; `hold` shifts them with the clock instead (a train standing at a
 * station, whose report is refreshed every round). `revise` changes a trip from a round on.
 */

export const ROUND_0 = Date.parse('2026-11-10T14:11:00Z') / 1000;
export const ROUND_SECONDS = 30;
export const ROUND_COUNT = 3;

/** Seconds a feed's header is older than the round's clock, per round (a feed is refreshed at its own moment). */
export const HEADER_AGE: Record<string, number[]> = {
  ace: [0, 0, 0],
  bdfm: [0, 0, 0],
  g: [0, 0, 0],
  // jz is 200 s old in round 1: past MAX_FEED_AGE_SECONDS, so its trains vanish for a round and come back.
  jz: [1, 200, 1],
  l: [14, 14, 4],
  nqrw: [10, 0, 0],
  numbered: [4, 4, 1],
};

/** The feed a round's header timestamp must be skipped for (too old), by round. */
export const STALE_FEEDS: Record<number, string[]> = { 1: ['jz'] };

/** What the estimator should do with a trip: place it underground, on a named stretch, or not at all. */
export type Where = 'ug' | 'none' | 'manhattan-bridge' | 'williamsburg-bridge' | 'culver-viaduct' | 'franklin-av';

export interface Report {
  stop?: string;
  status?: VehicleStatus;
  /** Seconds relative to ROUND_0. */
  ts?: number;
}

export interface ScenarioTrip {
  feed: string;
  route?: string;
  /** Undefined leaves the trip ID out. */
  id?: string;
  /** Where the train last reported: its stop, its status and when. `null`: no vehicle entity at all. */
  at: [stop: string, status: VehicleStatus, ts: number] | Report | null;
  /** `STOP@arrival/departure`, space separated: `-` for no event, `~` for an event without a time. */
  stops: string;
  expect: Where | Where[];
  /** Why: one line, read by people. */
  why: string;
  hold?: boolean;
  /** First and last round the trip is in its feed. */
  from?: number;
  until?: number;
  revise?: Record<number, { at?: ScenarioTrip['at']; stops?: string }>;
  /** The trip's train is moving between stations and the test checks its place along the track from the timeline. */
  track?: boolean;
  /** Quirks of the encoding. */
  odd?: { deleted?: boolean; noTripUpdate?: boolean; noRoute?: boolean; vehicleNoTripId?: boolean; noStopIdOnVehicle?: boolean; noVehicleTime?: boolean };
  /** The stops without a stop ID (an odd update the parser must skip), by index. */
  noStopId?: number[];
  /** TripDescriptor.start_time; the default is an invented clock time (none for the L feed, which doesn't send one). */
  startTime?: string;
}

const t = (trip: ScenarioTrip): ScenarioTrip => trip;

/**
 * Where each train is, feed by feed. Heights, distances and run times come from subway-data.ts; the comments give the
 * intent. "Left A" means the train's last report is A (stopped there at that time) and A is no longer in its stops.
 */
export const SCENARIO: ScenarioTrip[] = [
  // ---------------------------------------------------------------------------------------------------- A, C, E
  t({ feed: 'ace', route: 'A', id: '117260_A..N55R', at: ['A41N', 'stopped', -11], stops: 'A41N@-11 A40N@88 A38N@152 A36N@226 A34N@301 A02N@1500', hold: true, expect: 'ug', why: 'standing at a station that is still listed' }),
  t({ feed: 'ace', route: 'A', id: '117640_A..S58R', at: ['A40S', 'stopped', -21], stops: 'A41S@70 A42S@160 A46S@250 A48S@340 A51S@430 H11S@1300', expect: 'ug', track: true, why: 'left Hoyt-Schermerhorn 21 s ago, due at Jay St in 70 s' }),
  t({ feed: 'ace', route: 'C', id: '118120_C..N04R', at: ['A40N', 'stopped', -79], stops: 'A38N@51 A36N@141 A34N@231 A33N@321 A32N@411 A09N@1500', expect: 'ug', track: true, why: 'left a station 79 s ago; the next listed one is the station after it' }),
  t({ feed: 'ace', route: 'E', id: '118940_E..S69R', at: ['A33S', 'stopped', -9], stops: 'A33S@-9 A34S@72 E01S@380', hold: true, expect: 'ug', why: 'a three-stop trip (a short run), standing at its first stop' }),
  t({ feed: 'ace', route: 'E', id: '119370_E..N72R', at: ['E01N', 'stopped', -48], stops: 'A34N@115 A33N@265 A32N@330 A31N@395 A30N@460 G05N@1700', expect: 'ug', track: true, why: 'left the Hudson-side terminal 48 s ago: the segment to Chambers St has track in the area' }),
  t({ feed: 'ace', route: 'A', id: '119820_A..S', at: ['A32S', 'stopped', -24], stops: 'A32S@-24 A34S@51 A36S@141 A38S@231', hold: true, expect: 'ug', why: 'a trip ID with no shape suffix (looked up by route and direction); standing' }),
  t({ feed: 'ace', route: 'C', id: '120250_C..S04R', at: ['A42S', 'transit', -25], stops: 'A42S@40 A43S@130 A44S@190 A45S@250 A46S@310 A55S@900', expect: 'ug', track: true, why: 'reported on its way to Hoyt-Schermerhorn: placed from the schedule\'s approach (shape lookup)' }),
  t({ feed: 'ace', route: 'E', id: '120610_E..N72R', at: ['A32N', 'incoming', -6], stops: 'A32N@80 A31N@140 A30N@200 A28N@260 A27N@320 G05N@1500', expect: 'ug', track: true, why: 'INCOMING_AT (status 0) instead of IN_TRANSIT_TO: handled alike' }),
  t({ feed: 'ace', route: 'A', id: '121040_A..N20X002', at: ['A41N', 'stopped', -16], stops: 'A41N@-16 A40N@68 A38N@132 A36N@206 A34N@281 A32N@348 A02N@1480', hold: true, expect: 'ug', why: 'an express trip ID (X and a counter in the shape)' }),
  t({ feed: 'ace', route: 'A', id: '121390_A..N55R', at: ['A55N', 'stopped', -14], stops: 'A55N@-14 A51N@208 A48N@300 A46N@390 A42N@480 A41N@560 A02N@1700', hold: true, expect: 'none', why: 'standing at a station outside the extract' }),
  t({ feed: 'ace', route: 'E', id: '121740_E..S69R', at: ['F07S', 'stopped', -19], stops: 'F06S@-24 F07S@-19 G08S@60 G14S@150 G21S@240 F09S@330 E01S@900', hold: true, expect: 'none', why: 'stale stops listed before the reported one, all outside the extract' }),
  t({ feed: 'ace', route: 'C', id: '122110_C..N04R', at: ['A44N', 'stopped', -19], stops: 'A44N@-19 A43N@51 A42N@111 A41N@171', hold: true, odd: { deleted: true }, expect: 'none', why: 'the trip update entity is marked deleted: dropped by the decoder' }),
  t({ feed: 'ace', route: 'C', id: '122480_C..N04R', at: ['A43N', 'stopped', -12], stops: 'A43N@-12 A42N@48 A41N@108', hold: true, odd: { noTripUpdate: true }, expect: 'none', why: 'a vehicle position with no trip update at all (an orphan)' }),
  t({ feed: 'ace', route: 'E', id: '122830_E..N72R', at: ['A34N', 'stopped', -13], stops: 'A34N@-13 A33N@47 A32N@107', hold: true, odd: { vehicleNoTripId: true }, expect: 'none', why: 'the vehicle position carries no trip ID: nothing ties it to the trip update' }),

  // -------------------------------------------------------------------------------- B, D, F, M and the shuttle
  t({ feed: 'bdfm', route: 'B', id: '117330_B..N66R', at: ['R30N', 'stopped', -60], stops: 'D22N@205 D21N@345 D20N@415 D17N@485 D16N@555 D13N@1100', expect: ['ug', 'manhattan-bridge', 'manhattan-bridge'], track: true, why: 'leaving DeKalb Av for the Manhattan Bridge: under the street in round 0, on the bridge from round 1, 45% of the way over it in the last, at the Brooklyn approach where ElevatedSightlineTests needs a train (its sightline result only holds within a few meters of there)' }),
  t({ feed: 'bdfm', route: 'B', id: '117720_B..N66R', at: ['R30N', 'stopped', -150], stops: 'D22N@110 D21N@270 D20N@340 D17N@410 D16N@480 D13N@1000', expect: 'manhattan-bridge', track: true, why: 'on the Manhattan Bridge for all three rounds, northbound' }),
  t({ feed: 'bdfm', route: 'D', id: '118060_D..S07R', at: ['D22S', 'stopped', -50], stops: 'R31S@330 R36S@690 B12S@750 B13S@810 B14S@870 D43S@1900', expect: 'manhattan-bridge', track: true, why: 'on the Manhattan Bridge, southbound (the other direction of the same stretch)' }),
  t({ feed: 'bdfm', route: 'D', id: '118410_D..S07R', at: ['D22S', 'stopped', -380], stops: 'R31S@190 R36S@550 B12S@610 B13S@670 B14S@730 D43S@1700', expect: 'ug', track: true, why: 'past the bridge, in the tunnel to Canal St' }),
  t({ feed: 'bdfm', route: 'D', id: '118770_D..N07R', at: ['D22N', 'stopped', -40], stops: 'D21N@50 D20N@200 D17N@270 D16N@340 D15N@410 D01N@1400', expect: 'ug', track: true, why: 'left Grand St for the next station' }),
  t({ feed: 'bdfm', route: 'D', id: '119130_D..S08X007', at: ['D21S', 'stopped', -55], stops: 'D22S@50 R31S@680 R36S@740 B12S@800 B13S@860 B21S@1500', expect: 'ug', track: true, why: 'an express trip ID' }),
  t({ feed: 'bdfm', route: 'F', id: '119450_F..S54R', at: ['F23S', 'stopped', -16], stops: 'F22S@-20 F23S@-16 F24S@75 F25S@165 F26S@255 F27S@345 D43S@1500', hold: true, expect: 'culver-viaduct', why: 'standing on the Culver Viaduct; a stale stop (F22S) is listed before the reported one' }),
  t({ feed: 'bdfm', route: 'F', id: '119830_F..N54R', at: ['F22N', 'stopped', -15], stops: 'F22N@-15 F21N@54 F20N@144 A41N@234 F18N@324 F16N@414 F01N@1600', hold: true, expect: 'culver-viaduct', why: 'standing on the viaduct, northbound' }),
  t({ feed: 'bdfm', route: 'F', id: '120160_F..S54R', at: ['F16S', 'stopped', -15], stops: 'F16S@-15 F18S@95 A41S@220 F20S@310 F21S@400 F22S@490 D43S@1800', hold: true, expect: 'ug', why: 'standing at East Broadway, at the mouth of the East River tunnel' }),
  t({ feed: 'bdfm', route: 'F', id: '120520_F..N54R', at: ['F18N', 'stopped', -30], stops: 'F16N@150 F15N@220 F14N@290 D21N@360 D20N@430 F01N@1500', expect: 'ug', track: true, why: 'in the East River tunnel, northbound: left York St 30 s ago, at the tube\'s low point in the last round' }),
  t({ feed: 'bdfm', route: 'F', id: '120880_F..S54R', at: ['A41S', 'stopped', -22], stops: 'A41S@-22 F20S@50 F21S@140 F22S@230 F23S@320 F24S@410 D43S@1700', hold: true, expect: 'ug', why: 'standing at Jay St' }),
  t({ feed: 'bdfm', route: 'F', id: '121210_F..N20R', at: ['D43N', 'transit', 2683], stops: 'D43N@2683/2683 D42N@2773/2773 F39N@2863 F38N@2953 F36N@3043 F01N@4300', expect: 'none', why: 'not started yet: reported IN_TRANSIT_TO with a time 45 minutes ahead' }),
  t({ feed: 'bdfm', route: 'F', id: '121570_F..S54R', at: ['A41S', 'stopped', -1500], stops: 'A41S@-1500 F20S@-1440 F21S@-1380', expect: 'none', why: 'its last report is 25 minutes old (MAX_REPORT_AGE_SECONDS is 20)' }),
  t({ feed: 'bdfm', route: 'B', id: '121940_B..S66R', at: ['A21S', 'stopped', -15], stops: 'A21S@-15 A22S@50 A24S@110 D14S@170 D15S@230 D40S@900', hold: true, expect: 'none', why: 'reported at a station outside the extract' }),
  t({ feed: 'bdfm', route: 'M', id: '122250_M..S24R', at: ['M18S', 'stopped', -130], stops: 'M16S@160 M14S@220 M13S@280 M12S@340 M11S@400 M01S@1200', expect: 'williamsburg-bridge', track: true, why: 'on the Williamsburg Bridge, heading for Marcy Av' }),
  t({ feed: 'bdfm', route: 'M', id: '122660_M..S24R', at: ['D21S', 'stopped', -17], stops: 'D21S@-17 M18S@90 M16S@290 M14S@350 M13S@410 M12S@470 M01S@1300', hold: true, expect: 'ug', why: 'standing at Grand St before the bridge' }),
  t({ feed: 'bdfm', route: 'M', id: '123030_M..N24R', at: ['D21N', 'stopped', -34], stops: 'D20N@50 D19N@140 D18N@230 D17N@320 D16N@410 G08N@1500', expect: 'ug', track: true, why: 'left a station 34 s ago' }),
  t({ feed: 'bdfm', route: 'FS', id: '123380_FS.N01R', at: ['S03N', 'stopped', -20], stops: 'S01N@100', expect: 'franklin-av', track: true, why: 'the Franklin Av shuttle, one stop left: on its embankment all three rounds' }),
  t({ feed: 'bdfm', route: 'FS', id: '123750_FS.N01R', at: ['S03N', 'stopped', -20], stops: 'S01N@20', expect: ['franklin-av', 'franklin-av', 'none'], track: true, why: 'the shuttle arrives at its terminal before round 1, stands there its dwell, and is gone by round 2' }),
  t({ feed: 'bdfm', route: 'FS', id: '124090_FS.N01R', at: ['S03N', 'stopped', -15], stops: 'S01N@105', from: 2, expect: ['none', 'none', 'franklin-av'], track: true, why: 'a shuttle that first shows up in round 2' }),
  t({ feed: 'bdfm', route: 'D', id: '124460_D..N07R', at: ['D22N', 'stopped', -35], stops: 'D21N@55 D20N@205 D17N@275', until: 1, expect: ['ug', 'ug', 'none'], track: true, why: 'a trip that is gone from its feed after round 1' }),

  // ------------------------------------------------------------------------------------------------------- G
  t({ feed: 'g', route: 'G', id: '117410_G..S14R', at: ['F21S', 'stopped', -40], stops: 'F22S@65 F23S@185 F24S@305 F25S@425 F26S@545 F27S@665', expect: 'culver-viaduct', track: true, why: 'on the Culver Viaduct, heading for 4 Av-9 St: still on it in round 2' }),
  t({ feed: 'g', route: 'G', id: '117790_G..N14R', at: ['A42N', 'stopped', -14], stops: 'A42N@-14 G36N@56 G35N@146 G34N@236 G33N@296 G32N@386 G22N@1100', hold: true, expect: 'ug', why: 'standing at Hoyt-Schermerhorn' }),
  t({ feed: 'g', route: 'G', id: '118130_G..S14R', at: ['G36S', 'stopped', -34], stops: 'A42S@59 F20S@194 F21S@284 F22S@374 F23S@464 F27S@900', expect: 'ug', track: true, why: 'left Bedford-Nostrand 34 s ago' }),
  t({ feed: 'g', route: 'G', id: '118500_G..N14R', at: ['F22N', 'stopped', -30], stops: 'F21N@100 F20N@190 A42N@280 G36N@370 G35N@460 G22N@1200', expect: 'culver-viaduct', track: true, why: 'northbound on the viaduct (the segment is stored the other way round)' }),
  t({ feed: 'g', route: 'G', id: '118870_G..S14R', at: ['G24S', 'stopped', -74], stops: 'G26S@80 G28S@170 G29S@260 G30S@350 G31S@440 F27S@1000', expect: 'none', why: 'between two stations outside the extract' }),
  t({ feed: 'g', route: 'G', id: '119210_G..S14R', at: ['G22S', 'transit', 794], stops: 'G22S@794/794 G24S@854 G26S@944', expect: 'none', why: 'not started yet (future report)' }),
  t({ feed: 'g', route: 'G', id: '119590_G..N14R', at: ['G24N', 'stopped', -20], stops: 'G24N@-20 G22N@200', hold: true, expect: 'none', why: 'a two-stop trip outside the extract' }),

  // ------------------------------------------------------------------------------------------------------ J, Z
  t({ feed: 'jz', route: 'J', id: '117470_J..S12R', at: ['M20S', 'stopped', -13], stops: 'M20S@-13 M21S@70 M22S@160 M23S@250', hold: true, expect: 'ug', why: 'a four-stop trip, standing' }),
  t({ feed: 'jz', route: 'J', id: '117860_J..S12R', at: ['M16S', 'stopped', -13], stops: 'M16S@-13 M18S@352 M19S@440 M20S@530 M21S@620 M22S@710 M23S@800', hold: true, expect: 'williamsburg-bridge', why: 'standing at Marcy Av, on the bridge\'s Brooklyn end' }),
  t({ feed: 'jz', route: 'J', id: '118220_J..N41R', at: ['J21N', 'stopped', -13], stops: 'J21N@-13 J20N@55 J19N@145 J17N@235 J16N@325 J15N@415 G05N@1200', hold: true, expect: 'none', why: 'outside the extract' }),
  t({ feed: 'jz', route: 'J', id: '118580_J..N41R', at: ['M19N', 'stopped', -18], stops: 'M19N@-18 M18N@52 M16N@140 M14N@230 M13N@320', hold: true, expect: 'ug', why: 'standing at Essex St' }),
  t({ feed: 'jz', route: 'J', id: '118950_J..S12R', at: ['G05S', 'transit', 645], stops: 'G05S@645/645 G06S@705 J12S@795', expect: 'none', why: 'not started yet (future report)' }),
  t({ feed: 'jz', route: 'Z', id: '119330_J..S12R', at: ['M16N', 'stopped', -80], stops: 'M18N@180 M19N@270 M20N@360 M21N@450', expect: 'williamsburg-bridge', track: true, why: 'a Z (it runs under J trip IDs) on the bridge, heading for Manhattan' }),

  // ------------------------------------------------------------------------------------------------------- L
  t({ feed: 'l', route: 'L', id: '117520_L..N', at: ['L06N', 'stopped', -29], stops: 'L06N@9/24 L05N@69/84 L03N@159/189 L02N@249/279 L01N@399', hold: true, expect: 'ug', why: 'standing, though its first stop is predicted ahead; the L feed\'s own fields (delay, uncertainty, stop sequence, schedule relationship)' }),
  t({ feed: 'l', route: 'L', id: '117930_L..N', at: ['L06N', 'transit', -14], stops: 'L06N@121/136 L05N@166/196 L03N@286/316 L02N@376/406 L01N@526', expect: 'ug', track: true, why: 'reported on its way to a station, in transit' }),
  t({ feed: 'l', route: 'L', id: '118300_L..S', at: ['L05S', 'stopped', -30], stops: 'L05S@-7/8 L06S@58/73 L08S@253/283 L10S@373/403 L11S@433/463 L12S@523/553 L29S@1900', hold: true, expect: 'ug', why: 'standing at a station whose predicted arrival is already past' }),
  t({ feed: 'l', route: 'L', id: '118660_L..S', at: ['L03S', 'transit', -14], stops: 'L05S@90/105 L06S@150/165 L08S@270/300', expect: 'none', why: 'in transit to a station that has no predicted arrival in the trip update' }),
  t({ feed: 'l', route: 'L', id: '119020_L..N', at: null, stops: 'L29N@-/1513 L28N@1573/1603 L27N@1663/1693 L26N@1753/1783', expect: 'none', why: 'no vehicle entity (a trip not assigned yet); stops with a departure only' }),
  t({ feed: 'l', route: 'L', id: '119390_L..N', at: ['L06N', 'stopped', -20], stops: 'L06N@~ L05N@~ L03N@~', hold: true, expect: 'none', why: 'stop time events that carry no time at all' }),

  // ------------------------------------------------------------------------------------- 1 to 6, 7 and the shuttle
  t({ feed: 'numbered', route: '1', id: '117570_1..S15R', at: ['135S', 'stopped', -37], stops: '135S@-7 136S@53 137S@113 138S@173 139S@263 142S@500', hold: true, expect: 'ug', why: 'standing at Canal St; its stop is listed with a time just ahead of the report' }),
  t({ feed: 'numbered', route: '1', id: '117950_1..N15R', at: ['135N', 'transit', -2], stops: '135N@43 134N@133 133N@223 132N@313 131N@373 101N@2500', expect: 'ug', track: true, why: 'in transit to Canal St' }),
  t({ feed: 'numbered', route: '2', id: '118310_2..S17R', at: ['237S', 'stopped', -12], stops: '237S@18 238S@138 239S@228 241S@408 242S@498 247S@1000', hold: true, expect: 'ug', why: 'standing' }),
  t({ feed: 'numbered', route: '2', id: '118690_2..S17R', at: ['231S', 'transit', -6], stops: '231S@257 232S@317 233S@377 234S@437 235S@497 247S@900', expect: 'ug', track: true, why: 'in transit' }),
  t({ feed: 'numbered', route: '2', id: '119050_2..N14R', at: ['137N', 'transit', -6], stops: '137N@54 132N@324 128N@384 127N@444 123N@504 201N@1500', expect: 'ug', track: true, why: 'in transit, with a long run to the next stop' }),
  t({ feed: 'numbered', route: '2', id: '119420_2..N14R', at: ['232N', 'incoming', -3], stops: '232N@37 231N@127 230N@217 229N@307 228N@397 201N@1700', expect: 'ug', track: true, why: 'INCOMING_AT' }),
  t({ feed: 'numbered', route: '3', id: '119780_3..S06R', at: ['234S', 'stopped', -32], stops: '234S@-2 235S@88/118 236S@208 237S@298 238S@388 257S@1400', hold: true, expect: 'ug', why: 'standing; a stop with a dwell (departure later than arrival)' }),
  t({ feed: 'numbered', route: '3', id: '120150_3..S06R', at: ['228S', 'stopped', -1], stops: '228S@29 229S@149 230S@239 231S@329 232S@419 257S@1500', hold: true, expect: 'ug', why: 'standing' }),
  t({ feed: 'numbered', route: '3', id: '120510_3..N01R', at: ['230N', 'stopped', -34], stops: '230N@-4 229N@56 228N@146 137N@236 132N@326 301N@1700', hold: true, expect: 'ug', why: 'standing' }),
  t({ feed: 'numbered', route: '4', id: '120880_4..S06R', at: ['640S', 'transit', -7], stops: '640S@112/142 418S@262 419S@352 420S@442 423S@532 250S@1500', expect: 'ug', track: true, why: 'in transit, with a dwell at the first stop' }),
  t({ feed: 'numbered', route: '4', id: '121240_4..N06R', at: ['640N', 'stopped', -116], stops: '640N@-86 635N@184 631N@274 629N@364 626N@454 401N@1800', hold: true, expect: 'ug', why: 'standing for two minutes' }),
  t({ feed: 'numbered', route: '5', id: '121610_5..S38R', at: ['419S', 'transit', -2], stops: '419S@52 420S@142/-', expect: 'ug', track: true, why: 'a two-stop trip whose last stop has no departure' }),
  t({ feed: 'numbered', route: '5', id: '121990_5..N48R', at: ['419N', 'stopped', -42], stops: '419N@-12 418N@48 640N@138 635N@228 631N@318 501N@1600', hold: true, expect: 'ug', why: 'standing' }),
  t({ feed: 'numbered', route: '5', id: '122350_5..N48R', at: ['423N', 'transit', -6], stops: '423N@30 420N@330 419N@390 418N@450 640N@510 501N@1700', expect: 'ug', track: true, why: 'in transit, with a long run' }),
  t({ feed: 'numbered', route: '6', id: '122720_6..S01R', at: ['636S', 'stopped', -27], stops: '636S@3 637S@123 638S@213 639S@303 640S@393', hold: true, expect: 'ug', why: 'a five-stop trip, standing' }),
  t({ feed: 'numbered', route: '6', id: '123080_6..N01R', at: ['636N', 'stopped', -26], stops: '636N@4 635N@94 634N@184 633N@274 632N@364 601N@1500', hold: true, expect: 'ug', why: 'standing' }),
  t({ feed: 'numbered', route: '6', id: '123450_6..N01R', at: ['639N', 'stopped', -1], stops: '639N@29 638N@119 637N@209 636N@299 635N@389 601N@1500', hold: true, expect: 'ug', why: 'standing' }),
  t({ feed: 'numbered', route: '7', id: '123810_7..S', at: ['726S', 'stopped', -4099], stops: '726S@-4227', expect: 'none', why: 'a route the extract has no track for, and a report over an hour old' }),
  t({ feed: 'numbered', route: 'GS', id: '124170_GS.N01R', at: null, stops: '901N@-/1397 902N@1487/-', expect: 'none', why: 'the Grand Central shuttle: no vehicle, a first stop with a departure only, a last one with an arrival only' }),

  // ------------------------------------------------------------------------------------------------- N, Q, R, W
  t({ feed: 'nqrw', route: 'W', id: '117620_N..S72R', at: ['R24S', 'stopped', -14], stops: 'R24S@-14 R25S@51 R26S@111 R27S@171', hold: true, expect: 'ug', why: 'a W whose trip ID carries the N shape; standing' }),
  t({ feed: 'nqrw', route: 'N', id: '118000_N..N31R', at: ['R30N', 'stopped', -90], stops: 'Q01N@250 R20N@520 R17N@610 R16N@700 R15N@790 R01N@1900', expect: ['ug', 'manhattan-bridge', 'manhattan-bridge'], track: true, why: 'leaves DeKalb Av for the bridge: under the street in round 0, on the bridge from round 1' }),
  t({ feed: 'nqrw', route: 'N', id: '118360_N..S34R', at: ['Q01S', 'stopped', -19], stops: 'Q01S@-19 R31S@536 R36S@596 R41S@656 N02S@716 N03S@776 D43S@1600', hold: true, expect: 'ug', why: 'standing at Canal St' }),
  t({ feed: 'nqrw', route: 'N', id: '118720_N..N31R', at: ['R36N', 'stopped', -14], stops: 'R36N@-14 R35N@51 R34N@111 R33N@171 R32N@231 R31N@291 R01N@1500', hold: true, expect: 'none', why: 'standing at a station outside the extract' }),
  t({ feed: 'nqrw', route: 'W', id: '119090_N..N72R', at: ['R21N', 'stopped', -14], stops: 'R21N@-14 R20N@51 R19N@111 R18N@171', hold: true, expect: 'ug', why: 'standing' }),
  t({ feed: 'nqrw', route: 'Q', id: '119460_Q..S36R', at: ['D39S', 'stopped', -14], stops: 'D39S@-14 D40S@171 D41S@231 D42S@291 D43S@351', hold: true, expect: 'none', why: 'five stops, all outside the extract' }),
  t({ feed: 'nqrw', route: 'Q', id: '119830_Q..N', at: ['Q01N', 'stopped', -14], stops: 'Q01N@-14 R20N@116 R17N@206 R16N@296 R15N@386 Q05N@900', hold: true, expect: 'ug', why: 'a trip ID with no shape suffix; standing at Canal St' }),
  t({ feed: 'nqrw', route: 'Q', id: '120190_Q..N36R', at: ['Q01N', 'stopped', -31], stops: 'R20N@254 R17N@449 R16N@539 R14N@629 B08N@719 Q05N@1500', expect: 'ug', track: true, why: 'left Canal St 31 s ago on the long run to the next listed station' }),
  t({ feed: 'nqrw', route: 'Q', id: '120560_Q..N36R', at: ['R30N', 'stopped', -14], stops: 'R30N@-14 Q01N@501 R20N@600 R17N@690', hold: true, expect: 'ug', why: 'standing at DeKalb Av' }),
  t({ feed: 'nqrw', route: 'Q', id: '120930_Q..S36R', at: ['Q01S', 'stopped', -150], stops: 'R30S@250 D24S@370 D25S@430 D26S@490 D27S@550 D43S@1600', expect: 'manhattan-bridge', track: true, why: 'on the Manhattan Bridge southbound, toward DeKalb Av' }),
  t({ feed: 'nqrw', route: 'Q', id: '121290_Q..S36R', at: ['Q01S', 'stopped', -200], stops: 'R30S@120 D24S@240 D25S@300 D26S@360 D27S@420 D43S@1500', expect: ['manhattan-bridge', 'ug', 'ug'], track: true, why: 'comes off the bridge into the tunnel under Brooklyn between rounds 0 and 1' }),
  t({ feed: 'nqrw', route: 'Q', id: '121660_Q..N36R', at: ['D24N', 'stopped', -14], stops: 'D24N@-14 R30N@191 Q01N@300 R20N@400', hold: true, expect: 'ug', why: 'standing' }),
  t({ feed: 'nqrw', route: 'Q', id: '122020_Q..S36R', at: ['D25S', 'stopped', -14], stops: 'D25S@-14 D26S@51 D27S@111 D28S@171', hold: true, expect: 'ug', why: 'standing, southbound' }),
  t({ feed: 'nqrw', route: 'R', id: '122390_R..S71R', at: ['R32S', 'stopped', -14], stops: 'R32S@-14 R33S@79 R34S@139 R35S@199 R36S@259 R45S@900', hold: true, expect: 'ug', why: 'standing' }),
  t({ feed: 'nqrw', route: 'R', id: '122750_R..S71R', at: ['R28S', 'stopped', -14], stops: 'R28S@-14 R29S@63 R30S@123 R31S@183 R32S@243 R45S@900', hold: true, expect: 'ug', why: 'standing' }),
  t({ feed: 'nqrw', route: 'R', id: '123110_R..N93R', at: ['R22N', 'stopped', -14], stops: 'R22N@-14 R21N@51 R20N@111 R19N@171 R18N@231 G08N@1000', hold: true, expect: 'ug', why: 'standing' }),
  t({ feed: 'nqrw', route: 'R', id: '123480_R..N93R', at: ['R31N', 'stopped', -14], stops: 'R31N@-14 R30N@121 R29N@181 R28N@241 R65N@301 G08N@1200', hold: true, expect: 'ug', why: 'standing' }),
  t({ feed: 'nqrw', route: 'R', id: '123840_R..N93R', at: ['R27N', 'stopped', -14], stops: 'R27N@-14 R26N@51 R25N@111 R24N@171', odd: { noRoute: true }, hold: true, expect: 'none', why: 'the trip descriptor has no route ID' }),
  t({ feed: 'nqrw', route: 'R', id: undefined, at: ['R23S', 'stopped', -14], stops: 'R23S@-14 R24S@51 R25S@111', hold: true, expect: 'none', why: 'the trip descriptor has no trip ID' }),
  t({ feed: 'nqrw', route: 'R', id: '124220_R..S71R', at: ['R23S', 'stopped', -14], stops: 'R23S@-14 R24S@51 R25S@111', noStopId: [0], hold: true, odd: { noStopIdOnVehicle: true }, expect: 'none', why: 'a vehicle position with no stop ID, and a first stop update with none either' }),
  t({ feed: 'nqrw', route: 'R', id: '124590_R..S71R', at: ['R24S', 'stopped', 0], stops: 'R24S@0 R25S@60 R26S@120', odd: { noVehicleTime: true }, hold: true, expect: 'none', why: 'a vehicle position with no timestamp' }),
  t({ feed: 'nqrw', route: 'N', id: '124950_N..N31R', at: ['R20', 'stopped', -14], stops: 'R20@-14 R17@40 R16@100', hold: true, expect: 'none', why: 'stop IDs without a direction letter: no direction to give the train' }),
];

/** Whether the trip is in its feed in round `r` (from and until). */
export function inRound(trip: ScenarioTrip, r: number): boolean {
  return r >= (trip.from ?? 0) && r <= (trip.until ?? Infinity);
}

/** The trip's `expect` for round `r`. */
export function expectIn(trip: ScenarioTrip, r: number): Where {
  if (!inRound(trip, r) || STALE_FEEDS[r]?.includes(trip.feed)) return 'none';
  return Array.isArray(trip.expect) ? trip.expect[r] : trip.expect;
}

export interface ParsedStop {
  stopId: string;
  arrival?: number | null;
  departure?: number | null;
}

/** `A41N@-11 A40N@88/118 L29N@-/1513 L06N@~` to stops, times relative to ROUND_0. */
export function parseStops(text: string): ParsedStop[] {
  return text.split(/\s+/).filter(Boolean).map((token) => {
    const [stopId, times = ''] = token.split('@');
    if (times === '~') return { stopId, arrival: null, departure: null };
    if (times === '') return { stopId };
    const [a, d = a] = times.split('/');
    const num = (s: string) => (s === '-' ? undefined : Number(s));
    const arrival = num(a);
    const departure = d === '-' ? undefined : num(d);
    return { stopId, arrival, departure };
  });
}

/** A trip as of round `r`: its report and stops after the revisions up to then. */
export function tripAt(trip: ScenarioTrip, r: number): { at: ScenarioTrip['at']; stops: ParsedStop[]; shift: number } {
  let at = trip.at;
  let stops = trip.stops;
  for (let k = 1; k <= r; k++) {
    const rev = trip.revise?.[k];
    if (rev?.at !== undefined) at = rev.at;
    if (rev?.stops !== undefined) stops = rev.stops;
  }
  return { at, stops: parseStops(stops), shift: trip.hold ? ROUND_SECONDS * r : 0 };
}

export const roundClock = (r: number) => ROUND_0 + ROUND_SECONDS * r;

/** `20261110T141100Z` for round `r`. */
export function roundStamp(r: number): string {
  return new Date(roundClock(r) * 1000).toISOString().replace(/[-:]/g, '').replace(/\.\d+Z$/, 'Z');
}

const FLAVOR_TRACKS: Record<string, [string, string] | undefined> = { numbered: ['2', '2'], ace: ['A1', 'A1'], bdfm: ['B1', 'B1'], g: ['E1', 'E1'], jz: ['M2', 'M2'], nqrw: ['R1', 'R1'] };

/** One feed of one round as bytes. */
export function buildFeed(feed: string, r: number): Uint8Array {
  const clock = roundClock(r);
  const l = feed === 'l';
  const trips: TripSpec[] = [];
  let entity = 1;
  const suffix = (route: string | undefined) => (l ? '' : (route ?? 'X').slice(0, 1));
  const entityId = () => (l ? String(entity++) : String(entity++).padStart(6, '0') + suffix(feedRoute));
  let feedRoute: string | undefined;
  for (const trip of SCENARIO) {
    if (trip.feed !== feed || !inRound(trip, r)) continue;
    feedRoute = trip.route;
    const { at, stops, shift } = tripAt(trip, r);
    const abs = (s: number | undefined) => (s === undefined ? undefined : ROUND_0 + s + shift);
    const trainClock = String(1700 + (entity % 400)).padStart(4, '0');
    const spec: TripSpec = {
      tripId: trip.id,
      routeId: trip.odd?.noRoute ? undefined : trip.route,
      startTime: trip.startTime ?? (l ? undefined : `${trainClock.slice(0, 2)}:${trainClock.slice(2)}:00`),
      startDate: '20261110',
      nyct: { trainId: `${(trip.route ?? 'X').padStart(2, '0')} ${trainClock} T${entity}/U${entity}`, assigned: true, direction: trip.stops.split(/\s+/)[0]?.endsWith('N') ? 1 : 3 },
      lStyle: l,
      entityId: entityId(),
      stops: stops.map((s, i): StopSpec => {
        const track = FLAVOR_TRACKS[feed];
        return {
          stopId: trip.noStopId?.includes(i) ? undefined : s.stopId,
          arrival: s.arrival === null ? null : abs(s.arrival),
          departure: s.departure === null ? null : abs(s.departure),
          ...(l ? { sequence: 19 + i, delay: 131 - 15 * i, uncertainty: 0 } : {}),
          ...(track ? { tracks: [track[0], track[1]] as [string, string] } : { tracks: ['2', '2'] as [string, string] }),
        };
      }),
      deleted: trip.odd?.deleted,
      noTripUpdate: trip.odd?.noTripUpdate,
    };
    if (at !== null) {
      const [stop, status, ts] = Array.isArray(at) ? at : [at.stop, at.status, at.ts];
      spec.vehicle = {
        entityId: entityId(),
        stopId: trip.odd?.noStopIdOnVehicle ? undefined : stop,
        status,
        timestamp: trip.odd?.noVehicleTime || ts === undefined ? undefined : abs(ts),
        sequence: l ? 19 : 33,
        noTripId: trip.odd?.vehicleNoTripId,
      };
    }
    trips.push(spec);
  }
  const header = clock - HEADER_AGE[feed][r];
  const spec: FeedSpec = {
    timestamp: header,
    incrementality: feed === 'l' || feed === 'g' ? 0 : undefined,
    // Every feed carries NYCT's header extension: replacement periods, per route, that end at the feed's own time or
    // some time after it (the L and G feeds name a start as well).
    replacement: {
      routes: [...SUBWAY_FEED_ROUTES[SUBWAY_FEEDS.find((f) => feedName(f) === feed)!]],
      start: feed === 'l' ? header : undefined,
      end: header + (feed === 'l' ? 1800 : feed === 'g' ? 3600 : 0),
    },
    trips,
    alerts: feed === 'nqrw' ? ['alert-1'] : undefined,
    trailer: feed === 'jz',
  };
  return encodeFeed(spec);
}

/** Every feed of round `r`, by file name part (`numbered`, `ace`, ...). */
export function buildRound(r: number): Map<string, Uint8Array> {
  return new Map(SUBWAY_FEEDS.map((f) => [feedName(f), buildFeed(feedName(f), r)]));
}
