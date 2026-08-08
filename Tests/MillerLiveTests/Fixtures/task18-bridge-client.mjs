import { spawn } from "node:child_process";
import { createInterface } from "node:readline";
import { once } from "node:events";

const maximumDiagnosticBytes = 32 * 1024;

function boundedAppend(current, chunk) {
  const next = current + chunk;
  return next.length <= maximumDiagnosticBytes
    ? next
    : next.slice(0, maximumDiagnosticBytes);
}

function requiredEnvironment(environment, name) {
  const value = environment[name];
  if (!value || !value.startsWith("/") || value.includes("\0")) {
    throw new Error(`task18_missing_${name.toLowerCase()}`);
  }
  return value;
}

function sanitizeDiagnostic(value) {
  return value
    .replaceAll(process.cwd(), "<workspace>")
    .replaceAll(/\/Users\/[^\s]+/g, "<private-path>")
    .replaceAll(/MILLER_CAPABILITY_RPC_TOKEN=[^\s]+/g, "MILLER_CAPABILITY_RPC_TOKEN=<redacted>");
}

export async function callTask18Bridge(options = {}) {
  const environment = { ...process.env, ...(options.env ?? {}) };
  const bridge = requiredEnvironment(environment, "MILLER_TASK18_BRIDGE_PATH");
  const child = spawn(bridge, [], {
    cwd: environment.MILLER_TASK18_FIXTURE_ROOT ?? process.cwd(),
    env: { ...environment, LANG: "C", LC_ALL: "C" },
    stdio: ["pipe", "pipe", "pipe"],
  });
  let stderr = "";
  child.stderr.setEncoding("utf8");
  child.stderr.on("data", (chunk) => { stderr = boundedAppend(stderr, chunk); });
  const records = [];
  const input = createInterface({ input: child.stdout, crlfDelay: Infinity });
  input.on("line", (line) => {
    try {
      records.push(JSON.parse(line));
    } catch {
      records.push({ parseError: true });
    }
  });
  const exit = once(child, "exit");
  let nextID = 1;
  const waitFor = async (id) => {
    const deadline = Date.now() + 10_000;
    while (Date.now() < deadline) {
      const found = records.find((value) => value.id === id);
      if (found) return found;
      if (child.exitCode !== null) {
        throw new Error(`task18_bridge_exit_${child.exitCode}_${sanitizeDiagnostic(stderr)}`);
      }
      await new Promise((resolve) => setTimeout(resolve, 10));
    }
    throw new Error(`task18_bridge_timeout_${sanitizeDiagnostic(stderr)}`);
  };
  const send = (value) => child.stdin.write(JSON.stringify(value) + "\n");
  const request = async (method, params) => {
    const id = nextID;
    nextID += 1;
    send({ jsonrpc: "2.0", id, method, params });
    return waitFor(id);
  };
  try {
    const initialized = await request("initialize", {
      protocolVersion: "2025-06-18",
      capabilities: {},
      clientInfo: { name: "miller-task18-route", version: "0.1.1" },
    });
    if (initialized.error) throw new Error("task18_bridge_initialize_failed");
    send({ jsonrpc: "2.0", method: "notifications/initialized" });
    const listed = await request("tools/list", {});
    const tools = listed.result?.tools ?? [];
    const matches = tools.filter((value) => value.name?.endsWith("_lookup_note"));
    if (matches.length !== 1) throw new Error("task18_bridge_tool_count");
    const tool = matches[0];
    if (!tool.name.endsWith("_lookup_note") || tool.annotations?.readOnlyHint !== true) {
      throw new Error("task18_bridge_tool_identity");
    }
    const called = await request("tools/call", {
      name: tool.name,
      arguments: {},
    });
    const result = called.result?.content?.[0]?.text;
    if (called.result?.isError !== false || result !== "lookup_note:ok") {
      throw new Error("task18_bridge_result_identity");
    }
    return { result, toolName: tool.name };
  } finally {
    input.close();
    child.stdin.end();
    const finished = await Promise.race([
      exit.then(([code, signal]) => ({ code, signal })),
      new Promise((resolve) => setTimeout(() => resolve(null), 2_000)),
    ]);
    if (finished === null && child.exitCode === null) {
      child.kill("SIGTERM");
      await Promise.race([exit, new Promise((resolve) => setTimeout(resolve, 2_000))]);
    }
    if (child.exitCode !== 0 && child.signalCode === null) {
      throw new Error(`task18_bridge_exit_${child.exitCode}_${sanitizeDiagnostic(stderr)}`);
    }
  }
}
