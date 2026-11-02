import 'production_order_keys.dart';
// Candidate offline production review protocol. Not connected to the rehearsal UI
// or its key store. This message approval cannot sign a spending transaction.
import 'dart:convert';
import 'package:bitcoin_base/bitcoin_base.dart';
import 'package:blockchain_utils/blockchain_utils.dart';
import 'package:xbt_market_escrow_lab/escrow_signer.dart' show sha;
import 'shared_order.dart' show sortedJson;

class ProductionContractReview {
  ProductionContractReview._(this._contract,this._challenge,this.publicKey);
  final Map<String,dynamic> _contract,_challenge;
  final String publicKey;
  static const domain='XBT Market: production contract review only, NOT a payment or funding authorization. v1\n';
  static const chain={'network':'main','genesis':'000000000019d6689c085ae165831e934ff763ae46a2a6c172b3f1b60a8ce26f','checkpointHeight':961640,'checkpointHash':'0000000000000050c1e5f69672f459293be14f46e5a494e7a8c8541396f18eeb'};
  static void need(bool v){if(!v)throw const FormatException('Production contract review mismatch.');}
  static void exact(Map v,Set<String> fields)=>need(v.length==fields.length&&v.keys.every(fields.contains));
  static String digest(dynamic v)=>sha(utf8.encode(jsonEncode(sortedJson(v))));
  static bool hex(dynamic v)=>v is String&&RegExp(r'^[a-f0-9]{64}$').hasMatch(v);
  static BigInt sats(dynamic v){need(v is String&&RegExp(r'^(0|[1-9][0-9]{0,15})$').hasMatch(v));final n=BigInt.parse(v as String);need(n<=BigInt.parse('2100000000000000'));return n;}
  static void origin(String v){final u=Uri.parse(v);need(u.scheme=='https'&&u.origin==v&&u.userInfo.isEmpty&&u.path.isEmpty&&!u.hasQuery&&!u.hasFragment);}
  String get reviewJson=>const JsonEncoder.withIndent('  ').convert(_contract);
  String get contractHash=>_contract['contractHash'] as String;
  String get messageHash=>sha(utf8.encode(domain+jsonEncode(sortedJson(_challenge))));
  static ProductionContractReview parse(String encoded,{required String expectedContractHash,required String expectedOrigin,required String ownPublicKey,required String expectedMediatorPublicKey,required String role,required int now}){
    need(encoded.length<=40000);origin(expectedOrigin);
    final input=Map<String,dynamic>.from(jsonDecode(encoded) as Map);exact(input,{'schema','contract','challenge'});need(input['schema']=='xbt-production-contract-request-v1');
    final c=Map<String,dynamic>.from(input['contract'] as Map);
    exact(c,{'schema','chainProfile','origin','revision','preflight','snapshot','keys','sellerPriceSats','buyerFeeReserveSats','totalDepositSats','feePolicy','orderKeys','witnessScript','scriptPubKey','payoutScripts','fundingEnabled','contractHash'});
    need(c['schema']=='xbt-production-contract-review-v3'&&c['fundingEnabled']==false&&c['origin']==expectedOrigin&&c['revision'] is int&&c['revision']>0&&c['revision']<=9007199254740991&&digest(c['chainProfile'])==digest(chain));
    final p=Map<String,dynamic>.from(c['preflight'] as Map);exact(p,{'schema','orderId','snapshotHash','accountBindingHash','paymentMode','sellerPriceSats','fundingEnabled','signingEnabled','preflightHash'});
    need(p['schema']=='xbt-escrow-order-preflight-v1'&&p['fundingEnabled']==false&&p['signingEnabled']==false&&['direct','escrow_setup'].contains(p['paymentMode'])&&hex(p['snapshotHash'])&&hex(p['accountBindingHash'])&&hex(p['preflightHash'])&&digest({...p}..remove('preflightHash'))==p['preflightHash']);
    final s=Map<String,dynamic>.from(c['snapshot'] as Map);exact(s,{'orderId','listingId','sellerProfileId','title','description','terms','totalXbt','delivery','destinationCountry','shipping','platformFeePolicy'});
    need(p['orderId'] is String&&RegExp(r'^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$').hasMatch(p['orderId'])&&s['orderId']==p['orderId']&&s['delivery']=='shipping'&&digest(s)==p['snapshotHash']);
    for(final field in ['title','description','terms']){need(s[field] is String&&s[field].isNotEmpty&&s[field].length<=10000);}
    need(s['totalXbt'] is String&&RegExp(r'^(0|[1-9][0-9]{0,9})(\.[0-9]{1,8})?$').hasMatch(s['totalXbt']));
    final parts=(s['totalXbt'] as String).split('.'),price=sats(c['sellerPriceSats']),reserve=sats(c['buyerFeeReserveSats']),deposit=sats(c['totalDepositSats']);
    need(price>=BigInt.from(546)&&price.toString()==p['sellerPriceSats']&&price==BigInt.parse(parts[0])*BigInt.from(100000000)+BigInt.parse((parts.length==2?parts[1]:'').padRight(8,'0'))&&reserve>=BigInt.from(1000)&&reserve<=BigInt.from(100000)&&deposit==price+reserve);
    need(digest(c['feePolicy'])==digest({'version':'buyer-reserve-review-v1','payer':'buyer','unusedReserve':'buyer','minimumOutputSats':'546','platformFeeIncluded':false,'replacement':'not-authorized'}));
    final keys=Map<String,dynamic>.from(c['keys'] as Map);exact(keys,{'buyer','seller','market'});
    for(final k in keys.values){need(k is String&&RegExp(r'^0[23][a-f0-9]{64}$').hasMatch(k));ECPublic.fromHex(k as String);}
    need(keys.values.toSet().length==3&&['buyer','seller','market'].contains(role)&&keys[role]==ownPublicKey&&keys['market']==expectedMediatorPublicKey);
    final orderKeys=ProductionOrderKeys.derive(c);need(digest(c['orderKeys'])==digest(orderKeys));
    final sorted=orderKeys.values.toList()..sort(),witness='52${sorted.map((k)=>'21$k').join()}53ae';
    need(c['witnessScript']==witness&&c['scriptPubKey']=='0020${sha(BytesUtils.fromHexString(witness))}');
    need(digest(c['payoutScripts'])==digest({for(final r in ['buyer','seller'])r:ECPublic.fromHex(keys[r] as String).toSegwitAddress().toScriptPubKey().toHex()}));
    need(hex(expectedContractHash)&&c['contractHash']==expectedContractHash&&digest({...c}..remove('contractHash'))==expectedContractHash);
    final q=Map<String,dynamic>.from(input['challenge'] as Map);exact(q,{'schema','purpose','origin','contractHash','orderId','revision','role','publicKey','nonce','issuedAt','expiresAt'});
    need(q['schema']=='xbt-production-contract-challenge-v1'&&q['purpose']=='review-production-contract-not-payment'&&q['origin']==expectedOrigin&&q['contractHash']==expectedContractHash&&q['orderId']==p['orderId']&&q['revision']==c['revision']&&q['role']==role&&q['publicKey']==ownPublicKey&&hex(q['nonce']));
    need(q['issuedAt'] is int&&q['expiresAt'] is int&&q['issuedAt']>=0&&q['expiresAt']<=9007199254740991&&q['expiresAt']-q['issuedAt']==900000&&now>=q['issuedAt']&&now<q['expiresAt']);
    return ProductionContractReview._(c,q,ownPublicKey);
  }
  Map<String,dynamic> sign(ECPrivate key,{required bool confirmReview,required bool productionRecoveryVerified,required int now}){
    need(confirmReview&&productionRecoveryVerified&&key.getPublic().toHex()==publicKey&&now>=_challenge['issuedAt']&&now<_challenge['expiresAt']);
    final message=BytesUtils.fromHexString(messageHash),encoded=BytesUtils.fromHexString(key.signECDSA(message,sighash:1)),signature=encoded.sublist(0,encoded.length-1);
    need(BitcoinSignatureVerifier.fromKeyBytes(BytesUtils.fromHexString(publicKey)).verifyECDSADerSignature(digest:message,signature:signature));
    return {'schema':'xbt-production-contract-proof-v1','challenge':jsonDecode(jsonEncode(_challenge)),'signature':base64Encode(signature)};
  }
}
