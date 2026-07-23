# Provenance policy

Miller starts as a clean repository. It does not inherit source code, tests,
assets, or Git history from Cortana Assistant, VoiceInk, or any prospective
donor project.

## Contributions and borrowed work

Before third-party source or assets enter Miller, record:

- the upstream project and canonical source URL;
- the exact version, tag, or commit;
- the license and copyright notices;
- which files or assets were incorporated;
- whether the material was copied, adapted, or used only as a reference;
- the modifications made in Miller;
- relevant transitive dependencies and distribution requirements.

Preserve all notices required by the upstream license in
`THIRD_PARTY_NOTICES.md` or the applicable distributed artifact.

## Dependency and asset review

Review source code, transitive packages, downloaded or bundled binaries, model
weights, tokenizers, phonemizers, voice packs, wake-word models, fonts, audio,
artwork, and other shipped assets separately. A permissive repository license
does not establish that every dependency or model asset is safe to redistribute.

Miller must not incorporate copyleft, noncommercial, source-available,
field-of-use-restricted, or unknown-license source code or assets. External
provider compatibility does not authorize Miller to copy, modify, bundle, or
redistribute a provider's implementation or assets.

## Clean-room boundary

Cortana Assistant and VoiceInk may inform public behavioral requirements, but
their implementation must not be copied into Miller. Any independently
authored Cortana material proposed for reuse requires a file-level authorship
and provenance review before incorporation.
