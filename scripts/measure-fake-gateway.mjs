import crypto from "node:crypto";
import { execFile } from "node:child_process";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { createInterface } from "node:readline";
import { promisify } from "node:util";

const [helperPath] = process.argv.slice(2);
if (!helperPath) process.exit(64);
const execFileAsync = promisify(execFile);
const child = spawn(process.execPath, [helperPath, "qualification"], {
  stdio: ["pipe", "pipe", "ignore"],
  env: { LANG: "en_US.UTF-8", LC_ALL: "en_US.UTF-8" },
});
const lines = createInterface({ input: child.stdout, crlfDelay: Infinity });
const iterator = lines[Symbol.asyncIterator]();
const ready = JSON.parse((await iterator.next()).value);
if (ready.type !== "gateway.ready") throw new Error("helper not ready");

const requestId = crypto.randomUUID();
const turnId = crypto.randomUUID();
child.stdin.write(`${JSON.stringify({
  protocol: "miller.gateway",
  version: 1,
  type: "reasoning.start",
  session_id: ready.session_id,
  request_id: requestId,
  conversation_id: crypto.randomUUID(),
  turn_id: turnId,
  generation: 1,
  provider_profile: {
    kind: "openai_compatible",
    base_url: "http://127.0.0.1:1/v1",
    model: "synthetic-model",
    credential_ref: crypto.randomUUID(),
  },
  context: [],
  user_text: "synthetic measurement",
  tools: [],
})}\n`);

let active = false;
while (!active) {
  const next = await iterator.next();
  if (next.done) throw new Error("helper ended before active measurement");
  const record = JSON.parse(next.value);
  active = record.type === "reasoning.text_delta";
}
const { stdout } = await execFileAsync("/bin/ps", ["-o", "rss=", "-p", String(child.pid)]);
const rss = Number.parseInt(stdout.trim(), 10);
if (!Number.isSafeInteger(rss) || rss <= 0) throw new Error("invalid RSS");

child.stdin.write(`${JSON.stringify({
  protocol: "miller.gateway",
  version: 1,
  type: "reasoning.cancel",
  session_id: ready.session_id,
  request_id: crypto.randomUUID(),
  turn_id: turnId,
  target_generation: 1,
})}\n`);
let stopped = false;
while (!stopped) {
  const next = await iterator.next();
  if (next.done) throw new Error("helper ended before stop");
  stopped = JSON.parse(next.value).type === "reasoning.stopped";
}
child.stdin.end();
const [code] = await once(child, "exit");
if (code !== 0) throw new Error(`helper exit ${code}`);
process.stdout.write(`synthetic_active_gateway_rss_kib=${rss}\n`);
