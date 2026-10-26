# Voice Mac architecture

For system-design reasoning, alternatives, consistency boundaries, and change triggers, start with the
[architecture and tradeoff guide](../ARCHITECTURE.md). This document retains the detailed implementation/evidence reference.

## A small process boundary

The Swift shell owns microphone capture, the Option-Space shortcut, and the notch/card UI. It launches Node
with the repository as its working directory. The engine routes to browser or native execution and pushes task
updates back over stdout. The AX helper is a separate Swift executable; the engine keeps it running for native
accessibility reads/actions. Logs are written below ignored `data/`.

The browser loop maps observed page controls to a typed action space, asks Jev to choose, validates the choice,
executes it, and reads state again. Text writers and speech transcription use separate adapters. Native execution
tries curated commands before using the accessibility action loop. These paths share task progress and approvals.

## Protocol

One JSON object per line over stdio. Requests contain `id`, `method`, and optional `params`. Replies contain
`id` plus `result` or `error`. This is not full JSON-RPC 2.0: no version marker, batch calls, or standard error codes.
Stdout is reserved for protocol data; stderr carries diagnostics.

| Method | Parameters | Behavior |
| --- | --- | --- |
| `ping` | `{}` | Returns `{ "ok": true }`; no provider call |
| `task.start` | `{ "goal": "...", "url": "...", "mine": false, "show": true }` | Starts browser execution |
| `mac.start` | `{ "goal": "..." }` | Starts native execution |
| `task.progress` | `{ "id": "...", "from": 0 }` | Returns steps and status; screenshots remain here |
| `task.approve` | `{ "id": "...", "ok": true }` | Resolves a pending approval |
| `task.stop` | `{ "id": "..." }` | Requests cancellation |
| `task.history` | `{}` | Returns browser task history |
| `utterance` | `{ "audio": "<base64 WAV>", "mine": false }` | Transcribes and routes speech |

The first line is an `event: "ready"` message listing methods. Long-running tasks emit `event: "task"`
updates until done, stuck, stopped, or errored. Native task IDs begin with `m-`. See
[the dispatcher](../engine/rpc.ts) for exact shapes and error handling. Tests exercise malformed input and
method dispatch through the real child process, then verify that a valid ping still succeeds.

## Configuration and trust boundaries

[`.env.example`](../.env.example) lists supported environment variables. Local whisper.cpp runs first when its
server/model is available, with hosted Groq transcription as a fallback. Text-generation fallbacks include Groq,
Ollama, Gemini, and the Claude Agent SDK depending on the code path; they are not all required to run offline checks.

Browser tasks can launch an isolated Playwright browser. Attaching an existing browser is an explicit `mine`
option and needs Chromium remote debugging; it gives the engine access to that browser's sessions. The app
is not sandboxed. Treat voice requests and page content as untrusted input and inspect approval prompts.
The current approval heuristics are defense in depth, not comprehensive authorization enforcement.

Microphone, Accessibility, and sometimes Automation permissions are macOS-controlled grants. Ad-hoc signatures
can lose stable permission identity across rebuilds. `shell/build.sh` stores absolute checkout/Node paths in
Info.plist, so a copied bundle is not a standalone distribution.

Local logs may hold request text, URLs, and action results. Model adapters can send task/page context or audio
to configured providers. Review this behavior before using private applications or recording a demo.

## Validation boundaries

Offline checks validate action mapping, probability/choice rejection, allowed URLs, and stdio robustness.
They do not establish end-to-end voice accuracy, task success on arbitrary websites, or safety for arbitrary
native actions. `npm run bench` performs live tasks and may call providers; it is excluded from CI.
No portable benchmark dataset is committed, so the README makes no live success-rate or latency claim.

## Provenance and licensing

The initial source comments/README attribute the browser loop to Jev Lab's Pilot and the browser-use
Jev implementation, curated AppleScript to Aloud, and accessibility-helper ideas to Computah (described there
as MIT). These descriptions record the original implementation's attribution; they are not a completed
third-party license audit. Before redistribution, identify exact upstream revisions, preserve required notices,
and choose an appropriate repository license. This repository currently grants no explicit license.
