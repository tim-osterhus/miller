# Miller connected-provider qualification

Overall: PASS

- Codex OAuth: PASS (2026-07-31)
- DeepSeek: PASS (2026-08-01)

This human gate is deliberately excluded from automated tests. Validation mode
checks refusal, syntax, redaction boundaries, cleanup wiring, and argument
handling without opening a browser, prompting for a key, reading Keychain, or
calling a provider:

```bash
./scripts/run-codex-oauth-check.sh --validate
./scripts/run-codex-oauth-check.sh --dry-run
./scripts/run-deepseek-check.sh --validate
./scripts/run-deepseek-check.sh --dry-run
```

Dry-run creates only a temporary synthetic status file, verifies its exact
provider/status/timing allowlist and canary redaction, exercises forced-failure
cleanup, and checks refusal/invalid-argument cleanup. It does not launch a
bundle, browser, Keychain prompt, credential read, or provider request.

Live qualification requires the explicit `--interactive --confirm-live`
arguments and a second typed confirmation. The scripts build one development
bundle, require `codesign --verify --deep --strict` to pass for that exact
bundle before launch, retain only a provider kind and PASS/FAIL result in a
temporary managed root, and delete that root on every exit.

## Codex OAuth

Result: PASS (2026-07-31)

The live gate completed with sanitized evidence only: login and readiness,
packaged and custom model selection, model persistence across relaunch,
streamed first-turn and contextual follow-up completion, cancellation without a
late terminal transition, refresh, local logout to authentication-required,
and successful re-login. No provider content or credential material was
retained.

Run `./scripts/run-codex-oauth-check.sh --interactive --confirm-live`.

1. In Settings, select **Start Codex login** while Miller is idle.
2. Confirm the credential destination is the Miller Keychain service, then
   complete the browser callback delivered by the native gateway.
3. Confirm the selected model defaults to **gpt-5.6-terra**, and that Settings
   shows the packaged choices plus the Advanced custom model control.
4. Select a model, relaunch Miller, and confirm the selected model survives
   restore. Confirm helper-backed readiness and **Refresh Codex** remain ready.
5. Complete one turn, one contextual follow-up, and one stopped turn.
6. Perform local logout and confirm Miller reports authentication required.
7. Record only PASS or FAIL in the runner.

## DeepSeek

Result: PASS (2026-08-01)

The live gate completed against the reviewed DeepSeek OpenAI-compatible origin
and `deepseek-v4-flash` with sanitized evidence only: profile admission and
readiness, streamed first-turn completion, contextual follow-up completion,
cancellation to a stopped terminal state, invalid-model failure without
admitted assistant text, and removal of both the temporary profile and its
Miller Keychain item. The separately configured environment credential and the
Codex OAuth profile remained unchanged.

Run `./scripts/run-deepseek-check.sh --interactive --confirm-live`.

1. In Settings, create or edit an OpenAI-compatible profile with the reviewed
   DeepSeek HTTPS origin and model. Enter a replacement API key only in the
   masked field; editing can retain the existing local credential.
2. Confirm endpoint validation occurs before the Keychain write and the
   credential destination disclosure names the Miller Keychain service.
3. Complete one turn, one follow-up, one cancellation, and one invalid-model
   failure. Confirm no authenticated redirect is followed.
4. Delete the profile and confirm the local credential is absent.
5. Record only PASS or FAIL in the runner.

Do not retain screenshots, callback URLs, account identifiers, tokens, keys,
prompts, provider responses, raw provider errors, Keychain values, or process
environments. Each provider remains `NOT_RUN` until a human performs its gate;
the overall result is `PASS` only when both provider gates pass.
