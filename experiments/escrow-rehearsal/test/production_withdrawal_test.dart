import 'dart:convert';
import 'dart:io';
import 'package:bitcoin_base/bitcoin_base.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xbt_escrow_rehearsal/production_withdrawal.dart';
import 'package:xbt_escrow_rehearsal/production_contract.dart';
void main(){
 final fixture=jsonDecode(File('test-fixtures/production-withdrawal.json').readAsStringSync()) as Map;
 ProductionWithdrawalReview parse(Map r,{String? destination,String? role})=>ProductionWithdrawalReview.parse(jsonEncode(r),expectedRequestHash:r['requestHash'],expectedDestination:destination??r['destination'],maximumFeeSats:'1000',expectedOrigin:'https://xbtmarket.store',role:role??r['role'],ownPublicKey:r['publicKey']);
 test('independent Dart withdrawal signatures verify in Node and require recovery and consent',(){
  final signatures=[];for(final r in fixture['requests']){final review=parse(r),key=ECPrivate.fromHex('02'.padLeft(64,'0'));
   expect(()=>review.sign(key,recoveryVerified:false,confirmWithdrawal:true),throwsA(anything));expect(()=>review.sign(key,recoveryVerified:true,confirmWithdrawal:false),throwsA(anything));
   signatures.add(review.sign(key,recoveryVerified:true,confirmWithdrawal:true));
   expect(()=>parse(r,role:'market'),throwsA(anything));expect(()=>parse(r,destination:'bc1q'),throwsA(anything));
  }
  Directory('test-results').createSync(recursive:true);File('test-results/dart-production-withdrawal-signatures.json').writeAsStringSync(jsonEncode(signatures));
 });
 test('rehashing tampered parent, transaction, chain and amounts cannot bypass withdrawal checks',(){
  for(final change in <void Function(Map)>[(r)=>r['parent']['valueSats']='1',(r)=>r['parent']['txid']='0'*64,(r)=>r['outputSats']='1',(r)=>r['unsignedHex']='00',(r)=>r['vout']=3,(r)=>r['chainProfile']['network']='regtest',(r)=>r['feeSats']='10001']){final r=jsonDecode(jsonEncode(fixture['requests'][0])) as Map;change(r);r.remove('requestHash');r['requestHash']=ProductionContractReview.digest(r);expect(()=>parse(r),throwsA(anything));}
 });
}
