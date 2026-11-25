import type { Logger } from './types';

export const log: Logger = (message) => {
  console.log(`${new Date().toISOString()} ${message}`);
};
