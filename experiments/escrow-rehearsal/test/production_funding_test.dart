import 'dart:convert';
import 'dart:io';
import 'package:bitcoin_base/bitcoin_base.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xbt_escrow_rehearsal/production_funding.dart';
void main(){
 final f=jsonDecode(File('test-fixtures/production-funding.json').readAsStringSync()) as Map;
 ProductionFundingReview parse(Map entry,{Map? request,int? now,String? fundingHash}){final r=request??entry['request'] as Map,c=r['bundle']['contract'];return ProductionFundingReview.parse(jsonEncode(r),expectedContractHash:c['contractHash'],expectedFundingTermsHash:fundingHash??r['terms']['fundingTermsHash'],expectedOrigin:f['origin'],ownPublicKey:c['keys'][entry['role']],expectedMediatorPublicKey:c['keys']['market'],role:entry['role'],now:now??f['now']);}
 test('independent funding parser verifies all three review signatures and produces Node-verifiable funding proofs',(){
  final proofs=[];
  for(final raw in f['entries']){final e=raw as Map,r=e['request'],review=parse(e);expect(ProductionFundingReview.messageHash(ProductionFundingReview.domain,r['challenge']),e['messageHash']);
   final key=ECPrivate.fromHex((e['scalar'] as int).toRadixString(16).padLeft(64,'0'));
   expect(()=>review.sign(key,confirmDeposit:false,productionRecoveryVerified:true,now:f['now']),throwsA(anything));
   expect(()=>review.sign(key,confirmDeposit:true,productionRecoveryVerified:false,now:f['now']),throwsA(anything));
   expect(()=>review.sign(key,confirmDeposit:true,productionRecoveryVerified:true,now:r['challenge']['expiresAt']),throwsA(anything));
   proofs.add(review.sign(key,confirmDeposit:true,productionRecoveryVerified:true,now:f['now']));
  }
  Directory('test-results').createSync(recursive:true);File('test-results/dart-production-funding-proofs.json').writeAsStringSync(jsonEncode(proofs));
 });
 test('funding consent rejects altered review proofs, scripts, policies, timing and independent hash',(){
  final e=f['entries'][0] as Map;expect(()=>parse(e,fundingHash:'0'*64),throwsA(anything));expect(()=>parse(e,now:e['request']['challenge']['expiresAt']),throwsA(anything));
  for(final mutate in <void Function(Map)>[(r)=>r['bundle']['proofs'].remove('market'),(r)=>r['bundle']['proofs']['seller']['signature']=r['bundle']['proofs']['buyer']['signature'],(r)=>r['terms']['valueSats']='1',(r)=>r['terms']['lateDepositPolicy']='unlock',(r)=>r['challenge']['role']='seller',(r)=>r['challenge']['purpose']='review-production-contract-not-payment']){final r=jsonDecode(jsonEncode(e['request'])) as Map;mutate(r);expect(()=>parse(e,request:r),throwsA(anything));}
 });
}
