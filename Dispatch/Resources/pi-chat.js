// Dispatch's opt-in bridge for an existing interactive Pi session.
// Uses Pi's extension API; no model traffic or credentials pass through here.
import { createServer } from "node:net";
import { randomUUID } from "node:crypto";
import { performance } from "node:perf_hooks";
import { homedir } from "node:os";
import { join } from "node:path";
import { lstatSync, mkdirSync, chmodSync, writeFileSync, renameSync, unlinkSync } from "node:fs";
import { getSupportedThinkingLevels } from "@earendil-works/pi-ai";

const limit = 4 * 1024 * 1024;

export default function dispatchChat(pi) {
  let context, server, registrationPath, socketPath, token, partial, uiPrompt;
  let generation = 0;
  let restoreUI = () => {};
  const clients = new Set();

  function privateDirectory(path) {
    mkdirSync(path, { recursive: true, mode: 0o700 });
    const info = lstatSync(path);
    if (!info.isDirectory() || info.isSymbolicLink() || info.uid !== process.getuid())
      throw new Error("Dispatch Pi bridge directory has an unexpected owner or type");
    chmodSync(path, 0o700);
  }
  function model(value) {
    if (!value) return null;
    return { provider: value.provider, id: value.id, name: value.name,
      reasoning: !!value.reasoning, thinkingLevels: getSupportedThinkingLevels(value) };
  }
  function state() {
    return { sessionId: context.sessionManager.getSessionId(), name: context.sessionManager.getSessionName() ?? null,
      transcriptPath: context.sessionManager.getSessionFile() ?? null,
      leafId: context.sessionManager.getLeafId() ?? null,
      busy: !context.isIdle() || !!uiPrompt, editor: context.ui.getEditorText(), uiPrompt: uiPrompt ?? null,
      model: model(context.model), effort: pi.getThinkingLevel(), partial: partial ?? null };
  }
  function register() {
    if (!registrationPath || !context) return;
    const current = state();
    const record = { protocol: 1, pid: process.pid, startedAt: performance.timeOrigin,
      sessionId: current.sessionId, transcriptPath: current.transcriptPath,
      socket: socketPath, token, version: "extension-v1", busy: current.busy,
      activity: uiPrompt ? "waiting" : current.busy ? "working" : "idle", leafId: current.leafId };
    const temporary = registrationPath + "." + token;
    writeFileSync(temporary, JSON.stringify(record) + "\n", { mode: 0o600, flag: "wx" });
    renameSync(temporary, registrationPath);
  }
  function shutdown() {
    generation += 1;
    restoreUI(); restoreUI = () => {};
    for (const client of clients) client.destroy();
    clients.clear();
    server?.close(); server = undefined;
    for (const path of [registrationPath, socketPath]) {
      if (path) { try { unlinkSync(path); } catch {} }
    }
    registrationPath = socketPath = token = partial = uiPrompt = undefined;
    context = undefined;
  }

  async function request(value, epoch) {
    if (epoch !== generation || !context || value.token !== token ||
        value.sessionId !== context.sessionManager.getSessionId())
      throw new Error("The Pi session changed. Reopen Chat before sending.");
    if (value.method === "state") return { state: state() };
    if (value.method === "models") {
      const scoped = context.scopedModels ?? [];
      const available = scoped.length ? scoped.map(item => item.model) : context.modelRegistry.getAvailable();
      return { state: state(), models: available.slice(0, 4096).map(model) };
    }
    if (uiPrompt) throw new Error("Pi needs an answer in Terminal. Your Chat draft is preserved.");
    if (value.method === "abort") {
      // An idle abort must never become a native Escape/rewind action.
      if (!context.isIdle()) await context.abort();
      const deadline = Date.now() + 2000;
      while (epoch === generation && !context.isIdle() && Date.now() < deadline)
        await new Promise(resolve => setTimeout(resolve, 10));
      if (epoch !== generation || !context.isIdle()) throw new Error("Pi has not confirmed Stop. Check Terminal before trying again.");
      return { state: state() };
    }
    if ((!context.isIdle() && value.method !== "steer") || context.ui.getEditorText().length)
      throw new Error("Pi is busy or has input in Terminal. Your Chat draft is preserved.");
    if (value.method === "prompt" || value.method === "steer") {
      if (typeof value.text !== "string" || !value.text.trim() ||
          Buffer.byteLength(value.text) > 1_048_576 || /[\x00-\x08\x0b-\x1f\x7f]/.test(value.text))
        throw new Error("Unsupported Pi message");
      // Pi owns delivery and its normal extension/tool permission flow. This
      // acknowledgment means accepted, never that the response has finished.
      pi.sendUserMessage(value.text, { expandPromptTemplates: false,
        ...(value.method === "steer" ? { deliverAs: "steer" } : {}) });
      return { state: state() };
    }
    if (value.method === "configure") {
      const available = context.modelRegistry.getAvailable();
      const next = available.find(item => item.provider === value.provider && item.id === value.model);
      const scoped = context.scopedModels ?? [];
      if (!next || (scoped.length && !scoped.some(item => item.model.provider === next.provider && item.model.id === next.id)))
        throw new Error("This model is not available in the Pi session");
      if (!getSupportedThinkingLevels(next).includes(value.effort))
        throw new Error("This thinking level is not supported by the selected model");
      if (context.model?.provider !== next.provider || context.model?.id !== next.id) {
        if (!await pi.setModel(next)) throw new Error("Pi could not select this model");
      }
      if (epoch !== generation) throw new Error("The Pi session changed while selecting a model");
      pi.setThinkingLevel(value.effort);
      return { state: state() };
    }
    throw new Error("Unsupported Dispatch Pi operation");
  }

  pi.on("session_start", async (_event, ctx) => {
    shutdown();
    // RPC/print sessions already have a controlling client. Only the visible
    // interactive CLI exposes a bridge, including terminals hosted by SSH.
    if (!ctx.hasUI || !process.stdin.isTTY || !process.stdout.isTTY || !process.getuid) return;
    context = ctx;
    try {
      const configured = process.env.PI_CODING_AGENT_DIR;
      const home = configured === "~" ? homedir() : configured?.startsWith("~/") ? join(homedir(), configured.slice(2))
        : configured || join(homedir(), ".pi", "agent");
      const directory = join(home, "dispatch", "sessions");
      const sockets = `/tmp/dispatch-pi-${process.getuid()}`;
      privateDirectory(directory); privateDirectory(sockets);
      token = randomUUID();
      socketPath = join(sockets, `${process.pid}-${token}.sock`);
      registrationPath = join(directory, `${process.pid}.json`);
      const epoch = generation;
      server = createServer(client => {
        if (clients.size >= 8) { client.destroy(); return; }
        clients.add(client);
        client.on("close", () => clients.delete(client));
        client.on("error", () => {});
        client.setTimeout(5000, () => client.destroy());
        let pending = Buffer.alloc(0), handled = false;
        client.on("data", async bytes => {
          if (handled) { client.destroy(); return; }
          pending = Buffer.concat([pending, bytes]);
          if (pending.length > limit) { client.destroy(); return; }
          const end = pending.indexOf(10);
          if (end < 0) return;
          handled = true;
          let value, response;
          try {
            if (end !== pending.length - 1) throw new Error("One request per connection is required");
            value = JSON.parse(pending.subarray(0, end).toString("utf8"));
            if (typeof value.id !== "string" || value.id.length > 128) throw new Error("Invalid request ID");
            const result = await request(value, epoch);
            if (epoch !== generation) throw new Error("The Pi session changed during this operation");
            response = { id: value.id, sessionId: value.sessionId, ok: true, ...result };
          } catch (error) { response = { id: value?.id ?? "", ok: false, error: String(error.message ?? error) }; }
          const output = JSON.stringify(response) + "\n";
          if (Buffer.byteLength(output) > limit) client.destroy(); else client.end(output);
        });
      });
      await new Promise((resolve, reject) => { server.once("error", reject); server.listen(socketPath, resolve); });
      chmodSync(socketPath, 0o600);
      // Published Pi shares this UI object across extension contexts, but does
      // not emit modal lifecycle events. Observe the public call's lifetime.
      const ui = ctx.ui, pending = new Set(), installed = [];
      restoreUI = () => {
        for (const [method, original, wrapped] of installed) {
          if (ui[method] === wrapped) ui[method] = original;
        }
      };
      for (const method of ["select", "confirm", "input", "editor", "custom"]) {
        const original = ui[method];
        if (typeof original !== "function") continue;
        const wrapped = function (...args) {
          if (epoch !== generation) return Reflect.apply(original, this, args);
          const prompt = { kind: method, ...(typeof args[0] === "string" ? { title: args[0].slice(0, 4096) } : {}) };
          pending.add(prompt); uiPrompt = prompt;
          try { register(); }
          catch { shutdown(); return Reflect.apply(original, this, args); }
          const finish = () => {
            if (epoch !== generation) return;
            pending.delete(prompt); uiPrompt = [...pending].at(-1);
            try { register(); } catch { shutdown(); }
          };
          try { return Promise.resolve(Reflect.apply(original, this, args)).finally(finish); }
          catch (error) { finish(); throw error; }
        };
        ui[method] = wrapped;
        installed.push([method, original, wrapped]);
      }
      register();
    } catch (error) {
      shutdown();
      ctx.ui.notify("Dispatch Chat: " + String(error.message ?? error), "error");
    }
  });
  pi.on("session_shutdown", shutdown);
  for (const event of ["agent_start", "agent_settled", "session_tree", "model_select", "thinking_level_select", "session_compact"]) {
    pi.on(event, (_event, ctx) => { if (server) { context = ctx; register(); } });
  }
  for (const event of ["message_start", "message_update", "message_end"]) {
    pi.on(event, (value, ctx) => {
      if (!server) return;
      context = ctx;
      if (value.message.role === "assistant") {
        if (event === "message_end") partial = undefined;
        else {
          const id = `pi-live-${value.message.timestamp}`;
          let turnId = partial?.id === id ? partial.turnId : undefined;
          let user = partial?.id === id ? partial.user : undefined;
          if (!turnId) {
            const branch = ctx.sessionManager.getBranch();
            for (let index = branch.length - 1; index >= 0; index--) {
              const entry = branch[index];
              if (entry.type === "message" && entry.message.role === "user") { turnId = entry.id; user = entry; break; }
            }
          }
          partial = { turnId: turnId ?? "history", id, message: value.message, user: user ?? null };
        }
      }
      // Persist only the small identity/activity registration. Streamed text is
      // served from memory; Pi's own JSONL remains the conversation history.
      if (event !== "message_update") register();
    });
  }
}
