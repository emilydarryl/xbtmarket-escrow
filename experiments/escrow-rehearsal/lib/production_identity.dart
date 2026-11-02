import 'production_resolution.dart';
// Candidate production identity lifecycle. No imports from the regtest key store.
import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'package:bitcoin_base/bitcoin_base.dart';
import 'package:blockchain_utils/blockchain_utils.dart';
import 'production_contract.dart';
import 'production_funding.dart';
import 'production_spend.dart';
import 'production_withdrawal.dart';

abstract class ProductionKeyStore {
  Future<String?> read(String namespace);
  Future<void> write(String namespace,String record);
}

// Only fixed, non-secret messages may cross the UI error boundary.
enum IdentityProblem {
  passphrase('Enter the original backup passphrase (16–1024 UTF-8 bytes). Switching apps clears this field.'),
  backup('Paste the complete encrypted recovery JSON from your saved backup.'),
  role('This backup belongs to a different role. Use the matching buyer or seller TEST app.'),
  origin('This backup belongs to a different site configuration. Keep it; do not edit its contents.'),
  format('The backup format or contents are not valid for this app. Keep the original saved copy.'),
  decrypt('The backup could not be decrypted. The passphrase may differ or the backup may be damaged. Neither was changed.'),
  read('Secure storage could not be read. Keep the app installed and preserve your backup.'),
  write('Secure storage could not save the identity. Keep your backup and reopen the app before retrying.'),
  verifyWrite('The saved identity could not be read back. Keep your backup and reopen the app; do not create another identity.');
  const IdentityProblem(this.message);
  final String message;
}
class IdentityFailure implements Exception {
  const IdentityFailure(this.problem);
  final IdentityProblem problem;
  @override String toString()=>'Identity check: ${problem.name}';
}

class ProductionIdentity {
  ProductionIdentity._(this._key,this.role,this.origin);
  final ECPrivate _key;
  final String role,origin;
  String get publicKey=>_key.getPublic().toHex();
  static void _need(bool v){if(!v)throw const FormatException('Production recovery data is invalid or does not match.');}
  static void _context(String role,String origin){_need(['buyer','seller','market'].contains(role));ProductionContractReview.origin(origin);}
  static List<int> _random(int n){final r=Random.secure();return List.generate(n,(_)=>r.nextInt(256));}
  static List<int> _decode(dynamic value,int size){_need(value is String);final bytes=base64Decode(value as String);_need(bytes.length==size&&base64Encode(bytes)==value);return bytes;}
  static List<int> _password(String value){final bytes=utf8.encode(value);if(bytes.length<16||bytes.length>1024)throw const IdentityFailure(IdentityProblem.passphrase);return bytes;}
  static void checkRecovery(String encoded,String passphrase,String role,String origin){
    final password=_password(passphrase);password.fillRange(0,password.length,0);
    if(encoded.trim().isEmpty||encoded.length>4096)throw const IdentityFailure(IdentityProblem.backup);
    dynamic envelope;
    try{envelope=jsonDecode(encoded);}catch(_){throw const IdentityFailure(IdentityProblem.backup);}
    if(envelope is! Map||envelope['schema']!='xbt-production-recovery-v1')throw const IdentityFailure(IdentityProblem.format);
    if(envelope['role']!=role)throw const IdentityFailure(IdentityProblem.role);
    if(envelope['origin']!=origin)throw const IdentityFailure(IdentityProblem.origin);
    try{inspect(encoded,role,origin);}catch(_){throw const IdentityFailure(IdentityProblem.format);}
  }
  static ProductionIdentity generate(String role,String origin){
    _context(role,origin);
    while(true){final bytes=_random(32);try{return ProductionIdentity._(ECPrivate.fromBytes(bytes),role,origin);}catch(_){/* retry invalid scalar */}finally{bytes.fillRange(0,bytes.length,0);}}
  }
  static Map<String,dynamic> inspect(String encoded,String role,String origin){
    _context(role,origin);_need(encoded.length<=4096);
    final e=Map<String,dynamic>.from(jsonDecode(encoded) as Map);
    ProductionContractReview.exact(e,{'schema','purpose','chainProfile','role','origin','publicKey','kdf','cipher','nonce','sealed'});
    _need(e['schema']=='xbt-production-recovery-v1'&&e['purpose']=='production-escrow-identity'&&e['role']==role&&e['origin']==origin&&ProductionContractReview.digest(e['chainProfile'])==ProductionContractReview.digest(ProductionContractReview.chain));
    _need(e['publicKey'] is String&&RegExp(r'^0[23][a-f0-9]{64}$').hasMatch(e['publicKey']));ECPublic.fromHex(e['publicKey'] as String);
    final k=Map<String,dynamic>.from(e['kdf'] as Map);ProductionContractReview.exact(k,{'name','n','r','p','salt'});
    _need(k['name']=='scrypt'&&k['n']==32768&&k['r']==8&&k['p']==1&&e['cipher']=='aes-256-gcm');
    _decode(k['salt'],16);_decode(e['nonce'],12);_decode(e['sealed'],48);return e;
  }
  String backup(String passphrase){
    final salt=_random(16),nonce=_random(12),password=_password(passphrase);
    final envelope=<String,dynamic>{'schema':'xbt-production-recovery-v1','purpose':'production-escrow-identity','chainProfile':ProductionContractReview.chain,'role':role,'origin':origin,'publicKey':publicKey,'kdf':{'name':'scrypt','n':32768,'r':8,'p':1,'salt':base64Encode(salt)},'cipher':'aes-256-gcm','nonce':base64Encode(nonce)};
    final derived=Scrypt.deriveKey(password,salt,n:32768,r:8,p:1,dkLen:32),plain=BytesUtils.fromHexString(_key.toHex());
    try{envelope['sealed']=base64Encode(GCM(AES(derived)).encrypt(nonce,plain,associatedData:utf8.encode(jsonEncode(_sorted(envelope)))));return jsonEncode(envelope);}
    finally{derived.fillRange(0,derived.length,0);plain.fillRange(0,plain.length,0);password.fillRange(0,password.length,0);}
  }
  static dynamic _sorted(dynamic v){if(v is Map){final keys=v.keys.cast<String>().toList()..sort();return {for(final k in keys)k:_sorted(v[k])};}if(v is List)return v.map(_sorted).toList();return v;}
  static ProductionIdentity restore(String encoded,String passphrase,String role,String origin){
    checkRecovery(encoded,passphrase,role,origin);
    try{
      final e=inspect(encoded,role,origin),k=e['kdf'] as Map,password=_password(passphrase),derived=Scrypt.deriveKey(password,_decode(k['salt'],16),n:32768,r:8,p:1,dkLen:32);
      List<int>? plain;
      try{
        final aad={...e}..remove('sealed');plain=GCM(AES(derived)).decrypt(_decode(e['nonce'],12),_decode(e['sealed'],48),associatedData:utf8.encode(jsonEncode(_sorted(aad))));
        _need(plain!=null&&plain.length==32);final identity=ProductionIdentity._(ECPrivate.fromBytes(plain!),role,origin);_need(identity.publicKey==e['publicKey']);return identity;
      }finally{derived.fillRange(0,derived.length,0);password.fillRange(0,password.length,0);plain?.fillRange(0,plain.length,0);}
    }catch(_){throw const IdentityFailure(IdentityProblem.decrypt);}
  }
}

class ProductionIdentitySession {
  ProductionIdentitySession(this.store,{required this.role,required this.origin}){ProductionIdentity._context(role,origin);}
  final ProductionKeyStore store;
  final String role,origin;
  ProductionIdentity? _identity;
  bool _opened=false,_hasSaved=false,_recoveryVerified=false;
  int _epoch=0;
  static final Map<String,Future<void>> _locks={};
  String get namespace=>'xbt_production_identity_v1_${ProductionContractReview.digest({'role':role,'origin':origin,'chain':ProductionContractReview.chain})}';
  String? get publicKey=>_identity?.publicKey;
  bool get hasSavedIdentity=>_hasSaved;
  bool get recoveryVerified=>_identity!=null&&_recoveryVerified;
  void lock(){_epoch++;_identity=null;_recoveryVerified=false;}
  Future<T> _exclusive<T>(Future<T> Function() action) async {
    final name=namespace,prior=_locks[name]??Future<void>.value(),done=Completer<void>();_locks[name]=done.future;
    await prior;try{return await action();}finally{done.complete();if(identical(_locks[name],done.future))_locks.remove(name);}
  }
  Future<String?> _read() async {try{return await store.read(namespace);}catch(_){throw const IdentityFailure(IdentityProblem.read);}}
  Future<void> _write(String backup) async {try{await store.write(namespace,backup);}catch(_){throw const IdentityFailure(IdentityProblem.write);}}
  void _current(int epoch){if(epoch!=_epoch)throw StateError('Identity operation cancelled by locking.');}
  String get _recoveryNamespace=>'${namespace}_recovery_check_v1';
  Map<String,dynamic> _recoveryBody(String saved,ProductionIdentity identity)=>{
    'schema':'xbt-local-recovery-check-v1','purpose':'remember-local-backup-check-not-payment',
    'namespace':namespace,'publicKey':identity.publicKey,'backupHash':ProductionContractReview.digest(jsonDecode(saved))
  };
  // A local, key-signed receipt remembers a successful separate-backup check.
  // It is never exported and cannot unlock the encrypted identity by itself.
  Future<void> _rememberRecovery(String saved,ProductionIdentity identity,int epoch) async {
    final body=_recoveryBody(saved,identity),digest=BytesUtils.fromHexString(ProductionContractReview.digest(body));
    final encoded=BytesUtils.fromHexString(identity._key.signECDSA(digest,sighash:1));
    final receipt=jsonEncode({'body':body,'signature':base64Encode(encoded.sublist(0,encoded.length-1))});
    _current(epoch);
    try{await store.write(_recoveryNamespace,receipt);if(await store.read(_recoveryNamespace)!=receipt)throw const IdentityFailure(IdentityProblem.verifyWrite);}
    on IdentityFailure {rethrow;}
    catch(_){throw const IdentityFailure(IdentityProblem.write);}
    _current(epoch);
  }
  Future<bool> _rememberedRecovery(String saved,ProductionIdentity identity) async {
    String? value;try{value=await store.read(_recoveryNamespace);}catch(_){throw const IdentityFailure(IdentityProblem.read);}
    if(value==null)return false;
    try{
      if(value.length>2048)return false;
      final receipt=Map<String,dynamic>.from(jsonDecode(value) as Map);
      ProductionContractReview.exact(receipt,{'body','signature'});
      final body=_recoveryBody(saved,identity);
      if(ProductionContractReview.digest(receipt['body'])!=ProductionContractReview.digest(body))return false;
      return BitcoinSignatureVerifier.fromKeyBytes(BytesUtils.fromHexString(identity.publicKey)).verifyECDSADerSignature(
        digest:BytesUtils.fromHexString(ProductionContractReview.digest(body)),signature:base64Decode(receipt['signature'] as String));
    }catch(_){return false;}
  }
  Future<void> open() async {
    lock();_opened=false;_hasSaved=false;final epoch=_epoch;
    try{final record=await _read();_current(epoch);if(record!=null)ProductionIdentity.inspect(record,role,origin);_hasSaved=record!=null;_opened=true;}
    on IdentityFailure {rethrow;}
    catch(_){throw StateError('Production identity storage could not be opened. No key was created or replaced.');}
  }
  Future<String> create(String passphrase) {
    final epoch=_epoch;
    return _exclusive(() async {
      if(!_opened||_hasSaved||_identity!=null)throw StateError('Open empty production storage before explicitly creating an identity.');_current(epoch);
      if(await _read()!=null)throw StateError('A production identity already exists.');_current(epoch);
      final r=role,o=origin;
      final backup=await Isolate.run(()=>ProductionIdentity.generate(r,o).backup(passphrase));_current(epoch);
      await _write(backup);_hasSaved=true;
      if(await _read()!=backup)throw const IdentityFailure(IdentityProblem.verifyWrite);_current(epoch);
      // Keep the newly created key locked until the separate backup is restored.
      return backup;
    });
  }
  Future<void> unlock(String passphrase) {
    lock();final epoch=_epoch;
    return _exclusive(() async {
      if(!_opened)throw StateError('Open production storage first.');_current(epoch);
      final saved=await _read();if(saved==null)throw StateError('No production identity found.');_current(epoch);
      final r=role,o=origin;final identity=await Isolate.run(()=>ProductionIdentity.restore(saved,passphrase,r,o));_current(epoch);
      if(await _read()!=saved)throw StateError('Stored identity changed during unlock.');_current(epoch);
      final remembered=await _rememberedRecovery(saved,identity);_current(epoch);
      if(await _read()!=saved)throw StateError('Stored identity changed during unlock.');_current(epoch);
      _identity=identity;_hasSaved=true;_recoveryVerified=remembered;
    });
  }
  Future<void> verifyRecovery(String backup,String passphrase) {
    lock();final epoch=_epoch;
    return _exclusive(() async {
      if(!_opened)throw StateError('Open production storage first.');_current(epoch);
      final saved=await _read();if(saved==null)throw StateError('Restore into empty storage explicitly first.');
      final r=role,o=origin;final identities=await Isolate.run(()=>[ProductionIdentity.restore(saved,passphrase,r,o),ProductionIdentity.restore(backup,passphrase,r,o)]);_current(epoch);
      if(identities[0].publicKey!=identities[1].publicKey||await _read()!=saved)throw StateError('Recovery does not match the saved production identity.');_current(epoch);
      await _rememberRecovery(saved,identities[0],epoch);
      if(await _read()!=saved)throw StateError('Stored identity changed during recovery.');_current(epoch);
      _identity=identities[0];_hasSaved=true;_recoveryVerified=true;
    });
  }
  Future<void> restoreEmpty(String backup,String passphrase) {
    final epoch=_epoch;
    return _exclusive(() async {
      if(!_opened||_hasSaved)throw StateError('Recovery import requires explicitly opened empty storage.');_current(epoch);
      if(await _read()!=null)throw StateError('Recovery never overwrites an existing identity.');
      final r=role,o=origin;final identity=await Isolate.run(()=>ProductionIdentity.restore(backup,passphrase,r,o));_current(epoch);
      await _write(backup);_hasSaved=true;
      if(await _read()!=backup)throw const IdentityFailure(IdentityProblem.verifyWrite);_current(epoch);
      await _rememberRecovery(backup,identity,epoch);
      if(await _read()!=backup)throw StateError('Stored identity changed during recovery.');_current(epoch);
      _identity=identity;_recoveryVerified=true;
    });
  }
  Future<String> exportBackup() async {
    final epoch=_epoch,identity=_identity;if(identity==null)throw StateError('Unlock before exporting the encrypted backup.');
    final saved=await _read();_current(epoch);
    if(saved==null||ProductionIdentity.inspect(saved,role,origin)['publicKey']!=identity.publicKey)throw StateError('Stored identity changed.');return saved;
  }
  Map<String,dynamic> enrollment(){
    if(!recoveryVerified)throw StateError('Verify production recovery before exporting enrollment.');
    return {'schema':'xbt-production-enrollment-v1','chainProfile':ProductionContractReview.chain,'origin':origin,'role':role,'publicKey':publicKey,'recoveryVerifiedLocally':true};
  }
  Map<String,dynamic> signReview(String request,{required String expectedContractHash,required String expectedMediatorPublicKey,required bool confirmReview,required int now}){
    if(!recoveryVerified)throw StateError('Verify production recovery before signing.');
    final review=ProductionContractReview.parse(request,expectedContractHash:expectedContractHash,expectedOrigin:origin,ownPublicKey:publicKey!,expectedMediatorPublicKey:expectedMediatorPublicKey,role:role,now:now);
    return review.sign(_identity!._key,confirmReview:confirmReview,productionRecoveryVerified:true,now:now);
  }
  Map<String,dynamic> signFunding(String request,{required String expectedContractHash,required String expectedFundingTermsHash,required String expectedMediatorPublicKey,required bool confirmDeposit,required int now}){
    if(!recoveryVerified)throw StateError('Verify production recovery before funding consent.');
    final review=ProductionFundingReview.parse(request,expectedContractHash:expectedContractHash,expectedFundingTermsHash:expectedFundingTermsHash,expectedOrigin:origin,ownPublicKey:publicKey!,expectedMediatorPublicKey:expectedMediatorPublicKey,role:role,now:now);
    return review.sign(_identity!._key,confirmDeposit:confirmDeposit,productionRecoveryVerified:true,now:now);
  }
  Map<String,dynamic> signResolution(String request,{required String expectedDecisionHash,required String expectedContractHash,required String expectedFundingTermsHash,required bool confirmDecision,required int now}){
    if(!recoveryVerified||role!='market')throw StateError('Verified mediator recovery required.');
    final review=ProductionResolutionReview.parse(request,expectedDecisionHash:expectedDecisionHash,expectedContractHash:expectedContractHash,expectedFundingTermsHash:expectedFundingTermsHash,expectedOrigin:origin,ownPublicKey:publicKey!,now:now);
    return review.sign(_identity!._key,recoveryVerified:true,confirmDecision:confirmDecision,now:now);
  }
  Map<String,dynamic> signSpend(String request,{required String expectedRequestHash,required String expectedContractHash,required String expectedFundingTermsHash,required String expectedMediatorPublicKey,required bool confirmPayout}){
    if(!recoveryVerified)throw StateError('Verify production recovery before payout signing.');
    final review=ProductionSpendReview.parse(request,expectedRequestHash:expectedRequestHash,expectedContractHash:expectedContractHash,expectedFundingTermsHash:expectedFundingTermsHash,expectedOrigin:origin,ownPublicKey:publicKey!,expectedMediatorPublicKey:expectedMediatorPublicKey,role:role);
    return review.sign(_identity!._key,recoveryVerified:recoveryVerified,confirmPayout:confirmPayout);
  }
  Map<String,dynamic> signWithdrawal(String request,{required String expectedRequestHash,required String expectedDestination,required String maximumFeeSats,required bool confirmWithdrawal}){
    if(!recoveryVerified)throw StateError('Verify production recovery before withdrawal.');
    final review=ProductionWithdrawalReview.parse(request,expectedRequestHash:expectedRequestHash,expectedDestination:expectedDestination,maximumFeeSats:maximumFeeSats,expectedOrigin:origin,role:role,ownPublicKey:publicKey!);
    return review.sign(_identity!._key,recoveryVerified:recoveryVerified,confirmWithdrawal:confirmWithdrawal);
  }
}
