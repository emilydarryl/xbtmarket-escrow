import 'dart:convert';
import 'dart:io';
import 'package:bitcoin_base/bitcoin_base.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xbt_escrow_rehearsal/approved_payout.dart';
import 'package:xbt_escrow_rehearsal/funding_draft.dart';
void main(){
 final requests=jsonDecode(File('test-fixtures/approved-payout.json').readAsStringSync()) as List;
 ECPrivate key(String role)=>ECPrivate.fromHex({'buyer':11,'seller':22,'market':33}[role]!.toRadixString(16).padLeft(64,'0'));
 ApprovedPayout parse(Map r,String role)=>ApprovedPayout.parse(jsonEncode(r),expectedRequestHash:r['requestHash'] as String,expectedDraftHash:r['draft']['draftHash'] as String,ownPublicKey:key(role).getPublic().toHex(),role:role);
 test('all three roles review and sign every exact variable-price outcome',(){
  for(final r in requests){for(final role in ['buyer','seller','market']){
   final p=parse(r as Map,role),signed=p.sign(key(role),recoveryVerified:true,confirmPayout:true);
   expect(signed['requestHash'],r['requestHash']);expect(signed['signerRole'],role);
  }}
 });
 test('recovery verification and explicit payout confirmation are both required',(){
  final p=parse(requests.first as Map,'buyer');
  expect(()=>p.sign(key('buyer'),recoveryVerified:false,confirmPayout:true),throwsA(anything));
  expect(()=>p.sign(key('buyer'),recoveryVerified:true,confirmPayout:false),throwsA(anything));
  expect(()=>p.sign(key('seller'),recoveryVerified:true,confirmPayout:true),throwsA(anything));
 });
 test('changed outputs, fees, script, signature flags and decision roles fail even with new request hashes',(){
  for(final mutate in <void Function(Map)>[
   (r)=>r['transaction']['outputs'][0]['sats']='99999',
   (r)=>r['transaction']['networkFeeSats']='1000',
   (r)=>r['transaction']['witnessScript']='00',
   (r)=>r['transaction']['broadcast']=true,
   (r)=>r['decision']['by']='seller',
   (r)=>r['transaction']['pin']['fundingBlockHash']='invalid',
  ]){final r=jsonDecode(jsonEncode(requests.first)) as Map;mutate(r);r.remove('requestHash');r['requestHash']=FundingDraft.digest(r);expect(()=>parse(r,'buyer'),throwsA(anything));}
 });
 test('independent draft and selected request pins reject an otherwise valid package',(){
  final r=requests.first;
  expect(()=>ApprovedPayout.parse(jsonEncode(r),expectedRequestHash:'0'*64,expectedDraftHash:r['draft']['draftHash'] as String,ownPublicKey:key('buyer').getPublic().toHex(),role:'buyer'),throwsA(anything));
 });
}
