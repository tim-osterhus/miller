# Miller Gate 4A offline qualification report

## Commands and sanitized outcomes

| Command | Outcome |
| --- | --- |
| `test "$(shasum -a 256 ../../lab/assist/research/plans/2026-07-29-miller-text-alpha-implementation-plan.md \| awk '{print $1}')" = "5f38f513622fc569b9eae2cbca168243af7c6b927e6c4fcc3150dd7bcdea9a02"` | PASS: plan bytes matched. |
| `test "$(git -C miller branch --show-current)" = "main"` | PASS: source branch remained `main`. |
| `cd miller/Gateway && /opt/homebrew/opt/node@22/bin/npm ci --ignore-scripts` | PASS: exact lockfile closure installed with scripts disabled. Audit reported zero vulnerabilities. |
| `cd miller && ./scripts/test.sh` | PASS: 33 protocol checks and 99 Swift tests passed. |
| `cd miller/Gateway && /opt/homebrew/opt/node@22/bin/npm test` | PASS: all 52 Gateway tests passed with local fixtures and loopback servers. |
| `cd miller && ./scripts/build.sh` | PASS: Swift build completed. |
| `cd miller && ./scripts/package-dev-app.sh` | PASS: reconstructed the scripts-disabled offline lockfile closure, verified its reviewed dependency inventory before copying, verified the assembled bundle dependency inventory, then passed exact Node archive hash and ad-hoc development signature checks. |
| `cd miller && ./scripts/verify-provenance.sh` | PASS: vendor closure and pinned workflow action verified. |
| `cd miller && ./scripts/verify-provenance.sh --development-bundle-inventory` | PASS: the complete 2,109-file, 7,802,537-byte admitted dependency closure matched its reviewed inventory commitment; unlisted files, changed bytes, symlinks, or an unexpected assembled dependency root fail the check. |
| `cd miller && ./scripts/clean.sh && ./scripts/clean.sh --dependencies` | PASS after the unexpected-write handling below. |
| `test ! -e miller/Gateway/node_modules && test ! -e miller/.build && test ! -e miller/.artifacts && test ! -e miller/.cache` | PASS after final cleanup. |
| Full-SHA workflow scan | PASS: every `uses:` entry is a full 40-character commit SHA. |
| Prohibited-source and retained-content audit | PASS: only speech/avatar contracts were present. No tool surface, raw provider diagnostic, credential, unknown dependency, generated root, or provider content was found. |
| Retained native H1 record review | PASS retained: configurable shortcut activation and relaunch persistence remain recorded without changing the unrun shortcut-failure case. |
| `git -C miller diff --check` | PASS. |
| `git -C miller status --short --untracked-files=all` plus path inspection | PASS: this packet matched its target list. Other paths belonged to prior completed packets. |
| Miller application/helper/test-server process scan | PASS: no qualification child remained. |

## Remaining human gates

- Connected Codex OAuth and DeepSeek qualification remains `NOT_RUN`.
- The native shortcut-registration failure-presentation case remains
  `NOT_RUN`. No system setting was changed to force a failure.
- Local speech-to-text, local-neural speech, macOS speech fallback,
  push-to-talk, microphone, raw-audio, audible-tail, and avatar qualification
  remain Gate 4B work.
- M1 performance, complete release-asset provenance, release signing,
  notarization, stable Keychain upgrade identity, clean-machine
  install/upgrade/removal, offline capability, and public distribution remain
  Gate 4B work.
- Final voice and avatar selection, numerical qualification profiles, the
  installer, and the updater remain unresolved Gate 4B work.
- This report does not mark Gate 4A or the integrated alpha complete.

## Unexpected write or process findings

- Finder recreated `.build/` containing only `.DS_Store` metadata after the
  first cleanup assertion. The exact metadata files were removed, both cleanup
  modes were rerun, and the final generated-root assertion passed.
- No Miller application, helper, test server, OAuth callback listener, or
  qualification child remained after the final process scan.
