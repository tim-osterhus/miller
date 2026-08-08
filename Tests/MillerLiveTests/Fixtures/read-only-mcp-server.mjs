import readline from "node:readline";
import fs from "node:fs/promises";
import path from "node:path";

const root = process.env.MILLER_MCP_FIXTURE_ROOT;
if (!root || !path.isAbsolute(root)) process.exit(64);

const tools = [
  ["lookup_note", true], ["replace_note", false], ["slow_note", true],
  ["oversize_result", true], ["fail_note", true],
].map(([name, readOnlyHint]) => ({
  name,
  description: name.replaceAll("_", " "),
  inputSchema: { type: "object", additionalProperties: false },
  annotations: { readOnlyHint },
}));

function reply(id, result) {
  process.stdout.write(`${JSON.stringify({ jsonrpc: "2.0", id, result })}\n`);
}
function error(id, code, message) {
  process.stdout.write(`${JSON.stringify({ jsonrpc: "2.0", id, error: { code, message } })}\n`);
}

readline.createInterface({ input: process.stdin }).on("line", async (line) => {
  const request = JSON.parse(line);
  if (request.method === "initialize") {
    reply(request.id, {
      protocolVersion: request.params.protocolVersion,
      capabilities: { tools: {} },
      serverInfo: { name: "miller-test", version: "1" },
    });
  } else if (request.method === "notifications/initialized") {
    // Notification has no response.
  } else if (request.method === "tools/list") {
    reply(request.id, { tools });
  } else if (request.method === "tools/call") {
    const name = request.params.name;
    if (name === "slow_note") await new Promise((resolve) => setTimeout(resolve, 250));
    if (name === "fail_note") return error(request.id, -32000, "fixture failure");
    if (name === "replace_note") {
      await fs.writeFile(path.join(root, "note.txt"), "replaced", "utf8");
    }
    const text = name === "oversize_result" ? "x".repeat(300_000) : `${name}:ok`;
    if (name === "lookup_note" && process.env.MILLER_MCP_FIXTURE_AUDIT_PATH) {
      await fs.appendFile(
        process.env.MILLER_MCP_FIXTURE_AUDIT_PATH,
        `${JSON.stringify({
          route: process.env.MILLER_MCP_FIXTURE_ROUTE,
          tool: name,
          result: text,
        })}\n`,
        { encoding: "utf8", mode: 0o600 },
      );
    }
    reply(request.id, { content: [{ type: "text", text }], isError: false });
  }
});
