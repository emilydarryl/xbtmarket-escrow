// Experimental, no network/broadcast/storage APIs. Private keys are supplied
// locally by the host wallet, never carried in PSBTs or returned to the server.
import 'dart:convert';
import 'package:bitcoin_base/bitcoin_base.dart';
import 'package:blockchain_utils/blockchain_utils.dart';
import 'unified_digest.dart';

String hex(List<int> value) => BytesUtils.toHexString(value);
String sha(List<int> value) => hex(QuickCrypto.sha256Hash(value));
Never invalid(String reason) => throw FormatException(reason);

class _Reader {
  _Reader(this.bytes);
  final List<int> bytes;
  int offset = 0;
  List<int> take(int length) {
    if (length < 0 || length > bytes.length - offset) invalid('Truncated PSBT');
    final result = bytes.sublist(offset, offset + length);
    offset += length;
    return result;
  }

  int compact() {
    final first = take(1).single;
    if (first < 253) return first;
    if (first == 255) invalid('Oversized PSBT length');
    final value = take(first == 253 ? 2 : 4);
    var n = 0;
    for (var i = value.length - 1; i >= 0; i--) {
      n = n * 256 + value[i];
    }
    if (n < 253 || (first == 254 && n <= 65535))
      invalid('Noncanonical PSBT length');
    return n;
  }

  Map<String, List<int>> map() {
    final result = <String, List<int>>{};
    while (true) {
      final size = compact();
      if (size == 0) return result;
      if (size > 10000 || result.length >= 1000) invalid('Oversized PSBT map');
      final key = hex(take(size));
      if (result.containsKey(key)) invalid('Duplicate PSBT key');
      final length = compact();
      if (length > 100000) invalid('Oversized PSBT value');
      result[key] = take(length);
    }
  }
}

List<int> _compact(int n) {
  if (n < 253) return [n];
  if (n <= 65535) return [253, n & 255, (n >> 8) & 255];
  return [254, for (var i = 0; i < 4; i++) (n >> (8 * i)) & 255];
}

List<int> _mapBytes(Map<String, List<int>> values) => [
      for (final entry in values.entries) ...[
        ..._compact(entry.key.length ~/ 2),
        ...BytesUtils.fromHexString(entry.key),
        ..._compact(entry.value.length),
        ...entry.value,
      ],
      0,
    ];

class EscrowPsbt {
  EscrowPsbt._(this.global, this.inputs, this.outputs, this.tx, this.raw);
  final Map<String, List<int>> global;
  final List<Map<String, List<int>>> inputs, outputs;
  final BtcTransaction tx;
  final List<int> raw;

  factory EscrowPsbt.parse(String encoded) {
    if (encoded.length > 140000) invalid('PSBT exceeds pilot size limit');
    final bytes = base64Decode(encoded), reader = _Reader(bytes);
    if (hex(reader.take(5)) != '70736274ff') invalid('Not a PSBT');
    final global = reader.map();
    if (global.length != 1 || !global.containsKey('00'))
      invalid('Only PSBT v0 with an unsigned transaction is supported');
    final raw = global['00']!, tx = BtcTransaction.deserialize(raw);
    if (tx.inputs.length != 1 || tx.outputs.isEmpty || tx.outputs.length > 2)
      invalid('Pilot supports one escrow input and up to two payout outputs');
    // Round-trip ensures this is the exact unsigned, non-witness serialization.
    if (tx.toHex() != hex(raw) ||
        tx.inputs.any((input) => input.scriptSig.toBytes().isNotEmpty))
      invalid('Transaction must be unsigned');
    final inputs = [for (var i = 0; i < tx.inputs.length; i++) reader.map()];
    final outputs = [for (var i = 0; i < tx.outputs.length; i++) reader.map()];
    if (reader.offset != bytes.length) invalid('Trailing PSBT data');
    return EscrowPsbt._(global, inputs, outputs, tx, raw);
  }

  String serialize() => base64Encode([
        0x70,
        0x73,
        0x62,
        0x74,
        0xff,
        ..._mapBytes(global),
        for (final input in inputs) ..._mapBytes(input),
        for (final output in outputs) ..._mapBytes(output)
      ]);

  /// [funding] must come from the host wallet's independent chain verification,
  /// not from the PSBT sender. Keys are "txid:vout", amounts are integer sats.
  Map<String, Object> review(
      {required String witnessScript,
      required Map<String, String> funding,
      required BigInt maximumFeeSats}) {
    final script = BytesUtils.fromHexString(witnessScript);
    if (script.length != 105 ||
        script.first != 0x52 ||
        hex(script.sublist(103)) != '53ae')
      invalid('Only exact 2-of-3 native P2WSH is supported');
    final keys = <String>[];
    for (var i = 0; i < 3; i++) {
      final start = 1 + i * 34;
      if (script[start] != 33) invalid('Compressed public keys required');
      final key = hex(script.sublist(start + 1, start + 34));
      ECPublic.fromHex(key);
      keys.add(key);
    }
    if (keys.toSet().length != 3 || ([...keys]..sort()).join() != keys.join())
      invalid('Three distinct sorted keys required');
    final outputScript = '0020${sha(script)}',
        amounts = <BigInt>[],
        scripts = <Script>[];
    final seen = <String>{};
    for (var i = 0; i < inputs.length; i++) {
      final input = inputs[i];
      for (final key in input.keys) {
        final type = int.parse(key.substring(0, 2), radix: 16);
        if (![1, 2, 3, 5, 6].contains(type))
          invalid('Unsupported or finalized input');
        if ([1, 3, 5].contains(type) && key.length != 2)
          invalid('Malformed PSBT input key');
        if (type == 2 && (key.length != 68 || !keys.contains(key.substring(2))))
          invalid('Unknown partial signer');
      }
      if (hex(input['05'] ?? []) != witnessScript)
        invalid('Witness script differs from saved escrow');
      if (input['03'] != null && hex(input['03']!) != '21000000')
        invalid('Only ALL|UNIFIED signing is allowed');
      final utxo = _Reader(input['01'] ?? []), amountBytes = utxo.take(8);
      final amount =
          BigInt.parse(hex(amountBytes.reversed.toList()), radix: 16);
      final scriptPubKey = utxo.take(utxo.compact());
      if (utxo.offset != utxo.bytes.length || hex(scriptPubKey) != outputScript)
        invalid('Witness UTXO is not this escrow');
      final outpoint = '${tx.inputs[i].txId}:${tx.inputs[i].txIndex}';
      if (!seen.add(outpoint) ||
          funding[outpoint] != amount.toString() ||
          amount <= BigInt.zero)
        invalid('Funding amount/outpoint not independently verified');
      amounts.add(amount);
      scripts.add(Script.deserialize(bytes: scriptPubKey));
    }
    if (funding.length != inputs.length)
      invalid('Funding set differs from the transaction');
    final inputSats = amounts.fold(BigInt.zero, (a, b) => a + b),
        outputSats = tx.outputs.fold(BigInt.zero, (a, b) => a + b.amount);
    final fee = inputSats - outputSats;
    if (fee < BigInt.zero ||
        fee > maximumFeeSats ||
        maximumFeeSats < BigInt.zero ||
        tx.outputs.any((o) => o.amount <= BigInt.zero))
      invalid('Invalid outputs or excessive network fee');
    for (var i = 0; i < inputs.length; i++) {
      final digest = escrowDigest(
          tx,
          i,
          Script.deserialize(bytes: BytesUtils.fromHexString(witnessScript)),
          amounts,
          scripts);
      for (final entry
          in inputs[i].entries.where((entry) => entry.key.startsWith('02'))) {
        final sig = entry.value;
        if (sig.isEmpty ||
            sig.last != 0x21 ||
            !BitcoinSignatureVerifier.fromKeyBytes(
                    BytesUtils.fromHexString(entry.key.substring(2)))
                .verifyECDSADerSignature(
                    digest: digest, signature: sig.sublist(0, sig.length - 1)))
          invalid('Invalid or unprotected existing signature');
      }
    }
    return {
      'transactionHash': sha(raw),
      'witnessScript': witnessScript,
      'keys': keys,
      'inputSats': inputSats.toString(),
      'feeSats': fee.toString(),
      'outputs': [
        for (final output in tx.outputs)
          {
            'script': output.scriptPubKey.toHex(),
            'sats': output.amount.toString()
          }
      ]
    };
  }

  String sign(
      {required ECPrivate privateKey,
      required String witnessScript,
      required Map<String, String> funding,
      required BigInt maximumFeeSats,
      required String approvedTransactionHash}) {
    final summary = review(
        witnessScript: witnessScript,
        funding: funding,
        maximumFeeSats: maximumFeeSats);
    if (summary['transactionHash'] != approvedTransactionHash)
      invalid('The transaction changed after review');
    final pubkey = privateKey.getPublic().toHex();
    if (!(summary['keys'] as List<String>).contains(pubkey))
      invalid('This key is not an escrow participant');
    final amounts = [
      for (final input in tx.inputs)
        BigInt.parse(funding['${input.txId}:${input.txIndex}']!)
    ];
    final scripts = [
      for (final _ in inputs)
        Script.deserialize(
            bytes: BytesUtils.fromHexString(
                '0020${sha(BytesUtils.fromHexString(witnessScript))}'))
    ];
    for (var i = 0; i < inputs.length; i++) {
      final digest = escrowDigest(
          tx,
          i,
          Script.deserialize(bytes: BytesUtils.fromHexString(witnessScript)),
          amounts,
          scripts);
      final signature =
          BytesUtils.fromHexString(privateKey.signECDSA(digest, sighash: 0x21));
      if (!BitcoinSignatureVerifier.fromKeyBytes(
              BytesUtils.fromHexString(pubkey))
          .verifyECDSADerSignature(
              digest: digest,
              signature: signature.sublist(0, signature.length - 1)))
        invalid('Signature self-check failed');
      inputs[i]['03'] = [0x21, 0, 0, 0];
      inputs[i]['02$pubkey'] = signature;
    }
    return serialize();
  }
}
