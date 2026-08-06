import { strictParse, validateProtocolRecord } from "./strict-json.mjs";

const DEFAULT_MAXIMUM_RECORD_BYTES = 1_048_576;
const MAXIMUM_TOOLS = 2_048;
const MAXIMUM_TOOL_SCHEMA_BYTES = 64 * 1_024;
const MAXIMUM_ARGUMENT_BYTES = 64 * 1_024;
const MAXIMUM_RESULT_BYTES = 256 * 1_024;
const uuidV4 = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const capabilityID = /^(?:codex_account|miller_mcp|provider_native)\/[!-\.0-~]{1,128}\/[!-\.0-~]{1,128}$/;
const toolName = /^[A-Za-z0-9_]{1,128}$/;
const toolOutcomes = new Set([
  "succeeded", "failed", "declined", "timed_out", "cancelled",
]);
const toolStatuses = new Set([
  "started", "awaiting_approval", "running", "succeeded", "failed",
  "declined", "timed_out", "cancelled", "tools_unavailable",
]);

export class FrameDecoder {
  constructor({ maximumRecordBytes = DEFAULT_MAXIMUM_RECORD_BYTES } = {}) {
    this.maximumRecordBytes = maximumRecordBytes;
    this.pending = Buffer.alloc(0);
    this.decoder = new TextDecoder("utf-8", { fatal: true });
  }

  push(chunk) {
    if (!Buffer.isBuffer(chunk)) chunk = Buffer.from(chunk);
    this.pending = Buffer.concat([this.pending, chunk]);
    const records = [];

    while (true) {
      const newline = this.pending.indexOf(0x0a);
      if (newline < 0) {
        if (this.pending.length > this.maximumRecordBytes) throw protocolError("record_too_large");
        return records;
      }
      if (newline > this.maximumRecordBytes) throw protocolError("record_too_large");
      const frame = this.pending.subarray(0, newline);
      this.pending = this.pending.subarray(newline + 1);
      if (frame.includes(0x00) || frame.includes(0x0d)) throw protocolError("invalid_record");
      try {
        const record = strictParse(this.decoder.decode(frame));
        validateGatewayRecord(record);
        records.push(record);
      } catch {
        throw protocolError("invalid_record");
      }
    }
  }

  end() {
    if (this.pending.length !== 0) throw protocolError("invalid_record");
  }
}

export function writeRecord(stream, record) {
  validateGatewayRecord(record);
  const bytes = Buffer.from(`${JSON.stringify(record)}\n`);
  if (bytes.length - 1 > DEFAULT_MAXIMUM_RECORD_BYTES) throw protocolError("record_too_large");
  stream.write(bytes);
}

export function validateGatewayRecord(record) {
  if (!record || Array.isArray(record) || typeof record !== "object") {
    throw protocolError("invalid_record");
  }
  if (record.type === "reasoning.start") {
    validateProtocolRecord(record);
    validateToolDefinitions(record.tools);
    return;
  }
  if (!record.type?.startsWith("reasoning.tool_")) {
    validateProtocolRecord(record);
    return;
  }
  const base = [
    "protocol", "version", "type", "session_id", "request_id", "turn_id",
    "generation", "call_id",
  ];
  const requiredByType = {
    "reasoning.tool_call": ["capability_id", "arguments"],
    "reasoning.tool_result": ["outcome"],
    "reasoning.tool_cancel": [],
    "reasoning.tool_event": ["status"],
  };
  const optionalByType = {
    "reasoning.tool_call": [],
    "reasoning.tool_result": ["result"],
    "reasoning.tool_cancel": [],
    "reasoning.tool_event": ["capability_id"],
  };
  const required = requiredByType[record.type];
  if (!required || record.protocol !== "miller.gateway" || record.version !== 1
    || !uuidV4.test(record.session_id) || !uuidV4.test(record.request_id)
    || !uuidV4.test(record.turn_id) || !Number.isInteger(record.generation)
    || record.generation < 0 || !uuidV4.test(record.call_id)) {
    throw protocolError("invalid_record");
  }
  requireExactKeys(record, [...base, ...required], optionalByType[record.type]);
  rejectNUL(record);
  if (record.type === "reasoning.tool_call") {
    validateCapabilityID(record.capability_id);
    validateJSONObject(record.arguments, MAXIMUM_ARGUMENT_BYTES);
  } else if (record.type === "reasoning.tool_result") {
    if (!toolOutcomes.has(record.outcome)) throw protocolError("invalid_record");
    if (record.outcome === "succeeded" || record.outcome === "failed") {
      if (!Object.hasOwn(record, "result")) throw protocolError("invalid_record");
      validateJSONObject(record.result, MAXIMUM_RESULT_BYTES);
    } else if (Object.hasOwn(record, "result")) {
      throw protocolError("invalid_record");
    }
  } else if (record.type === "reasoning.tool_event") {
    if (!toolStatuses.has(record.status)) throw protocolError("invalid_record");
    if (Object.hasOwn(record, "capability_id")) {
      validateCapabilityID(record.capability_id);
    }
  }
}

function validateToolDefinitions(tools) {
  if (!Array.isArray(tools) || tools.length > MAXIMUM_TOOLS) {
    throw protocolError("invalid_record");
  }
  const capabilityIDs = new Set();
  const names = new Set();
  for (const tool of tools) {
    requireExactKeys(tool, ["capability_id", "name", "description", "input_schema"]);
    validateCapabilityID(tool.capability_id);
    if (!toolName.test(tool.name) || typeof tool.description !== "string"
      || Buffer.byteLength(tool.description, "utf8") > 1_024
      || capabilityIDs.has(tool.capability_id) || names.has(tool.name)) {
      throw protocolError("invalid_record");
    }
    rejectNUL(tool);
    validateJSONObject(tool.input_schema, MAXIMUM_TOOL_SCHEMA_BYTES);
    capabilityIDs.add(tool.capability_id);
    names.add(tool.name);
  }
}

function validateCapabilityID(value) {
  if (typeof value !== "string" || Buffer.byteLength(value, "utf8") > 192
    || !capabilityID.test(value) || value !== value.toLowerCase()
    || value.includes("//") || value.includes(" ")) {
    throw protocolError("invalid_record");
  }
}

function validateJSONObject(value, maximumBytes) {
  if (!value || Array.isArray(value) || typeof value !== "object") {
    throw protocolError("invalid_record");
  }
  validateJSONValue(value, maximumBytes);
}

function validateJSONValue(value, maximumBytes) {
  let encoded;
  try {
    encoded = JSON.stringify(value);
  } catch {
    throw protocolError("invalid_record");
  }
  if (encoded === undefined || Buffer.byteLength(encoded, "utf8") > maximumBytes) {
    throw protocolError("invalid_record");
  }
  rejectNUL(value);
}

function requireExactKeys(value, required, optional = []) {
  if (!value || Array.isArray(value) || typeof value !== "object") {
    throw protocolError("invalid_record");
  }
  const keys = new Set(Object.keys(value));
  if (!required.every((key) => keys.has(key))
    || [...keys].some((key) => !required.includes(key) && !optional.includes(key))) {
    throw protocolError("invalid_record");
  }
}

function rejectNUL(value) {
  if (typeof value === "string") {
    if (value.includes("\0")) throw protocolError("invalid_record");
    return;
  }
  if (!value || typeof value !== "object") return;
  for (const [key, nested] of Object.entries(value)) {
    rejectNUL(key);
    rejectNUL(nested);
  }
}

function protocolError(code) {
  const error = new Error(code);
  error.code = code;
  return error;
}
