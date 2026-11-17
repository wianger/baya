const logged = new Map<string, number>();

/** Logs [message] to the host log at most once every ten minutes per [kind]. */
export function logOnce(kind: string, message: string): void {
  const now = Date.now();
  if (now - (logged.get(kind) ?? 0) < 600_000) return;
  logged.set(kind, now);
  console.error(`[baya] ${new Date(now).toISOString()} ${message}`);
}
