import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:xbt_escrow_rehearsal/device_selftest.dart';
import 'package:xbt_escrow_rehearsal/production_identity.dart';
class SelfTestStore implements ProductionKeyStore {
  final records=<String,String>{};bool fail=false;
  @override Future<String?> read(String namespace) async {if(fail)throw StateError('PRIVATE');return records[namespace];}
  @override Future<void> write(String namespace,String value) async {records[namespace]=value;}
}
void main(){
  final fixtures=jsonDecode(File('assets/device-selftest.json').readAsStringSync()) as Map;
  test('one-tap harness exercises real signing with synthetic identities and emits verifiable proofs',() async {
    final store=SelfTestStore();
    final report=await DeviceSelfTest(store,fixtures,storageKind:'memory-test-storage').run();
    expect(report['passed'],isTrue,reason:jsonEncode(report));expect(report['contractProofs'],hasLength(3));expect(report['fundingProofs'],hasLength(3));expect(report['spendSignatures'],hasLength(9));expect(store.records.keys.where((k)=>k.endsWith('_recovery_check_v1')),hasLength(4));expect(store.records,hasLength(8));
    expect(jsonEncode(report),isNot(contains(fixtures['passphrase'])));expect(report['independentSecurityReview'],isFalse);expect(report['ownerSellerApproval'],isFalse);
    File('test-results/device-selftest-report.json').writeAsStringSync(jsonEncode(report));
  },timeout:const Timeout(Duration(minutes:3)));
  test('storage failure cannot produce a passing self-test or leak backend detail',() async {
    final store=SelfTestStore()..fail=true;final report=await DeviceSelfTest(store,fixtures,storageKind:'memory-test-storage').run();
    expect(report['passed'],isFalse);expect(report['failureCategory'],'read');expect(jsonEncode(report),isNot(contains('PRIVATE')));
  });
  test('interruption cannot be reported as a pass',() async {
    final runner=DeviceSelfTest(SelfTestStore(),fixtures,storageKind:'memory-test-storage')..cancel();
    expect((await runner.run())['passed'],isFalse);
  });
}
