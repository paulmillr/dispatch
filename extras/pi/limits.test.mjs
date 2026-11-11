// node --test extras/pi/limits.test.mjs
import assert from "node:assert/strict";
import test from "node:test";
import { rows as openrouter } from "./dispatch-limits-openrouter.js";
import { rows as go } from "./dispatch-limits-opencode-go.js";

const now = Date.parse("2026-11-20T12:00:00Z");
const spend = { usage_daily: 1.2, usage_weekly: 6.1, usage_monthly: 18.35, limit: null, limit_remaining: null, effective_budget: null };

test("openrouter: no budget shows spend, with no bar", () => {
  assert.deepEqual(openrouter(spend, "moonshotai/kimi-k2.6", now), [
    { label: "Today", detail: "", value: "$1.20" },
    { label: "This week", detail: "", value: "$6.10" },
    { label: "This month", detail: "", value: "$18.35" },
  ]);
});

test("openrouter: the budget that blocks first", () => {
  const budget = { limit_usd: 20, spend_usd: 12.6, remaining_usd: 7.4, reset_interval: "monthly", resets_at: "2026-12-01T00:00:00Z" };
  assert.deepEqual(openrouter({ ...spend, effective_budget: budget }, "x/y", now), [
    { label: "Monthly budget", detail: "resets Dec 1", value: "$7.40 left of $20", used: 63 },
  ]);
});

test("openrouter: an overspent budget stops at nothing left", () => {
  const budget = { limit_usd: 5, spend_usd: 6, remaining_usd: -1, reset_interval: null, resets_at: null };
  assert.deepEqual(openrouter({ ...spend, effective_budget: budget }, "x/y", now), [
    { label: "Budget", detail: "", value: "$0 left of $5", used: 100 },
  ]);
});

test("openrouter: a key limit without budgets", () => {
  assert.deepEqual(openrouter({ ...spend, limit: 10, limit_remaining: 2.5 }, "x/y", now), [
    { label: "Key limit", detail: "", value: "$2.50 left of $10", used: 75 },
  ]);
});

test("openrouter: a free model shows its daily count", () => {
  const data = { ...spend, free_model_daily_requests: { used: 44, limit: 50, remaining: 6 } };
  assert.deepEqual(openrouter(data, "x/y:free", now), [
    { label: "Free requests", detail: "resets 12:00am UTC", value: "6 of 50 left", used: 88 },
  ]);
  assert.equal(openrouter(data, "x/y", now)[0].label, "Today");
});

test("opencode go: three windows", () => {
  const meter = (percent, resetsAt) => ({ status: "ok", percent, resetsAt });
  assert.deepEqual(go({ usage: {
    rolling: meter(33.6, "2026-11-20T15:12:00Z"),
    weekly: meter(61, "2026-11-23T08:00:00Z"),
    monthly: meter(0.4, "2026-12-03T00:00:00Z"),
  } }, now), [
    { label: "5-hour", detail: "resets in 3h 12m", value: "34%", used: 34 },
    { label: "Weekly", detail: "resets Nov 23", value: "61%", used: 61 },
    { label: "Monthly", detail: "resets Dec 3", value: "0%", used: 0 },
  ]);
});

test("opencode go: a limited meter says so", () => {
  const body = { usage: { rolling: { status: "rate-limited", percent: 100, resetsAt: "2026-11-20T13:00:00Z" } } };
  assert.deepEqual(go(body, now), [{ label: "5-hour", detail: "resets in 1h 0m", value: "Limit reached", used: 100 }]);
});

test("opencode go: an unexpected answer has no rows", () => {
  assert.deepEqual(go({}, now), []);
  assert.deepEqual(go(null, now), []);
  assert.deepEqual(go({ usage: { weekly: { percent: "x" } } }, now), []);
});
