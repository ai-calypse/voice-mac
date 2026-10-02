// The Mac's hands and eyes: Cua Driver (trycua/cua) tools, called through its CLI against the running
// CuaDriver daemon, which holds the Accessibility + Screen Recording grants under its own identity.
import { execFile } from "node:child_process";
import { homedir } from "node:os";
import { join } from "node:path";

const BIN = process.env.CUA_DRIVER ?? join(homedir(), ".local", "bin", "cua-driver");
// Element tokens live in a driver session; every CLI call is a new transport, so all calls share one label.
const SESSION = "voice-mac";
const NO_SESSION = new Set(["list_apps", "list_windows", "check_permissions", "get_screen_size"]);

/** One driver tool call; resolves to its JSON result, rejects with the driver's message. */
export function cua<T = any>(tool: string, args: Record<string, unknown> = {}, timeout = 20_000): Promise<T> {
  const t0 = performance.now();
  return new Promise((resolve, reject) => {
    const full = NO_SESSION.has(tool) || "session" in args ? args : { ...args, session: SESSION };
    execFile(BIN, ["call", tool, JSON.stringify(full)], { timeout, maxBuffer: 64 * 1024 * 1024 }, (err, stdout, stderr) => {
      if (process.env.MAC_DEBUG) console.error(`cua ${tool} ${Math.round(performance.now() - t0)}ms`);
      const text = stdout.trim();
      try {
        const j = JSON.parse(text);
        if (j?.isError || j?.error) return reject(new Error(String(j.error?.message ?? j.error ?? j.content?.[0]?.text ?? "Cua Driver error")));
        if (j?.status === "refused") return reject(new Error(`${j.refusal?.code ?? "refused"}: ${j.refusal?.message ?? ""}`));
        return resolve((j.structuredContent ?? j) as T);
      } catch {
        reject(new Error((stderr || text || String(err?.message ?? "Cua Driver failed")).split("\n")[0]));
      }
    });
  });
}
