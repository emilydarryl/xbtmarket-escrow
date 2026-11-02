import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:xbt_escrow_rehearsal/production_identity.dart';

class MemoryProductionStore implements ProductionKeyStore {
 final Map<String,String> values={};
 bool failRead=false,failWrite=false,dropWrite=false;
 Completer<void>? readGate;
 @override Future<String?> read(String namespace) async {await readGate?.future;if(failRead)throw StateError('PRIVATE upstream detail');return values[namespace];}
 @override Future<void> write(String namespace,String record) async {if(failWrite)throw StateError('PRIVATE upstream detail');if(!dropWrite)values[namespace]=record;}
}
void main(){
 final f=jsonDecode(File('test-fixtures/production-recovery.json').readAsStringSync()) as Map,encoded=jsonEncode(f['envelope']),password=f['passphrase'] as String,origin=f['envelope']['origin'] as String;
 ProductionIdentitySession session(MemoryProductionStore s)=>ProductionIdentitySession(s,role:'buyer',origin:origin);
 test('Node encrypted fixture restores in Dart and Dart reseals for independent Node verification',(){
  final identity=ProductionIdentity.restore(encoded,password,'buyer',origin);expect(identity.publicKey,f['envelope']['publicKey']);
  final backup=identity.backup(password),second=identity.backup(password);expect(backup,isNot(second));expect(backup.contains(password),isFalse);expect(jsonDecode(backup)['sealed'],isNot(f['envelope']['sealed']));
  Directory('test-results').createSync(recursive:true);File('test-results/dart-production-recovery.json').writeAsStringSync(backup);
 });
 test('recovery rejects password, role, origin, schema, KDF and authentication tampering',(){
  expect(()=>ProductionIdentity.restore(encoded,'wrong but long passphrase','buyer',origin),throwsA(anything));
  for(final change in <void Function(Map)>[(e)=>e['role']='seller',(e)=>e['origin']='https://other.example.test',(e)=>e['schema']='xbt-regtest-v1',(e)=>e['kdf']['n']=1073741824,(e)=>e['extra']=true,(e)=>e['sealed']='AA==',(e)=>e['nonce']='AAAAAAAAAAAAAAAA']){
   final e=jsonDecode(encoded) as Map;change(e);expect(()=>ProductionIdentity.restore(jsonEncode(e),password,'buyer',origin),throwsA(anything));
  }
 });
 test('verified recovery persists locally but lock and reopen require password unlock',() async {
  final store=MemoryProductionStore(),s=session(store);await s.open();await s.restoreEmpty(encoded,password);expect(s.recoveryVerified,isTrue);expect(s.enrollment()['publicKey'],f['envelope']['publicKey']);
  final contracts=jsonDecode(File('test-fixtures/production-contract.json').readAsStringSync()) as Map,entry=contracts['entries'][0] as Map,c=entry['request']['contract'] as Map;
  Map sign()=>s.signReview(jsonEncode(entry['request']),expectedContractHash:c['contractHash'],expectedMediatorPublicKey:c['keys']['market'],confirmReview:true,now:contracts['now']);
  expect(sign()['schema'],'xbt-production-contract-proof-v1');s.lock();expect(()=>sign(),throwsA(anything));expect(()=>s.enrollment(),throwsA(anything));
  await s.unlock(password);expect(s.recoveryVerified,isTrue);expect(await s.exportBackup(),encoded);await s.verifyRecovery(encoded,password);expect(s.recoveryVerified,isTrue);
  await expectLater(s.unlock('wrong but long passphrase'),throwsA(anything));expect(s.publicKey,isNull);expect(s.recoveryVerified,isFalse);
  await s.open();expect(s.publicKey,isNull);expect(s.hasSavedIdentity,isTrue);await expectLater(s.create(password),throwsA(anything));
 });
 test('storage failure cannot create or replace a key and errors redact backend details',() async {
  final store=MemoryProductionStore(),s=session(store);store.failRead=true;
  await expectLater(s.open(),throwsA(predicate((e)=>!e.toString().contains('PRIVATE'))));await expectLater(s.create(password),throwsA(anything));expect(store.values,isEmpty);
  store.failRead=false;await s.open();store.dropWrite=true;await expectLater(s.restoreEmpty(encoded,password),throwsA(anything));expect(s.publicKey,isNull);expect(s.recoveryVerified,isFalse);
 });
 test('new identities are distinct, encrypted, isolated from rehearsal storage and require backup verification',() async {
  final store=MemoryProductionStore();store.values['regtest_rehearsal_key_v1']='existing test key';final a=session(store),b=session(store);await a.open();await b.open();
  final results=await Future.wait([a.create(password).then<Object>((v)=>v).catchError((Object e)=>e),b.create(password).then<Object>((v)=>v).catchError((Object e)=>e)]);
  expect(results.whereType<String>().length,1);expect(store.values.length,2);expect(store.values['regtest_rehearsal_key_v1'],'existing test key');
  final backup=results.whereType<String>().single;await a.open();await a.unlock(password);expect(a.recoveryVerified,false);expect(()=>a.enrollment(),throwsA(anything));await a.verifyRecovery(backup,password);expect(a.publicKey,isNot(f['envelope']['publicKey']));expect(a.recoveryVerified,isTrue);
  final seller=ProductionIdentitySession(store,role:'seller',origin:origin);expect(seller.namespace,isNot(a.namespace));
 });
 test('locking during delayed unlock prevents an asynchronous operation from restoring signing access',() async {
  final store=MemoryProductionStore(),s=session(store);store.values[s.namespace]=encoded;await s.open();store.readGate=Completer<void>();
  final pending=s.unlock(password);await Future<void>.delayed(Duration.zero);s.lock();store.readGate!.complete();await expectLater(pending,throwsA(anything));expect(s.publicKey,isNull);expect(s.recoveryVerified,isFalse);
 });
 test('mediator session requires verified recovery, explicit consent and its own role; locking revokes decision signing',() async {
  final fixture=jsonDecode(File('test-fixtures/production-mediator-recovery.json').readAsStringSync()) as Map,requests=jsonDecode(File('test-fixtures/production-resolution.json').readAsStringSync()) as Map,r=requests['entries'][0] as Map,p=r['payoutRequest'],c=p['authorization']['bundle']['contract'];
  final store=MemoryProductionStore(),mediator=ProductionIdentitySession(store,role:'market',origin:fixture['envelope']['origin']);
  Map sign(ProductionIdentitySession s,{bool confirm=true})=>s.signResolution(jsonEncode(r),expectedDecisionHash:r['decisionHash'],expectedContractHash:c['contractHash'],expectedFundingTermsHash:p['authorization']['terms']['fundingTermsHash'],confirmDecision:confirm,now:requests['now']);
  expect(()=>sign(mediator),throwsA(anything));await mediator.open();await mediator.restoreEmpty(jsonEncode(fixture['envelope']),fixture['passphrase']);expect(()=>sign(mediator,confirm:false),throwsA(anything));
  final proof=sign(mediator);expect(proof['schema'],'xbt-production-resolution-proof-v1');File('test-results/dart-production-resolution-session-proof.json').writeAsStringSync(jsonEncode(proof));
  mediator.lock();expect(()=>sign(mediator),throwsA(anything));await mediator.unlock(fixture['passphrase']);expect(sign(mediator)['schema'],'xbt-production-resolution-proof-v1');
  final buyer=session(MemoryProductionStore());await buyer.open();await buyer.restoreEmpty(encoded,password);expect(()=>sign(buyer),throwsA(anything));
 });


 test('missing, forged, mismatched or corrupted recovery receipts never enable approval',() async {
  final store=MemoryProductionStore(),s=session(store);store.values[s.namespace]=encoded;await s.open();
  await s.unlock(password);expect(s.recoveryVerified,false);expect(()=>s.enrollment(),throwsA(anything));
  await s.verifyRecovery(encoded,password);
  final name='${s.namespace}_recovery_check_v1',valid=store.values[name]!;
  final receipt=jsonDecode(valid) as Map;
  for(final bad in ['{}','corrupt',jsonEncode({...receipt,'signature':'AA=='}),jsonEncode({...receipt,'body':{...receipt['body'] as Map,'backupHash':'a'*64}})]){
   store.values[name]=bad;await s.unlock(password);expect(s.recoveryVerified,false);expect(()=>s.enrollment(),throwsA(anything));
  }
  store.values[name]=valid;final reopened=session(store);await reopened.open();expect(reopened.publicKey,isNull);await reopened.unlock(password);expect(reopened.recoveryVerified,true);
  // Same key resealed as a different encrypted backup still requires a new check.
  store.values[s.namespace]=ProductionIdentity.restore(encoded,password,'buyer',origin).backup(password);
  await reopened.unlock(password);expect(reopened.recoveryVerified,false);
 });
 test('failed receipt persistence cannot grant recovery authority',() async {
  final store=MemoryProductionStore(),s=session(store);store.values[s.namespace]=encoded;await s.open();store.dropWrite=true;
  await expectLater(s.verifyRecovery(encoded,password),throwsA(anything));expect(s.recoveryVerified,false);expect(s.publicKey,isNull);
 });
}
