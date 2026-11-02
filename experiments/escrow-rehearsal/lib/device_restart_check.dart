// Two-phase persistence drill for the isolated self-test app. No owner identities.
import 'dart:convert';
import 'dart:math';
import 'production_identity.dart';

abstract class RestartRecordStore {
  Future<String?> read();
  Future<void> write(String record);
}
class RestartFailure implements Exception {
  const RestartFailure(this.code);
  final String code;
}
class DeviceRestartCheck {
  DeviceRestartCheck(this.keys,this.records,this.bootCount);
  final ProductionKeyStore keys;
  final RestartRecordStore records;
  final Future<int?> Function() bootCount;
  String randomHex(int count){final r=Random.secure();return List.generate(count,(_)=>r.nextInt(256).toRadixString(16).padLeft(2,'0')).join();}
  Future<Map?> pending() async {
    final value=await records.read();if(value==null)return null;
    final r=jsonDecode(value) as Map;
    if(r['schema']!='xbt-private-restart-record-v1'||r['bootBefore'] is! int||r['bootBefore']<0||r['runId'] is! String||!RegExp(r'^[a-f0-9]{32}$').hasMatch(r['runId'])||r['origin']!='https://restart-${r['runId']}.example.test')throw const RestartFailure('invalid-saved-record');
    return r;
  }
  Map<String,dynamic> receipt(Map r)=>{'schema':'xbt-device-restart-prepared-v1','syntheticKeysOnly':true,'runId':r['runId'],'publicKeyBefore':r['publicKey'],'bootCountBefore':r['bootBefore'],'persistenceVerified':false};
  Future<Map<String,dynamic>> prepare() async {
    final prior=await pending();if(prior!=null)return receipt(prior);
    final boot=await bootCount();if(boot==null||boot<0)throw const RestartFailure('boot-count-unavailable');
    final id=randomHex(16),password=randomHex(32);
    final site='https://restart-$id.example.test';
    final session=ProductionIdentitySession(keys,role:'buyer',origin:site);
    try{
      await session.open();if(session.hasSavedIdentity)throw const RestartFailure('unexpected-existing-identity');
      final backup=await session.create(password);await session.verifyRecovery(backup,password);
      final record={'schema':'xbt-private-restart-record-v1','runId':id,'origin':site,'bootBefore':boot,'publicKey':session.publicKey,'backup':backup,'passphrase':password};
      final encoded=jsonEncode(record);await records.write(encoded);
      if(await records.read()!=encoded)throw const RestartFailure('record-write-not-verified');
      return receipt(record);
    }finally{session.lock();}
  }
  Future<Map<String,dynamic>> verify() async {
    final r=await pending();if(r==null)throw const RestartFailure('no-prepared-record');
    final boot=await bootCount();if(boot==null||boot<0)throw const RestartFailure('boot-count-unavailable');
    if(boot<=r['bootBefore'])throw const RestartFailure('phone-restart-required');
    final session=ProductionIdentitySession(keys,role:'buyer',origin:r['origin']);
    try{
      await session.open();
      // This branch must NEVER restore or create an absent identity.
      if(!session.hasSavedIdentity)throw const RestartFailure('saved-identity-missing');
      await session.verifyRecovery(r['backup'],r['passphrase']);
      if(session.publicKey!=r['publicKey'])throw const RestartFailure('saved-identity-changed');
      return {'schema':'xbt-device-restart-report-v1','syntheticKeysOnly':true,'runId':r['runId'],'publicKeyBefore':r['publicKey'],'publicKeyAfter':session.publicKey,'bootCountBefore':r['bootBefore'],'bootCountAfter':boot,'existingIdentityRequired':true,'identityRecreated':false,'persistenceVerified':true,'storageKind':'android-secure-storage','evidence':'app-observed boot counter and storage; not hardware attestation','realFundsUsed':false,'independentSecurityReview':false,'ownerSellerApproval':false};
    }finally{session.lock();}
  }
}
