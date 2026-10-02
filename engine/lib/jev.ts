// Thin wrapper over the TypeSafe SDK: one shared client, a request-rate throttle,
// and a per-HTTP-request call log (AsyncLocalStorage) that the server returns as `jev`.
import { AsyncLocalStorage } from "node:async_hooks";
import { setTimeout as sleep } from "node:timers/promises";
import { TypeSafeClient, type EntryType, type Questions } from "@typesafe-ai/sdk";

export { choice, noul, score } from "@typesafe-ai/sdk";

/** Thrown by app handlers for bad input; the server answers 400 with this message. */
export class UserError extends Error {}

// Created on first use so pure-logic checks can import app modules without an API key.
let client: TypeSafeClient | undefined;
const USD_PER_INPUT_TOKEN = 0.042 / 1e6; // output tokens are free (docs.typesafe.ai/models)
const MAX_RPS = 35; // account limit is 40 requests/s

type Call = { label: string; ms: number; tokens: number; questions: number; request?: unknown; answers?: unknown };
const log = new AsyncLocalStorage<Call[]>();

// ponytail: per-process sliding window; several server processes share one account limit,
// and the SDK retries any 429 that slips through.
const starts: number[] = [];
async function throttle() {
  for (;;) {
    const now = Date.now();
    while (starts.length && now - starts[0] >= 1000) starts.shift();
    if (starts.length < MAX_RPS) return void starts.push(now);
    await sleep(1000 - (now - starts[0]) + 5);
  }
}

/** One System One request. Every question sees the same state and runs in parallel. */
export async function ask<const Q extends Questions>(state: EntryType, questions: Q, label = "jev") {
  await throttle();
  const t = performance.now();
  client ??= new TypeSafeClient({ timeout: 30_000, retry: { maxRetries: 4 } });
  const r = await client.systemOne({ state, questions });
  const calls = log.getStore();
  if (calls) {
    const sample = calls.length < 3; // keep a few full payloads for the "under the hood" panel
    calls.push({
      label,
      ms: Math.round(performance.now() - t),
      tokens: r.usage.input_tokens,
      questions: Object.keys(questions).length,
      ...(sample && { request: preview({ state, questions }), answers: preview(r.answers) }),
    });
  }
  return r.answers;
}

/** A display copy for the Under the hood panel: long strings, lists, and option maps are cut short. */
export function preview(v: unknown, depth = 0, key = ""): unknown {
  const KEEP = 40;
  if (typeof v === "string") return v.length > 1500 ? `${v.slice(0, 1500)}… (${v.length.toLocaleString()} characters)` : v;
  if (!v || typeof v !== "object" || depth > 8) return v;
  if (Array.isArray(v)) return [...v.slice(0, KEEP).map((x) => preview(x, depth + 1)), ...(v.length > KEEP ? [`… ${v.length - KEEP} more`] : [])];
  const entries = Object.entries(v);
  if (key === "probabilities") entries.sort((a, b) => (b[1] as number) - (a[1] as number)); // keep the likeliest
  const out = Object.fromEntries(entries.slice(0, KEEP).map(([k, x]) => [k, preview(x, depth + 1, k)]));
  if (entries.length > KEEP) out["…"] = `${entries.length - KEEP} more`;
  return out;
}

/** Run `fn` with a fresh call log; returns the log alongside the result. */
export function traced<T>(fn: () => T) {
  const calls: Call[] = [];
  return { calls, result: log.run(calls, fn) };
}

export function summarize(calls: Call[]) {
  const tokens = calls.reduce((s, c) => s + c.tokens, 0);
  return {
    calls: calls.length,
    questions: calls.reduce((s, c) => s + c.questions, 0),
    tokens,
    usd: tokens * USD_PER_INPUT_TOKEN,
    slowest_ms: Math.max(0, ...calls.map((c) => c.ms)),
    samples: calls.filter((c) => c.request),
  };
}

/** Run `fn` over items with bounded concurrency, preserving order. */
export async function mapLimit<T, R>(items: T[], limit: number, fn: (item: T, i: number) => Promise<R>) {
  const out: R[] = new Array(items.length);
  let next = 0;
  const worker = async () => {
    while (next < items.length) {
      const i = next++;
      out[i] = await fn(items[i], i);
    }
  };
  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, worker));
  return out;
}

/** Prefix each line with a stable id ("L007| ...") so a Choice can point at lines. */
export function numberLines(lines: string[]) {
  const id = (i: number) => `L${String(i).padStart(3, "0")}`;
  return { id, text: lines.map((l, i) => `${id(i)}| ${l}`).join("\n") };
}

/** Most options a line-pointing Choice gets (the API takes 255). */
export const MAX_UNITS = 250;

/** Join the shortest unit to the one after it until at most `max` remain, so each fits one Choice. */
export function fitUnits(units: string[], max = MAX_UNITS) {
  const out = [...units];
  // ponytail: O(n²) greedy merge; fine for the few thousand lines an app accepts
  while (out.length > max) {
    let i = 0;
    for (let j = 1; j < out.length; j++) if (out[j].length < out[i].length) i = j;
    if (i === out.length - 1) i--;
    out.splice(i, 2, `${out[i]} ${out[i + 1]}`);
  }
  return out;
}

// Jev reads at most 64k tokens per request. Measured: about 3.5 characters per state token and 9 tokens
// per Choice option, so this many line-pointing questions fit beside a numbered state of `stateChars`.
export const pointersPerRequest = (stateChars: number, options: number) =>
  Math.max(1, Math.floor((56_000 - stateChars / 3.5) / (options * 9 + 200)));
