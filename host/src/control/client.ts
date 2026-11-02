import { randomUUID } from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
import { connect } from "node:net";
import type { ControlCommand, ControlInfo, ControlRequest, ControlResponse } from "./protocol.ts";
import { controlInfoPath } from "./server.ts";

export function readControlInfo(): ControlInfo | null {
  if (!existsSync(controlInfoPath())) return null;
  try {
    const value = JSON.parse(readFileSync(controlInfoPath(), "utf8")) as Partial<ControlInfo>;
    if (
      typeof value.port !== "number" ||
      typeof value.token !== "string" ||
      typeof value.pid !== "number"
    )
      return null;
    return {
      port: value.port,
      token: value.token,
      pid: value.pid,
      started_at: typeof value.started_at === "number" ? value.started_at : 0,
    };
  } catch {
    return null;
  }
}

export async function controlCall<T = unknown>(
  command: ControlCommand,
  params?: Record<string, unknown>,
  timeoutMs = 30_000,
): Promise<T> {
  const info = readControlInfo();
  if (!info) throw new Error("Baya is not running. Start it with `baya start`.");
  const request: ControlRequest = {
    token: info.token,
    id: randomUUID(),
    command,
    ...(params ? { params } : {}),
  };
  return new Promise<T>((resolve, reject) => {
    const socket = connect({ host: "127.0.0.1", port: info.port });
    let buffer = "";
    const timer = setTimeout(() => {
      socket.destroy();
      reject(new Error("Baya control request timed out."));
    }, timeoutMs);
    socket.setEncoding("utf8");
    socket.on("connect", () => socket.write(`${JSON.stringify(request)}\n`));
    socket.on("data", (chunk: string) => {
      buffer += chunk;
      const newline = buffer.indexOf("\n");
      if (newline < 0) return;
      clearTimeout(timer);
      const line = buffer.slice(0, newline);
      socket.destroy();
      try {
        const response = JSON.parse(line) as ControlResponse;
        if (!response.ok) {
          reject(new Error(response.error || "Baya control request failed."));
          return;
        }
        resolve(response.data as T);
      } catch (error) {
        reject(error instanceof Error ? error : new Error("Invalid control response."));
      }
    });
    socket.on("error", (error) => {
      clearTimeout(timer);
      reject(error);
    });
  });
}
