import { describe, expect, it } from "vitest";
import {
  thinkingLevel,
  thinkingLevelsFromMap,
  thinkingLevelsFromOptions,
} from "../src/protocol/thinking.ts";

describe("thinking level normalization", () => {
  it("maps provider aliases to the canonical wire vocabulary", () => {
    expect(thinkingLevel("none")).toBe("off");
    expect(thinkingLevel("Extra High")).toBe("xhigh");
    expect(thinkingLevel("maximum")).toBe("max");
    expect(thinkingLevel("ultra")).toBe("ultra");
    expect(thinkingLevel("unsupported")).toBeUndefined();
  });

  it("preserves model-specific Codex effort subsets in SDK order", () => {
    expect(
      thinkingLevelsFromOptions([
        { reasoningEffort: "max", description: "Maximum" },
        { reasoningEffort: "low", description: "Fast" },
        { reasoningEffort: "none", description: "Off" },
        { reasoningEffort: "high", description: "Deep" },
        { reasoningEffort: "ultra", description: "Delegated" },
      ]),
    ).toEqual(["off", "low", "high", "max", "ultra"]);
  });

  it("applies Pi thinkingLevelMap support and omission rules", () => {
    expect(
      thinkingLevelsFromMap(
        {
          off: "none",
          minimal: null,
          low: "low",
          medium: null,
          high: "high",
          xhigh: null,
          max: "max",
        },
        true,
      ),
    ).toEqual(["off", "low", "high", "max"]);

    expect(thinkingLevelsFromMap(undefined, true)).toEqual([
      "off",
      "minimal",
      "low",
      "medium",
      "high",
    ]);
    expect(thinkingLevelsFromMap({}, false)).toEqual([]);
  });
});
