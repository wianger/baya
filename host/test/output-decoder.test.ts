import { describe, expect, test } from "vitest";
import { outputDecoder } from "../src/acp/client_services.ts";

describe("command output decoding", () => {
  test("UTF-8 stays UTF-8, even split across chunks", () => {
    const decode = outputDecoder("gbk");
    const bytes = Buffer.from("构建完成 ✓", "utf8");
    expect(decode(bytes.subarray(0, 4)) + decode(bytes.subarray(4))).toBe("构建完成 ✓");
  });

  test("a console's legacy code page is decoded, not shown as mojibake", () => {
    const decode = outputDecoder("gbk");
    // "命令已完成" in GBK, as cmd.exe prints it on Chinese Windows.
    const gbk = Buffer.from([0xc3, 0xfc, 0xc1, 0xee, 0xd2, 0xd1, 0xcd, 0xea, 0xb3, 0xc9]);
    expect(decode(gbk)).toBe("命令已完成");
  });
});
