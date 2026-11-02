import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:xbt_escrow_rehearsal/production_identity.dart';

class BrokenStore implements ProductionKeyStore {
  bool failRead=false,failWrite=false;
  @override Future<String?> read(String namespace) async {if(failRead)throw StateError('PRIVATE backend detail');return null;}
  @override Future<void> write(String namespace,String backup) async {if(failWrite)throw StateError('PRIVATE backend detail');}
}
void main(){
  final fixture=jsonDecode(File('test-fixtures/production-recovery.json').readAsStringSync()) as Map;
  final backup=jsonEncode(fixture['envelope']),password=fixture['passphrase'] as String,origin=fixture['envelope']['origin'] as String;
  Matcher problem(IdentityProblem p)=>isA<IdentityFailure>().having((e)=>e.problem,'safe category',p);
  test('recovery diagnostics distinguish missing input, role, origin and malformed data',(){
    void check(String b,String p,{String role='buyer',String? site})=>ProductionIdentity.checkRecovery(b,p,role,site??origin);
    expect(()=>check(backup,''),throwsA(problem(IdentityProblem.passphrase)));
    expect(()=>check('',password),throwsA(problem(IdentityProblem.backup)));
    expect(()=>check('{truncated',password),throwsA(problem(IdentityProblem.backup)));
    expect(()=>check(backup,password,role:'seller'),throwsA(problem(IdentityProblem.role)));
    expect(()=>check(backup,password,site:'https://other.example.test'),throwsA(problem(IdentityProblem.origin)));
    final changed=jsonDecode(backup) as Map;changed['sealed']='AA==';
    expect(()=>check(jsonEncode(changed),password),throwsA(problem(IdentityProblem.format)));
    expect(()=>check(backup,password),returnsNormally);
  });
  test('decryption diagnostic does not claim that the password alone is wrong',(){
    expect(()=>ProductionIdentity.restore(backup,'wrong synthetic passphrase','buyer',origin),throwsA(problem(IdentityProblem.decrypt)));
    expect(IdentityProblem.decrypt.message,contains('damaged'));
  });
  test('storage diagnostics survive session wrapping and contain no backend detail',() async {
    final store=BrokenStore(),session=ProductionIdentitySession(store,role:'buyer',origin:origin);
    store.failRead=true;await expectLater(session.open(),throwsA(problem(IdentityProblem.read)));
    store.failRead=false;await session.open();store.failWrite=true;
    await expectLater(session.restoreEmpty(backup,password),throwsA(problem(IdentityProblem.write)));
    expect(session.recoveryVerified,isFalse);expect(session.publicKey,isNull);
    store.failWrite=false;
    await expectLater(session.restoreEmpty(backup,password),throwsA(problem(IdentityProblem.verifyWrite)));
    expect(session.recoveryVerified,isFalse);expect(session.publicKey,isNull);
    for(final p in IdentityProblem.values){expect(p.message, isNot(contains('PRIVATE')));expect(IdentityFailure(p).toString(),isNot(contains(password)));}
  });
}
