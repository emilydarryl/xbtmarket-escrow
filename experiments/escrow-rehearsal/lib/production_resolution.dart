import 'dart:convert';
import 'package:bitcoin_base/bitcoin_base.dart';
import 'package:blockchain_utils/blockchain_utils.dart';
import 'package:xbt_market_escrow_lab/escrow_signer.dart' show sha;
import 'production_contract.dart';
import 'production_spend.dart';
import 'shared_order.dart' show sortedJson;
class ProductionResolutionReview {
 ProductionResolutionReview._(this._request,this.publicKey,this.payoutReview);
 final Map<String,dynamic> _request;final String publicKey;final ProductionSpendReview payoutReview;
 static const domain='XBT Market: approve this exact mediated payout selection; NOT a spending signature. v1\n';
 static void need(bool v){if(!v)throw const FormatException('Mediator resolution mismatch.');}
 String get reviewJson=>const JsonEncoder.withIndent('  ').convert({'workflow':_request['workflow'],'payout':jsonDecode(payoutReview.reviewJson),'decisionHash':_request['decisionHash'],'spendingAuthorized':false});
 static ProductionResolutionReview parse(String encoded,{required String expectedDecisionHash,required String expectedContractHash,required String expectedFundingTermsHash,required String expectedOrigin,required String ownPublicKey,required int now}){
  need(encoded.length<=100000);final r=Map<String,dynamic>.from(jsonDecode(encoded) as Map);ProductionContractReview.exact(r,{'schema','payoutRequest','workflow','challenge','decisionHash'});
  need(r['schema']=='xbt-production-resolution-request-v1'&&ProductionContractReview.hex(expectedDecisionHash)&&r['decisionHash']==expectedDecisionHash&&ProductionContractReview.digest({...r}..remove('decisionHash'))==expectedDecisionHash);
  final p=r['payoutRequest'] as Map,c=p['authorization']['bundle']['contract'] as Map;
  final review=ProductionSpendReview.parse(jsonEncode(p),expectedRequestHash:p['requestHash'],expectedContractHash:expectedContractHash,expectedFundingTermsHash:expectedFundingTermsHash,expectedOrigin:expectedOrigin,ownPublicKey:ownPublicKey,expectedMediatorPublicKey:ownPublicKey,role:'market');need(p['decision']['disputed']==true&&p['decision']['by']=='market');
  final w=r['workflow'] as Map,d=w['dispute'] as Map;ProductionContractReview.exact(w,{'orderId','revision','authorizationHash','status','dispute'});ProductionContractReview.exact(d,{'by','reason','openedAt'});
  need(w['orderId']==c['preflight']['orderId']&&w['authorizationHash']==p['authorization']['authorizationHash']&&w['status']=='disputed'&&w['revision'] is int&&w['revision']>0&&w['revision']<=9007199254740991&&['buyer','seller'].contains(d['by'])&&d['reason'] is String&&d['reason'].length>=10&&d['reason'].length<=1000&&!RegExp(r'[\x00-\x1f\x7f]').hasMatch(d['reason'])&&d['openedAt'] is int&&d['openedAt']>=0);
  final q=r['challenge'] as Map;ProductionContractReview.exact(q,{'schema','purpose','origin','orderId','revision','workflowHash','requestHash','publicKey','nonce','issuedAt','expiresAt'});
  need(q['schema']=='xbt-production-resolution-challenge-v1'&&q['purpose']=='approve-mediated-payout-selection'&&q['origin']==expectedOrigin&&q['orderId']==w['orderId']&&q['revision']==w['revision']&&q['workflowHash']==ProductionContractReview.digest(w)&&q['requestHash']==p['requestHash']&&q['publicKey']==ownPublicKey&&ProductionContractReview.hex(q['nonce']));
  need(q['issuedAt'] is int&&q['issuedAt']>=d['openedAt']&&q['expiresAt'] is int&&q['expiresAt']<=9007199254740991&&q['expiresAt']-q['issuedAt']==900000&&now>=q['issuedAt']&&now<q['expiresAt']);return ProductionResolutionReview._(r,ownPublicKey,review);
 }
 Map<String,dynamic> sign(ECPrivate key,{required bool recoveryVerified,required bool confirmDecision,required int now}){
  final q=_request['challenge'] as Map;need(recoveryVerified&&confirmDecision&&key.getPublic().toHex()==publicKey&&now>=q['issuedAt']&&now<q['expiresAt']);
  final digest=BytesUtils.fromHexString(sha(utf8.encode(domain+jsonEncode(sortedJson(q))))),encoded=BytesUtils.fromHexString(key.signECDSA(digest,sighash:1)),signature=encoded.sublist(0,encoded.length-1);
  need(BitcoinSignatureVerifier.fromKeyBytes(BytesUtils.fromHexString(publicKey)).verifyECDSADerSignature(digest:digest,signature:signature));
  return {'schema':'xbt-production-resolution-proof-v1','decisionHash':_request['decisionHash'],'challenge':jsonDecode(jsonEncode(q)),'signature':base64Encode(signature)};
 }
}
