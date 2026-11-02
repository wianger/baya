import { describe, expect, test } from "vitest";
import { sessionInventoryResponse } from "../src/host/session_host.ts";
import { sessionKeyForId } from "../src/rooms.ts";

describe("managed host session inventory", () => {
  test("returns every registered Baya session as one complete snapshot", () => {
    const response = sessionInventoryResponse(
      "inventory-request",
      [{ id: "session-a" }, { id: "session-b" }],
      42,
    );

    expect(response).toEqual({
      type: "sessions_inventory",
      in_reply_to: "inventory-request",
      session_keys: [sessionKeyForId("session-a"), sessionKeyForId("session-b")],
      scanned_at: 42,
      complete: true,
    });
    expect(response.session_keys).toHaveLength(2);
    expect(response.session_keys[0]).toMatch(/^[A-Za-z0-9_-]{16}$/);
  });
});
