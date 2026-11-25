/** Planar geometry for the subway extract generator: local meters around New York (equirectangular). */

export type LatLon = readonly [number, number];
export type XY = readonly [number, number];

const EARTH_RADIUS_M = 6_371_008.8;
const RAD = Math.PI / 180;
const LAT0 = 40.7;
const M_PER_DEG_LAT = EARTH_RADIUS_M * RAD;
const M_PER_DEG_LON = M_PER_DEG_LAT * Math.cos(LAT0 * RAD);

export const toXY = ([lat, lon]: LatLon): XY => [lon * M_PER_DEG_LON, lat * M_PER_DEG_LAT];
export const toLatLon = ([x, y]: XY): LatLon => [y / M_PER_DEG_LAT, x / M_PER_DEG_LON];
export const dist = (a: XY, b: XY): number => Math.hypot(b[0] - a[0], b[1] - a[1]);

/** A polyline with cumulative distances. */
export class Polyline {
  readonly cumulative: number[];

  constructor(readonly points: XY[]) {
    if (points.length === 0) throw new Error('empty polyline');
    this.cumulative = [0];
    for (let i = 1; i < points.length; i++) this.cumulative.push(this.cumulative[i - 1] + dist(points[i - 1], points[i]));
  }

  get length(): number {
    return this.cumulative[this.cumulative.length - 1];
  }

  /** The point `d` meters along (clamped). */
  at(d: number): XY {
    const c = this.cumulative;
    const u = Math.min(Math.max(d, 0), this.length);
    let i = 1;
    while (i < c.length - 1 && c[i] < u) i++;
    if (c.length === 1) return this.points[0];
    const f = c[i] > c[i - 1] ? (u - c[i - 1]) / (c[i] - c[i - 1]) : 0;
    const [a, b] = [this.points[i - 1], this.points[i]];
    return [a[0] + f * (b[0] - a[0]), a[1] + f * (b[1] - a[1])];
  }

  /** Unit direction of travel `d` meters along. */
  direction(d: number): XY {
    const c = this.cumulative;
    let i = 1;
    while (i < c.length - 1 && c[i] < d) i++;
    // Skip zero-length pieces.
    let j = i;
    while (j < this.points.length - 1 && dist(this.points[j - 1], this.points[j]) === 0) j++;
    const [a, b] = [this.points[j - 1], this.points[j]];
    const len = dist(a, b) || 1;
    return [(b[0] - a[0]) / len, (b[1] - a[1]) / len];
  }

  /** Nearest point on the polyline to `p`: how far along, and how far off. Restricted to [min, max] if given. */
  project(p: XY, min = 0, max = Infinity): { along: number; offset: number } {
    let best = { along: 0, offset: Infinity };
    for (let i = 1; i < this.points.length; i++) {
      const a = this.points[i - 1];
      const b = this.points[i];
      const vx = b[0] - a[0];
      const vy = b[1] - a[1];
      const len2 = vx * vx + vy * vy;
      let t = len2 > 0 ? ((p[0] - a[0]) * vx + (p[1] - a[1]) * vy) / len2 : 0;
      t = Math.min(Math.max(t, 0), 1);
      const along = this.cumulative[i - 1] + t * Math.sqrt(len2);
      if (along < min - 1e-6 || along > max + 1e-6) continue;
      const offset = dist(p, [a[0] + t * vx, a[1] + t * vy]);
      if (offset < best.offset) best = { along, offset };
    }
    return best;
  }

  /** The part between `from` and `to` meters along (from < to). */
  slice(from: number, to: number): Polyline {
    const pts: XY[] = [this.at(from)];
    for (let i = 0; i < this.points.length; i++) {
      if (this.cumulative[i] > from && this.cumulative[i] < to) pts.push(this.points[i]);
    }
    pts.push(this.at(to));
    return new Polyline(pts);
  }

  reversed(): Polyline {
    return new Polyline([...this.points].reverse());
  }
}

/** Douglas-Peucker: drops points within `tolerance` meters of the simplified line, never the ones in `keep`. */
export function simplify(points: XY[], tolerance: number, keep: Set<number> = new Set()): number[] {
  const kept = new Set<number>([0, points.length - 1, ...keep]);
  const sorted = () => [...kept].sort((a, b) => a - b);
  const stack: [number, number][] = [];
  const anchors = sorted();
  for (let i = 1; i < anchors.length; i++) stack.push([anchors[i - 1], anchors[i]]);
  while (stack.length > 0) {
    const [s, e] = stack.pop()!;
    let worst = -1;
    let worstD = tolerance;
    for (let i = s + 1; i < e; i++) {
      const d = distanceToSegment(points[i], points[s], points[e]);
      if (d > worstD) {
        worst = i;
        worstD = d;
      }
    }
    if (worst >= 0) {
      kept.add(worst);
      stack.push([s, worst], [worst, e]);
    }
  }
  return sorted();
}

function distanceToSegment(p: XY, a: XY, b: XY): number {
  const vx = b[0] - a[0];
  const vy = b[1] - a[1];
  const len2 = vx * vx + vy * vy;
  const t = len2 > 0 ? Math.min(Math.max(((p[0] - a[0]) * vx + (p[1] - a[1]) * vy) / len2, 0), 1) : 0;
  return dist(p, [a[0] + t * vx, a[1] + t * vy]);
}
