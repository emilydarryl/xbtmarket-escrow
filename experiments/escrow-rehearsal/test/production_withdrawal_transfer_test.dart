import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:xbt_escrow_rehearsal/production_transfer.dart';
import 'package:xbt_escrow_rehearsal/production_contract.dart';
import 'package:xbt_escrow_rehearsal/production_identity.dart';
import 'production_app_test.dart' show EmptyStore;
class RecipientSession extends ProductionIdentitySession {
 RecipientSession(String role,this.key,String origin):super(EmptyStore(),role:role,origin:origin);
 final String key;
 @override String? get publicKey=>key;
 @override bool get recoveryVerified=>true;
}
void main(){
 final fixture=jsonDecode(File('test-fixtures/production-withdrawal-transfer.json').readAsStringSync()) as Map;
 test('guided withdrawal verifies every recipient including a non-cosigning reserve recipient',(){
  for(final entry in fixture['cases']){
   final r=entry['request'] as Map,c=r['payoutRequest']['authorization']['bundle']['contract'] as Map,role=entry['role'] as String;
   final session=RecipientSession(role,c['keys'][role],c['origin']);
   Map envelope()=>{'schema':'xbt-signer-transfer-v1','origin':session.origin,'role':role,'request':jsonDecode(jsonEncode(r))};
   ProductionTransfer parse(Map e)=>ProductionTransfer.parse(jsonEncode(e),session,c['keys']['market'],0);
   final review=parse(envelope());expect(review.kind,'withdrawal');expect(review.orderId,c['preflight']['orderId']);expect(review.action,'Sign withdrawal to my wallet');
   for(final mutate in <void Function(Map)>[(e)=>e['request']['withdrawal']['parentHex']='00',(e)=>e['request']['payoutRequest']['transaction']['outputs'][0]['sats']='1',(e)=>e['request']['secret']='backup',(e)=>e['role']='market',(e)=>e['request']['withdrawal']['destination']='bc1q']){
    final e=envelope();mutate(e);expect(()=>parse(e),throwsA(anything));
   }
   final changed=envelope(),w=changed['request']['withdrawal'] as Map;w['parent']['txid']='a'*64;w.remove('requestHash');w['requestHash']=ProductionContractReview.digest(w);expect(()=>parse(changed),throwsA(anything));
  }
 });
}
