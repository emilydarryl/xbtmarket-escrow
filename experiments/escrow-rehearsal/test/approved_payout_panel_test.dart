import 'dart:convert';
import 'dart:io';
import 'package:bitcoin_base/bitcoin_base.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xbt_escrow_rehearsal/approved_payout_panel.dart';
import 'package:xbt_escrow_rehearsal/rehearsal.dart';
void main(){
 final r=(jsonDecode(File('test-fixtures/approved-payout.json').readAsStringSync()) as List).first;
 Finder field(String key)=>find.byKey(ValueKey('payout-$key'));
 Future<void> tap(WidgetTester t,String key)async{await t.ensureVisible(field(key));await t.tap(field(key));await t.pumpAndSettle();}
 Future<void> setup(WidgetTester t,{bool recovery=true})async{
  await t.pumpWidget(MaterialApp(home:Scaffold(body:SingleChildScrollView(child:ApprovedPayoutPanel(identity:RehearsalIdentity(ECPrivate.fromHex('0b'.padLeft(64,'0'))),role:'buyer',recoveryVerified:recovery)))));
  await t.enterText(field('draft'),r['draft']['draftHash'] as String);await t.enterText(field('pin'),r['requestHash'] as String);await t.enterText(field('json'),jsonEncode(r));await tap(t,'review');await tap(t,'confirm');
 }
 testWidgets('recovery gate and cancel prevent signatures; changing a pin clears review',(t)async{
  await setup(t,recovery:false);expect(t.widget<FilledButton>(field('sign')).onPressed,isNull);
  await setup(t);await tap(t,'sign');await t.tap(find.text('Cancel'));await t.pumpAndSettle();expect(field('copy'),findsNothing);
  await t.enterText(field('pin'),'0'*64);await t.pumpAndSettle();expect(field('sign'),findsNothing);
 });
 testWidgets('explicit confirmation creates public partial and backgrounding clears it',(t)async{
  await setup(t);await tap(t,'sign');await t.tap(find.text('Sign test payout'));await t.pumpAndSettle();expect(field('copy'),findsOneWidget);
  t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);await t.pumpAndSettle();expect(field('copy'),findsNothing);
  t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
 });
}
