// A stand-in for `hc connect`: plain hello, then frames, with one terminal t1.
let framed = false;
let buffer = Buffer.alloc(0);
let credit = 0;
const out = (channel, kind, payload = Buffer.alloc(0)) => {
  const header = Buffer.alloc(9);
  header.writeUInt32LE(channel, 0);
  header[4] = kind;
  header.writeUInt32LE(payload.length, 5);
  process.stdout.write(Buffer.concat([header, payload]));
};
const reply = (id, result) =>
  out(0, 0, Buffer.from(JSON.stringify({ jsonrpc: "2.0", id, result })));
const t1 = {
  address: "t1",
  argv: ["sh"],
  cwd: "/w",
  state: "live",
  status: { state: "blocked", app: "claude" },
};
function call({ id, method, params }) {
  switch (method) {
    case "terminal.list":
      return reply(id, { terminals: [t1] });
    case "terminal.get":
      return reply(id, { credit });
    case "events.subscribe":
      reply(id, { channel: 1, seq: 1, terminals: [t1] });
      return setTimeout(
        () =>
          out(
            1,
            0,
            Buffer.from(
              `${JSON.stringify({ jsonrpc: "2.0", method: "event", params: { seq: 2, type: "status", terminal: "t1" } })}\n`,
            ),
          ),
        20,
      );
    case "terminal.attach":
      reply(id, { channel: 2, terminal: t1, automatic_input: false, resize_notifications: false });
      return out(
        2,
        0,
        Buffer.from(`paint ${params.cols}x${params.rows} history=${params.history}`),
      );
    case "terminal.kill":
      out(2, 2, Buffer.from(JSON.stringify({ reason: "killed", exit_code: 0 })));
      return reply(id, t1);
    case "terminal.run":
      return reply(id, { address: "t2", params });
    default:
      return out(
        0,
        0,
        Buffer.from(
          JSON.stringify({
            jsonrpc: "2.0",
            id,
            error: {
              code: -32000,
              message: `no ${method}`,
              data: { kind: "not_found", hint: "try t1" },
            },
          }),
        ),
      );
  }
}
process.stdin.on("data", (chunk) => {
  buffer = Buffer.concat([buffer, chunk]);
  if (!framed) {
    const newline = buffer.indexOf(10);
    if (newline < 0) return;
    const hello = JSON.parse(buffer.subarray(0, newline));
    buffer = buffer.subarray(newline + 1);
    framed = true;
    process.stdout.write(
      `${JSON.stringify({ jsonrpc: "2.0", id: hello.id, result: { framed: true, generation: 1 } })}\n`,
    );
  }
  while (buffer.length >= 9) {
    const channel = buffer.readUInt32LE(0),
      kind = buffer[4],
      length = buffer.readUInt32LE(5);
    if (buffer.length < 9 + length) break;
    const payload = buffer.subarray(9, 9 + length);
    buffer = buffer.subarray(9 + length);
    if (channel === 0) call(JSON.parse(payload));
    else if (kind === 0) out(channel, 0, Buffer.concat([Buffer.from("echo:"), payload]));
    else if (kind === 1) credit += payload.readUInt32LE(0);
    else if (kind === 3)
      out(channel, 0, Buffer.from(`size:${payload.readUInt16LE(0)}x${payload.readUInt16LE(2)}`));
    else if (kind === 2) out(channel, 2);
  }
});
