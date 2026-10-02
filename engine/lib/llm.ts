// Generative models, used only where an app has to write text: Claude Sonnet through the
// local Claude subscription (Agent SDK, no API key) and Gemini through its REST API.
import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { join } from "node:path";
import { query } from "@anthropic-ai/claude-agent-sdk";

type Turn = { role: "user" | "assistant"; text: string };

/** Claude Sonnet via the Agent SDK. Isolated: no user settings, hooks, or plugins, and no tools
 *  unless `web` allows its web search (for answers that depend on current information). */
export async function claude(prompt: string | Turn[], system: string, schema?: Record<string, unknown>, { web = false } = {}): Promise<string> {
  const text = typeof prompt === "string" ? prompt : transcript(prompt);
  for await (const m of query({
    prompt: text,
    options: {
      model: "sonnet",
      systemPrompt: system,
      settingSources: [],
      tools: web ? ["WebSearch"] : [],
      // Only list allowedTools for search: an empty list also blocks the SDK's structured-output tool.
      ...(web && { allowedTools: ["WebSearch"] }),
      persistSession: false,
      maxTurns: web ? 6 : schema ? 3 : 1,
      ...(schema && { outputFormat: { type: "json_schema", schema } }),
    },
  })) {
    if (m.type !== "result") continue;
    if (m.subtype !== "success") throw new Error(`Claude failed: ${m.subtype}`);
    return schema ? JSON.stringify(m.structured_output) : m.result;
  }
  throw new Error("Claude returned no result");
}

const transcript = (turns: Turn[]) =>
  turns.map((t) => `${t.role === "user" ? "User" : "Assistant"}: ${t.text}`).join("\n\n") +
  "\n\nReply to the last user message as the assistant. Do not prefix your reply with a speaker label.";

export class GeminiTimeout extends Error {
  constructor(ms: number) {
    super(`Gemini took longer than ${ms} ms.`);
  }
}

export const GEMINI_FAST = "gemini-flash-lite-latest";
export const GEMINI_SMART = "gemini-flash-latest";

type Part = { text: string } | { inlineData: { mimeType: string; data: string } };

/** Gemini generateContent. `search` turns on Google Search grounding. */
export async function gemini(
  input: string | Part[] | Turn[],
  { model = GEMINI_FAST, system, json, search, timeout }: { model?: string; system?: string; json?: boolean; search?: boolean; timeout?: number } = {},
): Promise<string> {
  const contents =
    typeof input === "string"
      ? [{ role: "user", parts: [{ text: input }] }]
      : "role" in input[0]
        ? (input as Turn[]).map((t) => ({ role: t.role === "user" ? "user" : "model", parts: [{ text: t.text }] }))
        : [{ role: "user", parts: input }];
  // Gemini answers 429/503 when busy: retry twice with backoff before giving up.
  let r: Response | undefined;
  for (let attempt = 0; attempt < 3; attempt++) {
    if (attempt) await new Promise((ok) => setTimeout(ok, attempt * 1200));
    r = await geminiFetch(model, contents, system, json, search, timeout);
    if (![429, 500, 503].includes(r.status) || (search && r.status === 429)) break; // a search-grounding 429 is a spent quota, not a busy moment
  }
  const j = await r!.json();
  if (!r!.ok) throw new Error(`Gemini ${r!.status}: ${j.error?.message ?? "request failed"}`);
  const parts: { text?: string; thought?: boolean }[] = j.candidates?.[0]?.content?.parts ?? [];
  return parts.filter((p) => !p.thought).map((p) => p.text ?? "").join("").trim();
}

function geminiFetch(model: string, contents: unknown, system?: string, json?: boolean, search?: boolean, timeout?: number) {
  return fetch(`https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent`, {
    method: "POST",
    headers: { "x-goog-api-key": process.env.GEMINI_API_KEY ?? "", "content-type": "application/json" },
    body: JSON.stringify({
      contents,
      ...(system && { systemInstruction: { parts: [{ text: system }] } }),
      ...(search && { tools: [{ google_search: {} }] }),
      generationConfig: { ...(json && { responseMimeType: "application/json" }) },
    }),
    ...(timeout && { signal: AbortSignal.timeout(timeout) }),
  }).catch((e) => {
    throw e?.name === "TimeoutError" ? new GeminiTimeout(timeout!) : e;
  });
}

/** Image or PDF (as a data: URL) to plain text with Gemini, since Jev reads text only. */
export async function transcribe(dataUrl: string, instruction = "Transcribe all text in this file exactly as written. Output only the text.") {
  const m = /^data:((?:image\/(?:png|jpeg|webp|gif))|application\/pdf);base64,(.+)$/.exec(dataUrl);
  if (!m) return null;
  return gemini([{ inlineData: { mimeType: m[1], data: m[2] } }, { text: instruction }]);
}

/**
 * Groq's hosted open models (OpenAI-compatible API) with a strict JSON schema; ~0.3–1 s.
 * Env: GROQ_API_KEY, GROQ_TEXT_MODEL (default qwen/qwen3.8-27b, which beat gpt-oss-20b/120b at field values).
 */
export async function groq(prompt: string, system: string, schema: Record<string, unknown>, timeout = 4000): Promise<string> {
  if (!process.env.GROQ_API_KEY) throw new Error("GROQ_API_KEY is not set");
  const model = process.env.GROQ_TEXT_MODEL ?? "qwen/qwen3.8-27b";
  const r = await fetch("https://api.groq.com/openai/v1/chat/completions", {
    method: "POST",
    headers: { "content-type": "application/json", authorization: `Bearer ${process.env.GROQ_API_KEY}` },
    body: JSON.stringify({
      model,
      temperature: 0,
      ...(model.startsWith("openai/") && { reasoning_effort: "low" }),
      response_format: { type: "json_schema", json_schema: { name: "out", strict: true, schema: { ...schema, additionalProperties: false } } },
      messages: [
        { role: "system", content: system },
        { role: "user", content: prompt },
      ],
    }),
    signal: AbortSignal.timeout(timeout),
  });
  if (!r.ok) throw new Error(`Groq ${r.status}`);
  return (await r.json()).choices?.[0]?.message?.content ?? "";
}

/**
 * A local model through Ollama's native API (free, on this Mac). JSON-schema output, thinking off.
 * Env: OLLAMA_URL (default http://localhost:11434), LOCAL_TEXT_MODEL (default qwen3:4b).
 */
export async function local(prompt: string, system: string, schema: Record<string, unknown>, timeout = 4000): Promise<string> {
  const r = await fetch(`${process.env.OLLAMA_URL ?? "http://localhost:11434"}/api/chat`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      model: process.env.LOCAL_TEXT_MODEL ?? "qwen3:4b",
      stream: false,
      think: false,
      keep_alive: "30m", // stay loaded, so later calls skip the model load
      format: schema,
      options: { temperature: 0 },
      messages: [{ role: "system", content: system }, { role: "user", content: prompt }],
    }),
    signal: AbortSignal.timeout(timeout),
  });
  if (!r.ok) throw new Error(`Local model ${r.status}`);
  return (await r.json()).message?.content ?? "";
}

/**
 * Speech to text: local whisper.cpp first (large-v3-turbo, Metal, ~0.55 s; audio never leaves the Mac),
 * then Groq's hosted whisper-large-v3-turbo. Takes 16 kHz mono WAV. The local server is started on first
 * use and kept running, like Ollama. `-ac 768` (a 15 s window) halves latency; 512 repeats
 * phrases on 11 s clips, so clips are capped at 15 s.
 * Env: WHISPER_URL (default http://127.0.0.1:8178), WHISPER_MODEL (path to a ggml model), WHISPER_LANG (default en; auto detection costs ~1 s), GROQ_API_KEY.
 */
const WHISPER_URL = process.env.WHISPER_URL ?? "http://127.0.0.1:8178";
// Default: this repo's data/whisper, else the copy Jev Lab already downloaded next door.
const WHISPER_FILE = "ggml-large-v3-turbo-q5_0.bin";
const WHISPER_MODEL = process.env.WHISPER_MODEL ?? [join(import.meta.dirname, "..", "..", "data", "whisper", WHISPER_FILE), join(import.meta.dirname, "..", "..", "..", "data", "whisper", WHISPER_FILE)].find((p) => existsSync(p)) ?? "";
let whisperBoot: Promise<void> | null = null;

async function localWhisper(wav: Buffer, prompt: string) {
  const post = () => {
    const form = new FormData();
    form.append("file", new Blob([new Uint8Array(wav)], { type: "audio/wav" }), "speech.wav");
    form.append("response_format", "json");
    form.append("temperature", "0");
    if (prompt) form.append("prompt", prompt);
    return fetch(`${WHISPER_URL}/inference`, { method: "POST", body: form, signal: AbortSignal.timeout(15_000) });
  };
  const r = await post().catch(async (e) => {
    if (!/ECONNREFUSED/.test(String(e.cause?.code ?? e)) || !existsSync(WHISPER_MODEL)) throw e;
    whisperBoot ??= (async () => {
      const port = new URL(WHISPER_URL).port || "8178";
      spawn("whisper-server", ["-m", WHISPER_MODEL, "--port", port, "-nt", "-l", process.env.WHISPER_LANG ?? "en", "-ac", "768"], { stdio: "ignore", detached: true }).on("error", () => {}).unref();
      for (let i = 0; i < 60; i++) {
        if (await fetch(WHISPER_URL).then(() => true, () => false)) return;
        await new Promise((s) => setTimeout(s, 500));
      }
    })().finally(() => (whisperBoot = null));
    await whisperBoot;
    return post();
  });
  if (!r.ok) throw new Error(`whisper.cpp ${r.status}`);
  return String((await r.json()).text ?? "");
}

async function groqWhisper(wav: Buffer, prompt: string) {
  if (!process.env.GROQ_API_KEY) throw new Error("GROQ_API_KEY is not set");
  const form = new FormData();
  form.append("file", new Blob([new Uint8Array(wav)], { type: "audio/wav" }), "speech.wav");
  form.append("model", "whisper-large-v3-turbo");
  form.append("temperature", "0");
  if (prompt) form.append("prompt", prompt);
  const r = await fetch("https://api.groq.com/openai/v1/audio/transcriptions", {
    method: "POST", headers: { authorization: `Bearer ${process.env.GROQ_API_KEY}` }, body: form, signal: AbortSignal.timeout(10_000),
  });
  if (!r.ok) throw new Error(`Groq Whisper ${r.status}`);
  return String((await r.json()).text ?? "");
}

/** `prompt` biases spelling (site names, jargon). Returns the text and which engine produced it. */
export async function whisper(wav: Buffer, prompt = ""): Promise<{ text: string; by: "local" | "groq" }> {
  try {
    return { text: (await localWhisper(wav, prompt)).trim(), by: "local" };
  } catch {
    return { text: (await groqWhisper(wav, prompt)).trim(), by: "groq" };
  }
}
