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
      { value: "magpie/kiro/auto", name: "kiro/auto" },
      { value: "openai/gpt-5", name: "gpt-5" },
    ]);
  });

  it("offers them as the phone's model picker", () => {
    const option = modelOption([{ value: "opus", name: "Opus" }], null);
    expect(option).toMatchObject({ id: "model", category: "model", currentValue: "opus" });
  });
});
