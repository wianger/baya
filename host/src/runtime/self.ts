import { isSea } from "node:sea";

/** Whether this is the single-file `baya` executable rather than Node + script. */
export const packaged = isSea();

/**
 * The command that runs Baya itself: the executable alone when packaged,
 * otherwise Node and this script.
 */
export function selfCommand(): string[] {
  return packaged ? [process.execPath] : [process.execPath, process.argv[1]!];
}
