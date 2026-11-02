// Independent offline review of an UNFUNDED marketplace draft. Cannot sign it.
import 'dart:convert';
import 'package:bitcoin_base/bitcoin_base.dart';
import 'package:xbt_market_escrow_lab/escrow_signer.dart' show sha;
import 'shared_order.dart' show sortedJson;

class FundingDraft {
  FundingDraft._(this._data);
  final Map<String, dynamic> _data;
  String get hash => _data['draftHash'] as String;
  String get sellerPrice => _data['sellerPriceSats'] as String;
  String get reserve => _data['buyerFeeReserveSats'] as String;
  String get deposit => _data['totalDepositSats'] as String;
  String get orderId => _data['orderId'] as String;
  String get reviewJson => const JsonEncoder.withIndent('  ').convert(_data);
  static String xbt(String sats) {
    final n = BigInt.parse(sats), unit = BigInt.from(100000000);
    return '${n ~/ unit}.${(n % unit).toString().padLeft(8, '0')}';
  }
  static void require(bool value) {
    if (!value) throw const FormatException('Unfunded regtest draft mismatch.');
  }
  static String digest(dynamic data) => sha(utf8.encode(jsonEncode(sortedJson(data))));
  static BigInt amount(dynamic value) {
    require(value is String && RegExp(r'^(0|[1-9][0-9]{0,9})$').hasMatch(value));
    return BigInt.parse(value as String);
  }
  static void exact(Map data, Set<String> fields) => require(
    data.length == fields.length && data.keys.every(fields.contains));
  static FundingDraft parse(String encoded, String expectedHash,
      String ownPublicKey, String role) {
    require(encoded.length <= 24000);
    final d = Map<String, dynamic>.from(jsonDecode(encoded) as Map);
    exact(d, {'schema','chain','testOnly','fundingEnabled','keyOwnershipVerified',
      'orderId','setupRevision','setupAgreementHash','snapshot','snapshotHash',
      'keys','sellerPriceSats','buyerFeeReserveSats','totalDepositSats','feePolicy','draftHash'});
    require(d['schema'] == 'xbt-order-funding-draft-v1' &&
      d['chain'] == 'regtest' && d['testOnly'] == true &&
      d['fundingEnabled'] == false && d['keyOwnershipVerified'] == false);
    final hex = RegExp(r'^[a-f0-9]{64}$');
    require(d['orderId'] is String && RegExp(r'^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$').hasMatch(d['orderId'] as String));
    require(d['setupRevision'] is int && d['setupRevision'] > 0 && d['setupRevision'] <= 9007199254740991);
    for (final field in ['snapshotHash','setupAgreementHash','draftHash']) {
      require(d[field] is String && hex.hasMatch(d[field] as String));
    }
    final s = Map<String,dynamic>.from(d['snapshot'] as Map);
    require(s['orderId'] == d['orderId'] && s['delivery'] == 'shipping' && digest(s) == d['snapshotHash']);
    final keys = Map<String,dynamic>.from(d['keys'] as Map);
    exact(keys, {'buyer','seller','market'});
    for(final key in keys.values) {
      require(key is String && RegExp(r'^0[23][a-f0-9]{64}$').hasMatch(key));
      ECPublic.fromHex(key as String);
    }
    require(keys.values.toSet().length == 3 && ['buyer','seller','market'].contains(role) && keys[role] == ownPublicKey);
    require(digest({'snapshotHash':d['snapshotHash'],'policy':'2-of-3','keys':keys,'network':'not-enabled','fundingEnabled':false}) == d['setupAgreementHash']);
    require(digest(d['feePolicy']) == digest({'payer':'buyer','unusedReserve':'buyer','minimumFeeSats':'1000','maximumReserveSats':'100000','minimumOutputSats':'546','platformFeeIncluded':false}));
    require(s['totalXbt'] is String && RegExp(r'^(0|[1-9][0-9]{0,7})(?:\.[0-9]{1,8})?$').hasMatch(s['totalXbt'] as String));
    final parts = (s['totalXbt'] as String).split('.');
    final price = BigInt.parse(parts[0])*BigInt.from(100000000) + BigInt.parse((parts.length == 2 ? parts[1] : '').padRight(8,'0'));
    final reserve = amount(d['buyerFeeReserveSats']);
    require(price >= BigInt.from(546) && price <= BigInt.from(1000000000) && price == amount(d['sellerPriceSats']));
    require(reserve >= BigInt.from(1000) && reserve <= BigInt.from(100000) && amount(d['totalDepositSats']) == price+reserve);
    final unhashed = {...d}..remove('draftHash');
    require(hex.hasMatch(expectedHash) && digest(unhashed) == d['draftHash'] && expectedHash == d['draftHash']);
    return FundingDraft._(d);
  }

  Map<String,dynamic> payout(String scenario, String feeSats, {String? sellerAwardSats}) {
    final price = amount(sellerPrice), reserved = amount(reserve), fee = amount(feeSats);
    require(fee >= BigInt.from(1000) && fee <= reserved && ['release','refund','split-refund'].contains(scenario));
    final award = scenario == 'release' ? price : scenario == 'refund' ? BigInt.zero : amount(sellerAwardSats);
    require(scenario == 'split-refund' ? award > BigInt.zero && award < price : sellerAwardSats == null);
    final buyer = price-award+reserved-fee;
    final keys = _data['keys'] as Map;
    final outputs = [
      {'role':'buyer','publicKey':keys['buyer'],'sats':buyer.toString()},
      {'role':'seller','publicKey':keys['seller'],'sats':award.toString()},
    ].where((o)=>o['sats'] != '0').toList();
    require(outputs.every((o)=>amount(o['sats']) >= BigInt.from(546)));
    require(outputs.fold<BigInt>(fee,(sum,o)=>sum+amount(o['sats'])) == amount(deposit));
    final plan = {'schema':'xbt-order-payout-plan-v1','chain':'regtest','testOnly':true,'fundingEnabled':false,
      'draftHash':hash,'scenario':scenario,'networkFeeSats':feeSats,'payouts':outputs};
    return {...plan,'planHash':digest(plan)};
  }
}
