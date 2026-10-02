# voice-mac

Talk to your Mac. One voice front door for native apps, the browser, taught routines, dictation and
meeting notes. TypeSafe's Jev picks every action (typed probabilities, ~0.2 s per step); code owns the
workflow, verifies each step, and asks before anything that buys, sends, deletes or signs in.

Plan: `~/.claude/plans/happy-snuggling-ocean.md` (milestones 1–6).

## Layout

- `engine/` — TypeScript engine, driven over stdio JSON-RPC (`engine/rpc.ts`).
  - `browser.ts` + `snapshot.js` — browser agent (copied from Jev Lab's Pilot, itself a port of
    browser-use/jev-ultrafast): one Jev request per step, your-Brave attach over CDP, open-address
    deep links, requirement checklist, repeat guard, risky-click approval, voice router.
  - `lib/jev.ts` — Jev client, throttle, cost tracing. `lib/llm.ts` — text writers (Groq → local
    Ollama → Gemini → Claude) and speech (local whisper.cpp → Groq Whisper).
- `cli/bench.ts` — 13 live browser tasks, each answer checked in code.
- `shell/` — Swift menu-bar app (milestone 2).

## Run

```bash
npm install
cp .env.example .env        # TYPESAFE_API_KEY, GROQ_API_KEY, GEMINI_API_KEY
npm run check               # offline checks
npm run bench               # live browser benchmark → data/browser/bench.json
npm run engine              # stdio JSON-RPC; try: {"id":1,"method":"ping"}
```

Speech runs on this Mac with whisper.cpp (`brew install whisper-cpp`) and the large-v3-turbo model
(`data/whisper/ggml-large-v3-turbo-q5_0.bin`, or Jev Lab's copy next door); the server starts on first use.

### Engine API (newline-delimited JSON)

| method | params | result |
|---|---|---|
| `task.start` | `{goal, url?, mine?, show?}` | `{id, start}`; then `{"event":"task", ...}` lines until it ends |
| `task.approve` / `task.stop` | `{id, ok?}` | `{ok}` |
| `task.progress` / `task.history` | `{id, from?}` / `{}` | step list with screenshots / past tasks |
| `utterance` | `{audio (base64 16 kHz WAV), live?, pending?, mine?}` | what was heard, Jev's routing, what was done |

## Status

- Milestone 1 (engine copy + RPC): browser bench 12/13 on the first run from this repo, median 3 s per task.
- Milestone 2 (Swift shell): `shell/build.sh` → `shell/dist/Voice Mac.app`. Hold ⌥Space to talk; a floating
  panel shows what was heard, Jev's routing, live steps, approvals and the answer. Menu: "Use my Brave".
  Test without a mic: `"shell/dist/Voice Mac.app/Contents/MacOS/VoiceMac" --utterance file.wav`.
