# Release 0.1.0 — source review snapshot

Published scope: contract construction, per-order key derivation, funding consent, spend and withdrawal validation, mediator decision validation, supporting order-binding modules, Android/Dart signer source, synthetic fixtures and offline tests.

`SOURCE-MANIFEST.json` records each selected file's SHA-256 and the originating private repository revision. The public repository starts with a new history; the private repository and its operational history remain private. Files covered by this manifest were copied byte-for-byte. Public README, verification tools and the threshold demonstration are additions to this review package.

`DEPLOYMENT-HASHES.json` records an operator-observed comparison against the running marketplace container on November 2, 2026. All 30 exported server modules matched at that check. The recorded image digest identifies that container snapshot, not a published downloadable container. This evidence is **operator-reported, not remote attestation**, and applies only to that time. Future deployment changes require a new comparison.

## Validation

- Node.js v24.14.1 on Windows: selected contract, order-key, spend and explicit threshold tests executed successfully.
- Synthetic tests cover zero/one/duplicate-signature rejection, valid eligible pairs, context binding, altered payout rejection and modified-script rejection.
- No network consensus interpreter was run for this public release; these are application-level tests.
- Dart/Flutter tests are supplied but were not rerun for this release because Flutter is unavailable in this review environment.
- No APK was built, signed or independently reproduced. Android build files are historical rehearsal templates. Original `production_*.dart` files and the production entry point are included for review; release-time public configuration and Android packaging changes are outside this snapshot.
- No independent security audit is claimed. The owner authorized publication; that is not independent review.

## Excluded material

No databases, operational logs, customer exports, live contracts, `.env` files, SSH keys, Android keystores, live recovery archives, wallet seeds or private repository history were copied. An allowlist selected tracked source and explicitly identified synthetic fixtures. A credential-pattern and known-private-identifier scan was performed before publication; such scanning is not a guarantee that software is secure.

Synthetic fixtures intentionally contain disposable test scalars, test passphrases, encrypted test identities and signatures. They are public test inputs and must never be used with real funds.

The export includes marketplace support code needed by contract tests, not the complete server, deployment configuration, observer service or operational dashboard. This publication is not a substitute for a full-system audit or a complete production build distribution.
