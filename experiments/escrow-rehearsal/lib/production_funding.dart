import 'dart:convert';
import 'package:bitcoin_base/bitcoin_base.dart';
import 'package:blockchain_utils/blockchain_utils.dart';
import 'package:xbt_market_escrow_lab/escrow_signer.dart' show sha;
import 'shared_order.dart' show sortedJson;
import 'production_contract.dart';

class ProductionFundingReview {
  ProductionFundingReview._(this._terms,this._challenge,this.publicKey);
  final Map<String,dynamic> _terms,_challenge;
  final String publicKey;
  static const domain='XBT Market: authorize this exact production escrow deposit; no spending permission. v1\n';
  static void need(bool value){if(!value)throw const FormatException('Production funding consent mismatch.');}
  static String digest(dynamic value)=>ProductionContractReview.digest(value);
  static String messageHash(String domain,Map challenge)=>sha(utf8.encode(domain+jsonEncode(sortedJson(challenge))));
  String get reviewJson=>const JsonEncoder.withIndent('  ').convert(_terms);
  String get fundingTermsHash=>_terms['fundingTermsHash'] as String;
  static void verify(String key,String hash,dynamic encoded){
    need(encoded is String&&encoded.length<=100);final der=base64Decode(encoded as String);
    need(base64Encode(der)==encoded&&der.length>=8&&der.length<=72&&der[0]==48&&der[1]==der.length-2);
    var offset=2;final numbers=<BigInt>[];
    for(var i=0;i<2;i++){need(offset+2<=der.length&&der[offset++]==2);final size=der[offset++];need(size>=1&&size<=33&&offset+size<=der.length);final b=der.sublist(offset,offset+size);offset+=size;need((b[0]&128)==0&&!(size>1&&b[0]==0&&(b[1]&128)==0));numbers.add(BigInt.parse(BytesUtils.toHexString(b),radix:16));}
    final n=BigInt.parse('fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141',radix:16);
    need(offset==der.length&&numbers[0]>BigInt.zero&&numbers[0]<n&&numbers[1]>BigInt.zero&&numbers[1]<=n~/BigInt.from(2));
    need(BitcoinSignatureVerifier.fromKeyBytes(BytesUtils.fromHexString(key)).verifyECDSADerSignature(digest:BytesUtils.fromHexString(hash),signature:der));
  }
  static ProductionFundingReview parse(String encoded,{required String expectedContractHash,required String expectedFundingTermsHash,required String expectedOrigin,required String ownPublicKey,required String expectedMediatorPublicKey,required String role,required int now}){
    need(encoded.length<=50000);final input=Map<String,dynamic>.from(jsonDecode(encoded) as Map);ProductionContractReview.exact(input,{'schema','bundle','terms','challenge'});need(input['schema']=='xbt-production-funding-request-v1');
    final bundle=Map<String,dynamic>.from(input['bundle'] as Map);ProductionContractReview.exact(bundle,{'contract','proofs','acceptedAt','receipt'});
    final c=Map<String,dynamic>.from(bundle['contract'] as Map),proofs=Map<String,dynamic>.from(bundle['proofs'] as Map),accepted=Map<String,dynamic>.from(bundle['acceptedAt'] as Map);
    ProductionContractReview.exact(proofs,{'buyer','seller','market'});ProductionContractReview.exact(accepted,{'buyer','seller','market'});
    need(['buyer','seller','market'].contains(role)&&c['keys'][role]==ownPublicKey);
    for(final r in ['buyer','seller','market']){
      final proof=Map<String,dynamic>.from(proofs[r] as Map);ProductionContractReview.exact(proof,{'schema','challenge','signature'});need(proof['schema']=='xbt-production-contract-proof-v1'&&accepted[r] is int);
      final reviewed=ProductionContractReview.parse(jsonEncode({'schema':'xbt-production-contract-request-v1','contract':c,'challenge':proof['challenge']}),expectedContractHash:expectedContractHash,expectedOrigin:expectedOrigin,ownPublicKey:c['keys'][r],expectedMediatorPublicKey:expectedMediatorPublicKey,role:r,now:accepted[r]);
      verify(c['keys'][r],reviewed.messageHash,proof['signature']);
    }
    final receipt={'schema':'xbt-production-contract-review-receipt-v1','contractHash':expectedContractHash,'proofHashes':{for(final r in ['buyer','seller','market'])r:digest(proofs[r])},'acceptedAt':accepted,'fundingEnabled':false};
    need(digest(bundle['receipt'])==digest({...receipt,'receiptHash':digest(receipt)}));
    final terms={'schema':'xbt-production-funding-terms-v1','chainProfile':c['chainProfile'],'origin':c['origin'],'orderId':c['preflight']['orderId'],'contractHash':expectedContractHash,'reviewReceiptHash':digest(receipt),'scriptPubKey':c['scriptPubKey'],'valueSats':c['totalDepositSats'],'minimumConfirmations':3,'depositPolicy':'one-exact-output-other-outputs-require-review','lateDepositPolicy':'permanent-monitoring-no-automatic-unlock','replacementPolicy':'not-authorized','spendingAuthorized':false};
    need(ProductionContractReview.hex(expectedFundingTermsHash)&&digest(terms)==expectedFundingTermsHash&&digest(input['terms'])==digest({...terms,'fundingTermsHash':expectedFundingTermsHash}));
    final q=Map<String,dynamic>.from(input['challenge'] as Map);ProductionContractReview.exact(q,{'schema','purpose','origin','orderId','contractHash','fundingTermsHash','role','publicKey','nonce','issuedAt','expiresAt'});
    need(q['schema']=='xbt-production-funding-challenge-v1'&&q['purpose']=='authorize-exact-escrow-deposit'&&q['origin']==expectedOrigin&&q['orderId']==terms['orderId']&&q['contractHash']==expectedContractHash&&q['fundingTermsHash']==expectedFundingTermsHash&&q['role']==role&&q['publicKey']==ownPublicKey&&ProductionContractReview.hex(q['nonce']));
    need(q['issuedAt'] is int&&q['expiresAt'] is int&&q['issuedAt']>=0&&q['expiresAt']<=9007199254740991&&q['expiresAt']-q['issuedAt']==900000&&now>=q['issuedAt']&&now<q['expiresAt']);
    need(accepted.values.every((time)=>q['issuedAt']>=time));
    return ProductionFundingReview._(Map<String,dynamic>.from(input['terms']),q,ownPublicKey);
  }
  Map<String,dynamic> sign(ECPrivate key,{required bool confirmDeposit,required bool productionRecoveryVerified,required int now}){
    need(confirmDeposit&&productionRecoveryVerified&&key.getPublic().toHex()==publicKey&&now>=_challenge['issuedAt']&&now<_challenge['expiresAt']);
    final hash=messageHash(domain,_challenge),raw=BytesUtils.fromHexString(key.signECDSA(BytesUtils.fromHexString(hash),sighash:1)),encoded=base64Encode(raw.sublist(0,raw.length-1));verify(publicKey,hash,encoded);
    return {'schema':'xbt-production-funding-proof-v1','challenge':jsonDecode(jsonEncode(_challenge)),'signature':encoded};
  }
}
