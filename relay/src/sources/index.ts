import { aisstream } from './aisstream';
import { mtaSubway } from './mta-subway';
import type { SourcePlugin } from './source';

/** Every source the relay can run. A new feed is a plug-in here, then enabled by name in SOURCES. */
export const SOURCE_PLUGINS: readonly SourcePlugin[] = [aisstream, mtaSubway];
