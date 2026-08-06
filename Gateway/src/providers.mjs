import { stream as streamOpenAICompletions } from "@miller/pi-mvp-overlay/api/openai-completions";
import { openaiCodexProvider } from "@miller/pi-mvp-overlay/providers/openai-codex";
import {
  normalizeCodexModelID,
  resolveCodexModel,
} from "./codex-models.mjs";

const nativeFetch = globalThis.fetch;
globalThis.fetch = (input, init = {}) => nativeFetch(input, { ...init, redirect: "manual" });
const authenticationAdapterKey = Symbol.for("miller.gateway.authenticationAdapter");

export function normalizeProviderProfile(profile) {
  if (profile?.kind === "codex_oauth") {
    if (profile.base_url !== null || typeof profile.model !== "string" || profile.model.length === 0) {
      throw new Error("configuration_invalid");
    }
    return { ...profile, model: normalizeCodexModelID(profile.model) };
  }
  if (profile?.kind !== "openai_compatible"
    || typeof profile.base_url !== "string"
    || typeof profile.model !== "string"
    || profile.model.length === 0) {
    throw new Error("configuration_invalid");
  }

  let endpoint;
  try {
    endpoint = new URL(profile.base_url);
  } catch {
    throw new Error("configuration_invalid");
  }
  if (endpoint.username || endpoint.password || endpoint.search || endpoint.hash
    || !["http:", "https:"].includes(endpoint.protocol)) {
    throw new Error("configuration_invalid");
  }
  if (endpoint.protocol === "http:" && !isLoopback(endpoint.hostname)) {
    throw new Error("configuration_invalid");
  }
  const pathname = endpoint.pathname.replace(/\/+$/, "");
  endpoint.pathname = pathname || "/";
  return { ...profile, base_url: endpoint.toString().replace(/\/$/, "") };
}

export function streamForProfile(profileInput, credentialInput, context, options = {}) {
  const profile = normalizeProviderProfile(profileInput);
  const credential = normalizeCredential(credentialInput);
  if (profile.kind === "codex_oauth") return streamCodex(profile, credential, context, options);
  const model = {
    id: profile.model,
    name: profile.model,
    api: "openai-completions",
    provider: "miller-openai-compatible",
    baseUrl: profile.base_url,
    reasoning: false,
    input: ["text"],
    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    contextWindow: 1_000_000,
    maxTokens: 256_000,
  };
  return streamOpenAICompletions(model, context, {
    apiKey: credential.key,
    signal: options.signal,
    maxRetries: 0,
  });
}

export async function beginCodexAuthentication({ signal, notify }) {
  const adapter = globalThis[authenticationAdapterKey];
  if (adapter?.begin) return adapter.begin({ signal, notify });
  const oauth = openaiCodexProvider().auth.oauth;
  return oauth.login({
    signal,
    prompt: async ({ type }) => {
      if (type !== "select") throw new Error("authentication_failed");
      return "browser";
    },
    notify(event) {
      if (event?.type === "auth_url" && typeof event.url === "string") notify(event.url);
    },
  });
}

export async function refreshCodexAuthentication(credential, { signal }) {
  const adapter = globalThis[authenticationAdapterKey];
  if (adapter?.refresh) return adapter.refresh(credential, { signal });
  return openaiCodexProvider().auth.oauth.refresh(normalizeCredential(credential), signal);
}

function streamCodex(profile, credential, context, options) {
  const provider = openaiCodexProvider();
  const model = resolveCodexModel(provider, profile.model);
  return provider.streamSimple(model, codexContextForModel(model, {
    ...context,
    tools: [],
  }), {
    apiKey: credential.access,
    signal: options.signal,
    maxRetries: 0,
  });
}

export function codexContextForModel(model, context) {
  return {
    ...context,
    messages: context.messages.map((message) => {
      if (message.role === "user") return message;
      return {
        role: "assistant",
        content: [{ type: "text", text: message.content }],
        api: model.api,
        provider: model.provider,
        model: model.id,
        stopReason: "stop",
        timestamp: 0,
      };
    }),
  };
}

function normalizeCredential(credential) {
  if (credential?.kind === "api_key") return { type: "api_key", ...credential };
  if (credential?.kind === "oauth") return { type: "oauth", ...credential };
  return credential;
}

function isLoopback(hostname) {
  if (hostname === "[::1]" || hostname === "::1") return true;
  const octets = hostname.split(".");
  return octets.length === 4
    && octets.every((octet) => /^(?:0|[1-9]\d{0,2})$/.test(octet) && Number(octet) <= 255)
    && Number(octets[0]) === 127;
}
