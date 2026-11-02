# XBT Market escrow source

Public source-review package for the XBT Market on-chain **2-of-3 multisignature escrow** design. Licensed under AGPL-3.0-or-later; see LICENSE.

## What can be verified

The contract builder constructs this witness script using three distinct, order-derived public keys, sorted lexicographically:

```
OP_2 <key 1> <key 2> <key 3> OP_3 OP_CHECKMULTISIG
```

The funding script is P2WSH: `OP_0 <SHA256(witnessScript)>`. A spend requires two valid signatures. A seller alone cannot spend; the marketplace mediator alone cannot spend. **Any two cooperating or compromised keys can spend.** The chain does not enforce delivery, reputation, dispute decisions or the app's signer-pair policy. Mediation therefore involves trust; this is not a claim of fully trustless trading or insurance.

Start here:

- [Contract and script construction](lib/market-escrow-contract.mjs)
- [Per-order public-key derivation](lib/market-escrow-order-keys.mjs)
- [Spend validation and finalization](lib/market-escrow-spend.mjs)
- [Android signer contract review](experiments/escrow-rehearsal/lib/production_contract.dart)
- [Android signer payout validation](experiments/escrow-rehearsal/lib/production_spend.dart)
- [Verify a funding output](docs/VERIFY.md)
- [Release scope and deployment evidence](docs/RELEASE.md)

## Run the offline tests

Requires Node.js 24 or newer and npm:

```sh
npm ci --ignore-scripts
npm test
```

Tests use disposable synthetic identities and in-memory databases. They do not connect to a node, broadcast, or use real funds. The public threshold test explicitly rejects zero, one and duplicate signatures and accepts the eligible two-party combinations. This is application-level testing, **not execution by an independent consensus interpreter**.

The chain is Bitcoin BLAKE2b/XBT. The implementation pins its chain profile and uses ALL|UNIFIED (`0x21`) signing. Do not substitute a Bitcoin SHA256 wallet or assume that an address prefix identifies the chain.

## Signer source

The historical folder name `experiments/escrow-rehearsal` contains both earlier rehearsal code and production-path signer code. The production entry point is `lib/main_production.dart`; `production_*.dart` contains its identity, contract, funding, payout and transfer logic. The original source paths are retained for checksum comparison. The included default package/build settings are rehearsal templates, not production release configuration. Do not install a default build for real funds.

Dart/Flutter tests and synthetic fixture files are included for review. Flutter is not bundled. This release does not claim a reproduced APK, hardware attestation, independent audit, or verification of whatever app a user has installed. No APK, keystore, live recovery material, customer order, deployment secret or private repository history is published.

Dependencies retain their own licenses. The small marketplace support modules are included because the contract tests exercise actual order/account binding; this is not a complete marketplace server distribution.

## Security reports

Report suspected vulnerabilities privately to **help@xbtmarket.store**. Do not publish wallet secrets, recovery files, private order links or customer data in issues. This repository provides transparency, not a security certification.
