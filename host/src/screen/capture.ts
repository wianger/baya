/**
 * The screen as H.264 over RTP, from ffmpeg: Desktop Duplication
 * (`ddagrab`) captures on the GPU, the fastest encoder this computer has
 * (NVENC, Quick Sync, AMF, else x264) compresses for low latency, and RTP
 * packets go to a local UDP port for WebRTC to forward.
 */
import { type ChildProcess, execFile, spawn } from "node:child_process";
import { findExecutable } from "../workspace/directories.ts";

export interface Encoder {
  name: string;
  options: string[];
}

/**
 * Fastest first. Each is tuned for low latency without giving up quality:
 * no B-frames, no lookahead, constant bitrate, one frame in flight.
 */
const ENCODERS: Encoder[] = [
  {
    name: "h264_nvenc",
    options: ["-preset", "p4", "-tune", "ll", "-rc", "cbr", "-zerolatency", "1", "-delay", "0"],
  },
  {
    name: "h264_qsv",
    options: ["-preset", "faster", "-async_depth", "1", "-look_ahead", "0"],
  },
  {
    name: "h264_amf",
    options: ["-usage", "lowlatency", "-quality", "balanced", "-rc", "cbr"],
  },
  {
    name: "libx264",
    options: ["-preset", "veryfast", "-tune", "zerolatency"],
  },
];

/** H.264 profile names as each encoder spells them. */
export function profileOption(encoder: Encoder, profile: "high" | "baseline"): string[] {
  if (profile === "high") return ["-profile:v", "high"];
  return ["-profile:v", encoder.name === "h264_amf" ? "constrained_baseline" : "baseline"];
}

let found: Promise<{ ffmpeg: string; encoder: Encoder } | null> | null = null;

/** ffmpeg and the first encoder that works here, worked out once. */
export function screenEncoder(): Promise<{ ffmpeg: string; encoder: Encoder } | null> {
  found ??= (async () => {
    if (process.platform !== "win32") return null;
    const ffmpeg = await findExecutable("ffmpeg");
    if (!ffmpeg) return null;
    for (const encoder of ENCODERS) {
      if (await encodes(ffmpeg, encoder)) return { ffmpeg, encoder };
    }
    return null;
  })();
  return found;
}

/** One frame through [encoder], to see that this computer has it. */
function encodes(ffmpeg: string, encoder: Encoder): Promise<boolean> {
  return new Promise((resolve) => {
    execFile(
      ffmpeg,
      [
        "-hide_banner",
        "-loglevel",
        "error",
        "-f",
        "lavfi",
        "-i",
        "color=size=640x360:rate=5",
        "-frames:v",
        "1",
        "-pix_fmt",
        "nv12",
        "-c:v",
        encoder.name,
        ...encoder.options,
        ...profileOption(encoder, "high"),
        "-f",
        "null",
        "-",
      ],
      { timeout: 15_000, windowsHide: true },
      (error) => resolve(!error),
    );
  });
}

export interface CaptureOptions {
  port: number;
  ssrc: number;
  fps: number;
  /** Longest side, in pixels; the screen is scaled down to fit. */
  maxSide: number;
  bitrate: number;
  /** As negotiated with the phone: High where it decodes it. */
  profile: "high" | "baseline";
  payloadType: number;
  output?: number;
}

/** ffmpeg sending the screen to 127.0.0.1:[port] as RTP. */
export function startCapture(
  ffmpeg: string,
  encoder: Encoder,
  options: CaptureOptions,
): ChildProcess {
  const { port, ssrc, fps, maxSide, bitrate, profile, payloadType, output = 0 } = options;
  // Fits [maxSide] both ways, never enlarged, even dimensions for H.264.
  const scale = `scale=w='min(${maxSide},iw)':h='min(${maxSide},ih)':force_original_aspect_ratio=decrease:force_divisible_by=2`;
  const args = [
    "-hide_banner",
    "-loglevel",
    "error",
    "-fflags",
    "nobuffer",
    "-flags",
    "low_delay",
    "-f",
    "lavfi",
    "-i",
    `ddagrab=output_idx=${output}:framerate=${fps}:draw_mouse=1:dup_frames=1`,
    "-vf",
    `hwdownload,format=bgra,${scale},format=nv12`,
    "-c:v",
    encoder.name,
    ...encoder.options,
    ...profileOption(encoder, profile),
    "-bf",
    "0",
    "-g",
    String(fps),
    "-b:v",
    String(bitrate),
    "-maxrate",
    String(bitrate),
    "-bufsize",
    String(Math.round(bitrate / 2)),
    "-an",
    "-f",
    "rtp",
    "-payload_type",
    String(payloadType),
    "-ssrc",
    String(ssrc),
    `rtp://127.0.0.1:${port}?pkt_size=1200`,
  ];
  return spawn(ffmpeg, args, { stdio: ["ignore", "ignore", "pipe"], windowsHide: true });
}
