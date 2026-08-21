import fs from "node:fs";
import { spawn } from "node:child_process";
import readline from "node:readline";
import { callTask18Bridge } from "./task18-bridge-client.mjs";

const mode = process.argv[2] ?? "normal";
const pidPath = process.argv[3];
const liveTextCompatibility = mode.startsWith("live-text-compatibility-");
const liveTextScenario = liveTextCompatibility
  ? mode.slice("live-text-compatibility-".length)
  : null;
if (mode === "ignore-term" || mode === "typed-capability-inventory-late" ||
    mode === "typed-late-terminal" || mode === "realtime-late-start") {
  process.on("SIGTERM", () => {});
}
if (mode === "record-helper-launch") {
  fs.writeFileSync(pidPath, "launched\n", { mode: 0o600 });
}
let invocation = 1;
if (mode === "reuse-second-wait-stop" || mode === "reuse-second-wait-stop-no-output") {
  invocation = fs.existsSync(pidPath)
    ? Number.parseInt(fs.readFileSync(pidPath, "utf8"), 10) + 1
    : 1;
  fs.writeFileSync(pidPath, `${invocation}\n`, { mode: 0o600 });
}

function spawnDescendant() {
  const child = spawn(process.execPath, ["-e", "setInterval(() => {}, 1000)"], {
    detached: false,
    stdio: "ignore",
  });
  fs.writeFileSync(pidPath, `${child.pid}\n`, { mode: 0o600 });
}

if (mode === "crash") process.exit(23);
if (mode === "hang") setInterval(() => {}, 1000);
if (mode === "hang-child" || mode === "crash-child") {
  spawnDescendant();
  if (mode === "crash-child") setTimeout(() => process.exit(23), 50);
  else setInterval(() => {}, 1000);
}
if (mode === "flood-output") {
  const frame = JSON.stringify({ method: "synthetic/flood", params: { text: "x".repeat(1024) } }) + "\n";
  for (let index = 0; index < 256; index += 1) process.stdout.write(frame);
  setInterval(() => {}, 1000);
}

const lines = readline.createInterface({ input: process.stdin });
const send = (value) => process.stdout.write(JSON.stringify(value) + "\n");
const notify = (method, params) => send({ method, params, emittedAtMs: 1 });
if (mode === "record-stdin" || mode.startsWith("portable-skill-live")) {
  lines.on("line", (line) => fs.appendFileSync(pidPath, `${line}\n`, { mode: 0o600 }));
}
let threadId = "thread-1";
let helperThreadCreated = false;
const liveTextCompatibilityThreadID = "00000000-0000-4000-8000-000000000001";
let typedTurnId = "typed-turn-1";
let realtimePrompt = null;
let connectorApprovalResponses = 0;
let nativeApprovalResponses = 0;
let inventoryRefreshFloodCount = 0;
let lateInventoryResponseScheduled = false;
const pendingInventoryRefreshes = new Map();
const expectedFeatureConfig = "[features]\nrealtime_conversation = true\n\n[realtime]\nversion = \"v1\"\n";
const task18ToolMarker = "miller_mcp/task18_fixture/lookup_note";

async function task18RouteResult(value) {
  if (typeof value !== "string" || value !== task18ToolMarker) {
    process.exit(59);
  }
  return callTask18Bridge();
}

function featureConfigurationIsAdmitted() {
  try {
    const path = `${process.env.CODEX_HOME}/config.toml`;
    const contents = fs.readFileSync(path, "utf8");
    const mode = fs.statSync(path).mode & 0o777;
    return contents === expectedFeatureConfig && mode === 0o600;
  } catch {
    return false;
  }
}

function initializeResult() {
  return {
    codexHome: process.env.CODEX_HOME,
    platformFamily: "unix",
    platformOs: "macos",
    userAgent: "synthetic-codex-app-server",
  };
}

function typedThreadStartResult(id, cwd) {
  const returnedCwd = mode === "typed-authority-wrong-cwd"
    ? "/private/tmp/other"
    : cwd;
  const result = {
    approvalPolicy: "never",
    cwd: returnedCwd,
    runtimeWorkspaceRoots: mode === "typed-authority-wrong-root"
      ? ["/private/tmp/other"]
      : [returnedCwd],
    activePermissionProfile: {
      id: mode === "typed-authority-wrong-profile"
        ? "wrong"
        : "miller-typed-read-only",
    },
    sandbox: {
      type: mode === "typed-authority-writable" ? "workspaceWrite" : "readOnly",
      networkAccess: mode === "typed-authority-network",
    },
    thread: {
      id,
      cwd: returnedCwd,
      ephemeral: mode !== "typed-authority-persistent",
    },
  };
  if (mode === "typed-authority-missing-profile") {
    delete result.activePermissionProfile;
  }
  return result;
}

const answerSDP = "v=0\r\ns=-\r\n";

function connectorApprovalParams(approvalThread, approvalTurn, itemId, variant = 2) {
  const options = [
    { description: "Run the tool and continue.", label: "Allow" },
  ];
  if (variant >= 3) {
    options.push({
      description: "Remember for this session.",
      label: "Allow for this session",
    });
  }
  if (variant >= 4) {
    options.push({
      description: "Remember permanently.",
      label: "Allow and don't ask me again",
    });
  }
  options.push({ description: "Cancel this tool call.", label: "Cancel" });
  return {
    itemId,
    questions: [{
      header: "Approve app tool call?",
      id: `mcp_tool_call_approval_${itemId}`,
      isOther: false,
      isSecret: false,
      options,
      question: "The connector wants to modify data. Allow this action?",
    }],
    threadId: approvalThread,
    turnId: approvalTurn,
  };
}

function respondInventoryRequest(request) {
  if (request.method === "app/list") {
    if (request.params?.cursor === null) {
      send({ id: request.id, result: { data: [{
        id: "gmail", name: "Gmail", description: "Mail",
        isAccessible: true, isEnabled: true,
      }], nextCursor: "apps-page-2" } });
    } else if (request.params?.cursor === "apps-page-2") {
      send({ id: request.id, result: { data: [{
        id: "drive", name: "Drive", description: "Files",
        isAccessible: false, isEnabled: true,
      }], nextCursor: null } });
    } else process.exit(49);
    return;
  }
  if (request.method === "app/read") {
    send({ id: request.id, result: {
      apps: request.params.appIds.map((appId) => ({
        id: appId,
        name: appId === "gmail" ? "Gmail" : "Drive",
        description: "Synthetic app",
        toolSummaries: appId === "gmail" ? [{
          name: "search", title: "Search Gmail",
          description: "Search messages", isEnabled: true, isReadOnly: true,
        }] : [],
      })),
      missingAppIds: [],
    } });
    return;
  }
  if (request.method === "app/installed") {
    send({ id: request.id, result: { apps: [
      { id: "gmail", enabled: true, callable: true },
      { id: "drive", enabled: true, callable: false },
    ] } });
    return;
  }
  if (request.method === "mcpServerStatus/list") {
    if (request.params?.cursor === null) {
      send({ id: request.id, result: { data: [{
        name: "miller-capability-bridge", authStatus: "unsupported",
        tools: { miller_a13462d74f54f23f_list: {
          name: "miller_a13462d74f54f23f_list",
          title: "List events", description: "Duplicate",
          inputSchema: { type: "object" },
        } }, resources: [], resourceTemplates: [],
      }], nextCursor: "mcp-page-2" } });
    } else if (request.params?.cursor === "mcp-page-2") {
      send({ id: request.id, result: { data: [{
        name: "external", authStatus: "bearerToken",
        tools: { inspect: {
          name: "inspect", description: "Inspect resource",
          inputSchema: { type: "object" },
        } }, resources: [], resourceTemplates: [],
      }], nextCursor: null } });
    } else process.exit(50);
  }
}

function emitRealtimeStarted() {
  const emittedThread = mode === "wrong-thread" ? "thread-other" : threadId;
  const emittedSession = mode === "upstream-session" ? "session-other" : threadId;
  notify("thread/realtime/started", {
    threadId: emittedThread,
    realtimeSessionId: emittedSession,
    version: mode === "started-v1" ? "v1" : "v3",
  });
  return emittedThread;
}

function emitRealtimeAnswer(threadId) {
  const emittedThread = mode === "sdp-wrong-thread" ? "helper-other" : threadId;
  notify("thread/realtime/sdp", { threadId: emittedThread, sdp: answerSDP });
  if (mode === "duplicate-sdp") {
    notify("thread/realtime/sdp", { threadId: emittedThread, sdp: answerSDP });
  }
}

async function emitLifecycle() {
  const emittedThread = emitRealtimeStarted();
  if (mode === "crash-after-start") process.exit(23);
  emitRealtimeAnswer(emittedThread);
  if (mode === "realtime-user-transcript-deltas") {
    notify("thread/realtime/transcript/delta", {
      threadId: emittedThread, role: "user", delta: "hello",
    });
    notify("thread/realtime/transcript/delta", {
      threadId: emittedThread, role: "user", delta: " Miller",
    });
    notify("thread/realtime/transcript/done", {
      threadId: emittedThread, role: "user", text: "hello Miller",
    });
    notify("thread/realtime/transcript/delta", {
      threadId: emittedThread, role: "assistant", delta: "Hello",
    });
    notify("thread/realtime/transcript/done", {
      threadId: emittedThread, role: "assistant", text: "Hello!",
    });
    notify("thread/realtime/closed", {
      threadId: emittedThread, reason: "synthetic-complete",
    });
    return;
  }
  if (mode === "realtime-task18-three-route") {
    if (realtimePrompt !== task18ToolMarker) process.exit(59);
    const result = await task18RouteResult(realtimePrompt);
    const item = {
      type: "mcpToolCall", id: "task18-read-only-sideband",
      server: "miller-capability-bridge", tool: result.toolName,
      arguments: {}, status: "inProgress",
    };
    notify("thread/realtime/itemAdded", {
      threadId: emittedThread, turnId: "task18-live-turn-1", item,
    });
    notify("thread/realtime/itemAdded", {
      threadId: emittedThread, turnId: "task18-live-turn-1",
      item: {
        ...item, status: "completed",
        result: { content: [{ type: "text", text: result.result }], isError: false },
      },
    });
    notify("thread/realtime/closed", { threadId: emittedThread, reason: "synthetic-complete" });
    setTimeout(() => process.exit(0), 0);
    return;
  }
  if (mode === "realtime-error") {
    notify("thread/realtime/error", { threadId: emittedThread, message: "synthetic realtime error" });
    return;
  }
  if (mode === "realtime-capability" ||
      mode === "realtime-capability-wrong-authority") {
    const capabilityThread = mode === "realtime-capability-wrong-authority"
      ? "thread-other"
      : emittedThread;
    notify("item/started", {
      threadId: capabilityThread, startedAtMs: 1,
      turnId: "turn-capability-1",
      item: {
        type: "mcpToolCall", id: "capability-1", server: "gmail",
        tool: "search", status: "inProgress",
        arguments: { query: "private query" },
        appContext: { connectorId: "gmail", actionName: "search" },
      },
    });
    notify("item/completed", {
      threadId: capabilityThread, completedAtMs: 2,
      turnId: "turn-capability-1",
      item: {
        type: "mcpToolCall", id: "capability-1", server: "gmail",
        tool: "search", status: "completed",
        arguments: { query: "private query" },
        result: { private: "result" },
        appContext: { connectorId: "gmail", actionName: "search" },
      },
    });
  }
  if (mode === "realtime-capability-malformed") {
    notify("thread/realtime/itemAdded", {
      threadId: emittedThread,
      turnId: "turn-capability-1",
      item: {
        type: "mcpToolCall", id: "malformed-capability-1",
        tool: "search", status: "inProgress", arguments: {},
      },
    });
    return;
  }
  if (mode === "realtime-provider-approval" ||
      mode === "realtime-provider-approval-decline" ||
      mode === "realtime-provider-approval-replay") {
    send({
      id: "realtime-approval-1",
      method: "item/tool/requestUserInput",
      params: connectorApprovalParams(
        emittedThread,
        "turn-approval-1",
        "connector-call-1",
        mode === "realtime-provider-approval" ? 4
          : mode === "realtime-provider-approval-decline" ? 3
            : 2
      ),
    });
    return;
  }
  notify("thread/realtime/transcript/delta", { threadId: emittedThread, role: "assistant", delta: "hel" });
  notify("thread/realtime/transcript/done", { threadId: emittedThread, role: "assistant", text: "hello" });
  notify("thread/realtime/outputAudio/delta", {
    threadId: emittedThread,
    audio: { data: "AQID", sampleRate: 24000, numChannels: 1, samplesPerChannel: 3, itemId: null },
  });
  const itemThread = mode === "item-wrong-thread" ? "thread-other" : emittedThread;
  const itemParams = { threadId: itemThread, item: { type: "message", text: "discarded" } };
  if (mode === "item-unknown-field") itemParams.future = true;
  notify("thread/realtime/itemAdded", itemParams);
  notify("thread/realtime/closed", { threadId: emittedThread, reason: "synthetic-complete" });
  if (mode === "duplicate-terminal") notify("thread/realtime/closed", { threadId: emittedThread, reason: null });
  if (mode === "late-event") notify("thread/realtime/transcript/delta", { threadId: emittedThread, role: "assistant", delta: "late" });
}

function threadObject(id = "helper-thread-1") {
  const thread = {
    id, extra: {}, sessionId: "helper-session-1", forkedFromId: null,
    parentThreadId: null, preview: "",
    ephemeral: mode === "unsafe-thread-response" ? false : true, historyMode: "legacy",
    modelProvider: "openai", createdAt: 1, updatedAt: 1, recencyAt: null,
    status: { type: "idle" }, path: null, cwd: process.env.HOME, cliVersion: "0.145.0",
    source: "vscode", canAcceptDirectInput: null, threadSource: "user",
    agentNickname: null, agentRole: null, gitInfo: null, name: null, turns: [],
  };
  if (mode === "thread-shape-missing") delete thread.extra;
  if (mode === "thread-shape-wrong") thread.historyMode = 7;
  if (mode === "thread-shape-extra") thread.future = true;
  if (mode === "forward-thread-metadata") {
    thread.extra = { future: { enabled: true } };
    thread.preview = "bounded preview";
    thread.historyMode = "future-history";
    thread.status = { type: "future", metadata: { ready: true } };
    thread.cliVersion = "future-version";
    thread.source = "vscode";
    thread.threadSource = "future-source";
    thread.agentNickname = "nickname";
    thread.agentRole = "role";
    thread.gitInfo = { future: { branch: "main" } };
    thread.name = "name";
  }
  return thread;
}

function threadStartResult(id, threadID = "helper-thread-1") {
  const result = {
    thread: threadObject(threadID), model: "gpt-live", modelProvider: "openai", serviceTier: null,
    cwd: process.env.HOME, instructionSources: [], approvalPolicy: "never",
    approvalsReviewer: "user", sandbox: { type: "readOnly", networkAccess: false },
    activePermissionProfile: null, reasoningEffort: null,
    runtimeWorkspaceRoots: [process.env.HOME], multiAgentMode: "explicitRequestOnly",
  };
  if (mode === "active-profile-exact") {
    result.activePermissionProfile = { id: ":read-only", extends: null };
  }
  if (mode === "active-profile-missing") {
    result.activePermissionProfile = { extends: null };
  }
  if (mode === "active-profile-wrong") {
    result.activePermissionProfile = { id: 7, extends: null };
  }
  if (mode === "active-profile-unknown") {
    result.activePermissionProfile = { id: ":read-only", extends: null, future: true };
  }
  if (mode === "active-profile-modifications") {
    result.activePermissionProfile = { id: ":read-only", extends: null, modifications: [] };
  }
  if (mode === "forward-thread-metadata") {
    result.approvalsReviewer = "future-reviewer";
    result.activePermissionProfile = { future: { nested: true } };
    result.runtimeWorkspaceRoots = ["relative-but-informational"];
    result.multiAgentMode = "future-mode";
  }
  return { id, result };
}

function emitAccountNotifications() {
  const completed = { loginId: null, success: true, error: null };
  if (mode === "account-completed-unknown-field") completed.future = true;
  if (mode === "account-completed-invalid") completed.loginId = 7;
  const updated = { authMode: "chatgptAuthTokens", planType: null };
  if (mode === "account-updated-unknown-field") updated.future = true;
  if (mode === "account-updated-invalid") updated.authMode = "future";
  if (mode === "account-updated-before-completed") {
    notify("account/updated", updated);
    notify("account/login/completed", completed);
    return;
  }
  notify("account/login/completed", completed);
  if (mode === "duplicate-account-completed") {
    notify("account/login/completed", completed);
  }
  notify("account/updated", updated);
}

lines.on("line", async (line) => {
  if (mode === "malformed") {
    process.stdout.write("{not-json}\n");
    return;
  }
  if (mode === "oversized") {
    process.stdout.write(`{"method":"${"x".repeat(1_100_000)}"}\n`);
    return;
  }
  const request = JSON.parse(line);
  if (mode === "typed-capability-inventory-refresh" &&
      pendingInventoryRefreshes.has(request.id)) {
    if (!request.result?.accessToken?.startsWith("replacement-token-") ||
        request.result?.chatgptAccountId !== "account-1") process.exit(53);
    const pending = pendingInventoryRefreshes.get(request.id);
    pendingInventoryRefreshes.delete(request.id);
    respondInventoryRequest(pending);
    return;
  }
  if (mode === "typed-capability-inventory-refresh-flood" &&
      request.id === `inventory-refresh-flood-${inventoryRefreshFloodCount}`) {
    if (!request.result?.accessToken?.startsWith("replacement-token-") ||
        request.result?.chatgptAccountId !== "account-1") process.exit(56);
    if (inventoryRefreshFloodCount >= 70) return;
    inventoryRefreshFloodCount += 1;
    send({
      id: `inventory-refresh-flood-${inventoryRefreshFloodCount}`,
      method: "account/chatgptAuthTokens/refresh",
      params: { reason: "unauthorized", previousAccountId: "account-1" },
    });
    return;
  }
  if ((mode === "realtime-provider-approval" ||
       mode === "realtime-provider-approval-decline" ||
       mode === "realtime-provider-approval-replay") &&
      request.id === "realtime-approval-1") {
    const expected = mode === "realtime-provider-approval-decline"
      ? "__codex_mcp_decline__"
      : "Allow";
    if (request.result?.answers?.["mcp_tool_call_approval_connector-call-1"]
        ?.answers?.[0] !== expected) process.exit(51);
    connectorApprovalResponses += 1;
    if (mode === "realtime-provider-approval-replay") {
      if (connectorApprovalResponses > 1) process.exit(52);
      send({
        id: "realtime-approval-1",
        method: "item/tool/requestUserInput",
        params: connectorApprovalParams(
          threadId, "turn-approval-1", "connector-call-1", 2
        ),
      });
      return;
    }
    notify("thread/realtime/closed", {
      threadId, reason: "synthetic-complete",
    });
    return;
  }
  if (mode.startsWith("typed-")) {
    if ((mode === "typed-record" || mode === "typed-probe-record" ||
         mode === "typed-readiness-record" ||
         mode === "typed-portable-skill-routing-proof" ||
         mode.startsWith("typed-authority-")) && pidPath) {
      fs.appendFileSync(pidPath, `${line}\n`, { mode: 0o600 });
    }
    if (request.method === "initialize") {
      if (request.params?.capabilities?.experimentalApi !== true) {
        send({ id: request.id, error: { code: -32602, message: "experimental API required" } });
        return;
      }
      if (mode === "typed-readiness-initialize-error") {
        send({ id: request.id, error: { code: -32000, message: "synthetic initialize rejection" } });
        return;
      }
      if (mode === "typed-readiness-initialize-empty") {
        send({ id: request.id, result: {} });
        return;
      }
      if (mode === "typed-readiness-initialize-wrong") {
        send({ id: request.id, result: { codexHome: 7 } });
        return;
      }
      if (mode === "typed-readiness-malformed") {
        process.stdout.write("{malformed\n");
        return;
      }
      send({ id: request.id, result: initializeResult() });
      return;
    }
    if (request.method === "initialized") return;
    if (request.method === "account/login/start") {
      if (mode === "typed-readiness-login-error") {
        send({ id: request.id, error: { code: -32000, message: "authentication required" } });
        return;
      }
      if (mode === "typed-readiness-login-empty") {
        send({ id: request.id, result: {} });
        return;
      }
      if (mode === "typed-readiness-login-wrong") {
        send({ id: request.id, result: { type: "apikey" } });
        return;
      }
      send({ id: request.id, result: { type: "chatgptAuthTokens" } });
      return;
    }
    if (mode.startsWith("typed-capability-inventory") &&
        ["app/list", "app/read", "app/installed", "mcpServerStatus/list"]
          .includes(request.method)) {
      if (mode === "typed-capability-inventory-hang") {
        if (pidPath) fs.writeFileSync(pidPath, "inventory-pending\n", { mode: 0o600 });
        return;
      }
      if (mode === "typed-capability-inventory-late" &&
          request.method === "app/list" && request.params?.cursor === null &&
          !lateInventoryResponseScheduled) {
        lateInventoryResponseScheduled = true;
        setTimeout(() => respondInventoryRequest(request), 60);
        return;
      }
      if (mode === "typed-capability-inventory-refresh") {
        const refreshId = `inventory-refresh-${request.id}`;
        pendingInventoryRefreshes.set(refreshId, request);
        send({
          id: refreshId,
          method: "account/chatgptAuthTokens/refresh",
          params: { reason: "unauthorized", previousAccountId: "account-1" },
        });
        return;
      }
      if (mode === "typed-capability-inventory-refresh-flood") {
        inventoryRefreshFloodCount = 1;
        send({
          id: "inventory-refresh-flood-1",
          method: "account/chatgptAuthTokens/refresh",
          params: { reason: "unauthorized", previousAccountId: "account-1" },
        });
        return;
      }
      respondInventoryRequest(request);
      return;
    }
    if (request.method === "thread/start") {
      if (request.params?.approvalPolicy !== "never" ||
          request.params?.permissions !== undefined ||
          request.params?.runtimeWorkspaceRoots !== undefined ||
          request.params?.sandbox !== undefined || request.params?.sandboxPolicy !== undefined) {
        send({ id: request.id, error: { code: -32602, message: "unsafe thread policy" } });
        return;
      }
      if (mode === "typed-thread-failure") {
        send({ id: request.id, error: { code: -32000, message: "bridge unavailable" } });
        return;
      }
      if (mode === "typed-probe-malformed") {
        process.stdout.write("{malformed\n");
        return;
      }
      if (mode === "typed-startup-wait") {
        if (pidPath) fs.writeFileSync(pidPath, "thread-start-pending\n", { mode: 0o600 });
        return;
      }
      helperThreadCreated = true;
      threadId = "typed-thread-1";
      if (mode === "typed-record-workspace" && pidPath) {
        fs.appendFileSync(pidPath, `${request.params.cwd}\n`, { mode: 0o600 });
      }
      const response = {
        id: request.id,
        result: typedThreadStartResult(threadId, request.params.cwd),
      };
      const started = () => notify("thread/started", { thread: { id: threadId } });
      if (mode === "typed-thread-notification-first") {
        started();
        send(response);
      } else {
        send(response);
        started();
      }
      return;
    }
    if (request.method === "thread/resume") {
      send({ id: request.id, result: { thread: { id: request.params?.threadId } } });
      notify("thread/started", { thread: { id: request.params?.threadId } });
      return;
    }
    if (request.method === "turn/start") {
      const input = request.params?.input;
      const portableSkillInputIsValid = !mode.startsWith("typed-portable-skill-")
        ? input?.length === 1
        : input?.length === 1 || (
          input?.length === 2 && input[1]?.type === "skill"
          && input[1]?.name === "Weather"
          && typeof input[1]?.path === "string"
          && fs.existsSync(input[1].path)
          && (fs.statSync(input[1].path).mode & 0o777) === 0o600
        );
      if (!helperThreadCreated || request.params?.threadId !== threadId ||
          !Array.isArray(input) || !portableSkillInputIsValid ||
          input[0]?.type !== "text" || request.params?.approvalPolicy !== "never" ||
          request.params?.permissions !== undefined ||
          request.params?.runtimeWorkspaceRoots !== undefined ||
          request.params?.sandboxPolicy !== undefined) {
        send({ id: request.id, error: { code: -32602, message: "invalid typed turn" } });
        return;
      }
      const typedTurnResponse = { id: request.id, result: {
        turn: { id: typedTurnId, status: "inProgress", items: [], error: null },
      } };
      const emitTypedTurnStarted = () => notify("turn/started", {
        threadId,
        turn: { id: typedTurnId, status: "inProgress", items: [], error: null },
      });
      if (mode === "typed-turn-duplicate-response-same" ||
          mode === "typed-turn-duplicate-response-different") {
        send(typedTurnResponse);
        send({ id: request.id, result: {
          turn: {
            id: mode.endsWith("different") ? "typed-turn-other" : typedTurnId,
            status: "inProgress", items: [], error: null,
          },
        } });
        emitTypedTurnStarted();
      } else if (mode === "typed-turn-duplicate-notification-same" ||
                 mode === "typed-turn-duplicate-notification-different") {
        emitTypedTurnStarted();
        notify("turn/started", {
          threadId,
          turn: {
            id: mode.endsWith("different") ? "typed-turn-other" : typedTurnId,
            status: "inProgress", items: [], error: null,
          },
        });
        send(typedTurnResponse);
      } else if (mode === "typed-turn-notification-first") {
        emitTypedTurnStarted();
        send(typedTurnResponse);
      } else {
        send(typedTurnResponse);
        emitTypedTurnStarted();
      }
      if (mode.startsWith("typed-turn-duplicate-")) return;
      if (mode === "typed-late-terminal") {
        notify("item/started", {
          threadId, turnId: typedTurnId, startedAtMs: 1,
          item: {
            type: "mcpToolCall", id: "typed-late-capability-1",
            server: "gmail", tool: "search", status: "inProgress", arguments: {},
          },
        });
        notify("turn/completed", {
          threadId,
          turn: { id: typedTurnId, status: "completed", items: [], error: null },
        });
        return;
      }
      if (mode === "typed-wait" || mode === "typed-portable-skill-wait") {
        if (pidPath) fs.writeFileSync(pidPath, "turn-started\n", { mode: 0o600 });
        return;
      }
      if (mode.startsWith("typed-probe-")) {
        if (mode === "typed-probe-slow" ||
            mode === "typed-probe-late" ||
            (mode === "typed-probe-slow-once" && !fs.existsSync(pidPath))) {
          if (pidPath) fs.writeFileSync(pidPath, "remote-probe-pending\n", { mode: 0o600 });
          if (mode === "typed-probe-late") {
            setTimeout(() => {
              notify("item/agentMessage/delta", {
                threadId, turnId: typedTurnId,
                itemId: "typed-probe-late-message-1", delta: "OK",
              });
              notify("turn/completed", {
                threadId,
                turn: {
                  id: typedTurnId, status: "completed", items: [], error: null,
                },
              });
            }, 250);
          }
          return;
        }
        if (mode === "typed-probe-refresh-unavailable" ||
            mode === "typed-probe-refresh-rejected") {
          send({
            id: "typed-probe-refresh-1",
            method: "account/chatgptAuthTokens/refresh",
            params: { reason: "unauthorized", previousAccountId: "account-1" },
          });
          return;
        }
        if (mode === "typed-probe-post-admission-error") {
          send({
            id: "typed-probe-post-admission-error-1",
            error: { code: -32000, message: "provider execution failed" },
          });
          return;
        }
        if (mode !== "typed-probe-no-stream") {
          notify("item/agentMessage/delta", {
            threadId, turnId: typedTurnId, itemId: "typed-probe-message-1", delta: "OK",
          });
        }
        notify("turn/completed", {
          threadId,
          turn: {
            id: typedTurnId,
            status: mode === "typed-probe-failed-terminal"
              ? "failed"
              : mode === "typed-probe-interrupted-terminal"
                ? "interrupted"
                : "completed",
            items: [],
            error: mode === "typed-probe-failed-terminal" ||
              mode === "typed-probe-interrupted-terminal"
              ? { message: "probe failed" }
              : null,
          },
        });
        return;
      }
      if (mode === "typed-refresh") {
        send({
          id: "typed-refresh-1",
          method: "account/chatgptAuthTokens/refresh",
          params: { reason: "unauthorized", previousAccountId: "account-1" },
        });
        return;
      }
      if (mode === "typed-capability-malformed") {
        notify("item/started", {
          threadId, turnId: typedTurnId, startedAtMs: 1,
          item: {
            type: "mcpToolCall", id: "malformed-capability-1",
            tool: "search", status: "inProgress", arguments: {},
          },
        });
        return;
      }
      if (mode === "typed-native-approval-distinct-then-replay") {
        send({
          id: "native-approval-request-1",
          method: "item/commandExecution/requestApproval",
          params: {
            threadId, turnId: typedTurnId, itemId: "native-command-1",
            approvalId: "native-approval-a", startedAtMs: 1,
          },
        });
        return;
      }
      if (mode === "typed-capability-wrong-authority") {
        notify("item/started", {
          threadId: "thread-other",
          turnId: typedTurnId, startedAtMs: 1,
          item: {
            type: "mcpToolCall", id: "wrong-authority-1", server: "gmail",
            tool: "search", status: "inProgress",
            arguments: { query: "private query" },
          },
        });
        return;
      }
      if (mode === "typed-provider-approval" ||
          mode === "typed-provider-approval-decline" ||
          mode === "typed-provider-approval-replay" ||
          mode === "typed-provider-approval-wrong-authority") {
        send({
          id: "tool-approval-request-1",
          method: "item/tool/requestUserInput",
          params: connectorApprovalParams(
            mode === "typed-provider-approval-wrong-authority"
              ? "thread-other"
              : threadId,
            typedTurnId,
            "connector-call-1",
            mode === "typed-provider-approval-decline" ? 3
              : mode === "typed-provider-approval-replay" ? 4
                : 2
          ),
        });
        return;
      }
      if (mode === "typed-approval") {
        send({
          id: "approval-request-1",
          method: "item/commandExecution/requestApproval",
          params: {
            threadId, turnId: typedTurnId, itemId: "approval-item-1",
            startedAtMs: 1, reason: "private approval reason",
          },
        });
        return;
      }
      if (mode === "typed-permissions-approval") {
        send({
          id: "permissions-request-1",
          method: "item/permissions/requestApproval",
          params: {
            threadId, turnId: typedTurnId, itemId: "permissions-item-1",
            cwd: request.params.cwd, startedAtMs: Date.now(),
            permissions: { network: { enabled: true } },
          },
        });
        return;
      }
      if (mode === "typed-stale") {
        notify("item/agentMessage/delta", {
          threadId, turnId: "stale-turn", itemId: "typed-message-1", delta: "stale",
        });
        return;
      }
      if (mode === "typed-too-many") {
        for (let index = 0; index < 1025; index += 1) {
          notify("item/agentMessage/delta", {
            threadId, turnId: typedTurnId, itemId: "typed-message-1", delta: "x",
          });
        }
        return;
      }
      if (mode === "typed-burst") {
        for (let index = 0; index < 64; index += 1) {
          notify("item/agentMessage/delta", {
            threadId, turnId: typedTurnId,
            itemId: "typed-message-1", delta: "x",
          });
        }
        notify("turn/completed", {
          threadId,
          turn: { id: typedTurnId, status: "completed", items: [], error: null },
        });
        return;
      }
      if (mode === "typed-hidden-only") {
        for (const type of ["reasoning", "commandExecution", "fileChange"]) {
          notify("item/completed", {
            threadId, turnId: typedTurnId,
            item: {
              type, id: `hidden-${type}`, summary: ["private"],
              content: ["private"], aggregatedOutput: "private", changes: ["private"],
            },
          });
        }
      } else if (mode === "typed-capabilities") {
        for (const type of ["webSearch", "mcpToolCall", "app-mcpToolCall"]) {
          const wireType = type === "app-mcpToolCall" ? "mcpToolCall" : type;
          const appContext = type === "app-mcpToolCall"
            ? { connectorId: "app", actionName: "search" }
            : undefined;
          notify("item/started", {
            threadId, turnId: typedTurnId, startedAtMs: 1,
            item: {
              type: wireType, id: `cap-${type}`, status: "inProgress",
              appContext,
              query: wireType === "webSearch" ? "private" : undefined,
              server: wireType === "mcpToolCall" ? "server" : undefined,
              tool: wireType === "mcpToolCall" ? "search" : undefined,
              arguments: { secret: "private" },
            },
          });
          notify("item/completed", {
            threadId, turnId: typedTurnId, completedAtMs: 2,
            item: {
              type: wireType, id: `cap-${type}`, status: "completed",
              appContext,
              query: wireType === "webSearch" ? "private" : undefined,
              server: wireType === "mcpToolCall" ? "server" : undefined,
              tool: wireType === "mcpToolCall" ? "search" : undefined,
              arguments: { secret: "private" },
              result: { secret: "private" },
            },
          });
        }
      } else if (mode === "typed-task18-three-route") {
        const result = await task18RouteResult(input[0].text);
        const item = {
          type: "mcpToolCall", id: "task18-read-only-typed",
          server: "miller-capability-bridge", tool: result.toolName,
          arguments: {}, status: "inProgress",
        };
        notify("item/started", { threadId, turnId: typedTurnId, startedAtMs: 1, item });
        notify("item/completed", {
          threadId, turnId: typedTurnId, completedAtMs: 2,
          item: {
            ...item, status: "completed",
            result: { content: [{ type: "text", text: result.result }], isError: false },
          },
        });
      } else if (mode === "typed-failure") {
        notify("turn/completed", {
          threadId,
          turn: {
            id: typedTurnId, status: "failed", items: [],
            error: { message: "private provider failure" },
          },
        });
        return;
      } else {
        notify("item/agentMessage/delta", {
          threadId, turnId: typedTurnId, itemId: "typed-message-1", delta: "hel",
        });
        notify("item/agentMessage/delta", {
          threadId, turnId: typedTurnId, itemId: "typed-message-1", delta: "lo",
        });
        notify("item/completed", {
          threadId, turnId: typedTurnId,
          item: { type: "agentMessage", id: "typed-message-1", text: "hello" },
        });
      }
      notify("turn/completed", {
        threadId,
        turn: { id: typedTurnId, status: "completed", items: [], error: null },
      });
      if (mode === "typed-task18-three-route") setTimeout(() => process.exit(0), 0);
      return;
    }
    if (mode === "typed-refresh" && request.id === "typed-refresh-1") {
      if (request.result?.accessToken !== "replacement-token" ||
          request.result?.chatgptAccountId !== "account-1") {
        process.exit(46);
      }
      notify("item/agentMessage/delta", {
        threadId, turnId: typedTurnId, itemId: "typed-message-1", delta: "refreshed",
      });
      notify("item/completed", {
        threadId, turnId: typedTurnId,
        item: { type: "agentMessage", id: "typed-message-1", text: "refreshed" },
      });
      notify("turn/completed", {
        threadId,
        turn: { id: typedTurnId, status: "completed", items: [], error: null },
      });
      return;
    }
    if (mode === "typed-native-approval-distinct-then-replay" &&
        request.id?.startsWith("native-approval-request-")) {
      if (request.result?.decision !== "accept") process.exit(54);
      nativeApprovalResponses += 1;
      if (nativeApprovalResponses === 1) {
        send({
          id: "native-approval-request-2",
          method: "item/commandExecution/requestApproval",
          params: {
            threadId, turnId: typedTurnId, itemId: "native-command-1",
            approvalId: "native-approval-b", startedAtMs: 2,
          },
        });
        return;
      }
      if (nativeApprovalResponses === 2) {
        send({
          id: "native-approval-request-replay",
          method: "item/commandExecution/requestApproval",
          params: {
            threadId, turnId: typedTurnId, itemId: "native-command-1",
            approvalId: "native-approval-b", startedAtMs: 2,
          },
        });
        return;
      }
      process.exit(55);
    }
    if ((mode === "typed-provider-approval" ||
         mode === "typed-provider-approval-decline" ||
         mode === "typed-provider-approval-replay") &&
        request.id === "tool-approval-request-1") {
      const expected = mode === "typed-provider-approval-decline"
        ? "__codex_mcp_decline__"
        : "Allow";
      if (request.result?.answers?.["mcp_tool_call_approval_connector-call-1"]
          ?.answers?.[0] !== expected) process.exit(47);
      connectorApprovalResponses += 1;
      if (mode === "typed-provider-approval-replay") {
        if (connectorApprovalResponses > 1) process.exit(49);
        send({
          id: "tool-approval-request-1",
          method: "item/tool/requestUserInput",
          params: connectorApprovalParams(
            threadId, typedTurnId, "connector-call-1", 4
          ),
        });
        return;
      }
      notify("turn/completed", {
        threadId,
        turn: { id: typedTurnId, status: "completed", items: [], error: null },
      });
      return;
    }
    if (mode === "typed-approval" &&
        request.id === "approval-request-1") {
      if (request.result?.decision !== "decline") process.exit(47);
      notify("turn/completed", {
        threadId,
        turn: {
          id: typedTurnId,
          status: "failed",
          items: [],
          error: { message: "private approval unavailable" },
        },
      });
      return;
    }
    if (mode === "typed-permissions-approval" && request.id === "permissions-request-1") {
      if (request.result?.scope !== "turn" ||
          request.result?.strictAutoReview !== true ||
          Object.keys(request.result?.permissions ?? {}).length !== 0) process.exit(48);
      notify("turn/completed", {
        threadId,
        turn: {
          id: typedTurnId, status: "failed", items: [],
          error: { message: "private permissions unavailable" },
        },
      });
      return;
    }
    if (request.method === "turn/interrupt") {
      if (pidPath) fs.appendFileSync(pidPath, "interrupt\n", { mode: 0o600 });
      send({ id: request.id, result: {} });
      notify("turn/completed", {
        threadId,
        turn: { id: typedTurnId, status: "interrupted", items: [], error: null },
      });
      return;
    }
    if (request.method === "skills/extraRoots/set") {
      if (!Array.isArray(request.params?.extraRoots) || request.params.extraRoots.length !== 1
          || !request.params.extraRoots[0].startsWith("/")) process.exit(56);
      if (mode === "typed-portable-skill-routing-proof") {
        const root = request.params.extraRoots[0];
        const skillDirectories = fs.readdirSync(`${root}/skills`);
        if (skillDirectories.length !== 1) process.exit(56);
        const file = `${root}/skills/${skillDirectories[0]}/SKILL.md`;
        const contents = fs.readFileSync(file, "utf8");
        if ((fs.statSync(file).mode & 0o777) !== 0o600
            || !contents.includes("name: Weather")
            || !contents.includes("description: Forecast guidance")
            || !contents.includes("Use forecasts.")) process.exit(56);
      }
      send({ id: request.id, result: {} });
      return;
    }
    if (["app/list", "mcpServerStatus/list", "skills/list"].includes(request.method)) {
      if (mode === "typed-probe-missing" && request.method === "app/list") {
        send({ id: request.id, error: { code: -32601, message: "method not found" } });
      } else {
        send({ id: request.id, result: { data: [], nextCursor: null } });
      }
      return;
    }
    send({ id: request.id, error: { code: -32601, message: "method not found" } });
    return;
  }
  if (mode === "transport-race") {
    if (request.method !== "race" || typeof request.ordinal !== "number" ||
        typeof request.payload !== "string" || request.payload.length !== 32768 ||
        !/^x+$/.test(request.payload)) process.exit(45);
    return;
  }
  if (mode === "normal") {
    send({ id: 1, result: {} });
    return;
  }
  if (mode === "hang-client") return;
  if (request.method === "initialize") {
    if (mode === "wait-initialize") {
      fs.writeFileSync(pidPath, "initialize\n", { mode: 0o600 });
      return;
    }
    if (mode === "unknown-method") {
      notify("synthetic/unknown", {});
      return;
    }
    if (mode === "startup-out-of-band-notifications") {
      notify("remoteControl/status/changed", {
        status: "disabled", serverName: "discard-server",
        installationId: "discard-installation", environmentId: null,
      });
      send({
        method: "configWarning",
        params: { summary: "discard-summary", details: null },
        emittedAtMs: 1785758400123,
      });
      notify("future/ambient", { opaque: "discard" });
    }
    const id = mode === "wrong-request" ? "wrong-request" : request.id;
    const result = initializeResult();
    if (mode === "initialize-required-wrong-type") result.codexHome = 42;
    send({ id, result });
    return;
  }
  if (request.method === "account/login/start") {
    if (mode === "wait-login") {
      fs.writeFileSync(pidPath, "login\n", { mode: 0o600 });
      return;
    }
    if (mode === "login-error") {
      send({ id: request.id, error: { code: -32000, message: "synthetic admission failure" } });
      return;
    }
    if (mode === "login-unexpected-notification") {
      notify("thread/started", { thread: threadObject("helper-thread-1") });
      return;
    }
    if (mode === "login-notifications-before-response") emitAccountNotifications();
    const loginResult = { type: "chatgptAuthTokens" };
    if (mode === "login-required-wrong-type") loginResult.type = 42;
    send({ id: request.id, result: loginResult });
    if (mode !== "thread-response-before-login-notifications" &&
        mode !== "login-notifications-before-response" &&
        mode !== "wait-after-thread-created") emitAccountNotifications();
    return;
  }
  if (request.method === "skills/extraRoots/set") {
    const roots = request.params?.extraRoots;
    if (!Array.isArray(roots) || roots.length !== 1 || !roots[0].startsWith("/")) {
      process.exit(57);
    }
    if (mode === "portable-skill-live-routing-proof") {
      const skillDirectories = fs.readdirSync(`${roots[0]}/skills`);
      if (skillDirectories.length !== 1) process.exit(57);
      const file = `${roots[0]}/skills/${skillDirectories[0]}/SKILL.md`;
      const contents = fs.readFileSync(file, "utf8");
      if ((fs.statSync(file).mode & 0o777) !== 0o600
          || !contents.includes("name: Weather")
          || !contents.includes("description: Forecast guidance")
          || !contents.includes("Use forecasts.")) process.exit(57);
    } else if (!fs.existsSync(`${roots[0]}/skills/weather/SKILL.md`)) {
      process.exit(57);
    }
    send({ id: request.id, result: {} });
    return;
  }
  if (request.method === "skills/list") {
    if (!Array.isArray(request.params?.cwds) || request.params.cwds.length !== 1 ||
        request.params?.forceReload !== true) process.exit(58);
    send({ id: request.id, result: { data: [], nextCursor: null } });
    return;
  }
  if (request.method === "thread/start") {
    if (mode === "wait-thread-start") {
      fs.writeFileSync(pidPath, "thread-start\n", { mode: 0o600 });
      return;
    }
    if (mode === "feature-missing" || mode === "feature-incorrect" || !featureConfigurationIsAdmitted()) {
      send({ id: request.id, error: { code: -32600, message: "realtime_conversation feature unavailable" } });
      return;
    }
    const params = request.params ?? {};
    if (params.ephemeral !== true || params.approvalPolicy !== "never" ||
        params.sandbox !== "read-only" || typeof params.cwd !== "string") {
      send({ id: request.id, error: { code: -32602, message: "unsafe thread configuration" } });
      return;
    }
    helperThreadCreated = true;
    const startedThreadID = liveTextCompatibility
      ? liveTextCompatibilityThreadID
      : "helper-thread-1";
    if (mode === "thread-notification-before-response") {
      notify("thread/started", { thread: threadObject(startedThreadID) });
    }
    send(threadStartResult(request.id, startedThreadID));
    if (mode === "wait-after-thread-created") {
      fs.writeFileSync(pidPath, "after-thread-created\n", { mode: 0o600 });
      return;
    }
    if (mode === "thread-response-before-login-notifications") emitAccountNotifications();
    if (mode === "realtime-response-before-thread-started" ||
        mode === "thread-notification-before-response") return;
    const startedThread = threadObject(
      mode === "thread-started-wrong-thread" ? "helper-other" : startedThreadID
    );
    const startedParams = { thread: startedThread };
    if (mode === "thread-started-unknown-field") startedParams.future = true;
    notify("thread/started", startedParams);
    if (mode === "duplicate-thread-started") notify("thread/started", startedParams);
    return;
  }
  if (request.method === "thread/realtime/start") {
    const expectedThreadID = liveTextCompatibility
      ? liveTextCompatibilityThreadID
      : "helper-thread-1";
    if (!helperThreadCreated || request.params.threadId !== expectedThreadID) {
      send({ id: request.id, error: { code: -32600, message: "thread not loaded" } });
      return;
    }
    const params = request.params ?? {};
    if (liveTextCompatibility) {
      const keys = Object.keys(params).sort();
      const expectedKeys = [
        "initialItems", "outputModality", "prompt", "realtimeSessionId",
        "threadId", "transport", "version", "voice",
      ];
      const initialItems = params.initialItems;
      const validItems = Array.isArray(initialItems)
        && initialItems.every((item) => item && typeof item === "object"
          && Object.keys(item).sort().join(",") === "role,text"
          && ["user", "developer", "assistant"].includes(item.role)
          && typeof item.text === "string"
          && item.text.length > 0
          && item.text.length <= 768);
      if (JSON.stringify(keys) !== JSON.stringify(expectedKeys)
          || !validItems
          || params.outputModality !== "audio"
          || typeof params.prompt !== "string"
          || params.prompt.length === 0
          || params.realtimeSessionId !== null
          || params.version !== "v3"
          || params.voice !== null
          || params.transport?.type !== "websocket") {
        send({ id: request.id, error: { code: -32602, message: "synthetic realtime start rejected" } });
        return;
      }
      threadId = request.params.threadId;
      send({ id: request.id, result: {} });
      notify("thread/realtime/started", {
        threadId, realtimeSessionId: null, version: "v3",
      });
      notify("thread/realtime/transcript/delta", {
        threadId, role: "assistant", delta: "synthetic-active",
      });
      return;
    }
    const keys = Object.keys(params).sort();
    const expectedKeys = ["outputModality", "prompt", "realtimeSessionId", "threadId", "transport", "version", "voice"];
    if (JSON.stringify(keys) !== JSON.stringify(expectedKeys) ||
        params.outputModality !== "audio" || typeof params.prompt !== "string" || params.prompt.length === 0 ||
        params.realtimeSessionId !== null || params.version !== "v3" || params.voice !== null ||
        params.transport?.type !== "webrtc" || typeof params.transport?.sdp !== "string" ||
        !params.transport.sdp.startsWith("v=0\r\n") ||
        !params.transport.sdp.includes("m=audio ") ||
        !params.transport.sdp.includes("m=application ")) {
      send({ id: request.id, error: { code: -32602, message: "unsupported realtime start configuration" } });
      return;
    }
    threadId = request.params.threadId;
    if (mode === "realtime-task18-three-route") realtimePrompt = params.prompt;
    if (mode === "realtime-start-rejected") {
      send({ id: request.id, error: { code: -32602, message: "synthetic provider diagnostic" } });
      return;
    }
    if (mode === "realtime-start-malformed") {
      process.stdout.write("{not-json}\n");
      return;
    }
    if (mode === "realtime-start-error") {
      send({ id: request.id, result: {} });
      notify("thread/realtime/error", { threadId, message: "synthetic provider diagnostic" });
      return;
    }
    if (mode === "realtime-start-closed") {
      send({ id: request.id, result: {} });
      notify("thread/realtime/closed", { threadId, reason: "synthetic provider diagnostic" });
      return;
    }
    if (mode === "wait-realtime-response") {
      fs.writeFileSync(pidPath, "realtime-response\n", { mode: 0o600 });
      return;
    }
    if (mode === "realtime-late-start") {
      send({ id: request.id, result: {} });
      setTimeout(() => { void emitLifecycle(); }, 60);
      return;
    }
    if (mode === "unexpected-sdp") {
      emitRealtimeAnswer(threadId);
      send({ id: request.id, result: {} });
      return;
    }
    if (mode === "missing-sdp") {
      const emittedThread = emitRealtimeStarted();
      send({ id: request.id, result: {} });
      notify("thread/realtime/closed", { threadId: emittedThread, reason: "synthetic-complete" });
      return;
    }
    if (mode === "wait-after-realtime-started") {
      send({ id: request.id, result: {} });
      emitRealtimeStarted();
      fs.writeFileSync(pidPath, "realtime-started\n", { mode: 0o600 });
      return;
    }
    if (mode === "realtime-notification-before-response") emitRealtimeStarted();
    if (mode === "webrtc-started-sdp-response-last") {
      const emittedThread = emitRealtimeStarted();
      emitRealtimeAnswer(emittedThread);
      send({ id: request.id, result: {} });
      notify("thread/realtime/closed", { threadId: emittedThread, reason: "synthetic-complete" });
      return;
    }
    if (mode === "terminal-during-response") {
      const emittedThread = emitRealtimeStarted();
      emitRealtimeAnswer(emittedThread);
      send({ id: request.id, result: {} });
      const terminal = setInterval(() => {
        if (!pidPath || !fs.existsSync(pidPath)) return;
        if (!fs.readFileSync(pidPath, "utf8").includes("response-started\n")) return;
        clearInterval(terminal);
        fs.appendFileSync(pidPath, "terminal-sent\n", { mode: 0o600 });
        notify("thread/realtime/closed", {
          threadId: emittedThread, reason: "synthetic-complete",
        });
      }, 5);
      return;
    }
    if (mode === "duplicate-realtime-started") {
      notify("thread/realtime/started", {
        threadId: request.params.threadId,
        realtimeSessionId: request.params.realtimeSessionId,
        version: "v3",
      });
      notify("thread/realtime/started", {
        threadId: request.params.threadId,
        realtimeSessionId: request.params.realtimeSessionId,
        version: "v3",
      });
    }
    if (mode === "duplicate-realtime-response") {
      send({ id: request.id, result: {} });
      send({ id: request.id, result: {} });
      return;
    }
    if (mode === "realtime-duplicate-thread-started") {
      send({ id: request.id, result: {} });
      notify("thread/started", { thread: threadObject("helper-thread-1") });
      return;
    }
    if (mode === "realtime-item-before-start") {
      send({ id: request.id, result: {} });
      notify("thread/realtime/itemAdded", { threadId, item: { type: "message" } });
      return;
    }
    if (mode === "realtime-start-eof") {
      send({ id: request.id, result: {} });
      emitRealtimeStarted();
      setTimeout(() => process.exit(0), 10);
      return;
    }
    send({ id: request.id, result: {} });
    if (mode === "wait-after-realtime-response") {
      fs.writeFileSync(pidPath, "after-realtime-response\n", { mode: 0o600 });
      return;
    }
    if (mode === "realtime-response-before-thread-started") {
      notify("thread/started", { thread: threadObject("helper-thread-1") });
    }
    if (mode === "realtime-notification-before-response") {
      emitRealtimeAnswer(threadId);
      notify("thread/realtime/transcript/delta", { threadId, role: "assistant", delta: "hel" });
      notify("thread/realtime/transcript/done", { threadId, role: "assistant", text: "hello" });
      notify("thread/realtime/closed", { threadId, reason: "synthetic-complete" });
      return;
    }
    if (mode === "refresh" || mode === "refresh-integer-id" || mode === "refresh-mismatch" || mode === "refresh-invalid-reason") {
      send({
        id: mode === "refresh-integer-id" ? 41 : "server-refresh-1",
        method: "account/chatgptAuthTokens/refresh",
        params: {
          reason: mode === "refresh-invalid-reason" ? "expired" : "unauthorized",
          previousAccountId: mode === "refresh-mismatch" ? "account-other" : "account-1",
        },
      });
      return;
    }
    if (mode === "reuse-second-wait-stop-no-output" && invocation === 1) {
      emitRealtimeStarted();
      emitRealtimeAnswer(threadId);
      notify("thread/realtime/closed", { threadId, reason: "synthetic-complete" });
      return;
    }
    const waitsForStop =
      (mode === "reuse-second-wait-stop" || mode === "reuse-second-wait-stop-no-output") &&
      invocation > 1;
    if (!waitsForStop && !["wait-stop", "wait-stop-close-first", "stop-close-no-ack", "delay-stop", "hold-terminal-cleanup", "wait-stream-close", "wait-append", "hold-append", "wait-output", "wait-output-failed-stop", "output-failed-during-interrupt", "wait-provider-failure-trigger", "stop-on-sdp", "portable-skill-live-routing-proof"].includes(mode)) {
      await emitLifecycle();
    } else {
      emitRealtimeStarted();
      emitRealtimeAnswer(threadId);
      if (mode === "wait-output" || mode === "wait-output-failed-stop" || mode === "output-failed-during-interrupt") {
        notify("thread/realtime/outputAudio/delta", {
          threadId,
          audio: {
            data: Buffer.alloc(4800).toString("base64"),
            sampleRate: 24000,
            numChannels: 1,
            samplesPerChannel: 2400,
            itemId: null,
          },
        });
      }
      if (mode === "output-failed-during-interrupt") {
        setTimeout(() => {
          if (pidPath) fs.writeFileSync(pidPath, "provider-failed\n", { mode: 0o600 });
          notify("thread/realtime/error", {
            threadId,
            message: "synthetic provider diagnostic that must lose to playback failure",
          });
        }, 20);
      }
      if (mode === "wait-provider-failure-trigger") {
        const trigger = setInterval(() => {
          if (!pidPath || !fs.existsSync(pidPath)) return;
          if (fs.readFileSync(pidPath, "utf8") !== "emit\n") return;
          clearInterval(trigger);
          fs.writeFileSync(pidPath, "provider-failed\n", { mode: 0o600 });
          notify("thread/realtime/error", {
            threadId,
            message: "synthetic provider diagnostic after local audio failure",
          });
        }, 5);
      }
      if (mode === "wait-stream-close") {
        notify("thread/realtime/transcript/delta", {
          threadId, role: "assistant", delta: "streaming",
        });
      }
    }
    return;
  }
  if (request.method === "thread/realtime/appendAudio") {
    const audio = request.params?.audio;
    if (request.params?.threadId !== threadId || typeof request.id !== "string" ||
        !request.id.includes(":append:") || audio?.sampleRate !== 24000 ||
        audio?.numChannels !== 1 || audio?.samplesPerChannel !== 2400 ||
        Buffer.from(audio?.data ?? "", "base64").length !== 4800) process.exit(46);
    if (mode === "wait-append") send({ id: request.id, result: {} });
    if (mode === "reuse-second-wait-stop-no-output") {
      fs.appendFileSync(pidPath, "append-received\n", { mode: 0o600 });
      send({ id: request.id, result: {} });
    }
    return;
  }
  if (request.method === "thread/realtime/appendText" && liveTextCompatibility) {
    const params = request.params ?? {};
    const keys = Object.keys(params).sort();
    const validShape = JSON.stringify(keys) === JSON.stringify(["role", "text", "threadId"])
      && params.threadId === threadId
      && ["user", "developer", "assistant"].includes(params.role)
      && typeof params.text === "string"
      && params.text.length > 0;
    if (liveTextScenario === "malformed" || !validShape) {
      send({ id: request.id, error: { code: -32602, message: "synthetic append malformed" } });
      return;
    }
    if (liveTextScenario === "oversized" || params.text.length > 768) {
      send({ id: request.id, error: { code: -32602, message: "synthetic append oversized" } });
      return;
    }
    if (liveTextScenario === "cancelled") return;
    const respond = () => {
      if (liveTextScenario === "rejected") {
        send({ id: request.id, error: { code: -32602, message: "synthetic append rejected" } });
        return;
      }
      send({ id: request.id, result: {} });
      if (liveTextScenario === "duplicate") {
        send({ id: request.id, result: {} });
      }
      if (liveTextScenario === "accepted") {
        notify("thread/realtime/transcript/delta", {
          threadId, role: "user", delta: "synthetic-echo",
        });
        notify("thread/realtime/transcript/done", {
          threadId, role: "user", text: "synthetic-echo",
        });
      }
    };
    if (liveTextScenario === "late") setTimeout(respond, 60);
    else respond();
    return;
  }
  if (request.method === "thread/realtime/stop") {
    if (mode === "stop-on-sdp" && pidPath) {
      fs.appendFileSync(pidPath, "stop\n", { mode: 0o600 });
    }
    if ((mode === "wait-output" || mode === "wait-output-failed-stop") && pidPath) {
      fs.appendFileSync(pidPath, "stop-received\n", { mode: 0o600 });
    }
    if (mode === "wait-stop-close-first") {
      notify("thread/realtime/closed", { threadId, reason: "stopped" });
      setTimeout(() => send({ id: request.id, result: {} }), 30);
    } else if (mode === "stop-close-no-ack") {
      if (pidPath) fs.writeFileSync(pidPath, "stop-received\n", { mode: 0o600 });
      notify("thread/realtime/closed", { threadId, reason: "stopped" });
      setTimeout(() => process.exit(0), 10);
    } else if (mode === "wait-output-failed-stop") {
      send({ id: request.id, result: {} });
      notify("thread/realtime/error", {
        threadId,
        message: "synthetic provider diagnostic that must not reach presentation",
      });
    } else if (mode === "delay-stop") {
      fs.writeFileSync(pidPath, "stop-received\n", { mode: 0o600 });
      setTimeout(() => {
        send({ id: request.id, result: {} });
        notify("thread/realtime/closed", { threadId, reason: "stopped" });
      }, 300);
    } else if (mode === "hold-terminal-cleanup") {
      notify("thread/realtime/closed", { threadId, reason: "stopped" });
      fs.writeFileSync(pidPath, "terminal-delivered-cleanup-held\n", { mode: 0o600 });
      setTimeout(() => send({ id: request.id, result: {} }), 300);
    } else {
      send({ id: request.id, result: {} });
      notify("thread/realtime/closed", { threadId, reason: "stopped" });
    }
    return;
  }
  if (request.id === "server-refresh-1" || request.id === 41) {
    if (request.result?.accessToken !== "replacement-token") process.exit(44);
    await emitLifecycle();
  }
});
