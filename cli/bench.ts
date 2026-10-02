// Pilot benchmark: real tasks on live websites, each checked in code against what the answer must
// contain. `npm run pilot-bench` prints a table and saves data/browser/bench.json.
import { mkdir, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { setTimeout as sleep } from "node:timers/promises";
import { approve, progress, start } from "../engine/browser.ts";

type Case = { goal: string; url?: string; expect: RegExp; approveOn?: RegExp };
const CASES: Case[] = [
  { goal: "What is the latest LTS version of Node.js?", expect: /LTS/ },
  { goal: "On Wikipedia, find the population of Tokyo", url: "https://en.wikipedia.org", expect: /\d{1,3}(,\d{3})+|\d+(\.\d+)? million/ },
  { goal: "Find the price of the Raspberry Pi 5 8GB on adafruit.com", expect: /\$\d+/ },
  { goal: "How many stars does the anthropics/claude-code repository have on GitHub?", expect: /\d+(\.\d+)?k/i },
  { goal: "Open the comments of the top story on Hacker News", url: "https://news.ycombinator.com", expect: /./ },
  { goal: "What is the capital of Australia according to Wikipedia?", expect: /Canberra/ },
  { goal: "Find the latest Python version on python.org", expect: /Python 3\.\d+/ },
  { goal: "Who wrote the book The Pragmatic Programmer? Use Wikipedia", expect: /Hunt|Thomas/ },
  { goal: "On MDN, find what Array.prototype.at() returns", expect: /item|element|undefined/i },
  { goal: "Find the weekly downloads of the react package on npmjs.com", expect: /\d{1,3}(,\d{3})+/ },
  { goal: "What does the word serendipity mean? Check Wiktionary", expect: /fortun|chance|luck|accident/i },
  {
    goal: "Find one-way flights from Zurich to London on December 15, 2026, for one adult in economy. Stop when matching flight options are visible. Do not select or book a flight.",
    url: "https://www.google.com/travel/flights?hl=en",
    expect: /Nonstop|\d+ hr|\$\d+/,
  },
  {
    goal: "Fill the pizza order form with customer name Ana, a large pizza with mushrooms and onion, and submit it",
    url: "https://httpbin.org/forms/post",
    expect: /Ana/,
    approveOn: /Submit order/i, // a test form, so the benchmark approves its submit button
  },
];

const results = [];
for (const c of CASES) {
  const { id } = await start({ goal: c.goal, url: c.url });
  let r = await progress({ id });
  const t0 = Date.now();
  while ((r.status === "running" || r.status === "waiting") && Date.now() - t0 < 120_000) {
    if (r.status === "waiting" && r.pending) await approve({ id, ok: Boolean(c.approveOn?.test(r.pending.label)) });
    await sleep(300);
    r = await progress({ id });
  }
  const text = (r.answer?.lines ?? []).join(" ");
  const pass = r.status === "done" && c.expect.test(text);
  const row = { goal: c.goal, pass, status: r.status, steps: r.total, seconds: +(r.elapsed_ms / 1000).toFixed(1), usd: r.usage.usd, answer: text.slice(0, 160) };
  results.push(row);
  console.log(`${pass ? "PASS" : "FAIL"}  ${row.steps} steps  ${row.seconds}s  $${row.usd.toFixed(5)}  ${c.goal}\n      ${row.status}: ${row.answer}`);
}

const passed = results.filter((r) => r.pass);
const summary = {
  ran: new Date().toISOString(),
  tasks: results.length,
  passed: passed.length,
  median_seconds: results.map((r) => r.seconds).sort((a, b) => a - b)[Math.floor(results.length / 2)],
  avg_steps: +(results.reduce((s, r) => s + r.steps, 0) / results.length).toFixed(1),
  total_usd: results.reduce((s, r) => s + r.usd, 0),
  results,
};
await mkdir(join(import.meta.dirname, "..", "data", "browser"), { recursive: true });
await writeFile(join(import.meta.dirname, "..", "data", "browser", "bench.json"), JSON.stringify(summary, null, 2));
console.log(`\n${summary.passed}/${summary.tasks} passed, median ${summary.median_seconds}s, ${summary.avg_steps} steps on average, $${summary.total_usd.toFixed(4)} in total`);
process.exit(0);
