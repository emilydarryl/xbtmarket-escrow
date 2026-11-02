// Test harness only. Compiled into a separate offline APK, never a signer entrypoint.
import 'dart:convert';
import 'production_identity.dart';

class DeviceSelfTest {
  DeviceSelfTest(this.store,this.fixtures,{required this.storageKind,this.onProgress});
  final ProductionKeyStore store;
  final Map fixtures;
  final String storageKind;
  final void Function(String)? onProgress;
  bool cancelled=false;
  final sessions=<ProductionIdentitySession>[];
  void cancel(){cancelled=true;for(final s in sessions){s.lock();}}
  void need(bool value){if(!value)throw StateError('Self-test assertion failed');}
  Future<Map<String,dynamic>> run() async {
    final checks=<Map<String,dynamic>>[],contracts=<Map>[],funding=<Map>[],spends=<Map>[];
    String current='fixture-validation';
    final report=<String,dynamic>{'schema':'xbt-device-selftest-report-v1','syntheticKeysOnly':true,'recoveryCheckPolicy':'local-signed-receipt-v1','storageKind':storageKind,'startedAt':DateTime.now().toUtc().toIso8601String(),'passed':false,'realFundsUsed':false,'independentSecurityReview':false,'ownerSellerApproval':false,'actualBackgroundRestartTested':false,'fixtureClockUsed':true,'checks':checks,'contractProofs':contracts,'fundingProofs':funding,'spendSignatures':spends};
    Future<void> check(String id,Future<void> Function() action) async {
      if(cancelled)throw StateError('Interrupted');current=id;onProgress?.call(id);
      await Future<void>.delayed(const Duration(milliseconds:10));await action();
      if(cancelled)throw StateError('Interrupted');checks.add({'id':id,'passed':true});
    }
    Future<void> reject(String id,Future<void> Function() action) async {
      await check(id,() async {bool rejected=false;try{await action();}catch(_){rejected=true;}need(rejected);});
    }
    try{
      need(fixtures['schema']=='xbt-device-selftest-fixtures-v1'&&fixtures['syntheticKeysOnly']==true);
      final password=fixtures['passphrase'] as String;
      for(final role in ['buyer','seller','market']){
        final envelope=fixtures['recovery'][role] as Map,backup=jsonEncode(envelope);
        final s=ProductionIdentitySession(store,role:role,origin:envelope['origin']);sessions.add(s);
        await check('$role.storage-open',() async {await s.open();});
        await check('$role.restore',() async {if(s.hasSavedIdentity){await s.verifyRecovery(backup,password);}else{await s.restoreEmpty(backup,password);}need(s.recoveryVerified&&s.publicKey==envelope['publicKey']);});
        await reject('$role.no-overwrite',() async {await s.create(password);});
        await reject('$role.wrong-password',() async {await s.unlock('wrong public synthetic passphrase');});
        await check('$role.failed-unlock-locked',() async {need(!s.recoveryVerified&&s.publicKey==null);});
        await reject('$role.wrong-role-backup',() async {await s.verifyRecovery(jsonEncode(fixtures['recovery'][role=='buyer'?'seller':'buyer']),password);});
        await check('$role.recovery-after-rejection',() async {await s.verifyRecovery(backup,password);need(s.publicKey==envelope['publicKey']);});
        final entry=(fixtures['contract']['entries'] as List).firstWhere((e)=>e['role']==role),request=jsonEncode(entry['request']),c=entry['request']['contract'];
        final now=fixtures['contract']['now'] as int;
        Map<String,dynamic> sign({String? hash,int? at,bool confirm=true})=>s.signReview(request,expectedContractHash:hash??c['contractHash'],expectedMediatorPublicKey:c['keys']['market'],confirmReview:confirm,now:at??now);
        await reject('$role.wrong-hash',() async {sign(hash:'0'*64);});
        await reject('$role.expired-request',() async {sign(at:entry['request']['challenge']['expiresAt']);});
        await reject('$role.unconfirmed-contract',() async {sign(confirm:false);});
        await check('$role.contract-sign',() async {contracts.add(sign());});
        await check('$role.lock',() async {s.lock();need(!s.recoveryVerified&&s.publicKey==null);});
        await reject('$role.locked-sign',() async {sign();});
        await check('$role.unlock-remembers-verified-recovery',() async {await s.unlock(password);need(s.recoveryVerified);});
        await reject('$role.unlocked-still-needs-consent',() async {sign(confirm:false);});
        await check('$role.reopen-storage',() async {await s.open();need(s.hasSavedIdentity&&!s.recoveryVerified);await s.verifyRecovery(backup,password);need(s.enrollment()['publicKey']==envelope['publicKey']);});
        final fe=(fixtures['funding']['entries'] as List).firstWhere((e)=>e['role']==role),fr=fe['request'],fc=fr['bundle']['contract'];
        Map<String,dynamic> signFunding(bool confirm)=>s.signFunding(jsonEncode(fr),expectedContractHash:fc['contractHash'],expectedFundingTermsHash:fr['terms']['fundingTermsHash'],expectedMediatorPublicKey:fc['keys']['market'],confirmDeposit:confirm,now:fixtures['funding']['now']);
        await reject('$role.unconfirmed-funding',() async {signFunding(false);});
        await check('$role.funding-sign',() async {funding.add(signFunding(true));});
        for(var i=0;i<(fixtures['spend']['cases'] as List).length;i++){
          final r=fixtures['spend']['cases'][i]['request'] as Map,sc=r['authorization']['bundle']['contract'],d=r['decision'];
          final allowed=d['disputed']?{'release':['seller','market'],'refund':['buyer','market'],'split-refund':['buyer','seller','market']}[d['scenario']]!:['buyer','seller'];
          Map<String,dynamic> signSpend(Map input,{bool confirm=true})=>s.signSpend(jsonEncode(input),expectedRequestHash:r['requestHash'],expectedContractHash:sc['contractHash'],expectedFundingTermsHash:r['authorization']['terms']['fundingTermsHash'],expectedMediatorPublicKey:sc['keys']['market'],confirmPayout:confirm);
          if(!allowed.contains(role)){await reject('$role.payout-$i-ineligible',() async {signSpend(r);});continue;}
          await reject('$role.payout-$i-unconfirmed',() async {signSpend(r,confirm:false);});
          final altered=jsonDecode(jsonEncode(r)) as Map;altered['transaction']['outputs'][0]['sats']='1';
          await reject('$role.payout-$i-altered',() async {signSpend(altered);});
          await check('$role.payout-$i-sign',() async {spends.add(signSpend(r));});
        }
      }
      final created=ProductionIdentitySession(store,role:'buyer',origin:'https://selftest-create.example.test');sessions.add(created);
      await check('fresh-key.encrypted-storage-roundtrip',() async {
        await created.open();String backup;
        if(created.hasSavedIdentity){await created.unlock(password);backup=await created.exportBackup();}else{backup=await created.create(password);}
        need(!backup.contains(password));await created.verifyRecovery(backup,password);final publicKey=created.publicKey;
        await created.open();need(!created.recoveryVerified);await created.verifyRecovery(backup,password);need(created.publicKey==publicKey);
      });
      report['passed']=true;
    }catch(error){report['failedCheck']=current;report['failureCategory']=cancelled?'interrupted':error is IdentityFailure?error.problem.name:'assertion-or-runtime';}
    finally{for(final s in sessions){s.lock();}report['completedAt']=DateTime.now().toUtc().toIso8601String();}
    return report;
  }
}
