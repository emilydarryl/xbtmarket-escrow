import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:xbt_escrow_rehearsal/production_device_store.dart';
import 'package:xbt_escrow_rehearsal/production_identity.dart';
void main(){
 TestWidgetsFlutterBinding.ensureInitialized();
 test('device storage adapter retains the identity and separate recovery receipt across reopen',()async{
  FlutterSecureStorage.setMockInitialValues({});
  final f=jsonDecode(File('test-fixtures/production-recovery.json').readAsStringSync()) as Map;
  final store=ProductionDeviceStore(),s=ProductionIdentitySession(store,role:'buyer',origin:f['envelope']['origin']);
  await s.open();await s.restoreEmpty(jsonEncode(f['envelope']),f['passphrase']);s.lock();
  final reopened=ProductionIdentitySession(ProductionDeviceStore(),role:'buyer',origin:s.origin);
  await reopened.open();expect(reopened.publicKey,isNull);await reopened.unlock(f['passphrase']);
  expect(reopened.recoveryVerified,true);expect(reopened.publicKey,f['envelope']['publicKey']);
  expect(await reopened.exportBackup(),jsonEncode(f['envelope']));
  for(final name in ['regtest','${s.namespace}_unknown','${s.namespace}_recovery_check_v1_extra']){expect(()=>store.read(name),throwsArgumentError);}
 });
}
