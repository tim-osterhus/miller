const whitespace = new Set([" ", "\t", "\n", "\r"]);

export function strictParse(text) {
  if (text.includes("\0")) throw new Error("invalid_json");
  let index = 0;

  function skipWhitespace() {
    while (index < text.length && whitespace.has(text[index])) index += 1;
  }

  function parseString() {
    const start = index;
    if (text[index++] !== '"') throw new Error("invalid_json");
    while (index < text.length) {
      const character = text[index++];
      if (character === '"') return JSON.parse(text.slice(start, index));
      if (character.charCodeAt(0) < 0x20) throw new Error("invalid_json");
      if (character === "\\") {
        const escape = text[index++];
        if (escape === "u") {
          const digits = text.slice(index, index + 4);
          if (!/^[0-9a-fA-F]{4}$/.test(digits)) throw new Error("invalid_json");
          index += 4;
        } else if (!'"\\/bfnrt'.includes(escape)) {
          throw new Error("invalid_json");
        }
      }
    }
    throw new Error("invalid_json");
  }

  function parseObject() {
    index += 1;
    skipWhitespace();
    const keys = new Set();
    if (text[index] === "}") {
      index += 1;
      return;
    }
    while (index < text.length) {
      const key = parseString();
      if (keys.has(key)) throw new Error("duplicate_key");
      keys.add(key);
      skipWhitespace();
      if (text[index++] !== ":") throw new Error("invalid_json");
      skipWhitespace();
      parseValue();
      skipWhitespace();
      if (text[index] === "}") {
        index += 1;
        return;
      }
      if (text[index++] !== ",") throw new Error("invalid_json");
      skipWhitespace();
    }
    throw new Error("invalid_json");
  }

  function parseArray() {
    index += 1;
    skipWhitespace();
    if (text[index] === "]") {
      index += 1;
      return;
    }
    while (index < text.length) {
      parseValue();
      skipWhitespace();
      if (text[index] === "]") {
        index += 1;
        return;
      }
      if (text[index++] !== ",") throw new Error("invalid_json");
      skipWhitespace();
    }
    throw new Error("invalid_json");
  }

  function parseValue() {
    if (text[index] === "{") return parseObject();
    if (text[index] === "[") return parseArray();
    if (text[index] === '"') return parseString();
    const remainder = text.slice(index);
    const token = remainder.match(/^(?:true|false|null|-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?)/)?.[0];
    if (!token) throw new Error("invalid_json");
    index += token.length;
  }

  skipWhitespace();
  parseValue();
  skipWhitespace();
  if (index !== text.length) throw new Error("invalid_json");
  const value = JSON.parse(text);
  rejectDecodedNUL(value);
  return value;
}

function rejectDecodedNUL(value) {
  if (typeof value === "string") {
    if (value.includes("\0")) throw new Error("invalid_json");
    return;
  }
  if (Array.isArray(value)) {
    for (const item of value) rejectDecodedNUL(item);
    return;
  }
  if (value !== null && typeof value === "object") {
    for (const [key, item] of Object.entries(value)) {
      rejectDecodedNUL(key);
      rejectDecodedNUL(item);
    }
  }
}

export function requireClosedObject(record, required, optional = []) {
  if (record === null || Array.isArray(record) || typeof record !== "object") {
    throw new Error("invalid_record");
  }
  const allowed = new Set([...required, ...optional]);
  for (const key of Object.keys(record)) {
    if (!allowed.has(key)) throw new Error("unknown_field");
  }
  for (const key of required) {
    if (!Object.hasOwn(record, key)) throw new Error("missing_field");
  }
}

const uuidV4 = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const readinessStatuses = new Set([
  "ready", "refresh_required", "authentication_required", "configuration_invalid",
  "network_unavailable", "provider_unavailable", "unsupported_model", "failed",
]);
const reasoningFailureCodes = new Set([
  "authentication_expired", "network_unavailable", "provider_unavailable",
  "unsupported_model", "response_limit", "gateway_unavailable",
  "redirect_refused", "capability_timeout",
]);
const protocolSchemas = {
  "gateway.ready": { request: false, required: { helper_version: "string", supported_protocols: "protocols" } },
  "provider.readiness": { required: { provider_profile: "profile", credential_ref: "uuid" } },
  "provider.readiness_result": { required: { status: "readiness-status" }, optional: { error_code: "string" } },
  "provider.models": { required: { provider_kind: "string" } },
  "provider.models_result": {
    required: {
      provider_kind: "string",
      default_model: "string",
      models: "model-choices",
    },
  },
  "auth.begin": { required: { operation_id: "uuid", generation: "nonnegative", credential_ref: "uuid", provider_kind: "string" } },
  "auth.refresh": { required: { operation_id: "uuid", generation: "nonnegative", credential_ref: "uuid" } },
  "auth.open_url": { required: { operation_id: "uuid", generation: "nonnegative", url: "string" } },
  "auth.credential_candidate": { required: { operation_id: "uuid", generation: "nonnegative", credential_ref: "uuid", credential: "object" } },
  "auth.persisted": { required: { operation_id: "uuid", generation: "nonnegative", credential_ref: "uuid" } },
  "auth.persist_failed": { required: { operation_id: "uuid", generation: "nonnegative", credential_ref: "uuid" } },
  "auth.restore": { required: { operation_id: "uuid", generation: "nonnegative", credential_ref: "uuid", credential: "object" } },
  "auth.cancel": { required: { operation_id: "uuid", target_generation: "nonnegative" } },
  "auth.clear": { required: { operation_id: "uuid", generation: "nonnegative", credential_ref: "uuid" } },
  "auth.completed": { required: { operation_id: "uuid", generation: "nonnegative", credential_ref: "uuid" } },
  "auth.stopped": { required: { operation_id: "uuid", generation: "nonnegative" } },
  "auth.failed": { required: { operation_id: "uuid", generation: "nonnegative", error_code: "string" } },
  "reasoning.start": { required: { conversation_id: "uuid", turn_id: "uuid", generation: "nonnegative", provider_profile: "profile", context: "context", user_text: "user-text", tools: "array" }, optional: { voice_history_attachment: "voice-history", portable_skills: "portable-skills", portable_skills_omitted: "nonnegative" } },
  "reasoning.cancel": { required: { turn_id: "uuid", target_generation: "nonnegative" } },
  "reasoning.accepted": { required: { turn_id: "uuid", generation: "nonnegative" } },
  "reasoning.text_delta": { required: { turn_id: "uuid", generation: "nonnegative", ordinal: "nonnegative", text: "text" } },
  "reasoning.usage": { required: { turn_id: "uuid", generation: "nonnegative" }, optional: { input_tokens: "nullable-nonnegative", output_tokens: "nullable-nonnegative" } },
  "reasoning.completed": { required: { turn_id: "uuid", generation: "nonnegative" } },
  "reasoning.stopped": { required: { turn_id: "uuid", generation: "nonnegative" } },
  "reasoning.failed": { required: { turn_id: "uuid", generation: "nonnegative", error_code: "reasoning-failure-code" } },
};

export function validateProtocolRecord(record) {
  if (record === null || Array.isArray(record) || typeof record !== "object") {
    throw new Error("invalid_record");
  }
  if (typeof record.type !== "string") throw new Error("invalid_record");
  const schema = protocolSchemas[record.type];
  if (!schema || record.protocol !== "miller.gateway" || record.version !== 1
    || !isUUID(record.session_id)) {
    throw new Error("invalid_record");
  }

  const required = ["protocol", "version", "type", "session_id", ...Object.keys(schema.required)];
  if (schema.request !== false) required.push("request_id");
  requireClosedObject(record, required, Object.keys(schema.optional ?? {}));
  if (schema.request !== false && !isUUID(record.request_id)) throw new Error("invalid_record");
  rejectDecodedNUL(record);

  for (const [field, kind] of Object.entries(schema.required)) validateField(record[field], kind);
  for (const [field, kind] of Object.entries(schema.optional ?? {})) {
    if (Object.hasOwn(record, field)) validateField(record[field], kind);
  }
}

export function validateProtocolSequence(records) {
  let sessionID;
  const requests = new Map();

  for (const record of records) {
    validateProtocolRecord(record);
    if (record.type === "gateway.ready") {
      if (sessionID !== undefined) throw new Error("invalid_sequence");
      sessionID = record.session_id;
      continue;
    }
    if (record.type === "reasoning.start") {
      if (record.session_id !== sessionID || requests.has(record.request_id)) {
        throw new Error("invalid_sequence");
      }
      requests.set(record.request_id, {
        turnID: record.turn_id,
        generation: record.generation,
        nextOrdinal: 0,
        phase: "awaiting-accepted",
      });
      continue;
    }

    const state = requests.get(record.request_id);
    if (record.session_id !== sessionID || !state || state.phase === "terminal"
      || record.turn_id !== state.turnID || record.generation !== state.generation) {
      throw new Error("invalid_sequence");
    }
    switch (record.type) {
      case "reasoning.accepted":
        if (state.phase !== "awaiting-accepted") throw new Error("invalid_sequence");
        state.phase = "streaming";
        break;
      case "reasoning.text_delta":
        if (state.phase !== "streaming" || record.ordinal !== state.nextOrdinal) {
          throw new Error("invalid_sequence");
        }
        state.nextOrdinal += 1;
        break;
      case "reasoning.usage":
        if (state.phase !== "streaming") throw new Error("invalid_sequence");
        break;
      case "reasoning.completed":
      case "reasoning.stopped":
      case "reasoning.failed":
        if (state.phase !== "streaming") throw new Error("invalid_sequence");
        state.phase = "terminal";
        break;
      default:
        throw new Error("invalid_sequence");
    }
  }
}

function validateField(value, kind) {
  switch (kind) {
    case "string":
      if (typeof value !== "string") throw new Error("invalid_field");
      return;
    case "uuid":
      if (!isUUID(value)) throw new Error("invalid_field");
      return;
    case "nonnegative":
      if (!Number.isInteger(value) || value < 0) throw new Error("invalid_field");
      return;
    case "nullable-nonnegative":
      if (value !== null && (!Number.isInteger(value) || value < 0)) throw new Error("invalid_field");
      return;
    case "readiness-status":
      if (!readinessStatuses.has(value)) throw new Error("invalid_field");
      return;
    case "reasoning-failure-code":
      if (!reasoningFailureCodes.has(value)) throw new Error("invalid_field");
      return;
    case "protocols":
      if (!Array.isArray(value) || !value.every(Number.isInteger) || !value.includes(1)) {
        throw new Error("invalid_field");
      }
      return;
    case "object":
      if (value === null || Array.isArray(value) || typeof value !== "object") throw new Error("invalid_field");
      return;
    case "array":
      if (!Array.isArray(value)) throw new Error("invalid_field");
      return;
    case "model-choices":
      validateModelChoices(value);
      return;
    case "profile":
      validateProfile(value);
      return;
    case "context":
      if (!Array.isArray(value)) throw new Error("invalid_field");
      for (const message of value) validateContextMessage(message);
      return;
    case "user-text":
      if (typeof value !== "string" || Array.from(value).length > 65_536) throw new Error("invalid_field");
      return;
    case "voice-history":
      if (typeof value !== "string" || Buffer.byteLength(value, "utf8") > 32 * 1024) throw new Error("invalid_field");
      return;
    case "portable-skills":
      validatePortableSkills(value);
      return;
    case "text":
      if (typeof value !== "string" || Array.from(value).length > 8_192) throw new Error("invalid_field");
      return;
    default:
      throw new Error("unclassified_constraint");
  }
}

function validatePortableSkills(value) {
  if (!Array.isArray(value) || value.length > 128) throw new Error("invalid_field");
  const ids = new Set();
  let bytes = 0;
  for (const skill of value) {
    requireClosedObject(skill, ["id", "name", "description", "markdown"]);
    if (typeof skill.id !== "string" || !skill.id || Buffer.byteLength(skill.id) > 96
      || !/^[A-Za-z0-9._-]+$/.test(skill.id)
      || ids.has(skill.id) || typeof skill.name !== "string" || !skill.name
      || Buffer.byteLength(skill.name) > 256
      || typeof skill.description !== "string" || !skill.description
      || Buffer.byteLength(skill.description) > 1024
      || typeof skill.markdown !== "string" || Buffer.byteLength(skill.markdown) > 64 * 1024) {
      throw new Error("invalid_field");
    }
    ids.add(skill.id);
    bytes += Buffer.byteLength(skill.id) + Buffer.byteLength(skill.name)
      + Buffer.byteLength(skill.description) + Buffer.byteLength(skill.markdown);
    if (bytes > 128 * 1024) throw new Error("invalid_field");
  }
}

function validateModelChoices(value) {
  if (!Array.isArray(value)) throw new Error("invalid_field");
  for (const choice of value) {
    requireClosedObject(choice, ["id", "name"]);
    if (typeof choice.id !== "string" || typeof choice.name !== "string") {
      throw new Error("invalid_field");
    }
  }
}

function validateProfile(value) {
  requireClosedObject(value, ["kind", "model", "credential_ref"], ["base_url"]);
  if (!["codex_oauth", "openai_compatible", "fake"].includes(value.kind)
    || typeof value.model !== "string" || !isUUID(value.credential_ref)
    || (Object.hasOwn(value, "base_url") && value.base_url !== null && typeof value.base_url !== "string")) {
    throw new Error("invalid_field");
  }
}

function validateContextMessage(value) {
  requireClosedObject(value, ["role", "text"]);
  if (!["user", "assistant"].includes(value.role) || typeof value.text !== "string") {
    throw new Error("invalid_field");
  }
}

function isUUID(value) {
  return typeof value === "string" && uuidV4.test(value);
}
