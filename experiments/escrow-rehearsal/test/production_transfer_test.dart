import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:xbt_escrow_rehearsal/production_transfer.dart';
import 'production_app_test.dart' show UiSession;
void main(){
 final f=jsonDecode(File('test-fixtures/production-spend.json').readAsStringSync()) as Map;
 final request=f['cases'][0]['request'] as Map,c=request['authorization']['bundle']['contract'] as Map;
 final session=UiSession(c['keys']['buyer'])..verified=true;
 Map<String,dynamic> envelope()=>{'schema':'xbt-signer-transfer-v1','origin':session.origin,'role':'buyer','request':jsonDecode(jsonEncode(request))};
 ProductionTransfer parse(Map value)=>ProductionTransfer.parse(jsonEncode(value),session,c['keys']['market'],DateTime.now().millisecondsSinceEpoch);
 test('import validates the full signed payout and binds a stable comparison code',(){
   final e=envelope(),review=parse(e);expect(review.kind,'spend');expect(review.orderId,c['preflight']['orderId']);expect(review.code, matches(RegExp(r'^[a-f0-9]{4}( [a-f0-9]{4}){3}$')));
   expect(parse(Map.fromEntries(e.entries.toList().reversed)).code,review.code);
 });
 test('rejects swapped role, origin, extra fields, corrupted outputs and recovery files',(){
   for(final mutate in <void Function(Map)>[(e)=>e['role']='seller',(e)=>e['origin']='https://evil.test',(e)=>e['backup']='private',(e)=>e['request']['transaction']['outputs'][0]['sats']='1',(e)=>e['request']['schema']='xbt-production-recovery-v1']){
     final e=envelope();mutate(e);expect(()=>parse(e),throwsA(anything));
   }
   expect(()=>ProductionTransfer.parse('x'*100001,session,c['keys']['market'],0),throwsA(anything));
 });

 test('connect request binds role, order and origin without fabricating contract approval',(){
   final e=envelope();e['request']={'schema':'xbt-signer-connect-request-v1','origin':session.origin,'role':'buyer','orderId':c['preflight']['orderId'],'expectedPreflightHash':'a'*64,'sellerId':null};
   final review=parse(e);expect(review.kind,'connect');expect(review.contract,isEmpty);expect(review.action,'Connect signer for this order');
   final selection=review.approve(session,c['keys']['market'],0);expect(selection['schema'],'xbt-signer-selection-v1');expect(selection.containsKey('signature'),false);expect(selection['orderId'],review.orderId);
   session.verified=false;expect(()=>review.approve(session,c['keys']['market'],0),throwsA(anything));session.verified=true;
   for(final change in <void Function(Map)>[(r)=>r['role']='seller',(r)=>r['origin']='https://evil.test',(r)=>r['sellerId']='secret',(r)=>r['orderId']='bad',(r)=>r['expectedPreflightHash']='bad',(r)=>r['backup']='secret']){
     final altered=jsonDecode(jsonEncode(e)) as Map;change(altered['request'] as Map);expect(()=>parse(altered),throwsA(anything));
   }
 });
}

