import crypto from "node:crypto";
import { CredentialStore } from "./credential-store.mjs";
import {
  beginCodexAuthentication,
  normalizeProviderProfile,
  refreshCodexAuthentication,
} from "./providers.mjs";
import { codexModelCatalog, resolveCodexModel } from "./codex-models.mjs";
import { FrameDecoder, writeRecord } from "./protocol.mjs";
import { ReasoningOperation } from "./reasoning.mjs";

const sessionId = crypto.randomUUID();
const credentials = new CredentialStore();
const decoder = new FrameDecoder();
let authOperation;
let reasoningOperation;
let dispatchChain = Promise.resolve();
let closing = false;

function emit(record) {
  writeRecord(process.stdout, {
    protocol: "miller.gateway",
    version: 1,
    session_id: sessionId,
    ...record,
  });
}

function diagnose(requestId, phase) {
  process.stderr.write(`provider_failure ${requestId} ${phase}\n`);
}

function validateSession(record) {
  if (record.session_id !== sessionId) throw new Error("invalid_session");
}

async function dispatch(record) {
  validateSession(record);
  if (record.type === "provider.models") {
    requireIdle();
    if (record.provider_kind !== "codex_oauth") throw new Error("configuration_invalid");
    const catalog = codexModelCatalog();
    emit({
      type: "provider.models_result",
      request_id: record.request_id,
      provider_kind: "codex_oauth",
      default_model: catalog.defaultModel,
      models: catalog.models.map(({ id, name }) => ({ id, name })),
    });
    return;
  }
  if (record.type === "provider.readiness") {
    if (authOperation || reasoningOperation) throw new Error("operation_active");
    let status;
    let error_code;
    try {
      const profile = normalizeProviderProfile(record.provider_profile);
      if (profile.credential_ref !== record.credential_ref) throw new Error("configuration_invalid");
      status = credentials.readiness(record.credential_ref);
      if (status === "ready" && profile.kind === "codex_oauth") {
        const provider = await import("@miller/pi-mvp-overlay/providers/openai-codex");
        resolveCodexModel(provider.openaiCodexProvider(), profile.model);
      }
    } catch (error) {
      status = "configuration_invalid";
      if (error?.message === "provider_unavailable") status = "provider_unavailable";
      if (status === "configuration_invalid") error_code = "configuration_invalid";
    }
    emit({
      type: "provider.readiness_result",
      request_id: record.request_id,
      status,
      ...(error_code ? { error_code } : {}),
    });
    return;
  }

  if (record.type === "auth.restore") {
    requireIdle();
    credentials.restore(record.credential_ref, record.credential);
    emitAuthCompleted(record);
    return;
  }
  if (record.type === "auth.clear") {
    requireIdle();
    credentials.clear(record.credential_ref);
    emitAuthCompleted(record);
    return;
  }
  if (record.type === "auth.begin") {
    requireIdle();
    if (record.provider_kind !== "codex_oauth") {
      emitAuthFailed(record, "authentication_required");
      return;
    }
    startAuthentication(record, () => beginCodexAuthentication({
      signal: authOperation.controller.signal,
      notify: (url) => emit({
        type: "auth.open_url",
        request_id: record.request_id,
        operation_id: record.operation_id,
        generation: record.generation,
        url,
      }),
    }));
    return;
  }
  if (record.type === "auth.refresh") {
    requireIdle();
    let credential;
    try {
      credential = credentials.require(record.credential_ref);
    } catch {
      emitAuthFailed(record, "authentication_required");
      return;
    }
    if (!["oauth"].includes(credential.kind ?? credential.type)) {
      emitAuthFailed(record, "authentication_required");
      return;
    }
    startAuthentication(record, () => refreshCodexAuthentication(credential, {
      signal: authOperation.controller.signal,
    }));
    return;
  }
  if (record.type === "auth.persisted") {
    if (!authOperation?.waiting
      || authOperation.operationId !== record.operation_id
      || authOperation.generation !== record.generation) {
      throw new Error("unknown_auth_operation");
    }
    credentials.admitCandidate(record.credential_ref);
    authOperation = undefined;
    emitAuthCompleted(record);
    return;
  }
  if (record.type === "auth.persist_failed") {
    if (!authOperation?.waiting
      || authOperation.operationId !== record.operation_id
      || authOperation.generation !== record.generation) {
      throw new Error("unknown_auth_operation");
    }
    credentials.rejectCandidate(record.credential_ref);
    authOperation = undefined;
    emitAuthFailed(record, "credential_persistence_failed");
    return;
  }
  if (record.type === "auth.cancel") {
    if (authOperation?.operationId === record.operation_id
      && authOperation.generation === record.target_generation) {
      const current = authOperation;
      authOperation.controller.abort();
      if (authOperation.waiting) {
        credentials.discardCandidate(authOperation.credentialRef);
        authOperation = undefined;
        emit({
          type: "auth.stopped",
          request_id: record.request_id,
          operation_id: record.operation_id,
          generation: record.target_generation,
        });
      } else {
        current.cancelRequestId = record.request_id;
      }
    }
    return;
  }

  if (record.type === "reasoning.start") {
    requireIdle();
    const credential = credentials.require(record.provider_profile.credential_ref);
    reasoningOperation = new ReasoningOperation(
      record,
      credential,
      emit,
      diagnose,
    );
    const current = reasoningOperation;
    void current.run().finally(() => {
      if (reasoningOperation === current) reasoningOperation = undefined;
    });
    return;
  }
  if (record.type === "reasoning.tool_result") {
    if (!reasoningOperation?.resolveToolResult(record)) {
      throw new Error("unknown_tool_call");
    }
    return;
  }
  if (record.type === "reasoning.tool_cancel") {
    if (!reasoningOperation?.cancelTool(record)) {
      throw new Error("unknown_tool_call");
    }
    return;
  }
  if (record.type === "reasoning.cancel") {
    reasoningOperation?.cancel(record.request_id, record.turn_id, record.target_generation);
    return;
  }
  throw new Error("unsupported_record");
}

function startAuthentication(record, operation) {
  authOperation = {
    operationId: record.operation_id,
    generation: record.generation,
    credentialRef: record.credential_ref,
    controller: new AbortController(),
    waiting: false,
  };
  const current = authOperation;
  void (async () => {
    try {
      const candidate = await operation();
      if (authOperation !== current) return;
      if (current.controller.signal.aborted) {
        emit({
          type: "auth.stopped",
          request_id: current.cancelRequestId ?? record.request_id,
          operation_id: record.operation_id,
          generation: record.generation,
        });
        authOperation = undefined;
        return;
      }
      credentials.stageCandidate(record.credential_ref, candidate);
      current.waiting = true;
      emit({
        type: "auth.credential_candidate",
        request_id: record.request_id,
        operation_id: record.operation_id,
        generation: record.generation,
        credential_ref: record.credential_ref,
        credential: candidate,
      });
    } catch {
      if (authOperation !== current) return;
      authOperation = undefined;
      if (current.controller.signal.aborted) {
        emit({
          type: "auth.stopped",
          request_id: current.cancelRequestId ?? record.request_id,
          operation_id: record.operation_id,
          generation: record.generation,
        });
      } else {
        diagnose(record.request_id, "authentication");
        emitAuthFailed(record, "authentication_failed");
      }
    }
  })();
}

function requireIdle() {
  if (authOperation || reasoningOperation) throw new Error("operation_active");
}

function emitAuthCompleted(record) {
  emit({
    type: "auth.completed",
    request_id: record.request_id,
    operation_id: record.operation_id,
    generation: record.generation,
    credential_ref: record.credential_ref,
  });
}

function emitAuthFailed(record, error_code) {
  emit({
    type: "auth.failed",
    request_id: record.request_id,
    operation_id: record.operation_id,
    generation: record.generation,
    error_code,
  });
}

function emitReasoningFailed(record, error_code) {
  emit({
    type: "reasoning.failed",
    request_id: record.request_id,
    turn_id: record.turn_id,
    generation: record.generation,
    error_code,
  });
}

function failInput() {
  process.stderr.write("protocol_failure\n");
  process.exitCode = 70;
  process.stdin.destroy();
}

emit({
  type: "gateway.ready",
  helper_version: "miller-gateway-1",
  supported_protocols: [1],
});

process.stdin.on("data", (chunk) => {
  if (closing) return;
  let records;
  try {
    records = decoder.push(chunk);
  } catch {
    failInput();
    return;
  }
  for (const record of records) {
    dispatchChain = dispatchChain.then(() => dispatch(record)).catch(() => failInput());
  }
});

process.stdin.on("end", () => {
  closing = true;
  try {
    decoder.end();
  } catch {
    process.exitCode = 70;
  }
  authOperation?.controller.abort();
  reasoningOperation?.controller.abort();
});
