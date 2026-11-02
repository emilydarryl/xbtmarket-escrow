import 'dart:convert';
import 'dart:io';
import 'package:bitcoin_base/bitcoin_base.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xbt_escrow_rehearsal/production_contract.dart';

void main(){
 final fixture=jsonDecode(File('test-fixtures/production-contract.json').readAsStringSync()) as Map,entries=fixture['entries'] as List,now=fixture['now'] as int;
 ECPrivate key(Map e)=>ECPrivate.fromHex((e['scalar'] as int).toRadixString(16).padLeft(64,'0'));
 ProductionContractReview parse(Map e,{String? hash,String? origin,String? mediator,String? role,int? at})=>ProductionContractReview.parse(jsonEncode(e['request']),expectedContractHash:hash??e['request']['contract']['contractHash'],expectedOrigin:origin??fixture['origin'],ownPublicKey:key(e).getPublic().toHex(),expectedMediatorPublicKey:mediator??e['request']['contract']['keys']['market'],role:role??e['role'],now:at??now);
 test('independent production contract parser matches Node digest and signs all three roles',(){
  final proofs=<Map<String,dynamic>>[];
  for(final entry in entries){final e=entry as Map,r=parse(e);expect(r.messageHash,e['messageHash']);proofs.add(r.sign(key(e),confirmReview:true,productionRecoveryVerified:true,now:now+1));}
  Directory('test-results').createSync(recursive:true);File('test-results/dart-production-contract-proofs.json').writeAsStringSync(jsonEncode(proofs));
 });
 test('production review rejects mismatched independent pins and expired challenges',(){
  final e=entries.first as Map;
  for(final action in [()=>parse(e,hash:'0'*64),()=>parse(e,origin:'http://127.0.0.1:4368'),()=>parse(e,origin:'https://other.example.test'),()=>parse(e,mediator:key(e).getPublic().toHex()),()=>parse(e,role:'seller'),()=>parse(e,at:now-1),()=>parse(e,at:now+900000)]){expect(action,throwsA(anything));}
 });
 test('rehashed protocol tampering still fails independent semantic checks',(){
  final changes=<void Function(Map)>[(c)=>c['chainProfile']['network']='regtest',(c)=>c['fundingEnabled']=true,(c)=>c['totalDepositSats']='1',(c)=>c['scriptPubKey']='0020${'0'*64}',(c)=>c['payoutScripts']['buyer']=c['payoutScripts']['seller'],(c)=>c['feePolicy']['replacement']='automatic',(c)=>c['keys']['seller']=c['keys']['buyer'],(c)=>c['extra']=true];
  for(final change in changes){final e=jsonDecode(jsonEncode(entries.first)) as Map,c=e['request']['contract'] as Map;change(c);c.remove('contractHash');c['contractHash']=ProductionContractReview.digest(c);e['request']['challenge']['contractHash']=c['contractHash'];expect(()=>parse(e),throwsA(anything));}
 });
 test('production message signing requires confirmation, recovery and matching key',(){
  final e=entries.first as Map,r=parse(e);
  expect(()=>r.sign(key(e),confirmReview:false,productionRecoveryVerified:true,now:now),throwsA(anything));
  expect(()=>r.sign(key(e),confirmReview:true,productionRecoveryVerified:false,now:now),throwsA(anything));
  expect(()=>r.sign(key(entries[1] as Map),confirmReview:true,productionRecoveryVerified:true,now:now),throwsA(anything));
  expect(()=>r.sign(key(e),confirmReview:true,productionRecoveryVerified:true,now:now+900000),throwsA(anything));
 });
}
