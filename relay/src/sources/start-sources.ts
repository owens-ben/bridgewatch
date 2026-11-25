import { describeError } from '../guard';
import type { Logger } from '../types';
import type { Source } from './source';

/**
 * Starts every source. One that throws in `start()` is logged as `source <id>: failed to start: ...` and the others
 * still start: a broken source must not take the rest of the relay with it. Returns the ids that started.
 */
export function startSources(running: readonly { id: string; source: Source }[], log: Logger): string[] {
  const started: string[] = [];
  for (const { id, source } of running) {
    try {
      source.start();
      started.push(id);
    } catch (err) {
      log(`source ${id}: failed to start: ${describeError(err)}`);
    }
  }
  return started;
}
