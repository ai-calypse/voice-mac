// The engine's only interface: newline-delimited JSON-RPC over stdio, so the Swift shell (or any
// process) can drive it. Requests: {"id", "method", "params"}; replies: {"id", "result"} or
// {"id", "error"}. Running tasks also push {"event": "task", ...} lines until they finish.
import { createInterface } from "node:readline";
import { UserError } from "./lib/jev.ts";
import * as browser from "./browser.ts";

const METHODS: Record<string, (p: any) => Promise<unknown>> = {
  "task.start": browser.start,
  "task.progress": browser.progress,
  "task.approve": browser.approve,
  "task.stop": browser.stop,
  "task.history": browser.history,
  utterance: browser.voice, // {audio: base64 16 kHz WAV, live?, pending?, mine?}
  ping: async () => ({ ok: true }),
};

const send = (msg: unknown) => process.stdout.write(JSON.stringify(msg) + "\n");

/** Push a task's new steps and status until it ends, so the shell never has to poll. */
async function watch(id: string) {
  let from = 0;
  for (;;) {
    const p: any = await browser.progress({ id, from }).catch(() => null);
    if (!p) return;
    if (p.steps.length || ["done", "stuck", "stopped", "error", "waiting"].includes(p.status)) send({ event: "task", id, ...p, live: undefined, steps: p.steps.map(({ shot, ...s }: any) => s) }); // screenshots stay in task.progress
    from += p.steps.length;
    if (["done", "stuck", "stopped", "error"].includes(p.status)) return;
    await new Promise((r) => setTimeout(r, 300));
  }
}

createInterface({ input: process.stdin }).on("line", async (line) => {
  let req: { id?: unknown; method?: string; params?: unknown };
  try {
    req = JSON.parse(line);
  } catch {
    return send({ id: null, error: { message: "Not JSON." } });
  }
  const fn = METHODS[String(req.method)];
  if (!fn) return send({ id: req.id, error: { message: `Unknown method ${req.method}.` } });
  try {
    const result: any = await fn(req.params ?? {});
    send({ id: req.id, result });
    const taskId = req.method === "task.start" ? result?.id : result?.task?.id;
    if (taskId) watch(taskId);
  } catch (e) {
    send({ id: req.id, error: { message: String((e as Error).message ?? e).split("\n")[0], user: e instanceof UserError } });
  }
});
send({ event: "ready", methods: Object.keys(METHODS) });
