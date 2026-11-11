// A Pi extension: your OpenRouter key's budget, free requests or spend, for Dispatch's activity popover.
// Not in use yet (extras/README.md). It asks OpenRouter only when Dispatch's popover opens, after
// you press Show Limits there, and uses the key Pi already has; the key stays in this process.
const NAME = "openrouter-limits";

const usd = (value) => "$" + (Math.round(value * 100) / 100).toFixed(2).replace(/\.00$/, "");

function resets(iso, now) {
  if (!iso) return "";
  const at = new Date(iso);
  const left = at.getTime() - now;
  if (!Number.isFinite(left) || left <= 0) return "";
  if (left < 86_400_000) {
    const minutes = Math.round(left / 60_000);
    return `resets in ${Math.floor(minutes / 60)}h ${minutes % 60}m`;
  }
  return "resets " + at.toLocaleDateString("en-US", { month: "short", day: "numeric" });
}

const percent = (part, whole) => Math.max(0, Math.min(100, Math.round((part / whole) * 100)));

/** The rows for one `GET /api/v1/key` answer: a free model's daily count, the budget that blocks first, else spend. */
export function rows(data, model, now) {
  const free = data.free_model_daily_requests;
  if (String(model).endsWith(":free") && free?.limit > 0) {
    return [{
      label: "Free requests",
      detail: "resets 12:00am UTC",
      value: `${free.remaining} of ${free.limit} left`,
      used: percent(free.used, free.limit),
    }];
  }
  const budget = data.effective_budget;
  if (budget?.limit_usd > 0) {
    const interval = { daily: "Daily budget", weekly: "Weekly budget", monthly: "Monthly budget" }[budget.reset_interval];
    return [{
      label: interval ?? "Budget",
      detail: resets(budget.resets_at, now),
      value: `${usd(Math.max(0, budget.remaining_usd))} left of ${usd(budget.limit_usd)}`,
      used: percent(budget.spend_usd, budget.limit_usd),
    }];
  }
  if (data.limit > 0 && Number.isFinite(data.limit_remaining)) {
    return [{
      label: "Key limit",
      detail: "",
      value: `${usd(Math.max(0, data.limit_remaining))} left of ${usd(data.limit)}`,
      used: percent(data.limit - data.limit_remaining, data.limit),
    }];
  }
  return [
    ["Today", data.usage_daily],
    ["This week", data.usage_weekly],
    ["This month", data.usage_monthly],
  ].filter(([, value]) => Number.isFinite(value)).map(([label, value]) => ({ label, detail: "", value: usd(value) }));
}

export default function (pi) {
  pi.events.on("dispatch:limits:describe", ({ provider, reply }) => {
    if (provider === "openrouter") reply(NAME);
  });
  pi.events.on("dispatch:limits:read", async ({ source, model, ctx, reply }) => {
    if (source !== NAME) return;
    try {
      const key = await ctx.modelRegistry.getApiKeyForProvider("openrouter");
      if (!key) return reply([]);
      const response = await fetch("https://openrouter.ai/api/v1/key", {
        headers: { Authorization: `Bearer ${key}` },
        signal: AbortSignal.timeout(4000),
      });
      if (!response.ok) return reply(null);
      const { data } = await response.json();
      reply(rows(data, model, Date.now()));
    } catch {
      reply(null);
    }
  });
}
