import crypto from "node:crypto";
import { streamForProfile } from "./providers.mjs";

const MAXIMUM_EVENTS = 1_024;
const MAXIMUM_RESPONSE_CHARACTERS = 256_000;
const MAXIMUM_DELTA_CHARACTERS = 8_192;
const MAXIMUM_WALL_MILLISECONDS = 60 * 60 * 1_000;
const MAXIMUM_TOOL_CALLS = 256;
const DEFAULT_TOOL_TIMEOUT_MILLISECONDS = 2 * 60 * 1_000;

export class ReasoningOperation {
  constructor(
    record,
    credential,
    emit,
    diagnose,
    providerStream = streamForProfile,
    { toolTimeoutMilliseconds = DEFAULT_TOOL_TIMEOUT_MILLISECONDS } = {},
  ) {
    this.record = record;
    this.credential = credential;
    this.emit = emit;
    this.diagnose = diagnose;
    this.controller = new AbortController();
    this.terminal = false;
    this.eventCount = 0;
    this.responseCharacters = 0;
    this.providerStream = providerStream;
    this.toolTimeoutMilliseconds = toolTimeoutMilliseconds;
    this.pendingTools = new Map();
    this.toolCalls = 0;
    this.providerCallIDs = new Set();
  }

  cancel(requestId, turnId, generation) {
    if (requestId !== this.record.request_id
      || turnId !== this.record.turn_id
      || generation !== this.record.generation) return false;
    this.controller.abort();
    this.terminatePendingTools("cancelled", new Error("aborted"));
    return true;
  }

  resolveToolResult(record) {
    if (record.request_id !== this.record.request_id
      || record.turn_id !== this.record.turn_id
      || record.generation !== this.record.generation) return false;
    const pending = this.pendingTools.get(record.call_id);
    if (!pending) return false;
    this.pendingTools.delete(record.call_id);
    clearTimeout(pending.timer);
    pending.resolve(record);
    return true;
  }

  cancelTool(record) {
    if (record.request_id !== this.record.request_id
      || record.turn_id !== this.record.turn_id
      || record.generation !== this.record.generation) return false;
    const pending = this.pendingTools.get(record.call_id);
    if (!pending) return false;
    this.pendingTools.delete(record.call_id);
    clearTimeout(pending.timer);
    pending.resolve({ ...record, outcome: "cancelled" });
    return true;
  }

  async run() {
    this.send("reasoning.accepted");
    const timer = setTimeout(() => {
      this.controller.abort("response_limit");
      this.terminatePendingTools("cancelled", new Error("response_limit"));
    }, MAXIMUM_WALL_MILLISECONDS);
    try {
      const context = {
        messages: [
          ...this.record.context.map(({ role, text }) => ({ role, content: text })),
          { role: "user", content: [
            this.record.voice_history_attachment,
            this.record.user_text,
          ].filter(Boolean).join("\n\n") },
        ],
        tools: this.record.tools,
      };
      if (this.record.portable_skills?.length) {
        context.messages.unshift({
          role: "user",
          content: portableSkillInstructions(
            this.record.portable_skills,
            this.record.portable_skills_omitted ?? 0,
          ),
        });
      }
      let ordinal = 0;
      let usage;
      let toolsAvailable = context.tools.length > 0;
      let toolsUnavailableEmitted = false;
      while (true) {
        const round = await this.consumeRound(context, toolsAvailable, ordinal);
        ordinal = round.ordinal;
        usage = mergeUsage(usage, round.usage);
        if (round.toolsUnsupported && toolsAvailable) {
          toolsAvailable = false;
          context.tools = [];
          if (!toolsUnavailableEmitted) {
            this.send("reasoning.tool_event", {
              call_id: this.record.request_id,
              status: "tools_unavailable",
            });
            toolsUnavailableEmitted = true;
          }
          continue;
        }
        if (round.toolCalls.length === 0) break;
        const waits = round.toolCalls.map((call) => this.waitForTool(call));
        let results;
        try {
          results = await Promise.all(waits);
        } catch (error) {
          await this.settlePendingTools("cancelled", error);
          await Promise.allSettled(waits);
          throw error;
        }
        if (round.assistantMessage) context.messages.push(round.assistantMessage);
        for (let index = 0; index < round.toolCalls.length; index += 1) {
          context.messages.push(toolResultMessage(round.toolCalls[index], results[index]));
        }
      }
      if (this.controller.signal.aborted) {
        this.send("reasoning.stopped");
      } else {
        if (usage) {
          this.send("reasoning.usage", {
            input_tokens: nonnegativeOrNull(usage.input),
            output_tokens: nonnegativeOrNull(usage.output),
          });
        }
        this.send("reasoning.completed");
      }
    } catch (error) {
      await this.settlePendingTools("cancelled", error);
      if (this.controller.signal.aborted && this.controller.signal.reason !== "response_limit") {
        this.send("reasoning.stopped");
      } else {
        const errorCode = mapProviderError(error);
        this.diagnose(this.record.request_id, "reasoning");
        this.send("reasoning.failed", { error_code: errorCode });
      }
    } finally {
      clearTimeout(timer);
      await this.settlePendingTools("cancelled", new Error("operation_ended"));
    }
  }

  async consumeRound(context, toolsAvailable, ordinal) {
    const stream = this.providerStream(
      this.record.provider_profile,
      this.credential,
      context,
      { signal: this.controller.signal },
    );
    let usage;
    let assistantMessage;
    const toolCalls = [];
    const bufferedText = [];
    let bufferedCharacters = 0;
    for await (const event of stream) {
      if (event.type === "text_delta") {
        const pieces = splitScalars(event.delta, MAXIMUM_DELTA_CHARACTERS);
        for (const text of pieces) {
          const characters = Array.from(text).length;
          if (this.responseCharacters + bufferedCharacters + characters > MAXIMUM_RESPONSE_CHARACTERS) {
            this.controller.abort("response_limit");
            throw new Error("response_limit");
          }
          if (toolsAvailable) {
            bufferedText.push(text);
            bufferedCharacters += characters;
          } else {
            this.responseCharacters += characters;
            this.send("reasoning.text_delta", { ordinal, text });
            ordinal += 1;
          }
        }
      } else if (event.type === "toolcall_end") {
        toolCalls.push(this.admitToolCall(event.toolCall));
      } else if (event.type === "done") {
        usage = event.message?.usage;
        assistantMessage = event.message;
      } else if (event.type === "error") {
        if (toolsAvailable && isToolsUnsupportedError(event.error)) {
          return { ordinal, usage, assistantMessage, toolCalls: [], toolsUnsupported: true };
        }
        const message = providerErrorMessage(event.error);
        throw new Error(message);
      }
    }
    for (const text of bufferedText) {
      this.responseCharacters += Array.from(text).length;
      this.send("reasoning.text_delta", { ordinal, text });
      ordinal += 1;
    }
    return { ordinal, usage, assistantMessage, toolCalls, toolsUnsupported: false };
  }

  admitToolCall(toolCall) {
    if (++this.toolCalls > MAXIMUM_TOOL_CALLS) throw new Error("response_limit");
    const providerCallID = toolCall?.id;
    const name = toolCall?.name;
    const definition = this.record.tools.find((tool) => tool.name === name);
    if (typeof providerCallID !== "string" || providerCallID.length === 0
      || Buffer.byteLength(providerCallID, "utf8") > 256
      || this.providerCallIDs.has(providerCallID)
      || typeof name !== "string" || Buffer.byteLength(name, "utf8") > 128
      || !definition || !toolCall?.arguments || Array.isArray(toolCall.arguments)
      || typeof toolCall.arguments !== "object") {
      throw new Error("malformed_tool_call");
    }
    const argumentsBytes = Buffer.byteLength(JSON.stringify(toolCall.arguments), "utf8");
    if (argumentsBytes > 64 * 1_024) throw new Error("malformed_tool_call");
    this.providerCallIDs.add(providerCallID);
    return {
      providerCallID,
      callID: crypto.randomUUID(),
      name,
      capabilityID: definition.capability_id,
      arguments: toolCall.arguments,
    };
  }

  waitForTool(call) {
    let resolvePending;
    let rejectPending;
    const promise = new Promise((resolve, reject) => {
      resolvePending = resolve;
      rejectPending = reject;
    });
    const timer = setTimeout(() => {
      this.pendingTools.delete(call.callID);
      this.send("reasoning.tool_event", {
        call_id: call.callID,
        capability_id: call.capabilityID,
        status: "timed_out",
      });
      rejectPending(new Error("tool_timeout"));
    }, this.toolTimeoutMilliseconds);
    this.pendingTools.set(call.callID, {
      call, resolve: resolvePending, reject: rejectPending, timer, promise,
    });
    try {
      this.send("reasoning.tool_call", {
        call_id: call.callID,
        capability_id: call.capabilityID,
        arguments: call.arguments,
      });
    } catch (error) {
      clearTimeout(timer);
      this.pendingTools.delete(call.callID);
      rejectPending(error);
    }
    return promise;
  }

  terminatePendingTools(status, error) {
    const pendingTools = [...this.pendingTools.values()];
    this.pendingTools.clear();
    for (const pending of pendingTools) {
      clearTimeout(pending.timer);
      this.send("reasoning.tool_event", {
        call_id: pending.call.callID,
        capability_id: pending.call.capabilityID,
        status,
      });
      pending.reject(error);
    }
    return pendingTools.map((pending) => pending.promise);
  }

  async settlePendingTools(status, error) {
    await Promise.allSettled(this.terminatePendingTools(status, error));
  }

  send(type, payload = {}) {
    if (this.terminal) return;
    const terminal = ["reasoning.completed", "reasoning.stopped", "reasoning.failed"].includes(type);
    if (this.eventCount >= MAXIMUM_EVENTS || (!terminal && this.eventCount >= MAXIMUM_EVENTS - 1)) {
      this.controller.abort("response_limit");
      throw new Error("response_limit");
    }
    this.eventCount += 1;
    this.emit({
      type,
      request_id: this.record.request_id,
      turn_id: this.record.turn_id,
      generation: this.record.generation,
      ...payload,
    });
    if (terminal) {
      this.terminal = true;
    }
  }
}

function portableSkillInstructions(skills, omitted) {
  const sections = skills.map((skill) => [
    `Portable skill [${skill.id}] — ${skill.name}`,
    skill.description,
    skill.markdown,
  ].join("\n"));
  if (omitted > 0) {
    sections.push(`${omitted} enabled skill(s) omitted to stay within the 128 KiB limit.`);
  }
  return sections.join("\n\n");
}

function toolResultMessage(call, result) {
  const content = result.result === undefined ? { outcome: result.outcome } : result.result;
  return {
    role: "toolResult",
    toolCallId: call.providerCallID,
    toolName: call.name,
    content: [{ type: "text", text: JSON.stringify(content) }],
    isError: result.outcome !== "succeeded",
    timestamp: 0,
  };
}

function mergeUsage(accumulated, next) {
  if (!next) return accumulated;
  if (!accumulated) return next;
  return {
    input: sumNonnegative(accumulated.input, next.input),
    output: sumNonnegative(accumulated.output, next.output),
  };
}

function sumNonnegative(left, right) {
  if (!Number.isInteger(left) || left < 0 || !Number.isInteger(right) || right < 0) return undefined;
  return left + right;
}

export function mapProviderError(error) {
  const message = error instanceof Error ? error.message : "";
  if (/\b30[0-9]\b|redirect/i.test(message)) return "redirect_refused";
  if (/\b401\b|\b403\b|unauthori[sz]ed|authentication/i.test(message)) return "authentication_expired";
  if (/\b404\b|model_not_found|unsupported_model/i.test(message)) return "unsupported_model";
  if (/abort/i.test(message)) return "provider_unavailable";
  if (/response_limit/.test(message)) return "response_limit";
  if (/tool_timeout|capability_timeout/.test(message)) return "capability_timeout";
  if (/fetch|network|connect|socket|timeout/i.test(message)) return "network_unavailable";
  return "provider_unavailable";
}

function providerErrorMessage(error) {
  for (const value of [error?.errorMessage, error?.message, error?.error?.message]) {
    if (typeof value === "string" && value.length > 0) return value.slice(0, 1_024);
  }
  return "provider_failure";
}

function isToolsUnsupportedError(error) {
  const code = [error?.code, error?.type, error?.error?.code]
    .find((value) => typeof value === "string") ?? "";
  const message = providerErrorMessage(error);
  if (/^(tools?_unsupported|unsupported_tools?|tool_choice_unsupported|unsupported_tool_calls)$/i.test(code)) {
    return true;
  }
  if (/^(tools?_unsupported|unsupported_tools?|tool_choice_unsupported|unsupported_tool_calls)$/i.test(message)) {
    return true;
  }
  const mentionsTools = /\b(tools?|functions?|function calling|tool_choice)\b/i.test(message);
  const unsupported = /\b(unsupported|not supported|does not support|unavailable)\b/i.test(message);
  return mentionsTools && unsupported
    && (code === "" || /unsupported|invalid_request/i.test(code));
}

function splitScalars(text, size) {
  const scalars = Array.from(text);
  const chunks = [];
  for (let index = 0; index < scalars.length; index += size) {
    chunks.push(scalars.slice(index, index + size).join(""));
  }
  return chunks;
}

function nonnegativeOrNull(value) {
  return Number.isInteger(value) && value >= 0 ? value : null;
}
