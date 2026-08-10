# Packet 6 release closure

Target: Miller v0.1.2

Terminal result: `HEADLESS_RELEASE_READY_HUMAN_GATE_NOT_RUN`

Packet 6 aligns the v0.1.2 source, package, inventory, SPDX SBOM, notices,
provenance, and qualification schemas. It does not reopen Packets 1–5 or claim
the owner-visible M1 gate.

## Packet outcomes

| Packet | Result |
| --- | --- |
| 1 — external Codex readiness | committed deterministic result; owner gate remains `LIVE_NOT_RUN` |
| 2 — transcript copy | committed deterministic result; owner gate remains `LIVE_NOT_RUN` |
| 3 — Live-text compatibility spike | `INCONCLUSIVE` |
| 4 — in-process host seam | committed deterministic result |
| 5 — custom wake phrase | headless-approved; human gate `LIVE_NOT_RUN` |
| 6 — release closure | headless-ready; human gate `LIVE_NOT_RUN` |

## Required evidence

The generated headless report records command results, test counts, package
inventory, SPDX/provenance checks, package/file measurements, and cleanup:
`v0.1.2-headless-report.md`. The owner-visible protocol is
`v0.1.2-human-protocol.md`.

Packet 5's earlier route-fixture observation is explicitly superseded by the
later exact v0.1.2 headless run (`./scripts/run-headless-release-qualification.sh`)
at release HEAD `5dc99351d83027abdb9f9b1fe176b044444d0ed7`, whose committed
report records PASS for the route and Pi-provider checks. Packet 5 remains
`LIVE_NOT_RUN` for owner-visible microphone, custom-phrase, and wake behavior;
Packet 3 remains `INCONCLUSIVE`.

The release package must retain only the verified `Miller.app` and its sibling
inventory under `.artifacts/release/`. Build/cache roots, Gateway dependencies,
wake downloads/extraction/staging roots, temporary App Server/helper/test roots,
sockets, generated dependency roots, and measurement roots must be absent after
cleanup.

Publication requires a separate explicit owner instruction after every M1 row
passes. This closure does not tag, sign, notarize, push, publish, or claim
publication readiness.
