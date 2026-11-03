/** Wire shapes of Baya's `_baya/*` folder and file methods (camelCase, as in ACP). */

export interface WorkspaceDirectory {
  path: string;
  parent: string | null;
  home: string;
  roots: string[];
  directories: Array<{ name: string; path: string }>;
  truncated: boolean;
}

export interface SessionFileEntry {
  name: string;
  path: string;
  type: "file" | "directory";
  size: number | null;
  modifiedAt: number | null;
}

export interface SessionDirectory {
  root: string;
  path: string;
  parent: string | null;
  entries: SessionFileEntry[];
  truncated: boolean;
}

export interface SessionFileContent {
  name: string;
  path: string;
  size: number;
  modifiedAt: number;
  content: string | null;
  binary: boolean;
  truncated: boolean;
}
