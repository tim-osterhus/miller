const adapterKey = Symbol.for("miller.gateway.authenticationAdapter");

function waitForCandidate(signal) {
  return new Promise((resolve, reject) => {
    if (signal.aborted) {
      reject(signal.reason ?? new Error("aborted"));
      return;
    }
    const timer = setTimeout(resolve, 50);
    signal.addEventListener("abort", () => {
      clearTimeout(timer);
      reject(signal.reason ?? new Error("aborted"));
    }, { once: true });
  });
}

function candidate() {
  return {
    kind: "oauth",
    access: "synthetic-test-access",
    refresh: "synthetic-test-refresh",
    expires_at: null,
  };
}

globalThis[adapterKey] = {
  async begin({ signal, notify }) {
    notify("http://127.0.0.1:43191/authorize");
    await waitForCandidate(signal);
    return candidate();
  },
  async refresh(_credential, { signal }) {
    await waitForCandidate(signal);
    return candidate();
  },
};
