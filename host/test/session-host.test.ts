import { describe, expect, test } from "vitest";
import { roomIdForBayaSession, sessionInventoryResponse } from "../src/host/session_host.ts";

describe("managed host session inventory", () => {
  test("returns the room of every registered Baya session", () => {
    const sessions = [
      { id: "session-a", cwd: "/code/a", agent: "pi" as const },
      { id: "session-b", cwd: "/code/b", agent: "codex" as const },
    ];
    expect(sessionInventoryResponse("inventory-request", sessions, 42)).toEqual({
      type: "sessions_inventory",
      in_reply_to: "inventory-request",
      room_ids: sessions.map(roomIdForBayaSession),
      scanned_at: 42,
      complete: true,
    });
  });
});
