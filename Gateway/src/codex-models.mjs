export const defaultCodexModelID = "gpt-5.6-terra";

const validModelID = /^[A-Za-z0-9._:/-]+$/;
const packaged = Object.freeze([
  Object.freeze({ id: defaultCodexModelID, name: "GPT-5.6 Terra" }),
  Object.freeze({ id: "gpt-5.4", name: "GPT-5.4" }),
]);

export function normalizeCodexModelID(rawID) {
  const id = typeof rawID === "string" ? rawID.trim() : "";
  if (!id || id.length > 200 || !validModelID.test(id)) {
    throw new Error("configuration_invalid");
  }
  return id;
}

export function codexModelCatalog() {
  return {
    defaultModel: defaultCodexModelID,
    models: packaged,
  };
}

export function isPackagedCodexModel(rawID) {
  const id = normalizeCodexModelID(rawID);
  return packaged.some((model) => model.id === id);
}

export function resolveCodexModel(provider, rawID) {
  const id = normalizeCodexModelID(rawID);
  const models = provider.getModels();
  const upstream = models.find((model) => model.id === id);
  if (upstream) return upstream;

  const template = models.find((model) => model.id === "gpt-5.4");
  if (!template) throw new Error("provider_unavailable");

  const packagedName = packaged.find((model) => model.id === id)?.name;
  return {
    ...template,
    id,
    name: packagedName ?? id,
    input: ["text"],
    contextWindow: 128_000,
    maxTokens: 16_384,
  };
}
