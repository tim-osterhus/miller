import { streamForProfile } from "./providers.mjs";

const MAXIMUM_EVENTS = 1_024;
const MAXIMUM_RESPONSE_CHARACTERS = 256_000;
const MAXIMUM_DELTA_CHARACTERS = 8_192;
const MAXIMUM_WALL_MILLISECONDS = 60 * 60 * 1_000;

export class ReasoningOperation {
  constructor(record, credential, emit, diagnose) {
    this.record = record;
    this.credential = credential;
    this.emit = emit;
    this.diagnose = diagnose;
    this.controller = new AbortController();
    this.terminal = false;
    this.eventCount = 0;
    this.responseCharacters = 0;
  }

  cancel(requestId, turnId, generation) {
    if (requestId !== this.record.request_id
      || turnId !== this.record.turn_id
      || generation !== this.record.generation) return false;
    this.controller.abort();
    return true;
  }

  async run() {
    this.send("reasoning.accepted");
    const timer = setTimeout(() => this.controller.abort("response_limit"), MAXIMUM_WALL_MILLISECONDS);
    try {
      const stream = streamForProfile(
        this.record.provider_profile,
        this.credential,
        {
          messages: [
            ...this.record.context.map(({ role, text }) => ({ role, content: text })),
            { role: "user", content: [
              this.record.voice_history_attachment,
              this.record.user_text,
            ].filter(Boolean).join("\n\n") },
          ],
        },
        { signal: this.controller.signal },
      );
      let ordinal = 0;
      let usage;
      for await (const event of stream) {
        if (event.type === "text_delta") {
          const pieces = splitScalars(event.delta, MAXIMUM_DELTA_CHARACTERS);
          for (const text of pieces) {
            this.responseCharacters += Array.from(text).length;
            if (this.responseCharacters > MAXIMUM_RESPONSE_CHARACTERS) {
              this.controller.abort("response_limit");
              throw new Error("response_limit");
            }
            this.send("reasoning.text_delta", { ordinal, text });
            ordinal += 1;
          }
        } else if (event.type === "done") {
          usage = event.message?.usage;
        } else if (event.type === "error") {
          throw new Error(event.error?.errorMessage ?? "provider_failure");
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
      if (this.controller.signal.aborted && this.controller.signal.reason !== "response_limit") {
        this.send("reasoning.stopped");
      } else {
        const errorCode = mapProviderError(error);
        this.diagnose(this.record.request_id, "reasoning");
        this.send("reasoning.failed", { error_code: errorCode });
      }
    } finally {
      clearTimeout(timer);
    }
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

export function mapProviderError(error) {
  const message = error instanceof Error ? error.message : "";
  if (/\b30[0-9]\b|redirect/i.test(message)) return "redirect_refused";
  if (/\b401\b|\b403\b|unauthori[sz]ed|authentication/i.test(message)) return "authentication_expired";
  if (/\b404\b|model_not_found|unsupported_model/i.test(message)) return "unsupported_model";
  if (/abort/i.test(message)) return "provider_unavailable";
  if (/response_limit/.test(message)) return "response_limit";
  if (/fetch|network|connect|socket|timeout/i.test(message)) return "network_unavailable";
  return "provider_unavailable";
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
