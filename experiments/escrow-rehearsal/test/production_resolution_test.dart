import 'dart:convert';
import 'dart:io';
import 'package:bitcoin_base/bitcoin_base.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xbt_escrow_rehearsal/production_resolution.dart';
import 'package:xbt_escrow_rehearsal/production_contract.dart';
void main(){
 final f=jsonDecode(File('test-fixtures/production-resolution.json').readAsStringSync()) as Map;
 ProductionResolutionReview parse(Map r,{int? now,String? pin}){final p=r['payoutRequest'],c=p['authorization']['bundle']['contract'];return ProductionResolutionReview.parse(jsonEncode(r),expectedDecisionHash:pin??r['decisionHash'],expectedContractHash:c['contractHash'],expectedFundingTermsHash:p['authorization']['terms']['fundingTermsHash'],expectedOrigin:f['origin'],ownPublicKey:c['keys']['market'],now:now??f['now']);}
 test('mediator independently reviews and signs all three decision outcomes for Node verification',(){
  final proofs=[],key=ECPrivate.fromHex((f['scalar'] as int).toRadixString(16).padLeft(64,'0'));
  for(final r in f['entries']){final review=parse(r as Map);
   expect(()=>review.sign(key,recoveryVerified:false,confirmDecision:true,now:f['now']),throwsA(anything));expect(()=>review.sign(key,recoveryVerified:true,confirmDecision:false,now:f['now']),throwsA(anything));
   expect(()=>review.sign(ECPrivate.fromHex('16'.padLeft(64,'0')),recoveryVerified:true,confirmDecision:true,now:f['now']),throwsA(anything));
   proofs.add(review.sign(key,recoveryVerified:true,confirmDecision:true,now:f['now']));
  }
  Directory('test-results').createSync(recursive:true);File('test-results/dart-production-resolution-proofs.json').writeAsStringSync(jsonEncode(proofs));
 });
 test('rehashing wrong dispute, fee, role or challenge cannot bypass mediator review and expiry',(){
  final original=f['entries'][0] as Map;
  expect(()=>parse(original,pin:'00'*32),throwsA(anything));expect(()=>parse(original,now:original['challenge']['expiresAt']),throwsA(anything));
  for(final change in <void Function(Map)>[(r)=>r['workflow']['status']='delivered',(r)=>r['workflow']['revision']=2,(r)=>r['challenge']['publicKey']=r['payoutRequest']['authorization']['bundle']['contract']['keys']['buyer'],(r)=>r['payoutRequest']['decision']['networkFeeSats']='1',(r)=>r['challenge']['purpose']='sign-spend',(r)=>r['workflow']['dispute']['reason']='changed dispute reason']){
   final r=jsonDecode(jsonEncode(original)) as Map;change(r);r.remove('decisionHash');r['decisionHash']=ProductionContractReview.digest(r);expect(()=>parse(r),throwsA(anything));
  }
 });
}
