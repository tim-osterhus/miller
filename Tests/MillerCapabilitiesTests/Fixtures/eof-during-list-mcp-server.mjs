import fs from "node:fs";
import readline from "node:readline";

const sentinel = process.env.MILLER_MCP_EOF_SENTINEL;
const pidLog = process.env.MILLER_MCP_PID_LOG;
if (!sentinel || !pidLog) process.exit(64);
fs.appendFileSync(pidLog, `${process.pid}\n`, "utf8");

let listCount = 0;
const tool = {
  name: "lookup",
  description: "lookup",
  inputSchema: { type: "object" },
  annotations: { readOnlyHint: true },
};

function reply(id, result) {
  process.stdout.write(`${JSON.stringify({ jsonrpc: "2.0", id, result })}\n`);
}

readline.createInterface({ input: process.stdin }).on("line", (line) => {
  const request = JSON.parse(line);
  if (request.method === "initialize") {
    reply(request.id, {
      protocolVersion: request.params.protocolVersion,
      capabilities: { tools: {} },
      serverInfo: { name: "eof-during-list", version: "1" },
    });
  } else if (request.method === "tools/list") {
    listCount += 1;
    if (!fs.existsSync(sentinel) && listCount === 2) {
      fs.writeFileSync(sentinel, "closed", "utf8");
      fs.closeSync(1);
      return;
    }
    reply(request.id, { tools: [tool] });
  }
});
