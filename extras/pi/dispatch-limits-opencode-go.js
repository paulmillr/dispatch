// A Pi extension: your OpenCode Go plan's 5-hour, weekly and monthly usage, for Dispatch's activity popover.
// Not in use yet (extras/README.md). It asks OpenCode only when Dispatch's popover opens, after you
// press Show Limits there, and uses the key Pi already has; the key stays in this process.
//
// /zen/go/v1/usage is in OpenCode's open-source code but not its published docs: it may change, and then the popover
// says it couldn't read limits.
const NAME = "opencode-go-limits";

function resets(iso, now) {
  const at = new Date(iso);
  const left = at.getTime() - now;
  if (!Number.isFinite(left) || left <= 0) return "";
  if (left < 86_400_000) {
    const minutes = Math.round(left / 60_000);
    return `resets in ${Math.floor(minutes / 60)}h ${minutes % 60}m`;
  }
  return "resets " + at.toLocaleDateString("en-US", { month: "short", day: "numeric" });
}

/** The rows for one usage answer; a meter that is missing or malformed gets none. */
export function rows(body, now) {
  const usage = body?.usage ?? {};
  return [["5-hour", usage.rolling], ["Weekly", usage.weekly], ["Monthly", usage.monthly]]
    .filter(([, meter]) => Number.isFinite(meter?.percent))
    .map(([label, meter]) => {
      const used = Math.max(0, Math.min(100, Math.round(meter.percent)));
      return {
        label,
        detail: resets(meter.resetsAt, now),
        value: meter.status === "rate-limited" ? "Limit reached" : `${used}%`,
        used: meter.status === "rate-limited" ? 100 : used,
      };
    });
}

export default function (pi) {
  pi.events.on("dispatch:limits:describe", ({ provider, reply }) => {
    if (provider === "opencode-go") reply(NAME);
  });
  pi.events.on("dispatch:limits:read", async ({ source, ctx, reply }) => {
    if (source !== NAME) return;
    try {
      const key = await ctx.modelRegistry.getApiKeyForProvider("opencode-go");
      if (!key) return reply([]);
      const response = await fetch("https://opencode.ai/zen/go/v1/usage", {
        headers: { Authorization: `Bearer ${key}`, Accept: "application/json" },
        signal: AbortSignal.timeout(4000),
      });
      // OpenCode answers 403 for a workspace without Go.
      if (response.status === 403) return reply([]);
      if (!response.ok) return reply(null);
      reply(rows(await response.json(), Date.now()));
    } catch {
      reply(null);
    }
  });
}
