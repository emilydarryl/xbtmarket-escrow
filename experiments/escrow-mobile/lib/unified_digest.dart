// XBT WITNESS_V0 unified sighash. Layout pinned to Bitcoin Knots
// 58398baf33e588779685ead478e6397bb28ed3d6, doc/unified-sighash.md.
import 'dart:typed_data';
import 'package:bitcoin_base/bitcoin_base.dart';
import 'package:blockchain_utils/blockchain_utils.dart';

List<int> escrowDigest(BtcTransaction tx, int index, Script witnessScript,
    List<BigInt> amounts, List<Script> spentScripts) {
  List<int> hash(List<int> value) => QuickCrypto.sha256Hash(value);
  List<int> join(Iterable<List<int>> values) =>
      [for (final value in values) ...value];
  final tag = hash('UnifiedSighash'.codeUnits);
  return hash([
    ...tag,
    ...tag,
    0,
    0x21,
    ...tx.version,
    ...tx.locktime,
    0,
    ...hash(join(tx.inputs.map((input) => [
          ...BytesUtils.fromHexString(input.txId).reversed,
          ...IntUtils.toBytes(input.txIndex,
              length: 4, byteOrder: Endian.little),
        ]))),
    ...hash(join(amounts.map((amount) =>
        BigintUtils.toBytes(amount, length: 8, order: Endian.little)))),
    ...hash(join(spentScripts
        .map((script) => IntUtils.prependVarint(script.toBytes())))),
    ...hash(join(tx.inputs.map((input) => input.sequence))),
    ...hash(join(tx.outputs.map((output) => output.toBytes()))),
    1,
    ...IntUtils.toBytes(index, length: 4, byteOrder: Endian.little),
    ...IntUtils.prependVarint(witnessScript.toBytes()),
  ]);
}
