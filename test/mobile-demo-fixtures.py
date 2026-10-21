#!/usr/bin/env python3
"""Record the iPhone simulator demo's content (Mobile/Demo/Fixtures) from authored, fictional sessions.

Chats are the real helper's `chat.page` replies for transcripts written here (Claude Code JSONL and Codex rollouts),
recorded exactly as test/mobile-chat-fixtures.py records the iPhone's chat fixtures: the same recorder, the same
neutral pass. Terminals are the bytes a tmux pane replays on attach (CRLF, SGR colours, a prompt last); live files are
lines the demo appends one at a time. Everything is invented: the user is alex, anyone else Sam Example, times are on
2000-01-01 (the demo re-times them). Rerun after a helper change to the record encoders:

    python3 test/mobile-demo-fixtures.py [--helper build/helper-rust/bin/darwin-universal]
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / 'Mobile/Demo/Fixtures'

spec = importlib.util.spec_from_file_location('mobile_chat_fixtures', ROOT / 'test/mobile-chat-fixtures.py')
chat_fixtures = importlib.util.module_from_spec(spec)
spec.loader.exec_module(chat_fixtures)


# Claude Code transcripts ---------------------------------------------------------------------------------------------

class Claude:
    def __init__(self, session, cwd):
        self.session, self.cwd, self.lines, self.prompt = session, cwd, [], 0

    def row(self, kind, uid, message, ts, **extra):
        root = {'type': kind, 'uuid': uid, 'message': message, 'sessionId': self.session, 'version': '2.1.260',
                'timestamp': ts, 'cwd': self.cwd}
        root.update(extra)
        self.lines.append(json.dumps(root, sort_keys=True))

    def user(self, text, ts):
        self.prompt += 1
        self.row('user', 'u%d' % self.prompt, {'role': 'user', 'content': text}, ts, promptId='p%d' % self.prompt)

    def tool(self, call, name, arguments, result, ts1, ts2):
        self.row('assistant', 'a' + call, {'role': 'assistant', 'model': 'fable-5.1', 'stop_reason': 'tool_use',
                 'content': [{'type': 'tool_use', 'id': call, 'name': name, 'input': arguments}]}, ts1, effort='high')
        self.row('user', 'r' + call, {'role': 'user', 'content': [{'type': 'tool_result', 'tool_use_id': call,
                 'content': result, 'is_error': False}]}, ts2, promptId='p%d' % self.prompt)

    def answer(self, uid, text, ts):
        self.row('assistant', uid, {'role': 'assistant', 'model': 'fable-5.1', 'stop_reason': 'end_turn',
                 'content': [{'type': 'text', 'text': text}]}, ts, effort='high')

    def text(self):
        return '\n'.join(self.lines) + '\n'


def t(minute, second, hour=9):
    return '2000-01-01T%02d:%02d:%02d.000Z' % (hour, minute, second)


def numbered(text, start=1):
    return ''.join('%d\t%s\n' % (start + i, line) for i, line in enumerate(text.rstrip('\n').split('\n')))


def web_dark_mode():
    c = Claude('00000000-0000-4000-8000-000000000a01', '/Users/alex/src/web')
    c.user('Add a dark mode toggle to the settings page, persisted per user.', t(10, 0))
    c.tool('w1', 'Glob', {'pattern': 'src/app/settings/**/*.tsx'},
           'src/app/settings/page.tsx\nsrc/app/settings/layout.tsx\nsrc/app/settings/ProfileForm.tsx', t(10, 4), t(10, 4))
    c.tool('w2', 'Grep', {'pattern': 'ThemeProvider|useTheme', 'path': '/Users/alex/src/web/src', 'output_mode': 'files_with_matches'},
           'src/components/ThemeProvider.tsx\nsrc/app/layout.tsx\nsrc/components/Header.tsx', t(10, 9), t(10, 10))
    c.tool('w3', 'Read', {'file_path': '/Users/alex/src/web/src/app/settings/page.tsx'}, numbered('''import { getSession } from "@/lib/auth";
import { ProfileForm } from "./ProfileForm";

export default async function SettingsPage() {
  const session = await getSession();
  return (
    <main className="mx-auto max-w-2xl space-y-8 p-6">
      <h1 className="text-2xl font-semibold">Settings</h1>
      <ProfileForm user={session.user} />
    </main>
  );
}'''), t(10, 14), t(10, 15))
    c.tool('w4', 'Read', {'file_path': '/Users/alex/src/web/prisma/schema.prisma', 'offset': 12, 'limit': 14}, numbered('''model User {
  id        String   @id @default(cuid())
  email     String   @unique
  name      String?
  createdAt DateTime @default(now())
  sessions  Session[]
}''', 12), t(10, 21), t(10, 22))
    c.answer('w5', '''The app already has a `ThemeProvider` (class-based, `dark` on `<html>`), but the choice only lives in
`localStorage`, so it doesn't follow you to another device. Plan:

1. Add a `theme` column to `User` (`"system" | "light" | "dark"`, default `"system"`).
2. `PATCH /api/preferences` to save it; read it in the root layout so the first paint is right.
3. A `useThemePreference` hook that updates the provider at once and saves in the background.
4. A three-way toggle in a new **Appearance** section on the settings page.

Shall I go ahead?''', t(10, 48))
    c.user('Go ahead. Use the existing ThemeProvider.', t(12, 0))
    c.tool('w6', 'Read', {'file_path': '/Users/alex/src/web/src/components/ThemeProvider.tsx'}, numbered('''"use client";
import { createContext, useContext, useEffect, useState } from "react";

export type Theme = "system" | "light" | "dark";
const ThemeContext = createContext<{ theme: Theme; setTheme: (t: Theme) => void } | null>(null);

export function ThemeProvider({ initial, children }: { initial: Theme; children: React.ReactNode }) {
  const [theme, setTheme] = useState<Theme>(initial);
  useEffect(() => {
    const dark = theme === "dark" || (theme === "system" && matchMedia("(prefers-color-scheme: dark)").matches);
    document.documentElement.classList.toggle("dark", dark);
  }, [theme]);
  return <ThemeContext.Provider value={{ theme, setTheme }}>{children}</ThemeContext.Provider>;
}

export function useTheme() {
  const value = useContext(ThemeContext);
  if (!value) throw new Error("useTheme outside ThemeProvider");
  return value;
}'''), t(12, 5), t(12, 6))
    c.tool('w7', 'Write', {'file_path': '/Users/alex/src/web/src/hooks/useThemePreference.ts', 'content': '''"use client";
import { useCallback, useTransition } from "react";
import { useTheme, type Theme } from "@/components/ThemeProvider";

/** The theme, applied at once and saved for this user in the background. */
export function useThemePreference() {
  const { theme, setTheme } = useTheme();
  const [saving, startTransition] = useTransition();

  const choose = useCallback((next: Theme) => {
    setTheme(next);
    startTransition(async () => {
      await fetch("/api/preferences", {
        method: "PATCH",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ theme: next }),
      });
    });
  }, [setTheme]);

  return { theme, choose, saving };
}
'''}, 'File created successfully at: /Users/alex/src/web/src/hooks/useThemePreference.ts', t(12, 31), t(12, 31))
    c.tool('w8', 'Edit', {'file_path': '/Users/alex/src/web/src/app/settings/page.tsx',
                          'old_string': '''      <h1 className="text-2xl font-semibold">Settings</h1>
      <ProfileForm user={session.user} />
''', 'new_string': '''      <h1 className="text-2xl font-semibold">Settings</h1>
      <ProfileForm user={session.user} />
      <section className="space-y-3">
        <h2 className="text-lg font-medium">Appearance</h2>
        <ThemeToggle />
      </section>
'''}, 'The file /Users/alex/src/web/src/app/settings/page.tsx has been updated.', t(12, 49), t(12, 50))
    c.tool('w9', 'Edit', {'file_path': '/Users/alex/src/web/src/app/settings/page.tsx',
                          'old_string': 'import { ProfileForm } from "./ProfileForm";\n',
                          'new_string': 'import { ProfileForm } from "./ProfileForm";\nimport { ThemeToggle } from "./ThemeToggle";\n'},
           'The file /Users/alex/src/web/src/app/settings/page.tsx has been updated.', t(12, 55), t(12, 55))
    c.tool('w10', 'Bash', {'command': 'pnpm typecheck', 'description': 'Type-check the app'},
           '> web@0.18.2 typecheck /Users/alex/src/web\n> tsc --noEmit -p tsconfig.json\n\n'
           'src/app/settings/page.tsx(3,29): error TS2307: Cannot find module \'./ThemeToggle\' or its corresponding type declarations.\n'
           ' ELIFECYCLE  Command failed with exit code 2.', t(13, 2), t(13, 9))
    c.tool('w11', 'Write', {'file_path': '/Users/alex/src/web/src/app/settings/ThemeToggle.tsx', 'content': '''"use client";
import { useThemePreference } from "@/hooks/useThemePreference";

const options = [
  { value: "system", label: "System" },
  { value: "light", label: "Light" },
  { value: "dark", label: "Dark" },
] as const;

export function ThemeToggle() {
  const { theme, choose, saving } = useThemePreference();
  return (
    <div role="radiogroup" aria-label="Theme" aria-busy={saving} className="inline-flex rounded-lg border p-1">
      {options.map((option) => (
        <button
          key={option.value}
          role="radio"
          aria-checked={theme === option.value}
          onClick={() => choose(option.value)}
          className="rounded-md px-3 py-1.5 text-sm aria-checked:bg-neutral-900 aria-checked:text-white dark:aria-checked:bg-white dark:aria-checked:text-neutral-900"
        >
          {option.label}
        </button>
      ))}
    </div>
  );
}
'''}, 'File created successfully at: /Users/alex/src/web/src/app/settings/ThemeToggle.tsx', t(13, 30), t(13, 30))
    c.tool('w12', 'Bash', {'command': 'pnpm typecheck', 'description': 'Type-check the app'},
           '> web@0.18.2 typecheck /Users/alex/src/web\n> tsc --noEmit -p tsconfig.json\n', t(13, 41), t(13, 48))
    return c.text()


def billing_idempotency():
    c = Claude('00000000-0000-4000-8000-000000000a02', '/Users/alex/src/billing')
    c.user('Make billing webhook retries idempotent.', t(30, 0))
    c.tool('b1', 'Grep', {'pattern': 'constructEvent|webhooks', 'path': '/Users/alex/src/billing/src', 'output_mode': 'content', '-n': True},
           'src/routes/webhooks.ts:14:  const event = stripe.webhooks.constructEvent(body, signature, secret);\n'
           'src/routes/invoices.ts:9:  const event = stripe.webhooks.constructEvent(body, signature, secret);', t(30, 5), t(30, 6))
    c.tool('b2', 'Read', {'file_path': '/Users/alex/src/billing/src/routes/webhooks.ts'}, numbered('''import { Hono } from "hono";
import { stripe, secret } from "../lib/stripe";
import { handleCheckoutCompleted, handleSubscriptionUpdated } from "../handlers";

export const webhooks = new Hono();

const handled = new Set<string>();

webhooks.post("/stripe", async (c) => {
  const body = await c.req.text();
  const signature = c.req.header("stripe-signature") ?? "";
  // Stripe retries with the same event; skip ones we've seen this process.
  const event = stripe.webhooks.constructEvent(body, signature, secret);
  const key = `${event.id}:${c.req.header("stripe-attempt") ?? 0}`;
  if (handled.has(key)) return c.body(null, 200);
  handled.add(key);
  switch (event.type) {
    case "checkout.session.completed": await handleCheckoutCompleted(event.data.object); break;
    case "customer.subscription.updated": await handleSubscriptionUpdated(event.data.object); break;
  }
  return c.body(null, 200);
});'''), t(30, 10), t(30, 11))
    c.tool('b3', 'Read', {'file_path': '/Users/alex/src/billing/src/db/schema.ts', 'offset': 40, 'limit': 12}, numbered('''export const invoices = pgTable("invoices", {
  id: text("id").primaryKey(),
  customerId: text("customer_id").notNull(),
  amountDue: integer("amount_due").notNull(),
  status: text("status").notNull(),
  paidAt: timestamp("paid_at", { withTimezone: true }),
});''', 40), t(30, 18), t(30, 19))
    c.tool('b4', 'Write', {'file_path': '/Users/alex/src/billing/migrations/0042_idempotency_keys.sql', 'content': '''-- Webhook events already handled, keyed on Stripe's event id (stable across retries).
CREATE TABLE idempotency_keys (
  event_id     text PRIMARY KEY,
  event_type   text NOT NULL,
  processed_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idempotency_keys_processed_at ON idempotency_keys (processed_at);
'''}, 'File created successfully at: /Users/alex/src/billing/migrations/0042_idempotency_keys.sql', t(30, 40), t(30, 40))
    c.tool('b5', 'Write', {'file_path': '/Users/alex/src/billing/src/lib/idempotent.ts', 'content': '''import { sql } from "drizzle-orm";
import { db } from "../db";

/**
 * Runs `work` once per Stripe event id. The insert and the work share a transaction, so a crash
 * mid-way leaves no key behind and Stripe's next retry runs it again.
 */
export async function once(eventId: string, eventType: string, work: () => Promise<void>) {
  return db.transaction(async (tx) => {
    const inserted = await tx.execute(sql`
      INSERT INTO idempotency_keys (event_id, event_type) VALUES (${eventId}, ${eventType})
      ON CONFLICT (event_id) DO NOTHING
      RETURNING event_id`);
    if (inserted.rowCount === 0) return false;
    await work();
    return true;
  });
}
'''}, 'File created successfully at: /Users/alex/src/billing/src/lib/idempotent.ts', t(31, 2), t(31, 2))
    c.tool('b6', 'Edit', {'file_path': '/Users/alex/src/billing/src/routes/webhooks.ts', 'old_string': '''const handled = new Set<string>();

webhooks.post("/stripe", async (c) => {
  const body = await c.req.text();
  const signature = c.req.header("stripe-signature") ?? "";
  // Stripe retries with the same event; skip ones we've seen this process.
  const event = stripe.webhooks.constructEvent(body, signature, secret);
  const key = `${event.id}:${c.req.header("stripe-attempt") ?? 0}`;
  if (handled.has(key)) return c.body(null, 200);
  handled.add(key);
  switch (event.type) {
    case "checkout.session.completed": await handleCheckoutCompleted(event.data.object); break;
    case "customer.subscription.updated": await handleSubscriptionUpdated(event.data.object); break;
  }
  return c.body(null, 200);
''', 'new_string': '''webhooks.post("/stripe", async (c) => {
  const body = await c.req.text();
  const signature = c.req.header("stripe-signature") ?? "";
  const event = stripe.webhooks.constructEvent(body, signature, secret);
  // Keyed on the event id alone: a retry carries the same id with a new attempt count.
  await once(event.id, event.type, async () => {
    switch (event.type) {
      case "checkout.session.completed": await handleCheckoutCompleted(event.data.object); break;
      case "customer.subscription.updated": await handleSubscriptionUpdated(event.data.object); break;
    }
  });
  return c.body(null, 200);
'''}, 'The file /Users/alex/src/billing/src/routes/webhooks.ts has been updated.', t(31, 20), t(31, 21))
    c.tool('b7', 'Edit', {'file_path': '/Users/alex/src/billing/src/routes/webhooks.ts',
                          'old_string': 'import { handleCheckoutCompleted, handleSubscriptionUpdated } from "../handlers";\n',
                          'new_string': 'import { handleCheckoutCompleted, handleSubscriptionUpdated } from "../handlers";\nimport { once } from "../lib/idempotent";\n'},
           'The file /Users/alex/src/billing/src/routes/webhooks.ts has been updated.', t(31, 24), t(31, 24))
    c.tool('b8', 'Bash', {'command': 'pnpm vitest run billing', 'description': 'Run the billing tests'},
           ' RUN  v2.1.4 /Users/alex/src/billing\n\n'
           ' ✓ test/billing/webhooks.test.ts (6 tests) 412ms\n'
           ' ✓ test/billing/idempotent.test.ts (4 tests) 187ms\n'
           ' ✓ test/billing/invoices.test.ts (5 tests) 233ms\n\n'
           ' Test Files  3 passed (3)\n      Tests  15 passed (15)\n   Start at  09:31:40\n   Duration  1.92s', t(31, 38), t(31, 44))
    c.answer('b9', '''Done. Webhook retries are now keyed on the Stripe **event id**, which stays the same across retries — the old
key mixed in the attempt count, so every retry looked new, and the `Set` was per process anyway.

- `migrations/0042_idempotency_keys.sql` adds the `idempotency_keys` table.
- `src/lib/idempotent.ts` runs the handler once per event, in one transaction with the key, so a crash
  mid-way lets Stripe's next retry run it again.
- `src/routes/webhooks.ts` wraps both handlers in it.

```ts
await once(event.id, event.type, async () => { /* handlers */ });
```

All 15 billing tests pass. `invoice.paid` goes through `src/routes/invoices.ts`, which still has its own check —
want me to move that onto `once` too?''', t(31, 58))
    return c.text()


def docs_question():
    c = Claude('00000000-0000-4000-8000-000000000a03', '/Users/alex/src/docs')
    c.user('Our docs site is slow to build and hard to theme. Should we move off MkDocs?', t(5, 0, 11))
    c.tool('d1', 'Read', {'file_path': '/Users/alex/src/docs/mkdocs.yml'}, numbered('''site_name: Acme Platform Docs
theme:
  name: material
  custom_dir: overrides
  features: [navigation.tabs, navigation.sections, search.suggest, content.code.copy]
plugins:
  - search
  - macros
  - mkdocstrings:
      handlers: { python: { paths: [../api/src] } }
  - git-revision-date-localized
markdown_extensions: [admonition, pymdownx.superfences, pymdownx.tabbed, toc]'''), t(5, 6, 11), t(5, 7, 11))
    c.tool('d2', 'Bash', {'command': 'time mkdocs build --quiet', 'description': 'Time a clean build'},
           'INFO    -  Cleaning site directory\nINFO    -  Building documentation to directory: /Users/alex/src/docs/site\n'
           'INFO    -  Documentation built in 97.42 seconds\nmkdocs build --quiet  88.10s user 4.72s system 95% cpu 1:37.31 total',
           t(5, 12, 11), t(6, 51, 11))
    c.tool('d3', 'Bash', {'command': 'du -sh site && find docs -name "*.md" | wc -l && ls overrides/partials | wc -l',
                          'description': 'Size the output, pages and overrides'},
           ' 61M\tsite\n     412\n      23', t(6, 58, 11), t(6, 59, 11))
    c.tool('d4', 'Bash', {'command': 'mkdocs build --quiet 2>&1 | grep -c "git-revision"; python -m cProfile -s cumtime -m mkdocs build -q 2>/dev/null | head -8',
                          'description': 'Find where the build time goes'},
           '0\n         48213902 function calls in 96.881 seconds\n\n   Ordered by: cumulative time\n\n'
           '   ncalls  tottime  percall  cumtime  percall filename:lineno(function)\n'
           '      412    0.081    0.000   61.204    0.149 plugin.py:118(on_page_markdown) [git-revision-date-localized]\n'
           '        1    0.004    0.004   21.977   21.977 handler.py:66(collect) [mkdocstrings]', t(7, 20, 11), t(9, 2, 11))
    c.answer('d5', '''Most of the 97 s isn't MkDocs itself: **61 s** is `git-revision-date-localized` running `git log` once per
page (412 pages), and **22 s** is mkdocstrings importing the API package. Theming is the real limit — 23 Jinja
overrides in `overrides/partials` to bend Material.

| Option | Build (est.) | Theming | Migration |
| --- | --- | --- | --- |
| Astro Starlight | ~8 s | Components + CSS, easy | Markdown moves as is; admonitions and tabs need a remark plugin; API reference via a script |
| Docusaurus | ~25 s | React, flexible but heavier | MDX conversion for tabs; versioning built in |
| Keep MkDocs | ~14 s | Unchanged | Cache git dates in CI and build the API reference separately |

Keeping MkDocs with those two fixes gets the build under 15 s for a day of work; it doesn't help theming.
Starlight is the best fit if theming matters more than the move — about two days for 412 pages.

Which way do you want to go?''', t(9, 40, 11))
    return c.text()


# Codex rollouts ------------------------------------------------------------------------------------------------------

class Codex:
    def __init__(self, session, cwd, start):
        self.session, self.cwd, self.lines, self.ordinal, self.ms, self.ids = session, cwd, [], 0, start, 0
        self.event('session_meta', {'id': session, 'session_id': session, 'cli_version': '0.154.0', 'source': 'cli', 'cwd': cwd})

    def stamp(self):
        seconds = (self.ms - 946684800000) / 1000
        return '2000-01-01T%02d:%02d:%06.3fZ' % (seconds // 3600, seconds % 3600 // 60, seconds % 60)

    def event(self, kind, payload):
        self.lines.append(json.dumps({'timestamp': self.stamp(), 'ordinal': self.ordinal, 'type': kind, 'payload': payload}))
        self.ordinal += 1

    def uid(self):
        self.ids += 1
        return '%s%012x' % (self.session[:24], self.ids)

    def turn(self, text, wait=0):
        self.ms += wait
        self.turn_id = self.uid()
        self.turn_start = self.ms
        self.event('event_msg', {'type': 'task_started', 'turn_id': self.turn_id, 'started_at': self.ms // 1000,
                                 'model_context_window': 272000, 'collaboration_mode_kind': 'default'})
        self.event('turn_context', {'turn_id': self.turn_id, 'model': 'astra-6'})
        self.ms += 40
        self.event('event_msg', {'type': 'item_completed', 'thread_id': self.session, 'turn_id': self.turn_id,
                                 'item': {'type': 'UserMessage', 'id': self.uid(), 'content': [{'type': 'text', 'text': text, 'text_elements': []}]},
                                 'started_at_ms': self.ms, 'completed_at_ms': self.ms})

    def run(self, cmd, output, seconds=0.4, code=0, wait=2500):
        self.ms += wait
        call = self.uid()
        meta = {'turn_id': self.turn_id}
        self.event('response_item', {'type': 'function_call', 'id': self.uid(), 'name': 'exec_command',
                                     'arguments': json.dumps({'cmd': cmd, 'workdir': self.cwd}), 'call_id': call,
                                     'internal_chat_message_metadata_passthrough': meta})
        start = self.ms
        self.ms += int(seconds * 1000)
        self.event('event_msg', {'type': 'item_completed', 'thread_id': self.session, 'turn_id': self.turn_id, 'item': {
            'type': 'CommandExecution', 'id': call, 'process_id': '4%03d' % self.ids, 'command': ['/bin/zsh', '-lc', cmd],
            'cwd': self.cwd, 'parsed_cmd': [{'type': 'unknown', 'cmd': cmd}], 'source': 'unified_exec_startup',
            'status': 'completed' if code == 0 else 'failed', 'stdout': output, 'stderr': '', 'aggregated_output': output,
            'exit_code': code, 'duration': {'secs': int(seconds), 'nanos': int(seconds % 1 * 1e9)}, 'formatted_output': output},
            'started_at_ms': start, 'completed_at_ms': self.ms})
        self.event('response_item', {'type': 'function_call_output', 'id': 'fco_' + self.uid(), 'call_id': call,
                                     'output': 'Process exited with code %d\nOutput:\n%s' % (code, output),
                                     'internal_chat_message_metadata_passthrough': meta})

    def say(self, text, final=False, wait=3000):
        self.ms += wait
        item = self.uid()
        phase = 'final_answer' if final else 'commentary'
        self.event('event_msg', {'type': 'item_completed', 'thread_id': self.session, 'turn_id': self.turn_id,
                                 'item': {'type': 'AgentMessage', 'id': item, 'content': [{'type': 'Text', 'text': text}], 'phase': phase},
                                 'started_at_ms': self.ms - 600, 'completed_at_ms': self.ms})
        self.event('response_item', {'type': 'message', 'id': item, 'role': 'assistant', 'phase': phase,
                                     'content': [{'type': 'output_text', 'text': text}],
                                     'internal_chat_message_metadata_passthrough': {'turn_id': self.turn_id}})
        if final:
            self.event('event_msg', {'type': 'task_complete', 'turn_id': self.turn_id, 'last_agent_message': text,
                                     'started_at': self.turn_start // 1000, 'completed_at': self.ms // 1000,
                                     'duration_ms': self.ms - self.turn_start})

    def text(self):
        return '\n'.join(self.lines) + '\n'


def api_rate_limit():
    x = Codex('00000000-0000-4000-8000-000000000b01', '/Users/alex/src/api', 946717200000)
    x.turn('Add per-key rate limiting to the public API (100 req/min), with a 429 and Retry-After.')
    x.run('rg -n "layer\\(|middleware" src --type rust', 'src/main.rs:41:        .layer(TraceLayer::new_for_http())\n'
          'src/main.rs:42:        .layer(middleware::from_fn_with_state(state.clone(), auth::require_key))\n'
          'src/routes/mod.rs:18:pub fn public(state: AppState) -> Router<AppState> {\n'
          'src/auth.rs:12:pub async fn require_key(\n')
    x.run('sed -n 1,48p src/routes/mod.rs', '''use axum::{routing::{get, post}, Router};

use crate::{handlers, AppState};

pub fn public(state: AppState) -> Router<AppState> {
    Router::new()
        .route("/v1/projects", get(handlers::projects::list).post(handlers::projects::create))
        .route("/v1/projects/:id", get(handlers::projects::show))
        .route("/v1/deployments", post(handlers::deployments::create))
        .route("/v1/usage", get(handlers::usage::summary))
        .with_state(state)
}
''')
    x.run('sed -n 1,40p src/auth.rs', '''use axum::{extract::{Request, State}, http::StatusCode, middleware::Next, response::Response};

use crate::AppState;

#[derive(Clone, Debug)]
pub struct ApiKey { pub id: i64, pub owner: String }

pub async fn require_key(State(state): State<AppState>, mut request: Request, next: Next) -> Result<Response, StatusCode> {
    let header = request.headers().get("x-api-key").and_then(|v| v.to_str().ok()).ok_or(StatusCode::UNAUTHORIZED)?;
    let key = state.keys.lookup(header).await.map_err(|_| StatusCode::UNAUTHORIZED)?;
    request.extensions_mut().insert(key);
    Ok(next.run(request).await)
}
''')
    x.run('grep -A3 "^\\[dependencies\\]" Cargo.toml; grep -E "^(governor|tower_governor|dashmap)" Cargo.toml || true',
          '[dependencies]\naxum = "0.8"\nsqlx = { version = "0.8", features = ["runtime-tokio", "postgres", "macros"] }\ntokio = { version = "1", features = ["full"] }\n')
    x.say('''`require_key` already puts the resolved `ApiKey` in the request extensions, so the limiter can run right after it
and key on `ApiKey.id`. Plan:

- add `governor` (GCRA, no background task) and a `RateLimiter` keyed by key id: 100 per minute with a burst of 20
- new `src/limit.rs` middleware: on rejection, **429** with `Retry-After` in whole seconds and an `x-ratelimit-remaining` header
- layer it after auth in `main.rs`, so unauthenticated requests still get 401 first''', wait=4000)
    x.run('cargo add governor@0.8 && cargo check --quiet', '    Updating crates.io index\n      Adding governor v0.8.1 to dependencies\n'
          '             Features:\n             + std\n             + dashmap\n             + jitter\n', seconds=21.4)
    x.say('Added `src/limit.rs` and wired it in `main.rs`; `cargo check` is clean. Next I\'ll run the full test suite '
          '(`cargo test --workspace`), which starts a Postgres container for the integration tests.', wait=9000)
    return x.text()


def train_eval():
    x = Codex('00000000-0000-4000-8000-000000000b02', '/home/alex/train', 946717200000)
    x.turn("Summarise last night's eval run and flag regressions.")
    x.run('ls -1t runs | head -4', 'run-0412\nrun-0411\nrun-0409\nrun-0405\n')
    x.run('python scripts/compare.py runs/run-0411 runs/run-0412 --metrics all', '''comparing run-0411 (baseline) -> run-0412
loaded 6 eval suites, 18 432 examples

suite           metric      run-0411   run-0412     delta
--------------  ---------  ---------  ---------  --------
held-out        val_loss       2.031      1.988    -0.043
held-out        ppl             7.62       7.30    -0.32
code            pass@1         41.8%      43.6%    +1.8pt
math            exact          57.2%      57.9%    +0.7pt
long-context    recall@32k     88.4%      81.1%    -7.3pt  !
multilingual    chrF            61.3       61.0     -0.3
''', seconds=38.2)
    x.run('jq -r \'select(.suite=="long-context") | [.length, .recall] | @tsv\' runs/run-0412/eval.jsonl | sort -n | uniq | tail -5',
          '8192\t0.962\n16384\t0.931\n24576\t0.874\n32768\t0.702\n32768\t0.698\n')
    x.run('git -C . log --oneline run-0411..run-0412 -- configs src', 'a41c9e2 configs: rope scaling 4.0 -> 8.0 for 64k\n'
          '7d2f0b1 src/data: pack long documents without padding\n')
    x.say('''**run-0412 vs run-0411**

| suite | metric | run-0411 | run-0412 | Δ |
| --- | --- | --- | --- | --- |
| held-out | val_loss | 2.031 | 1.988 | −0.043 |
| code | pass@1 | 41.8% | 43.6% | +1.8 pt |
| math | exact | 57.2% | 57.9% | +0.7 pt |
| long-context | recall@32k | 88.4% | **81.1%** | **−7.3 pt** |
| multilingual | chrF | 61.3 | 61.0 | −0.3 |

One regression: **long-context recall** falls off at 32k (0.96 at 8k, 0.70 at 32k). The only config change
between the runs is `a41c9e2`, RoPE scaling 4.0 → 8.0, which usually trades short-range precision for reach —
here it seems to hurt at the length we evaluate. Everything else improved or is within noise.

I'd rerun long-context on run-0412 with scaling 4.0 at inference to confirm before reverting.''', final=True, wait=6000)
    return x.text()


# Terminals -----------------------------------------------------------------------------------------------------------

ESC = '\x1b'


def sgr(*codes):
    return ESC + '[' + ';'.join(str(c) for c in codes) + 'm'


R = sgr(0)
BOLD, DIM = sgr(1), sgr(2)
RED, GREEN, YELLOW, BLUE, MAGENTA, CYAN, WHITE = (sgr(c) for c in (31, 32, 33, 34, 35, 36, 37))
BRED, BGREEN, BYELLOW, BBLUE, BCYAN = (sgr(c) for c in (91, 92, 93, 94, 96))
GREY = sgr('38;5;244')


def mac_prompt(host, path):
    return f'{sgr("38;5;114")}alex@{host}{R} {sgr("38;5;75")}{path}{R} {DIM}%{R} '


def linux_prompt(path):
    return f'{BOLD}{BGREEN}alex@ai{R}:{BOLD}{BBLUE}{path}{R}$ '


def session(prompt, steps):
    """Commands and their output, a prompt before each and one last: CRLF lines, no newline after the last prompt."""
    out = []
    for command, output in steps:
        out.append(prompt + command)
        out.extend(output.rstrip('\n').split('\n') if output else [])
    text = '\r\n'.join(out) + '\r\n' + prompt
    return text.replace('\n', '\r\n').replace('\r\r\n', '\r\n')


TERMINAL_WIDTH = 52


def web_dev():
    p = mac_prompt('mba2', '~/src/web')
    return session(p, [('pnpm dev', f"""
> web@0.18.2 dev
> next dev --turbopack

  {BOLD}{MAGENTA}▲ Next.js 15.2.3{R} (Turbopack)
  - Local:   http://localhost:3000
  - Network: http://192.168.1.24:3000

 {GREEN}✓{R} Ready in 1.4s
 {GREY}○{R} Compiling / ...
 {GREEN}✓{R} Compiled / in 2.1s
 GET / {GREEN}200{R} in 2318ms
 {GREY}○{R} Compiling /settings ...
 {GREEN}✓{R} Compiled /settings in 980ms
 GET /settings {GREEN}200{R} in 412ms
 GET /api/session {GREEN}200{R} in 38ms
 POST /api/preferences {GREEN}200{R} in 61ms
 GET /settings {GREEN}200{R} in 74ms""")])[:-len(p)].rstrip('\r\n') + '\r\n'


def web_dev_live():
    import random
    rnd = random.Random(7)
    routes = [('GET', '/settings'), ('GET', '/api/session'), ('POST', '/api/preferences'), ('GET', '/dashboard'),
              ('GET', '/api/projects?limit=20'), ('GET', '/'), ('GET', '/_next/image?w=64')]
    lines = []
    for i in range(32):
        if i in (6, 19):
            lines.append(f' {GREY}○{R} Compiling /api/preferences ...')
            lines.append(f' {GREEN}✓{R} Compiled in {rnd.randint(180, 260)}ms')
            continue
        if i == 25:
            lines.append(f' {YELLOW}⚠{R} Fast Refresh did a full reload')
            continue
        method, route = routes[rnd.randrange(len(routes))]
        status = 200 if rnd.random() > 0.06 else 304
        lines.append(f' {method} {route} {GREEN}{status}{R} in {rnd.randint(9, 140) if i % 5 else rnd.randint(200, 700)}ms')
    return '\n'.join(lines) + '\n'


def web_git():
    p = mac_prompt('mba2', '~/src/web')
    return session(p, [
        ('git status -sb', f"""## {GREEN}dark-mode{R}...{RED}origin/dark-mode{R} [ahead 1]
 {RED}M{R} prisma/schema.prisma
 {RED}M{R} src/app/settings/page.tsx
{RED}??{R} src/app/settings/ThemeToggle.tsx
{RED}??{R} src/hooks/useThemePreference.ts"""),
        ('git log --oneline -8', f"""{YELLOW}9c1e4d2{R} Add theme column to User
{YELLOW}5b07aa1{R} ThemeProvider: initial theme from session
{YELLOW}e3f9c60{R} Merge #212: settings layout
{YELLOW}2a6b8f3{R} Settings: two columns on wide screens
{YELLOW}c48d1e9{R} ProfileForm: optimistic save
{YELLOW}7f3e2b0{R} Upgrade to Next.js 15.2
{YELLOW}41d9a7c{R} Header: avatar menu keyboard nav
{YELLOW}0b8e3f4{R} Fix hydration warning in Footer"""),
        ('git diff --stat', f""" prisma/schema.prisma      | 1 {GREEN}+{R}
 src/app/settings/page.tsx | 5 {GREEN}+++++{R}
 2 files changed, 6 insertions(+)"""),
    ])


def billing_tests():
    p = mac_prompt('mba2', '~/src/billing')
    first = f"""
 {sgr(46, 30)} RUN {R} {CYAN}v2.1.4{R} {GREY}~/src/billing{R}

 {GREEN}✓{R} billing/invoices.test.ts {GREY}(5){R} {YELLOW}233ms{R}
 {GREEN}✓{R} billing/subscriptions.test.ts {GREY}(9){R} {YELLOW}301ms{R}
 {RED}❯{R} billing/webhooks.test.ts {GREY}(6 | {RED}1 failed{GREY}){R}
   {RED}×{R} handles a retried event once
     {RED}→ expected 2 to be 1{R}
 {GREEN}✓{R} lib/money.test.ts {GREY}(12){R} {YELLOW}21ms{R}

{RED}⎯⎯⎯⎯⎯⎯⎯ Failed Tests 1 ⎯⎯⎯⎯⎯⎯⎯{R}

{sgr(41, 97)} FAIL {R} billing/webhooks.test.ts
  {GREY}>{R} webhooks {GREY}>{R} handles a retried event once
{RED}AssertionError{R}: expected 2 to be 1

 {CYAN}❯{R} webhooks.test.ts:{YELLOW}48:31{R}
   46| await post(event, {{ attempt: 1 }});
   47| await post(event, {{ attempt: 2 }});
   48| expect(handled).toHaveBeenCalledTimes(1);
     |                 {RED}^{R}

 Test Files  {BRED}1 failed{R} {GREY}|{R} {BGREEN}3 passed{R} {GREY}(4){R}
      Tests  {BRED}1 failed{R} {GREY}|{R} {BGREEN}31 passed{R} {GREY}(32){R}
   Duration  {BOLD}1.84s{R}"""
    second = f"""
 {sgr(46, 30)} RUN {R} {CYAN}v2.1.4{R} {GREY}~/src/billing{R}

 {GREEN}✓{R} billing/invoices.test.ts {GREY}(5){R} {YELLOW}229ms{R}
 {GREEN}✓{R} billing/subscriptions.test.ts {GREY}(9){R} {YELLOW}296ms{R}
 {GREEN}✓{R} billing/webhooks.test.ts {GREY}(6){R} {YELLOW}412ms{R}
 {GREEN}✓{R} billing/idempotent.test.ts {GREY}(4){R} {YELLOW}187ms{R}
 {GREEN}✓{R} lib/money.test.ts {GREY}(12){R} {YELLOW}19ms{R}

 Test Files  {BGREEN}5 passed{R} {GREY}(5){R}
      Tests  {BGREEN}36 passed{R} {GREY}(36){R}
   Duration  {BOLD}1.92s{R}"""
    return session(p, [('pnpm vitest run', first), ('pnpm vitest run', second)])


def api_cargo():
    p = mac_prompt('studio', '~/src/api')
    crates = ['proc-macro2 v1.0.92', 'libc v0.2.169', 'serde v1.0.217', 'tokio v1.43.0', 'hyper v1.5.2', 'tower v0.5.2',
              'sqlx-core v0.8.3', 'governor v0.8.1', 'axum v0.8.1', 'sqlx v0.8.3']
    build = '\n'.join(f'   {BOLD}{GREEN}Compiling{R} {c}' for c in crates)
    build += f"""
   {BOLD}{GREEN}Compiling{R} api v0.9.0 (~/src/api)
{BOLD}{YELLOW}warning{R}{BOLD}: unused variable: `burst`{R}
  {BOLD}{BLUE}-->{R} src/limit.rs:23:9
   {BOLD}{BLUE}|{R}
{BOLD}{BLUE}23{R} {BOLD}{BLUE}|{R}     let burst = NonZeroU32::new(20)?;
   {BOLD}{BLUE}|{R}         {BOLD}{YELLOW}^^^^^{R} {BOLD}{YELLOW}help: prefix it: `_burst`{R}
   {BOLD}{BLUE}|{R}
{BOLD}{YELLOW}warning{R}{BOLD}: `api` generated 1 warning{R}
    {BOLD}{GREEN}Finished{R} `dev` profile in 38.42s"""
    tests = ['auth::missing_key_is_401', 'auth::unknown_key_is_401', 'limit::allows_burst', 'limit::over_limit_is_429',
             'limit::keys_are_independent', 'projects::list_paginates', 'projects::create_validates', 'usage::by_day']
    test = f"""   {BOLD}{GREEN}Compiling{R} api v0.9.0 (~/src/api)
    {BOLD}{GREEN}Finished{R} `test` profile in 9.87s
     {BOLD}{GREEN}Running{R} unittests src/main.rs

running 42 tests
""" + '\n'.join(f'test {name} ... {GREEN}ok{R}' for name in tests) + f"""
{GREY}… 34 more{R}

test result: {GREEN}ok{R}. 42 passed; 0 failed; 0 ignored
finished in 1.37s
"""
    return session(p, [('cargo build', build), ('cargo test', test)])


def log_line(time, level, message):
    colour = {'INFO': GREEN, 'WARN': YELLOW, 'DEBUG': BLUE, 'ERROR': RED}[level]
    return f'{DIM}{time}{R} {colour}{level:<4}{R} {message}'


def api_logs():
    p = mac_prompt('studio', '~/src/api')
    lines = [f'    {BOLD}{GREEN}Finished{R} `dev` profile in 0.31s', f'     {BOLD}{GREEN}Running{R} `target/debug/api`',
             log_line('10:02:11', 'INFO', 'postgres pool ready (8)'),
             log_line('10:02:11', 'INFO', 'rate limit 100/min, burst 20'),
             log_line('10:02:11', 'INFO', 'listening on 0.0.0.0:8080')]
    lines += [log_line('10:02:%02d' % (12 + i), 'INFO', m) for i, m in enumerate([
        f'GET /v1/projects {GREEN}200{R} 12ms {DIM}k_31{R}',
        f'GET /v1/projects/prj_8f2 {GREEN}200{R} 7ms {DIM}k_31{R}',
        f'POST /v1/deployments {GREEN}201{R} 48ms {DIM}k_31{R}',
        f'GET /v1/usage {GREEN}200{R} 19ms {DIM}k_07{R}'])]
    return session(p, [('cargo run', '\n'.join(lines))])[:-len(p)].rstrip('\r\n') + '\r\n'


def api_logs_live():
    import random
    rnd = random.Random(11)
    paths = ['/v1/projects', '/v1/projects/prj_8f2', '/v1/usage', '/v1/projects?page=2']
    lines = []
    for i in range(34):
        second = 20 + i * 2
        stamp = '10:%02d:%02d' % (2 + second // 60, second % 60)
        key = rnd.choice(['k_31', 'k_07', 'k_12', 'k_99'])
        if i in (9, 10, 22):
            lines.append(log_line(stamp, 'WARN', f'GET /v1/projects {YELLOW}429{R} retry 14s {DIM}k_99{R}'))
        elif i == 17:
            lines.append(log_line(stamp, 'INFO', 'usage rollup: 1824 rows, 212ms'))
        else:
            method = 'POST' if rnd.random() < 0.15 else 'GET'
            path = '/v1/deployments' if method == 'POST' else rnd.choice(paths)
            status = 201 if method == 'POST' else 200
            lines.append(log_line(stamp, 'INFO', f'{method} {path} {GREEN}{status}{R} {rnd.randint(4, 60)}ms {DIM}{key}{R}'))
    return '\n'.join(lines) + '\n'


def docs_shell():
    p = mac_prompt('studio', '~/src/docs')
    ls = f"""README.md
{BOLD}{BLUE}docs{R}
mkdocs.yml
{BOLD}{BLUE}overrides{R}
requirements.txt
{BOLD}{GREEN}serve.sh{R}
{BOLD}{BLUE}site{R}"""
    build = """INFO - Cleaning site directory
INFO - Building documentation to site
INFO - Pages not in "nav":
  - changelog/2024.md
  - internal/runbook.md
INFO - Documentation built in 97.42 seconds"""
    return session(p, [('ls -1', ls), ('mkdocs build', build), ('du -sh site', ' 61M\tsite'),
                       ('ls docs/**/*.md | wc -l', '     412')])


def train_gpu():
    p = linux_prompt('~/train')
    smi = """0, 97 %, 44812 MiB, 71
1, 96 %, 44790 MiB, 69"""
    train = f"""{DIM}[10:41:07]{R} d_model 2048, 24 layers, seq 4096
{DIM}[10:41:07]{R} ddp x2, bf16, grad accum 4
{DIM}[10:41:31]{R} resumed run-0413/ckpt-ep6.pt
ep 7 1780/4000 loss {BOLD}1.958{R} 41.0k tok/s
ep 7 1800/4000 loss {BOLD}1.951{R} 41.3k tok/s
ep 7 1820/4000 loss {BOLD}1.947{R} 41.1k tok/s"""
    return session(p, [('nvidia-smi --format=csv,noheader \\\n> --query-gpu=index,utilization.gpu,\\\n> memory.used,temperature.gpu', smi),
                       ('python train.py configs/base.yaml', train)])[:-len(p)].rstrip('\r\n') + '\r\n'


def train_gpu_live():
    import random
    rnd = random.Random(3)
    lines, loss, step = [], 1.944, 1840
    for i in range(36):
        if i in (11, 29):
            val = loss + 0.06 + rnd.uniform(-0.01, 0.01)
            lines.append(f'{CYAN}eval{R} val_loss {BOLD}{val:.3f}{R} ppl {2.718281828 ** val:.2f} {DIM}41.8s{R}')
            continue
        loss -= rnd.uniform(0.0004, 0.0035)
        lines.append(f'ep 7 {step}/4000 loss {BOLD}{loss:.3f}{R} {rnd.uniform(40.6, 41.6):.1f}k tok/s')
        step += 20
    return '\n'.join(lines) + '\n'


def train_shell():
    p = f'{DIM}(.venv){R} ' + linux_prompt('~/train')
    first = linux_prompt('~/train')
    rest = session(p, [
        ('pip list | grep torch', 'torch          2.6.0+cu128\ntorchaudio     2.6.0+cu128\ntorchvision    0.21.0+cu128'),
        ('export R=runs/run-0412', ''),
        ('tail -n 4 $R/eval.jsonl', '\n'.join(json.dumps(r, separators=(',', ':')) for r in [
            {'suite': 'long-context', 'len': 24576, 'recall': 0.874},
            {'suite': 'long-context', 'len': 32768, 'recall': 0.702},
            {'suite': 'held-out', 'val_loss': 1.988},
            {'suite': 'code', 'pass@1': 0.436}])),
        ('df -h /data', 'Filesystem      Size  Used Avail Use%\n/dev/nvme1n1p1  7.3T  5.1T  1.9T  73%'),
    ])
    return first + 'source .venv/bin/activate\r\n' + rest


AGENT_WIDTH = 48


def visible(text):
    """Display columns of a line: its characters without the SGR escapes (each glyph one column)."""
    import re
    return len(re.sub('\x1b\\[[0-9;]*m', '', text))


def boxed(rows, colour, width=AGENT_WIDTH):
    """A rounded box `width` columns wide around rows of (text with SGR, plain text)."""
    lines = [f'{colour}╭' + '─' * (width - 2) + f'╮{R}']
    for text in rows:
        lines.append(f'{colour}│{R} {text}' + ' ' * (width - 4 - visible(text)) + f' {colour}│{R}')
    lines.append(f'{colour}╰' + '─' * (width - 2) + f'╯{R}')
    return lines


def agent_screen(lines):
    for line in lines:
        assert visible(line) <= AGENT_WIDTH, (visible(line), line)
    return '\r\n'.join(lines)


def agent_claude():
    """Claude Code at rest in a phone-narrow pane (an agent tab's Terminal segment): every line fits 48 columns."""
    o = sgr('38;5;173')
    lines = boxed([f'{o}✻{R} Welcome to {BOLD}Claude Code{R}!', '', f'{DIM}/help for help, /status{R}', f'{DIM}cwd: ~/src/web{R}'], o)
    lines += ['', f'{GREY}>{R} Go ahead. Use the existing ThemeProvider.', '',
              f'{GREEN}⏺{R} {BOLD}Read{R}(ThemeProvider.tsx)', '  ⎿  Read 21 lines', '',
              f'{GREEN}⏺{R} {BOLD}Write{R}(useThemePreference.ts)', '  ⎿  Wrote 22 lines', '',
              f'{GREEN}⏺{R} {BOLD}Update{R}(settings/page.tsx)', '  ⎿  Updated with 5 additions', '',
              f'{GREEN}⏺{R} {BOLD}Bash{R}(pnpm typecheck)', '  ⎿  tsc --noEmit -p tsconfig.json', '',
              f'{o}✶{R} {o}Wiring the toggle…{R} {DIM}(48s · esc to stop){R}', '']
    lines += boxed([f'{GREY}>{R} '], GREY)
    lines += [f'  {DIM}? for shortcuts{R}' + ' ' * 14 + f'{DIM}fable-5.1 · high{R}']
    return agent_screen(lines)


def agent_codex():
    """Codex at rest in a phone-narrow pane, asking to run the test suite: every line fits 48 columns."""
    lines = boxed([f'{BOLD}>_ OpenAI Codex{R} {DIM}(v0.154.0){R}', '', f'{DIM}model:{R}     astra-6 high',
                   f'{DIM}directory:{R} ~/src/api'], DIM)
    lines += ['', f'{BOLD}›{R} Add per-key rate limiting to the public',
              '  API (100 req/min), with a 429 and', '  Retry-After.', '',
              f'{GREEN}•{R} {BOLD}Explored{R}', f'  {DIM}└{R} Search layer|middleware in src',
              '    Read mod.rs, auth.rs', '',
              f'{GREEN}•{R} {BOLD}Ran{R} cargo add governor@0.8',
              f'  {DIM}└{R} Adding governor v0.8.1', '',
              f'{GREEN}•{R} Added src/limit.rs; cargo check is clean.',
              '  Next: the full test suite.', '',
              f'{YELLOW}▌{R} {BOLD}Allow command?{R}', f'{YELLOW}▌{R}   $ cargo test --workspace',
              f'{YELLOW}▌{R} {CYAN}›{R} 1. Yes, proceed', f'{YELLOW}▌{R}   2. Yes, always for this command',
              f'{YELLOW}▌{R}   3. No, tell Codex what to do {DIM}esc{R}', '',
              f'{BOLD}›{R} ', f'  {DIM}⏎ send  ⌃T transcript{R}' + ' ' * 7 + f'{DIM}82% context{R}']
    return agent_screen(lines)


# Main ----------------------------------------------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    parser.add_argument('--helper', default=str(ROOT / 'build/helper-rust/bin/darwin-universal'))
    args = parser.parse_args()
    (OUT / 'chats').mkdir(parents=True, exist_ok=True)
    (OUT / 'terminals').mkdir(parents=True, exist_ok=True)
    (OUT / 'live').mkdir(parents=True, exist_ok=True)

    terminals = {'web-dev': web_dev(), 'web-git': web_git(), 'billing-tests': billing_tests(), 'api-cargo': api_cargo(),
                 'api-logs': api_logs(), 'docs-shell': docs_shell(), 'train-gpu': train_gpu(), 'train-shell': train_shell(),
                 'agent-claude': agent_claude(), 'agent-codex': agent_codex()}
    live = {'web-dev': web_dev_live(), 'api-logs': api_logs_live(), 'train-gpu': train_gpu_live()}
    # On a host the app sizes the pane to the phone, so programs format for about 52 columns: so do the recordings.
    for name, text in terminals.items():
        for line in text.split('\r\n'):
            assert visible(line) <= TERMINAL_WIDTH, (name, visible(line), line)
    for name, text in live.items():
        for line in text.split('\n'):
            assert visible(line) <= TERMINAL_WIDTH, (name, visible(line), line)
    for name, text in terminals.items():
        (OUT / 'terminals' / (name + '.vt')).write_bytes(text.encode())
    for name, text in live.items():
        (OUT / 'live' / (name + '.txt')).write_bytes(text.encode())

    chats = [('web-dark-mode', 'claude', web_dark_mode(), '00000000-0000-4000-8000-000000000a01'),
             ('billing-idempotency', 'claude', billing_idempotency(), '00000000-0000-4000-8000-000000000a02'),
             ('docs-question', 'claude', docs_question(), '00000000-0000-4000-8000-000000000a03'),
             ('api-rate-limit', 'codex', api_rate_limit(), '00000000-0000-4000-8000-000000000b01'),
             ('train-eval', 'codex', train_eval(), '00000000-0000-4000-8000-000000000b02')]
    with tempfile.TemporaryDirectory(prefix='mdf', dir='/tmp') as work:
        work = Path(work)
        recorder = work / 'record'
        sources = ['test/mobile-chat-record.swift', 'test/helper-client-stubs.swift', 'Mobile/Shared/System.swift'] + [
            'Dispatch/Helper/' + name + '.swift' for name in
            ('HelperWire', 'HelperBinary', 'HelperConnection', 'HelperTransport', 'AppReplay')]
        subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-O', '-o', str(recorder)] + sources, cwd=ROOT, check=True)
        home = work / 'home'
        home.mkdir()
        environment = {key: value for key, value in os.environ.items() if key != 'TMUX'}
        environment['HOME'] = str(home)
        for name, key, transcript, session_id in chats:
            path = work / (name + '.jsonl')
            path.write_text(transcript)
            out = work / (name + '.json')
            subprocess.run([str(recorder), args.helper, key, str(path), session_id, str(out)], env=environment,
                           check=True, timeout=60)
            pages = chat_fixtures.neutral(json.loads(out.read_text()))
            (OUT / 'chats' / (name + '.json')).write_text(json.dumps(pages, indent=1, sort_keys=True, ensure_ascii=False) + '\n')
            print(name, sum(len(page['records']) for page in pages), 'records')


if __name__ == '__main__':
    main()
