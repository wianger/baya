import { describe, expect, it } from "vitest";
import { modelOption, parsePiModels } from "../src/herdr/models.ts";

describe("models a pane's agent switches between", () => {
  it("reads Pi's catalog", () => {
    const table = [
      "provider  model                     context  max-out  thinking  images",
      "magpie    kiro/auto                 1M       64K      yes       yes",
      "openai    gpt-5                     400K     128K     yes       yes",
      "",
    ].join("\n");
    expect(parsePiModels(table)).toEqual([
      { value: "magpie/kiro/auto", name: "kiro/auto", context: 1_000_000 },
      { value: "openai/gpt-5", name: "gpt-5", context: 400_000 },
    ]);
  });

  it("offers them as the phone's model picker", () => {
    const option = modelOption([{ value: "opus", name: "Opus" }], null);
    expect(option).toMatchObject({ id: "model", category: "model", currentValue: "opus" });
  });
});

describe("how full a pane conversation's context is", () => {
  it("reads Claude's last reply and Pi's with its model", async () => {
    const { usageOf } = await import("../src/herdr/records.ts");
    expect(
      usageOf("claude", [
        {
          type: "assistant",
          message: {
            usage: {
              input_tokens: 2,
              cache_creation_input_tokens: 1000,
              cache_read_input_tokens: 9000,
              output_tokens: 500,
            },
          },
        },
      ]),
    ).toEqual({ used: 10_502, size: 200_000, model: null });
    expect(
      usageOf("pi", [
        {
          type: "message",
          message: {
            role: "assistant",
            provider: "magpie",
            model: "kiro/auto",
            usage: { input: 3001, output: 67, cacheRead: 8576, cacheWrite: 0 },
          },
        },
      ]),
    ).toEqual({ used: 11_644, size: 0, model: "magpie/kiro/auto" });
  });

  it("knows a Pi model's window from its catalog", () => {
    const [model] = parsePiModels("provider model context\nmagpie kiro/auto 1.0M 64K yes yes\n");
    expect(model?.context).toBe(1_000_000);
  });
});
