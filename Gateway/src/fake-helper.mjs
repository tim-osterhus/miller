import crypto from "node:crypto";
import { strictParse, requireClosedObject, validateProtocolRecord } from "./strict-json.mjs";
import { codexModelCatalog } from "./codex-models.mjs";

const mode = process.argv[2] ?? "normal";
const sessionId = crypto.randomUUID();
const maximumRecordBytes = 1_048_576;
const qualificationDeltaDelayMs = 750;
const qualificationCompletionDelayMs = 5_000;
let pending = Buffer.alloc(0);
let active = null;

function write(record) {
  process.stdout.write(`${JSON.stringify(record)}\n`);
}

function base(type, requestId) {
  return {
    protocol: "miller.gateway",
    version: 1,
    type,
    session_id: sessionId,
    request_id: requestId,
  };
}

function fail() {
  process.stderr.write("fake_input_invalid\n");
  process.exit(70);
}

function clearActiveTimers(operation) {
  for (const timer of operation?.timers ?? []) clearTimeout(timer);
}

function validateBase(record) {
  if (
    record.protocol !== "miller.gateway"
    || record.version !== 1
    || record.session_id !== sessionId
    || typeof record.request_id !== "string"
  ) {
    throw new Error("invalid_record");
  }
}

function handle(record) {
  validateProtocolRecord(record);
  validateBase(record);
  if (record.type === "provider.models") {
    requireClosedObject(record, [
      "protocol", "version", "type", "session_id", "request_id", "provider_kind",
    ]);
    if (record.provider_kind !== "codex_oauth") throw new Error("configuration_invalid");
    const catalog = codexModelCatalog();
    write({
      ...base("provider.models_result", record.request_id),
      provider_kind: "codex_oauth",
      default_model: catalog.defaultModel,
      models: catalog.models.map(({ id, name }) => ({ id, name })),
    });
    return;
  }
  if (record.type === "reasoning.start") {
    requireClosedObject(record, [
      "protocol", "version", "type", "session_id", "request_id",
      "conversation_id", "turn_id", "generation", "provider_profile",
      "context", "user_text", "tools",
    ], ["voice_history_attachment", "portable_skills", "portable_skills_omitted"]);
    if (active) throw new Error("operation_active");
    active = {
      requestId: record.request_id,
      turnId: record.turn_id,
      generation: record.generation,
      timers: [],
    };
    if (mode === "crash") process.exit(17);
    if (mode === "malformed") {
      process.stdout.write('{"protocol":\n');
      return;
    }
    if (mode === "oversized") {
      process.stdout.write(`${"x".repeat(maximumRecordBytes + 1)}\n`);
      return;
    }
    if (mode === "wrong-session") {
      write({
        ...base("reasoning.accepted", record.request_id),
        session_id: crypto.randomUUID(),
        turn_id: record.turn_id,
        generation: record.generation,
      });
      return;
    }
    write({
      ...base("reasoning.accepted", record.request_id),
      turn_id: record.turn_id,
      generation: record.generation,
    });
    if (mode === "portable-skill-routing-proof") {
      const skills = record.portable_skills ?? [];
      const omitted = record.portable_skills_omitted ?? 0;
      if (!Array.isArray(skills) || !Number.isInteger(omitted)) fail();
      if (skills.length > 0) {
        if (skills.length !== 1 || omitted !== 0) fail();
        const skill = skills[0];
        if (Object.keys(skill).sort().join(",") !== "description,id,markdown,name"
            || skill.name !== "Weather"
            || skill.description !== "Forecast guidance"
            || !skill.markdown.includes("Use forecasts.")) fail();
      }
      write({
        ...base("reasoning.text_delta", record.request_id),
        turn_id: record.turn_id,
        generation: record.generation,
        ordinal: 0,
        text: skills.length === 1 ? "portable" : "ordinary",
      });
      write({
        ...base("reasoning.completed", record.request_id),
        turn_id: record.turn_id,
        generation: record.generation,
      });
      active = null;
      return;
    }
    if (mode === "markdown-qualification") {
      write({
        ...base("reasoning.text_delta", record.request_id),
        turn_id: record.turn_id,
        generation: record.generation,
        ordinal: 0,
        text: [
          "# Sample response",
          "",
          "**Bold text** and [a link](https://example.com).",
          "",
          "- First item",
          "- Second item",
          "",
          "Use `inline code`.",
          "",
          "```swift",
          "let value = 1",
          "```",
        ].join("\n"),
      });
      write({
        ...base("reasoning.completed", record.request_id),
        turn_id: record.turn_id,
        generation: record.generation,
      });
      active = null;
      return;
    }
    if (mode === "unsupported-model") {
      write({
        ...base("reasoning.failed", record.request_id),
        turn_id: record.turn_id,
        generation: record.generation,
        error_code: "unsupported_model",
      });
      active = null;
      return;
    }
    write({
      ...base("reasoning.text_delta", record.request_id),
      turn_id: record.turn_id,
      generation: record.generation,
      ordinal: 0,
      text: `fake: ${record.voice_history_attachment ? `${record.voice_history_attachment}\n\n` : ""}${record.user_text}`,
    });
    if (mode === "qualification" || mode === "cancellation-qualification") {
      const operation = active;
      operation.timers.push(setTimeout(() => {
        if (active !== operation) return;
        write({
          ...base("reasoning.text_delta", record.request_id),
          turn_id: record.turn_id,
          generation: record.generation,
          ordinal: 1,
          text: " [complete]",
        });
      }, qualificationDeltaDelayMs));
      operation.timers.push(setTimeout(() => {
        if (active !== operation) return;
        write({
          ...base("reasoning.completed", record.request_id),
          turn_id: record.turn_id,
          generation: record.generation,
        });
        active = null;
      }, mode === "cancellation-qualification"
        ? 30_000
        : qualificationCompletionDelayMs));
      return;
    }
    if (mode !== "hang-on-cancel") {
      write({
        ...base("reasoning.completed", record.request_id),
        turn_id: record.turn_id,
        generation: record.generation,
      });
      active = null;
      if (mode === "late-delta") {
        write({
          ...base("reasoning.text_delta", record.request_id),
          turn_id: record.turn_id,
          generation: record.generation,
          ordinal: 1,
          text: "late",
        });
      }
      if (mode === "terminal-then-exit") process.exit(19);
    }
    return;
  }

  if (record.type === "reasoning.cancel") {
    requireClosedObject(record, [
      "protocol", "version", "type", "session_id", "request_id",
      "turn_id", "target_generation",
    ]);
    if (!active || record.turn_id !== active.turnId
      || record.target_generation !== active.generation) {
      throw new Error("invalid_cancel");
    }
    if (mode === "hang-on-cancel") return;
    clearActiveTimers(active);
    write({
      ...base("reasoning.stopped", active.requestId),
      turn_id: active.turnId,
      generation: active.generation,
    });
    active = null;
    return;
  }

  throw new Error("unknown_record");
}

write({
  protocol: "miller.gateway",
  version: 1,
  type: "gateway.ready",
  session_id: sessionId,
  helper_version: "fake-1",
  supported_protocols: [1],
});

if (mode === "stdout-contamination") process.stdout.write("not-json\n");
if (mode === "stderr-flood") process.stderr.write(`${"x".repeat(4_097)}\n`);

process.stdin.on("data", (chunk) => {
  pending = Buffer.concat([pending, chunk]);
  if (pending.length > maximumRecordBytes && !pending.includes(0x0a)) {
    fail();
    return;
  }
  while (true) {
    const newline = pending.indexOf(0x0a);
    if (newline < 0) break;
    const line = pending.subarray(0, newline);
    pending = pending.subarray(newline + 1);
    if (line.includes(0x00) || line.includes(0x0d) || line.length > maximumRecordBytes) {
      fail();
      return;
    }
    try {
      handle(strictParse(new TextDecoder("utf-8", { fatal: true }).decode(line)));
    } catch {
      fail();
      return;
    }
  }
});

process.stdin.on("end", () => {
  if (pending.length !== 0) process.exitCode = 70;
});
