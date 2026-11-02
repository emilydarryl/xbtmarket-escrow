import 'dart:convert';
import 'dart:io';
import 'package:bitcoin_base/bitcoin_base.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xbt_escrow_rehearsal/production_spend.dart';
import 'package:xbt_escrow_rehearsal/production_contract.dart';
void main(){
 final fixture=jsonDecode(File('test-fixtures/production-spend.json').readAsStringSync()) as Map;
 ProductionSpendReview parse(Map request,String role){final c=request['authorization']['bundle']['contract'];return ProductionSpendReview.parse(jsonEncode(request),expectedRequestHash:request['requestHash'],expectedContractHash:c['contractHash'],expectedFundingTermsHash:request['authorization']['terms']['fundingTermsHash'],expectedOrigin:fixture['origin'],ownPublicKey:c['keys'][role],expectedMediatorPublicKey:c['keys']['market'],role:role);}
 test('independent production spend review signs every role/outcome for Node verification with the order-unique script',(){
  final signatures=[];
  for(final entry in fixture['cases']){for(final role in ['buyer','seller','market']){final r=entry['request'] as Map,d=r['decision'] as Map;final allowed=d['disputed']?{'release':['seller','market'],'refund':['buyer','market'],'split-refund':['buyer','seller','market']}[d['scenario']]!:['buyer','seller'];if(!allowed.contains(role)){expect(()=>parse(r,role),throwsA(anything));continue;}final review=parse(r,role),key=ECPrivate.fromHex((fixture['scalars'][role] as int).toRadixString(16).padLeft(64,'0'));
   expect(()=>review.sign(key,recoveryVerified:false,confirmPayout:true),throwsA(anything));expect(()=>review.sign(key,recoveryVerified:true,confirmPayout:false),throwsA(anything));
   signatures.add(review.sign(key,recoveryVerified:true,confirmPayout:true));
  }}
  Directory('test-results').createSync(recursive:true);File('test-results/dart-production-spend-signatures.json').writeAsStringSync(jsonEncode(signatures));
 });
 test('rehashing altered amounts, authorization, outpoints and payout metadata cannot bypass independent spending checks',(){
  final original=fixture['cases'][0]['request'];
  for(final change in <void Function(Map)>[(r)=>r['transaction']['outputs'][0]['sats']='1',(r)=>r['deposit']['vout']=2,(r)=>r['decision']['networkFeeSats']='1',(r)=>r['authorization']['proofs'].remove('market'),(r)=>r['transaction']['unsignedHex']='00',(r)=>r['transaction']['txid']='0'*64]){final r=jsonDecode(jsonEncode(original)) as Map;change(r);r.remove('requestHash');r['requestHash']=ProductionContractReview.digest(r);expect(()=>parse(r,'buyer'),throwsA(anything));}
 });
}
