// Quick commands: curated AppleScript actions (ported from aloud-tauri's native catalogue) that do a
// common request in one ~0.3 s call instead of clicking through an app. One Jev request picks the
// command (or "none" → the UI loop in mac.ts); a text model fills its arguments; risky ones need approval.
//
// Curated, not a generic "run this AppleScript": an approval prompt is only meaningful when the person
// can read what will happen, and each row here has a plain label and a fixed script.
import { execFile } from "node:child_process";
import { ask } from "./lib/jev.ts";
import { claude, groq } from "./lib/llm.ts";

type Param = { name: string; type: "string" | "integer"; description: string; enum?: string[]; required?: boolean };
type Quick = {
  id: string;
  what: string; // what the user says, for Jev
  app?: string; // the app it controls, for the Automation-permission message
  risky?: boolean; // sends, quits or deletes: ask first
  params: Param[];
  run: (a: Record<string, any>) => Promise<string>;
};

const esc = (s: unknown) => String(s ?? "").replace(/\\/g, "\\\\").replace(/"/g, '\\"');

/** osascript with a hard timeout (a modal dialog in the target app hangs it) and a readable -1743. */
function osa(source: string, app = "the app", timeout = 20_000): Promise<string> {
  return new Promise((resolve, reject) => {
    execFile("osascript", ["-e", source], { timeout }, (err, stdout, stderr) => {
      if (/-1743|-1712/.test(stderr)) return reject(new Error(`Allow control of ${app}: System Settings → Privacy & Security → Automation, then say it again.`));
      if (err) return reject(new Error((stderr || err.message).trim().split("\n")[0]));
      resolve(stdout.trim());
    });
  });
}

const sh = (cmd: string, args: string[]) =>
  new Promise<string>((resolve, reject) => execFile(cmd, args, { timeout: 15_000 }, (err, out, e) => (err ? reject(new Error((e || err.message).trim())) : resolve(out.trim()))));

const NOW = (app: string) => `tell application "${app}"
  if player state is stopped then return "nothing playing"
  return (get name of current track) & " — " & (get artist of current track)
end tell`;

export const QUICK: Quick[] = [
  { id: "open_app", what: "Open or switch to an app by name", params: [{ name: "name", type: "string", description: "App name as installed, e.g. Safari, System Settings", required: true }],
    run: async (a) => (await sh("open", ["-a", String(a.name)]), `Opened ${a.name}.`) },
  { id: "quit_app", what: "Quit an app by name", risky: true, params: [{ name: "name", type: "string", description: "App name", required: true }],
    run: async (a) => (await osa(`tell application "${esc(a.name)}" to quit`, a.name), `Quit ${a.name}.`) },
  { id: "music_play", what: "Play or resume music in Apple Music, optionally a song, album or artist from the library", app: "Music",
    params: [{ name: "query", type: "string", description: "Song, album or artist to play; empty to resume" }],
    run: async (a) => {
      if (!a.query) return (await osa(`tell application "Music" to play`, "Music"), "Playing.");
      const q = esc(a.query);
      const out = await osa(`tell application "Music"
  set hits to (every track of library playlist 1 whose name contains "${q}" or artist contains "${q}")
  if hits is {} then return "none"
  play (item 1 of hits)
  return (get name of current track) & " — " & (get artist of current track)
end tell`, "Music");
      return out === "none" ? `Nothing in your Music library matched “${a.query}”.` : `Playing ${out}.`;
    } },
  { id: "music_pause", what: "Pause Apple Music", app: "Music", params: [], run: async () => (await osa(`tell application "Music" to pause`, "Music"), "Paused Music.") },
  { id: "music_next", what: "Skip to the next track in Apple Music", app: "Music", params: [],
    run: async () => `Now playing ${await osa(`tell application "Music"\n next track\n return (get name of current track) & " — " & (get artist of current track)\nend tell`, "Music")}.` },
  { id: "music_now_playing", what: "Say what song is playing in Apple Music", app: "Music", params: [], run: async () => await osa(NOW("Music"), "Music") },
  { id: "spotify_playpause", what: "Play or pause Spotify", app: "Spotify", params: [], run: async () => (await osa(`tell application "Spotify" to playpause`, "Spotify"), "Toggled Spotify.") },
  { id: "spotify_next", what: "Skip to the next track in Spotify", app: "Spotify", params: [],
    run: async () => `Now playing ${await osa(`tell application "Spotify"\n next track\n delay 0.3\n return (name of current track) & " — " & (artist of current track)\nend tell`, "Spotify")}.` },
  { id: "spotify_now_playing", what: "Say what song is playing in Spotify", app: "Spotify", params: [], run: async () => await osa(NOW("Spotify"), "Spotify") },
  { id: "reminder_add", what: "Add a reminder or to-do in Reminders", app: "Reminders",
    params: [{ name: "text", type: "string", description: "The reminder, in the user's words", required: true }, { name: "list", type: "string", description: "A named list if the user said one, else empty" }],
    run: async (a) => {
      const where = a.list ? ` at end of list "${esc(a.list)}"` : "";
      await osa(`tell application "Reminders" to make new reminder${where} with properties {name:"${esc(a.text)}"}`, "Reminders");
      return `Added the reminder “${a.text}”${a.list ? ` to ${a.list}` : ""}.`;
    } },
  { id: "note_add", what: "Write a line into a note in Notes (created if missing)", app: "Notes",
    params: [{ name: "title", type: "string", description: "The note's title; if none was said, a short title from the content", required: true }, { name: "text", type: "string", description: "The text to add, in the user's words", required: true }],
    run: async (a) => {
      await osa(`tell application "Notes"
  if not (exists note "${esc(a.title)}") then
    make new note with properties {name:"${esc(a.title)}", body:"${esc(a.text)}"}
  else
    set n to note "${esc(a.title)}"
    set body of n to (body of n) & "<br>${esc(a.text)}"
  end if
end tell`, "Notes");
      return `Added to the note “${a.title}”.`;
    } },
  { id: "message_send", what: "Send an iMessage or SMS to a phone number or email address", app: "Messages", risky: true,
    params: [{ name: "to", type: "string", description: "Full phone number or email handle exactly as said; empty if only a name was given", required: true }, { name: "text", type: "string", description: "The message, in the user's words", required: true }],
    run: async (a) => {
      if (!/[@+\d]/.test(String(a.to))) throw new Error("Say the phone number or email to send to; names aren't looked up yet.");
      await osa(`tell application "Messages"
  set svc to 1st service whose service type = iMessage
  send "${esc(a.text)}" to buddy "${esc(a.to)}" of svc
end tell`, "Messages");
      return `Sent to ${a.to}.`;
    } },
  { id: "volume_set", what: "Set the Mac's output volume, mute or unmute", params: [{ name: "level", type: "integer", description: "0 to 100; 0 to mute", required: true }],
    run: async (a) => {
      const level = Math.max(0, Math.min(100, Math.round(Number(a.level) || 0)));
      await osa(`set volume output volume ${level}`, "System Events");
      return `Volume ${level}.`;
    } },
  { id: "window_arrange", what: "Move the front window: fill the screen, left or right half, a quarter, or center",
    params: [{ name: "position", type: "string", enum: ["full", "left", "right", "top-left", "top-right", "bottom-left", "bottom-right", "center"], description: "Where to put it", required: true }],
    run: async (a) => {
      const [, , sw, sh2] = (await osa(`tell application "Finder" to get bounds of window of desktop`, "Finder")).split(", ").map(Number);
      const top = 25, h = sh2 - top;
      const box: Record<string, number[]> = {
        full: [0, top, sw, h], left: [0, top, sw / 2, h], right: [sw / 2, top, sw / 2, h],
        "top-left": [0, top, sw / 2, h / 2], "top-right": [sw / 2, top, sw / 2, h / 2],
        "bottom-left": [0, top + h / 2, sw / 2, h / 2], "bottom-right": [sw / 2, top + h / 2, sw / 2, h / 2],
        center: [sw / 6, top + h / 6, (sw * 2) / 3, (h * 2) / 3],
      };
      const [x, y, w, hh] = (box[a.position] ?? box.full).map(Math.round);
      await osa(`tell application "System Events"
  set p to first application process whose frontmost is true
  tell front window of p
    set position to {${x}, ${y}}
    set size to {${w}, ${hh}}
  end tell
end tell`, "System Events");
      return `Moved the window (${a.position}).`;
    } },
  { id: "finder_search", what: "Find files on the Mac by name or content (Spotlight)",
    params: [{ name: "query", type: "string", description: "Words to search for", required: true }],
    run: async (a) => {
      const hits = (await sh("mdfind", ["-onlyin", process.env.HOME ?? "/", String(a.query)])).split("\n").filter(Boolean);
      return hits.length ? `Found ${hits.length}:\n${hits.slice(0, 8).join("\n")}` : `No files matched “${a.query}”.`;
    } },
  { id: "folder_open", what: "Open a folder in Finder (Downloads, Desktop, Documents, Applications, Home)",
    params: [{ name: "folder", type: "string", enum: ["Downloads", "Desktop", "Documents", "Applications", "Home"], description: "Which folder", required: true }],
    run: async (a) => {
      const path = a.folder === "Applications" ? "/Applications" : a.folder === "Home" ? process.env.HOME! : `${process.env.HOME}/${a.folder}`;
      await sh("open", [path]);
      return `Opened ${a.folder}.`;
    } },
  { id: "shortcut_run", what: "Run one of the user's Shortcuts by name", risky: true,
    params: [{ name: "name", type: "string", description: "The shortcut's name", required: true }],
    run: async (a) => (await sh("shortcuts", ["run", String(a.name)]), `Ran the shortcut “${a.name}”.`) },
];

const PICK = 0.6; // below this the request goes to the UI loop instead

/** Jev picks one quick command for the request, or "none". */
export async function route(goal: string) {
  const criteria: Record<string, string> = Object.fromEntries(QUICK.map((q) => [q.id, q.what]));
  criteria.none = "None of these fits exactly: the request needs clicking through an app's own screens, or several steps";
  const a: any = await ask({ request: goal }, { command: { type: "choice", instructions: "Which single built-in command does exactly what `request` asks, with nothing left over?", criteria } }, "quick route");
  const id = a.command.choice as string;
  const q = QUICK.find((x) => x.id === id);
  return { quick: q && a.command.confidence >= PICK ? q : null, id, confidence: a.command.confidence as number, probabilities: a.command.probabilities as Record<string, number> };
}

const ARGS = `Fill the arguments of a Mac command from the user's request. Return JSON with exactly the listed keys.
Copy names, numbers and text from the request; never invent a recipient, file or list the user didn't say.
Use an empty string for an optional value the user didn't give.`;

/** A text model fills the command's arguments (Groq, then Claude); enums and integers are checked here. */
export async function args(q: Quick, goal: string) {
  if (!q.params.length) return {};
  const schema = {
    type: "object",
    properties: Object.fromEntries(q.params.map((p) => [p.name, { type: p.type, description: p.description, ...(p.enum && { enum: p.enum }) }])),
    required: q.params.map((p) => p.name),
  };
  const prompt = JSON.stringify({ request: goal, command: q.what });
  for (const call of [() => groq(prompt, ARGS, schema), () => claude(prompt, ARGS, schema)]) {
    try {
      const a = JSON.parse(await call());
      const ok = q.params.every((p) => !p.required || (a[p.name] !== undefined && a[p.name] !== "")) && q.params.every((p) => !p.enum || !a[p.name] || p.enum.includes(a[p.name]));
      if (ok) return a as Record<string, any>;
    } catch {}
  }
  throw new Error(`Couldn't work out the details for “${q.what}”. Say it with the name, text or number.`);
}
