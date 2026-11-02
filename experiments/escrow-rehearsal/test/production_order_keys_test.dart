import 'dart:convert';
import 'dart:io';
import 'package:bitcoin_base/bitcoin_base.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xbt_escrow_rehearsal/production_order_keys.dart';
void main(){
 final fixture=jsonDecode(File('test-fixtures/production-contract.json').readAsStringSync()) as Map,c=fixture['entries'][0]['request']['contract'] as Map;
 test('independent order keys match Node and recovered synthetic identities derive the same child',(){
  expect(ProductionOrderKeys.derive(c),c['orderKeys']);
  for(final entry in fixture['entries']){final key=ECPrivate.fromHex((entry['scalar'] as int).toRadixString(16).padLeft(64,'0')),role=entry['role'] as String,child=ProductionOrderKeys.signingKey(c,role,key);
   expect(child.getPublic().toHex(),c['orderKeys'][role]);expect(child.getPublic().toHex(),isNot(key.getPublic().toHex()));
   expect(ProductionOrderKeys.signingKey(c,role,ECPrivate.fromHex(key.toHex())).getPublic().toHex(),child.getPublic().toHex());
   expect(()=>ProductionOrderKeys.signingKey(c,role,ECPrivate.fromHex('01'.padLeft(64,'0'))),throwsA(anything));
  }
 });
 test('role, order revision and participant changes cannot reuse child keys',(){
  final base=ProductionOrderKeys.derive(c);
  for(final change in <void Function(Map)>[(x)=>x['revision']++,(x)=>x['origin']='https://other.example.test',(x){final a=x['keys']['buyer'];x['keys']['buyer']=x['keys']['seller'];x['keys']['seller']=a;}]){final altered=jsonDecode(jsonEncode(c)) as Map;change(altered);final keys=ProductionOrderKeys.derive(altered);for(final role in keys.keys){expect(keys[role],isNot(base[role]));}}
  expect(()=>ProductionOrderKeys.tweak(c,'unknown'),throwsA(anything));
 });
}
