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
- `engine/mac.ts` — Mac apps: quick commands first (`engine/quick.ts`, curated AppleScript ported from
  aloud), else the step loop over accessibility reads from `axd`: one Jev request per step (operation, a
  target per operation, menu path, risk, requirements), act, read again.
- `shell/` — Swift menu-bar app, plus `axd`, the accessibility helper (in-process AX reads and actions,
  adapted from Computah, MIT). Cua Driver (`engine/lib/cua.ts`) stays available as a slower fallback.

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
- Milestone 2 (Swift shell): `shell/build.sh` → `shell/dist/Voice Mac.app`, signed with your Apple Development
  certificate (or `SIGN_IDENTITY`) so Accessibility/Microphone grants survive rebuilds. A black pill wraps the
  notch: grey dot idle, red dot + live mic bars while you hold ⌥Space, spinner while working, green when done.
  Click it (or open the app again) for the card: what was heard, Jev's routing, steps, Yes/No approvals, the
  answer, "Use my Brave" and Stop.
  Test without a mic: `"shell/dist/Voice Mac.app/Contents/MacOS/VoiceMac" --utterance file.wav`.
- Milestone 3 (Mac apps, in progress): one voice front door routes to web or Mac. Quick commands (open/quit
  app, Music, Spotify, reminders, notes, messages, volume, window layout, Spotlight, folders, Shortcuts) route
  in ~0.15 s and run in ~0.1–0.5 s. The step loop through axd: Calculator "12 × 3" in 2.8 s (was 21 s through
  Cua Driver, ~1.1 s per click); actions take 3–35 ms. The app needs Accessibility permission for axd.
