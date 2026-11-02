import 'dart:convert';
import 'package:bitcoin_base/bitcoin_base.dart';
import 'package:blockchain_utils/blockchain_utils.dart';
import 'package:xbt_market_escrow_lab/escrow_signer.dart';

const testMediator =
    '021697ffa6fd9de627c077e3d2fe541084ce13300b0bec1146f95ae57f0d0bd6a5';
dynamic sortedJson(dynamic value) {
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return {for (final key in keys) key: sortedJson(value[key])};
  }
  if (value is List) return value.map(sortedJson).toList();
  return value;
}

String publicFingerprint(String key) =>
    sha(BytesUtils.fromHexString(key)).substring(0, 12);

class SharedOrder {
  SharedOrder._(this._data, this.hash);
  final Map<String, dynamic> _data;
  final String hash;
  Map<String, dynamic> get data =>
      Map<String, dynamic>.from(jsonDecode(jsonEncode(_data)) as Map);
  String get id => _data['orderId'] as String;
  String get buyer => _data['buyerPublicKey'] as String;
  String get seller => _data['sellerPublicKey'] as String;
  String get market => _data['marketPublicKey'] as String;
  String get title => _data['title'] as String;
  String get terms => _data['terms'] as String;
  String encode() => jsonEncode({...data, 'contractHash': hash});

  static SharedOrder parse(String encoded, String ownPublicKey, String role) {
    if (encoded.length > 12000 || !['buyer', 'seller'].contains(role)) {
      throw const FormatException('Invalid shared test-order setup.');
    }
    final data = Map<String, dynamic>.from(jsonDecode(encoded) as Map);
    final claimed = data.remove('contractHash');
    const fields = {
      'schema',
      'chain',
      'testOnly',
      'orderId',
      'title',
      'terms',
      'buyerPublicKey',
      'sellerPublicKey',
      'marketPublicKey',
      'depositSats',
      'networkFeeSats',
      'funding',
      'fundingBlockHash',
      'witnessScript',
    };
    if (data.keys.toSet().difference(fields).isNotEmpty ||
        data.length != fields.length ||
        data['schema'] != 'xbt-shared-rehearsal-contract-v1' ||
        data['chain'] != 'regtest' ||
        data['testOnly'] != true ||
        data['depositSats'] != '500000000' ||
        data['networkFeeSats'] != '1000' ||
        data['fundingBlockHash'] is! String ||
        !RegExp(
          r'^[a-f0-9]{64}$',
        ).hasMatch(data['fundingBlockHash'] as String) ||
        data['orderId'] is! String ||
        !RegExp(
          r'^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$',
        ).hasMatch(data['orderId'] as String)) {
      throw const FormatException(
        'Only a fixed-amount shared regtest order is supported.',
      );
    }
    for (final field in ['title', 'terms']) {
      final value = data[field];
      if (value is! String ||
          value.length < 5 ||
          value.length > (field == 'title' ? 120 : 1500) ||
          RegExp(r'[\x00-\x1f\x7f]').hasMatch(value)) {
        throw const FormatException('Check the shared test-order terms.');
      }
    }
    final keys = [
      data['buyerPublicKey'],
      data['sellerPublicKey'],
      data['marketPublicKey'],
    ];
    for (final key in keys) {
      if (key is! String || !RegExp(r'^0[23][a-f0-9]{64}$').hasMatch(key)) {
        throw const FormatException('Invalid shared participant key.');
      }
      ECPublic.fromHex(key);
    }
    if (keys.toSet().length != 3 || data['${role}PublicKey'] != ownPublicKey) {
      throw const FormatException(
        'This shared order belongs to another phone or role.',
      );
    }
    final sorted = keys.cast<String>()..sort();
    if (data['witnessScript'] !=
        '52${sorted.map((key) => '21$key').join()}53ae') {
      throw const FormatException(
        'Shared escrow script does not match the participants.',
      );
    }
    final funding = Map<String, String>.from(data['funding'] as Map);
    if (funding.length != 1 ||
        funding.values.single != '500000000' ||
        !RegExp(
          r'^[a-f0-9]{64}:(0|[1-9]\d{0,9})$',
        ).hasMatch(funding.keys.single) ||
        BigInt.parse(funding.keys.single.split(':')[1]) >
            BigInt.from(4294967295)) {
      throw const FormatException('Invalid shared test funding outpoint.');
    }
    final digest = sha(utf8.encode(jsonEncode(sortedJson(data))));
    if (claimed != digest) {
      throw const FormatException('Shared test-order hash changed.');
    }
    return SharedOrder._(data, digest);
  }
}
