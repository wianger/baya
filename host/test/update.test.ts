import { describe, expect, test } from "vitest";
import { assetName, compareVersions, expectedDigest, newestRelease } from "../src/update.ts";

describe("self update", () => {
  test("names the executable for each platform", () => {
    expect(assetName("linux", "x64")).toBe("baya-linux-x64");
    expect(assetName("win32", "x64")).toBe("baya-win32-x64.exe");
    expect(assetName("darwin", "arm64")).toBe("baya-darwin-arm64");
  });

  test("picks the newest published host release, ignoring app releases and drafts", () => {
    const asset = (name: string) => ({ name, browser_download_url: `https://x/${name}` });
    const release = newestRelease([
      { tag_name: "app-v2.6.0+98", draft: false, assets: [] },
      { tag_name: "host-v4.2.0", draft: true, assets: [] },
      { tag_name: "host-v4.1.0", draft: false, assets: [asset("SHA256SUMS")] },
      { tag_name: "host-v4.0.0", draft: false, assets: [] },
      { tag_name: "host-v4.10.0", draft: false, assets: [asset("baya-linux-x64")] },
    ]);
    expect(release?.version).toBe("4.10.0");
    expect(release?.assets.get("baya-linux-x64")).toBe("https://x/baya-linux-x64");
    expect(compareVersions("4.10.0", "4.9.9")).toBeGreaterThan(0);
  });

  test("reads the expected digest from SHA256SUMS", () => {
    const digest = "a".repeat(64);
    const sums = `${"b".repeat(64)}  baya-darwin-arm64\n${digest}  baya-linux-x64\n`;
    expect(expectedDigest(sums, "baya-linux-x64")).toBe(digest);
    expect(expectedDigest(sums, "baya-win32-x64.exe")).toBeNull();
  });
});
