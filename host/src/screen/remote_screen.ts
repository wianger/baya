/**
 * Remote control of this computer from a phone: its screen as a WebRTC
 * video track (hardware H.264 from ffmpeg, low latency, straight over the
 * tailnet), and the phone's touches and keys back over a data channel.
 *
 * The phone asks with `_baya/screen_start` and gets an offer (ICE candidates
 * included, gathered over the tailnet's addresses); it answers with
 * `_baya/screen_answer`. Signalling rides the phone's encrypted link; the
 * media is DTLS-SRTP end to end. Capture starts once the phone is connected,
 * so its first frame is a key frame.
 */

import type { ChildProcess } from "node:child_process";
import { randomInt, randomUUID } from "node:crypto";
import { createSocket, type Socket } from "node:dgram";
import {
  MediaStreamTrack,
  type RTCDataChannel,
  RTCPeerConnection,
  RTCRtpCodecParameters,
  RtpPacket,
} from "werift";
import { type Encoder, screenEncoder, startCapture } from "./capture.ts";
import { type Screen, VIRTUAL_KEYS, WindowsInput } from "./windows_input.ts";

type Json = Record<string, unknown>;

const feedback = [
  { type: "nack" },
  { type: "nack", parameter: "pli" },
  { type: "ccm", parameter: "fir" },
];

/** High first: sharper for the bits; Constrained Baseline where it is not decoded. */
const H264_HIGH = new RTCRtpCodecParameters({
  mimeType: "video/H264",
  clockRate: 90000,
  payloadType: 96,
  rtcpFeedback: feedback,
  parameters: "level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=640034",
});
const H264_BASELINE = new RTCRtpCodecParameters({
  mimeType: "video/H264",
  clockRate: 90000,
  payloadType: 97,
  rtcpFeedback: feedback,
  parameters: "level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42e034",
});

/** At most this many phones watch at once. */
const MAX_SESSIONS = 2;

export interface ScreenQuality {
  fps: number;
  maxSide: number;
  /** Bits per pixel per frame; the bitrate follows the size and rate. */
  density: number;
  maxBitrate: number;
}

const QUALITY: Record<string, ScreenQuality> = {
  // The screen as it is: native resolution up to 4K, 60 fps, bits to spare.
  best: { fps: 60, maxSide: 3840, density: 0.09, maxBitrate: 45_000_000 },
  balanced: { fps: 60, maxSide: 1920, density: 0.07, maxBitrate: 12_000_000 },
  saver: { fps: 30, maxSide: 1280, density: 0.06, maxBitrate: 3_000_000 },
};

/** The size ffmpeg sends: [screen] fitted into [maxSide], never enlarged. */
function sentSize(screen: { width: number; height: number } | null, maxSide: number) {
  const width = screen?.width ?? 1920;
  const height = screen?.height ?? 1080;
  const fit = Math.min(1, maxSide / Math.max(width, height));
  return { width: Math.round(width * fit), height: Math.round(height * fit) };
}

export async function screenAvailable(): Promise<boolean> {
  return (await screenEncoder()) !== null;
}

class RemoteScreen {
  readonly id = randomUUID();
  private readonly pc: RTCPeerConnection;
  private readonly track = new MediaStreamTrack({ kind: "video" });
  private readonly transceiver: ReturnType<RTCPeerConnection["addTransceiver"]>;
  private readonly udp: Socket;
  private readonly input = new WindowsInput();
  private ffmpeg: ChildProcess | null = null;
  private screen: Screen | null = null;
  /** What goes to the phone, once capture starts. */
  sending: Json | null = null;
  private closed = false;
  readonly owner: object;
  private readonly onEnd: (screen: RemoteScreen, reason: string) => void;
  private readonly ffmpegPath: string;
  private readonly encoder: Encoder;
  private readonly quality: ScreenQuality;

  constructor(
    owner: object,
    ffmpegPath: string,
    encoder: Encoder,
    quality: ScreenQuality,
    onEnd: (screen: RemoteScreen, reason: string) => void,
  ) {
    this.owner = owner;
    this.ffmpegPath = ffmpegPath;
    this.encoder = encoder;
    this.quality = quality;
    this.onEnd = onEnd;
    this.pc = new RTCPeerConnection({
      codecs: { video: [H264_HIGH, H264_BASELINE], audio: [] },
    });
    this.transceiver = this.pc.addTransceiver(this.track, { direction: "sendonly" });
    const channel = this.pc.createDataChannel("input", { ordered: true });
    channel.onMessage.subscribe((data) => this.handleInput(channel, data));
    this.pc.connectionStateChange.subscribe((state) => {
      if (state === "connected") this.capture();
      if (state === "failed" || state === "closed") this.close(state);
    });
    this.udp = createSocket("udp4");
    this.udp.on("message", (message) => {
      const packet = RtpPacket.deSerialize(message);
      this.track.writeRtp(packet);
    });
    void this.input.screens.then(
      (screens) => {
        this.screen = screens.find((s) => s.primary) ?? screens[0] ?? null;
      },
      () => {},
    );
  }

  async offer(): Promise<Json> {
    await new Promise<void>((resolve) => this.udp.bind(0, "127.0.0.1", resolve));
    await this.pc.setLocalDescription(await this.pc.createOffer());
    const screen = await this.input.screens.then(
      (screens) => screens.find((s) => s.primary) ?? screens[0],
      () => undefined,
    );
    return {
      screenId: this.id,
      sdp: this.pc.localDescription?.sdp ?? "",
      encoder: this.encoder.name,
      ...(screen ? { width: screen.width, height: screen.height } : {}),
    };
  }

  async answer(sdp: string): Promise<void> {
    await this.pc.setRemoteDescription({ type: "answer", sdp });
  }

  async candidate(candidate: Json): Promise<void> {
    if (typeof candidate["candidate"] !== "string" || !candidate["candidate"]) return;
    await this.pc.addIceCandidate({
      candidate: candidate["candidate"],
      sdpMid: typeof candidate["sdpMid"] === "string" ? candidate["sdpMid"] : "0",
      sdpMLineIndex:
        typeof candidate["sdpMLineIndex"] === "number" ? candidate["sdpMLineIndex"] : 0,
    });
  }

  private capture(): void {
    if (this.ffmpeg || this.closed) return;
    const address = this.udp.address();
    // The codec the phone took: the first it answered with.
    const codec = this.transceiver.codecs[0] ?? H264_BASELINE;
    const high = /profile-level-id=64/iu.test(codec.parameters ?? "");
    const size = sentSize(this.screen, this.quality.maxSide);
    const bitrate = Math.min(
      this.quality.maxBitrate,
      Math.round(size.width * size.height * this.quality.fps * this.quality.density),
    );
    const ffmpeg = startCapture(this.ffmpegPath, this.encoder, {
      port: address.port,
      ssrc: randomInt(1, 0x7fffffff),
      fps: this.quality.fps,
      maxSide: this.quality.maxSide,
      bitrate,
      profile: high ? "high" : "baseline",
      payloadType: codec.payloadType,
    });
    this.sending = {
      codec: high ? "H.264 High" : "H.264",
      bitrate,
      ...size,
      fps: this.quality.fps,
    };
    let errors = "";
    ffmpeg.stderr?.on("data", (chunk: Buffer) => {
      errors = (errors + chunk.toString()).slice(-2000);
    });
    ffmpeg.on("exit", (code) => {
      if (this.ffmpeg !== ffmpeg) return;
      this.ffmpeg = null;
      if (!this.closed) {
        console.error(`[baya] screen capture ended (${code}): ${errors.trim()}`);
        this.close("capture_ended");
      }
    });
    this.ffmpeg = ffmpeg;
  }

  /** The phone's touches and keys; coordinates are fractions of the screen. */
  private handleInput(channel: RTCDataChannel, data: string | Buffer): void {
    let message: Json;
    try {
      message = JSON.parse(typeof data === "string" ? data : data.toString("utf8")) as Json;
    } catch {
      return;
    }
    const screen = this.screen;
    if (!screen) return;
    const pair = (value: unknown): [number, number] | null =>
      Array.isArray(value) &&
      typeof value[0] === "number" &&
      typeof value[1] === "number" &&
      Number.isFinite(value[0]) &&
      Number.isFinite(value[1])
        ? [value[0], value[1]]
        : null;
    const move = pair(message["m"]);
    if (move) {
      const x = screen.x + Math.round(Math.min(1, Math.max(0, move[0])) * (screen.width - 1));
      const y = screen.y + Math.round(Math.min(1, Math.max(0, move[1])) * (screen.height - 1));
      this.input.send(`m ${x} ${y}`);
    }
    const by = pair(message["r"]);
    if (by) {
      this.input.send(`r ${Math.round(by[0] * screen.width)} ${Math.round(by[1] * screen.height)}`);
    }
    const button = message["b"];
    if (button === "l" || button === "r" || button === "m") {
      const clicks = typeof message["n"] === "number" ? Math.min(3, Math.max(0, message["n"])) : 0;
      if (clicks > 0) {
        for (let i = 0; i < clicks; i++) {
          this.input.send(`b ${button} 1`);
          this.input.send(`b ${button} 0`);
        }
      } else {
        this.input.send(`b ${button} ${message["d"] ? 1 : 0}`);
      }
    }
    const wheel = pair(message["w"]);
    if (wheel) this.input.send(`w ${Math.round(wheel[0] * 120)} ${Math.round(wheel[1] * 120)}`);
    const key = message["k"];
    if (typeof key === "string") {
      const mods = (Array.isArray(message["mods"]) ? message["mods"] : [])
        .filter((m): m is string => typeof m === "string")
        .map((m) => VIRTUAL_KEYS[m])
        .filter((m) => m !== undefined);
      const target = VIRTUAL_KEYS[key.toLowerCase()];
      if (target) {
        const line = (k: { vk: number; extended?: boolean }, down: boolean) =>
          `k ${k.vk} ${down ? 1 : 0} ${k.extended ? 1 : 0}`;
        for (const mod of mods) this.input.send(line(mod, true));
        this.input.send(line(target, true));
        this.input.send(line(target, false));
        for (const mod of mods.toReversed()) this.input.send(line(mod, false));
      }
    }
    const text = message["t"];
    if (typeof text === "string" && text) {
      this.input.send(`t ${Buffer.from(text.slice(0, 4000), "utf8").toString("base64")}`);
    }
    if (message["ping"] !== undefined) {
      channel.send(JSON.stringify({ pong: message["ping"], sending: this.sending }));
    }
  }

  close(reason = "stopped"): void {
    if (this.closed) return;
    this.closed = true;
    this.ffmpeg?.kill();
    this.ffmpeg = null;
    this.udp.close();
    this.input.close();
    this.track.stop();
    void this.pc.close().catch(() => {});
    this.onEnd(this, reason);
  }
}

/** Every remote-control session on this computer. */
class RemoteScreens {
  private readonly sessions = new Map<string, RemoteScreen>();

  async start(
    owner: { notify(method: string, params: Json): void },
    quality: unknown,
  ): Promise<Json> {
    const found = await screenEncoder();
    if (!found) {
      throw new Error(
        process.platform === "win32"
          ? "Remote control needs ffmpeg on this computer (winget install ffmpeg)."
          : "Remote control works with a Baya host running on Windows.",
      );
    }
    // A phone that starts again replaces its own session.
    for (const screen of this.sessions.values()) {
      if (screen.owner === owner) screen.close("replaced");
    }
    if (this.sessions.size >= MAX_SESSIONS) {
      throw new Error("Two phones are already controlling this computer.");
    }
    const screen = new RemoteScreen(
      owner,
      found.ffmpeg,
      found.encoder,
      QUALITY[typeof quality === "string" ? quality : "best"] ?? QUALITY["best"]!,
      (ended, reason) => {
        if (this.sessions.get(ended.id) !== ended) return;
        this.sessions.delete(ended.id);
        owner.notify("_baya/screen_ended", { screenId: ended.id, reason });
      },
    );
    this.sessions.set(screen.id, screen);
    try {
      return await screen.offer();
    } catch (error) {
      screen.close("failed");
      throw error;
    }
  }

  answer(owner: object, id: string, sdp: string): Promise<void> {
    return this.get(owner, id).answer(sdp);
  }

  candidate(owner: object, id: unknown, candidate: Json): void {
    if (typeof id !== "string") return;
    const screen = this.sessions.get(id);
    if (screen?.owner === owner) void screen.candidate(candidate).catch(() => {});
  }

  stop(owner: object, id?: string): void {
    for (const screen of [...this.sessions.values()]) {
      if (screen.owner === owner && (id === undefined || screen.id === id)) screen.close();
    }
  }

  stopAll(): void {
    for (const screen of [...this.sessions.values()]) screen.close("host_stopped");
  }

  private get(owner: object, id: string): RemoteScreen {
    const screen = this.sessions.get(id);
    if (!screen || screen.owner !== owner) throw new Error("This remote-control session ended.");
    return screen;
  }
}

export const remoteScreens = new RemoteScreens();
