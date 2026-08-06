import fs from "node:fs";
import { spawn } from "node:child_process";
import readline from "node:readline";

const mode = process.argv[2] ?? "normal";
const pidPath = process.argv[3];
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
if (mode === "record-stdin") {
  lines.on("line", (line) => fs.appendFileSync(pidPath, `${line}\n`, { mode: 0o600 }));
}
let threadId = "thread-1";
let helperThreadCreated = false;
let typedTurnId = "typed-turn-1";
const expectedFeatureConfig = "[features]\nrealtime_conversation = true\n\n[realtime]\nversion = \"v1\"\n";

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

const answerSDP = "v=0\r\ns=-\r\n";

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

function emitLifecycle() {
  const emittedThread = emitRealtimeStarted();
  if (mode === "crash-after-start") process.exit(23);
  emitRealtimeAnswer(emittedThread);
  if (mode === "realtime-error") {
    notify("thread/realtime/error", { threadId: emittedThread, message: "synthetic realtime error" });
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

function threadStartResult(id) {
  const result = {
    thread: threadObject(), model: "gpt-live", modelProvider: "openai", serviceTier: null,
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

lines.on("line", (line) => {
  if (mode === "malformed") {
    process.stdout.write("{not-json}\n");
    return;
  }
  if (mode === "oversized") {
    process.stdout.write(`{"method":"${"x".repeat(1_100_000)}"}\n`);
    return;
  }
  const request = JSON.parse(line);
  if (mode.startsWith("typed-")) {
    if ((mode === "typed-record" || mode === "typed-probe-record") && pidPath) {
      fs.appendFileSync(pidPath, `${line}\n`, { mode: 0o600 });
    }
    if (request.method === "initialize") {
      if (request.params?.capabilities?.experimentalApi !== true) {
        send({ id: request.id, error: { code: -32602, message: "experimental API required" } });
        return;
      }
      send({ id: request.id, result: initializeResult() });
      return;
    }
    if (request.method === "initialized") return;
    if (request.method === "account/login/start") {
      send({ id: request.id, result: { type: "chatgptAuthTokens" } });
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
      if (mode === "typed-startup-wait") {
        if (pidPath) fs.writeFileSync(pidPath, "thread-start-pending\n", { mode: 0o600 });
        return;
      }
      helperThreadCreated = true;
      threadId = "typed-thread-1";
      const response = { id: request.id, result: { thread: { id: threadId } } };
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
      if (!helperThreadCreated || request.params?.threadId !== threadId ||
          !Array.isArray(request.params?.input) || request.params.input.length !== 1 ||
          request.params.input[0]?.type !== "text" || request.params?.approvalPolicy !== "never" ||
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
      if (mode === "typed-turn-notification-first") {
        emitTypedTurnStarted();
        send(typedTurnResponse);
      } else {
        send(typedTurnResponse);
        emitTypedTurnStarted();
      }
      if (mode === "typed-wait") {
        if (pidPath) fs.writeFileSync(pidPath, "turn-started\n", { mode: 0o600 });
        return;
      }
      if (mode.startsWith("typed-probe-")) {
        if (mode !== "typed-probe-no-stream") {
          notify("item/agentMessage/delta", {
            threadId, turnId: typedTurnId, itemId: "typed-probe-message-1", delta: "OK",
          });
        }
        notify("turn/completed", {
          threadId,
          turn: {
            id: typedTurnId,
            status: mode === "typed-probe-failed-terminal" ? "failed" : "completed",
            items: [],
            error: mode === "typed-probe-failed-terminal"
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
      if (mode === "typed-approval") {
        send({
          id: "approval-request-1",
          method: "item/commandExecution/requestApproval",
          params: {
            threadId, turnId: typedTurnId, itemId: "approval-item-1",
            reason: "private approval reason",
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
            ? { resourceUri: "private://resource" }
            : undefined;
          notify("item/started", {
            threadId, turnId: typedTurnId,
            item: {
              type: wireType, id: `cap-${type}`, status: "inProgress",
              appContext, arguments: { secret: "private" },
            },
          });
          notify("item/completed", {
            threadId, turnId: typedTurnId,
            item: {
              type: wireType, id: `cap-${type}`, status: "completed",
              appContext, result: { secret: "private" },
            },
          });
        }
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
    if (mode === "typed-approval" && request.id === "approval-request-1") {
      if (request.result?.decision !== "decline") process.exit(47);
      notify("turn/completed", {
        threadId,
        turn: {
          id: typedTurnId, status: "failed", items: [],
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
    if (mode === "unknown-field") result.unexpected = true;
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
    if (mode === "login-response-extra") loginResult.future = true;
    send({ id: request.id, result: loginResult });
    if (mode !== "thread-response-before-login-notifications" &&
        mode !== "login-notifications-before-response" &&
        mode !== "wait-after-thread-created") emitAccountNotifications();
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
    if (mode === "thread-notification-before-response") {
      notify("thread/started", { thread: threadObject("helper-thread-1") });
    }
    send(threadStartResult(request.id));
    if (mode === "wait-after-thread-created") {
      fs.writeFileSync(pidPath, "after-thread-created\n", { mode: 0o600 });
      return;
    }
    if (mode === "thread-response-before-login-notifications") emitAccountNotifications();
    if (mode === "realtime-response-before-thread-started" ||
        mode === "thread-notification-before-response") return;
    const startedThread = threadObject(mode === "thread-started-wrong-thread" ? "helper-other" : "helper-thread-1");
    const startedParams = { thread: startedThread };
    if (mode === "thread-started-unknown-field") startedParams.future = true;
    notify("thread/started", startedParams);
    if (mode === "duplicate-thread-started") notify("thread/started", startedParams);
    return;
  }
  if (request.method === "thread/realtime/start") {
    if (!helperThreadCreated || request.params.threadId !== "helper-thread-1") {
      send({ id: request.id, error: { code: -32600, message: "thread not loaded" } });
      return;
    }
    const params = request.params ?? {};
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
    if (!waitsForStop && !["wait-stop", "wait-stop-close-first", "stop-close-no-ack", "delay-stop", "hold-terminal-cleanup", "wait-stream-close", "wait-append", "hold-append", "wait-output", "wait-output-failed-stop", "output-failed-during-interrupt", "wait-provider-failure-trigger", "stop-on-sdp"].includes(mode)) {
      emitLifecycle();
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
    emitLifecycle();
  }
});
