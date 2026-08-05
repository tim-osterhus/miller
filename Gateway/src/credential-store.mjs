const MAXIMUM_CREDENTIAL_BYTES = 65_536;
const REFRESH_WINDOW_MILLISECONDS = 5 * 60 * 1_000;

export class CredentialStore {
  constructor({ now = Date.now } = {}) {
    this.now = now;
    this.selected = undefined;
    this.candidate = undefined;
  }

  restore(credentialRef, credential) {
    validateCredential(credential);
    this.selected = { credentialRef, credential: structuredClone(credential) };
    this.candidate = undefined;
  }

  clear(credentialRef) {
    if (this.selected?.credentialRef === credentialRef) this.selected = undefined;
    if (this.candidate?.credentialRef === credentialRef) this.candidate = undefined;
  }

  require(credentialRef) {
    if (this.selected?.credentialRef !== credentialRef) throw new Error("unknown_credential");
    return structuredClone(this.selected.credential);
  }

  readiness(credentialRef) {
    if (this.selected?.credentialRef !== credentialRef) return "authentication_required";
    const credential = this.selected.credential;
    const expiry = credential.expires_at ?? credential.expires;
    if (Number.isFinite(expiry) && expiry <= this.now() + REFRESH_WINDOW_MILLISECONDS) {
      return "refresh_required";
    }
    return "ready";
  }

  stageCandidate(credentialRef, credential) {
    validateCredential(credential);
    if (this.candidate) throw new Error("candidate_pending");
    this.candidate = { credentialRef, credential: structuredClone(credential) };
  }

  admitCandidate(credentialRef) {
    if (this.candidate?.credentialRef !== credentialRef) throw new Error("unknown_candidate");
    this.selected = this.candidate;
    this.candidate = undefined;
  }

  rejectCandidate(credentialRef) {
    if (this.candidate?.credentialRef !== credentialRef) throw new Error("unknown_candidate");
    this.candidate = undefined;
    if (this.selected?.credentialRef === credentialRef) this.selected = undefined;
  }

  discardCandidate(credentialRef) {
    if (this.candidate?.credentialRef !== credentialRef) throw new Error("unknown_candidate");
    this.candidate = undefined;
  }

  hasCandidate(credentialRef) {
    return this.candidate?.credentialRef === credentialRef;
  }
}

function validateCredential(credential) {
  if (credential === null || Array.isArray(credential) || typeof credential !== "object") {
    throw new Error("invalid_credential");
  }
  if (Buffer.byteLength(JSON.stringify(credential)) > MAXIMUM_CREDENTIAL_BYTES) {
    throw new Error("invalid_credential");
  }
}
