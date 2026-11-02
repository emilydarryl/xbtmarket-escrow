// Public order separation using pay-to-contract key tweaks, independently derived.
import 'dart:convert';
import 'package:bitcoin_base/bitcoin_base.dart';
import 'package:blockchain_utils/blockchain_utils.dart';
import 'package:xbt_market_escrow_lab/escrow_signer.dart' show sha;
import 'shared_order.dart' show sortedJson;
class ProductionOrderKeys {
 static final n=BigInt.parse('fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141',radix:16);
 static BigInt tweak(Map c,String role){
  if(!['buyer','seller','market'].contains(role))throw const FormatException('Invalid order role.');
  final value=BigInt.parse(sha(utf8.encode(jsonEncode(sortedJson({'domain':'xbt-production-order-key-v3','chainProfile':c['chainProfile'],'origin':c['origin'],'orderId':c['preflight']['orderId'],'revision':c['revision'],'preflightHash':c['preflight']['preflightHash'],'keys':c['keys'],'role':role})))),radix:16);
  if(value==BigInt.zero||value>=n)throw const FormatException('Invalid order tweak. New review required.');return value;
 }
 static Map<String,String> derive(Map c){
  final keys=<String,String>{};
  for(final role in ['buyer','seller','market']){
   final base=Secp256k1PublicKey.fromBytes(BytesUtils.fromHexString(c['keys'][role] as String)).point;
   final point=base+Curves.generatorSecp256k1*tweak(c,role);
   keys[role]=Secp256k1PublicKey.fromBytes(point.toBytes()).toHex();
  }
  if(keys.values.toSet().length!=3)throw const FormatException('Distinct order keys required.');return keys;
 }
 static ECPrivate signingKey(Map c,String role,ECPrivate identity){
  if(identity.getPublic().toHex()!=c['keys'][role])throw const FormatException('Wrong identity.');
  final scalar=(BigInt.parse(identity.toHex(),radix:16)+tweak(c,role))%n;
  if(scalar==BigInt.zero)throw const FormatException('Invalid order key.');
  final bytes=BytesUtils.fromHexString(scalar.toRadixString(16).padLeft(64,'0'));
  try{final key=ECPrivate.fromBytes(bytes);if(key.getPublic().toHex()!=derive(c)[role])throw const FormatException('Order key mismatch.');return key;}finally{bytes.fillRange(0,bytes.length,0);}
 }
}
