// Offline checks for Pilot's action space and answer validation (ported from jev-ultrafast's tests).
import assert from "node:assert/strict";
import { actionSpace, namedSite, validateChoice } from "./browser.ts";

const actions = [
  { id: "e1", kind: "fill", node: 1, role: "combobox", label: "Where from?", value: "" },
  { id: "e2", kind: "click", node: 1, role: "combobox", label: "Open Where from?", value: "" },
  { id: "e3", kind: "select", node: 2, role: "combobox", label: "Class → Business", value: "b", current_value: "Economy" },
  { id: "e4", kind: "click", node: 3, role: "checkbox", label: "Nonstop", checked: "false" },
  { id: "scroll_down", kind: "scroll", label: "Scroll down" },
  { id: "wait", kind: "wait", label: "Wait for the page to update" },
];
const { elements, targets, controls } = actionSpace(actions);
assert.equal(elements.length, 3, "one index per DOM node, even when it can be typed into and clicked");
assert.deepEqual(elements[0].operations, ["TYPE_TEXT", "CLICK"]);
assert.deepEqual(Object.keys(targets.SELECT), ["2:1"], "dropdown options carry an element:option index");
assert.equal(targets.CLICK["3"].id, "e4");
assert.deepEqual(Object.keys(controls), ["SCROLL_DOWN", "WAIT"]);

const ok = { choice: "a", confidence: 0.8, probabilities: { a: 0.9, b: 0.1 } };
assert.equal(validateChoice(ok, ["a", "b"]).choice, "a");
for (const bad of [
  { ...ok, choice: "c" },
  { ...ok, probabilities: { a: 0.9 } },
  { ...ok, probabilities: { a: 0.6, b: 0.6 } },
  { ...ok, choice: "b" },
  { ...ok, confidence: 2 },
]) assert.throws(() => validateChoice(bad, ["a", "b"]), /no action executed/);

assert.equal(namedSite("Who wrote The Pragmatic Programmer? Use Wikipedia"), "https://en.wikipedia.org/");
assert.equal(namedSite("On MDN, find what Array.prototype.at() returns"), "https://developer.mozilla.org/");
assert.equal(namedSite("What is the latest LTS version of Node.js?"), undefined);

// OPEN_URL stays on the current site or a site the goal names.
{
  const { allowedUrl } = await import("./browser.ts");
  const yt = "https://www.youtube.com/watch?v=abc";
  assert.equal(allowedUrl("https://www.youtube.com/watch?v=abc&t=600s", yt, "jump to 10:00"), true);
  assert.equal(allowedUrl("https://evil.example/phish", yt, "jump to 10:00"), false);
  assert.equal(allowedUrl("https://github.com/anthropics/claude-code", "https://search.brave.com/search?q=x", "stars of claude-code on GitHub"), true);
  assert.equal(allowedUrl("https://nodejs.org/en", "https://search.brave.com/search?q=x", "latest LTS on nodejs.org"), true);
  assert.equal(allowedUrl("javascript:alert(1)", yt, "x"), false);
}
