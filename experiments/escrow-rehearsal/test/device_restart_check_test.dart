import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:xbt_escrow_rehearsal/device_restart_check.dart';
import 'device_selftest_test.dart' show SelfTestStore;
class RestartMemoryRecords implements RestartRecordStore {
 String? value;
 @override Future<String?> read() async=>value;
 @override Future<void> write(String record) async{value=record;}
}
void main(){
 test('restart verification requires a newer boot count and existing random identity',() async {
  final keys=SelfTestStore(),records=RestartMemoryRecords();int? boot=4;
  final first=DeviceRestartCheck(keys,records,() async=>boot);
  final before=await first.prepare();expect(before['persistenceVerified'],isFalse);
  expect(jsonEncode(before),isNot(contains('passphrase')));expect(jsonEncode(before),isNot(contains('backup')));
  await expectLater(first.verify(),throwsA(isA<RestartFailure>().having((e)=>e.code,'code','phone-restart-required')));
  boot=5;final next=DeviceRestartCheck(keys,records,() async=>boot);final result=await next.verify();
  expect(result['publicKeyAfter'],before['publicKeyBefore']);expect(result['identityRecreated'],isFalse);expect(result['persistenceVerified'],isTrue);
  // Clearing only the identity, while retaining the prepared record, MUST fail.
  keys.records.clear();await expectLater(next.verify(),throwsA(isA<RestartFailure>().having((e)=>e.code,'code','saved-identity-missing')));
  expect(keys.records,isEmpty);expect((await next.prepare())['runId'],before['runId']);expect(keys.records,isEmpty);
 },timeout:const Timeout(Duration(minutes:2)));
 test('missing record or boot counter cannot be reported as a restart pass',() async {
  final keys=SelfTestStore(),records=RestartMemoryRecords(),check=DeviceRestartCheck(keys,records,() async=>null);
  await expectLater(check.verify(),throwsA(isA<RestartFailure>()));await expectLater(check.prepare(),throwsA(isA<RestartFailure>()));expect(keys.records,isEmpty);
 });
}
