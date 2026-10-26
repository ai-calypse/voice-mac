import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createInterface } from "node:readline";
import { once } from "node:events";
import test from "node:test";

test("stdio transport survives malformed requests and dispatches only registered methods", { timeout: 15000 }, async (t) => {
  const engine = spawn(process.execPath, ["engine/rpc.ts"], { stdio: ["pipe", "pipe", "pipe"] });
  t.after(() => engine.kill());
  let stderr = "";
  engine.stderr.on("data", (chunk) => { stderr += chunk; });
  const lines = createInterface({ input: engine.stdout })[Symbol.asyncIterator]();
  const read = async () => {
    const line = await lines.next();
    assert.equal(line.done, false, stderr);
    return JSON.parse(line.value);
  };
  assert.equal((await read()).event, "ready");
  const request = async (line) => { engine.stdin.write(line + "\n"); return read(); };
  assert.equal((await request("broken JSON")).error.message, "Not JSON.");
  for (const invalid of ["null", "[]", "42", '{}', '{"method":12}']) {
    assert.equal((await request(invalid)).error.message, "Expected an object with a method string.");
  }
  for (const method of ["missing", "toString", "constructor", "__proto__"]) {
    const response = await request(JSON.stringify({ id: 2, method }));
    assert.equal(response.id, 2);
    assert.match(response.error.message, /Unknown method/);
  }
  assert.deepEqual(await request('{"id":3,"method":"ping"}'), { id: 3, result: { ok: true } });
  const exited = once(engine, "exit");
  engine.stdin.end();
  const [code] = await exited;
  assert.equal(code, 0, stderr);
});
