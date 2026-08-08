import { spawn } from "node:child_process";
import { createInterface } from "node:readline";
import { once } from "node:events";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";

const node = process.execPath;
const fixture = resolve(fileURLToPath(new URL("./read-only-mcp-server.mjs", import.meta.url)));

export async function callTask18ReadOnlyMCP({ root, auditPath, route }) {
  if (!["typed", "sideband", "pi"].includes(route)) throw new Error("invalid_task18_route");
  const child = spawn(node, [fixture], {
    cwd: root,
    env: {
      ...process.env,
      MILLER_MCP_FIXTURE_ROOT: root,
      MILLER_MCP_FIXTURE_AUDIT_PATH: auditPath,
      MILLER_MCP_FIXTURE_ROUTE: route,
    },
    stdio: ["pipe", "pipe", "ignore"],
  });
  const records = [];
  const input = createInterface({ input: child.stdout, crlfDelay: Infinity });
  input.on("line", (line) => records.push(JSON.parse(line)));
  const waitFor = async (predicate) => {
    const deadline = Date.now() + 5_000;
    while (Date.now() < deadline) {
      const found = records.find(predicate);
      if (found) return found;
      await new Promise((resolvePromise) => setTimeout(resolvePromise, 10));
    }
    throw new Error("task18_mcp_fixture_timeout");
  };
  const send = (value) => child.stdin.write(JSON.stringify(value) + "\n");
  try {
    send({
      jsonrpc: "2.0",
      id: 1,
      method: "initialize",
      params: { protocolVersion: "2025-06-18" },
    });
    await waitFor((value) => value.id === 1);
    send({ jsonrpc: "2.0", method: "notifications/initialized" });
    send({ jsonrpc: "2.0", id: 2, method: "tools/list", params: {} });
    const listed = await waitFor((value) => value.id === 2);
    if (!listed.result.tools.some((tool) => tool.name === "lookup_note")) {
      throw new Error("task18_mcp_tool_missing");
    }
    send({
      jsonrpc: "2.0",
      id: 3,
      method: "tools/call",
      params: { name: "lookup_note", arguments: {} },
    });
    const called = await waitFor((value) => value.id === 3);
    const result = called.result?.content?.[0]?.text;
    if (called.result?.isError !== false || result !== "lookup_note:ok") {
      throw new Error("task18_mcp_fixture_result_mismatch");
    }
    return result;
  } finally {
    input.close();
    child.stdin.end();
    const exited = await Promise.race([
      once(child, "exit"),
      new Promise((resolvePromise) => setTimeout(() => resolvePromise(null), 1_000)),
    ]);
    if (exited === null && child.exitCode === null) child.kill("SIGTERM");
  }
}
