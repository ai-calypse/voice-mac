// axd client: the Swift accessibility helper (shell/Sources/axd), kept running and spoken to in JSON
// lines. In-process AX calls take milliseconds; Cua Driver (lib/cua.ts) remains the fallback.
import { spawn, type ChildProcessByStdio } from "node:child_process";
import type { Readable, Writable } from "node:stream";
import { existsSync } from "node:fs";
import { join } from "node:path";
import { createInterface } from "node:readline";

const CANDIDATES = [process.env.VOICE_MAC_AXD, join(import.meta.dirname, "..", "..", "shell", ".build", "release", "axd")].filter(Boolean) as string[];
let proc: ChildProcessByStdio<Writable, Readable, null> | null = null;
let nextId = 1;
const waiting = new Map<number, { resolve: (v: any) => void; reject: (e: Error) => void }>();

function start() {
  const bin = CANDIDATES.find((p) => existsSync(p));
  if (!bin) throw new Error("axd isn't built: run shell/build.sh");
  const child = spawn(bin, [], { stdio: ["pipe", "pipe", "inherit"] });
  proc = child;
  createInterface({ input: child.stdout }).on("line", (line) => {
    let msg: any;
    try {
      msg = JSON.parse(line);
    } catch {
      return;
    }
    const w = waiting.get(msg.id);
    if (!w) return;
    waiting.delete(msg.id);
    msg.error ? w.reject(new Error(msg.error)) : w.resolve(msg.result);
  });
  child.on("exit", () => {
    proc = null;
    for (const w of waiting.values()) w.reject(new Error("axd exited"));
    waiting.clear();
  });
}

export function ax<T = any>(cmd: string, args: Record<string, unknown> = {}, timeout = 15_000): Promise<T> {
  if (!proc) start();
  const id = nextId++;
  return new Promise<T>((resolve, reject) => {
    const timer = setTimeout(() => (waiting.delete(id), reject(new Error(`axd ${cmd} timed out`))), timeout);
    waiting.set(id, { resolve: (v) => (clearTimeout(timer), resolve(v)), reject: (e) => (clearTimeout(timer), reject(e)) });
    proc!.stdin.write(JSON.stringify({ id, cmd, ...args }) + "\n");
  });
}
