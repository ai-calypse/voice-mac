import { progress, start } from "./engine/mac.ts";
for (const goal of process.argv.slice(2)) {
  const { id } = await start({ goal });
  let p: any;
  do { await new Promise((r) => setTimeout(r, 200)); p = await progress({ id }); } while (p.status === "running" || p.status === "waiting");
  console.log("==", goal, "|", p.app, p.status, (p.elapsed_ms / 1000).toFixed(1) + "s", "$" + p.usage.usd.toFixed(4), p.error ?? "");
  for (const s of p.steps) console.log("  ", s.op, s.target?.label ?? "", s.text ? `“${s.text}”` : "", s.ms_jev + "+" + s.ms_act + "ms", s.note ?? "");
}
process.exit(0);
