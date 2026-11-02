# Verify that a deposit uses the reviewed multisig

Perform this locally. Do not upload your private order contract, addresses, backup, passphrase or signer identity to a public issue or an online verification site.

1. Obtain the exact reviewed contract from your order. Independently compare its contract hash, marketplace origin, revision and participant key fingerprints with the signers. A contract that verifies internally can still be the wrong contract for your trade.
2. Use your own correctly synced Bitcoin BLAKE2b/XBT node to inspect the deposit transaction and its **exact output index**. Obtain that output's `scriptPubKey.hex` and value. Confirm the node's chain/checkpoint, block inclusion, required confirmations and unspent status independently. Addresses alone do not distinguish this chain from Bitcoin SHA256. A received transaction ID alone does not establish any of these facts.
3. Run the offline comparison:

```sh
node tools/verify-contract.mjs contract.json SCRIPT_PUB_KEY_HEX
```

The file may be the contract object or a request containing a `contract` field. The tool validates the contract, derives its keys and witness script again, and compares its P2WSH commitment to the exact output script supplied. It prints `matches: true` only on equality. It never contacts a node or broadcasts.

4. Separately compare the output value in integer satoshis with the agreed funding terms and `totalDepositSats`. Confirm the output belongs to this order, not another transaction with the same script. The CLI deliberately does **not** claim to verify amount, chain, ownership, confirmation depth or whether an output is still unspent.
5. If a payout has occurred, the spending input's witness reveals the witness script and signatures. Independently check that the spent outpoint is this deposit. Before spending, a P2WSH output reveals only a hash, so the contract's witness script is required for the comparison.

## Reading the script

- `52`: OP_2 (two signatures required)
- Three `21` pushes, each followed by a 33-byte compressed public key
- `53`: OP_3 (three public keys)
- `ae`: OP_CHECKMULTISIG

Order-derived keys differ from the long-term identity public keys; the derivation binds the order, origin, revision, preflight and all participant keys. The verifier recomputes them rather than trusting displayed labels.

No timelock or automatic refund is present in this script. The website's deadlines and permitted payout pairs are workflow rules, not additional on-chain restrictions. Two keys can cooperate outside the website; one key cannot spend alone. Loss or unavailability of sufficient keys can strand funds.

## Limits of this evidence

Source availability proves inspectability, not that a remote server is running it. Operator-published file hashes help compare a snapshot but are not remote attestation. A successful unit test is not a chain consensus acceptance test. For a funded trade, independently checking the actual output against the contract is the relevant on-chain check.
