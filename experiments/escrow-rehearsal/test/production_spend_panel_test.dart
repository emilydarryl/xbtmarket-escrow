import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xbt_escrow_rehearsal/production_spend_panel.dart';
import 'production_app_test.dart' show UiSession;
class SpendSession extends UiSession {
 SpendSession(super.key);
 int payouts=0;
 @override Map<String,dynamic> signSpend(String request,{required String expectedRequestHash,required String expectedContractHash,required String expectedFundingTermsHash,required String expectedMediatorPublicKey,required bool confirmPayout}) {
  if(!verified||!confirmPayout)throw StateError('Recovery and confirmation required');
  payouts++;return {'schema':'synthetic-ui-signature'};
 }
}
void main(){
 final fixture=jsonDecode(File('test-fixtures/production-spend.json').readAsStringSync()) as Map;
 final request=fixture['cases'][0]['request'] as Map,c=request['authorization']['bundle']['contract'] as Map;
 Finder f(String name)=>find.byKey(ValueKey('spend-$name'));
 Future<void> tap(WidgetTester t,String name)async{await t.ensureVisible(f(name));await t.tap(f(name));await t.pumpAndSettle();}
 Future<void> start(WidgetTester t,SpendSession s)async{await t.pumpWidget(MaterialApp(home:Scaffold(body:SingleChildScrollView(child:ProductionSpendPanel(session:s,mediatorPublicKey:c['keys']['market'])))));await t.pumpAndSettle();}
 Future<void> fill(WidgetTester t)async{
  await t.enterText(f('contract'),c['contractHash']);await t.enterText(f('terms'),request['authorization']['terms']['fundingTermsHash']);await t.enterText(f('payout'),request['requestHash']);await t.enterText(f('request'),jsonEncode(request));await tap(t,'review');
 }
 testWidgets('payout requires recovery, independent hashes and explicit confirmation; edits revoke approval',(t)async{
  final s=SpendSession(c['keys']['buyer']);await start(t,s);expect(t.widget<FilledButton>(f('review')).onPressed,isNull);
  s.verified=true;await start(t,s);await fill(t);expect(f('reviewed'),findsOneWidget);expect(t.widget<FilledButton>(f('sign')).onPressed,isNull);
  await tap(t,'confirm');await tap(t,'sign');expect(s.payouts,1);expect(f('result'),findsOneWidget);
  await t.enterText(f('payout'),'0'*64);await t.pumpAndSettle();expect(f('result'),findsNothing);expect(f('reviewed'),findsNothing);
  await tap(t,'review');expect(f('reviewed'),findsNothing);expect(s.payouts,1);
 });
 testWidgets('backgrounding keeps public payout inputs but revokes review and confirmation',(t)async{
  final s=SpendSession(c['keys']['buyer'])..verified=true;await start(t,s);await fill(t);await tap(t,'confirm');
  t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);await t.pumpAndSettle();
  expect(t.widget<TextField>(f('contract')).controller!.text,c['contractHash']);
  expect(t.widget<TextField>(f('terms')).controller!.text,request['authorization']['terms']['fundingTermsHash']);
  expect(t.widget<TextField>(f('payout')).controller!.text,request['requestHash']);
  expect(t.widget<TextField>(f('request')).controller!.text,jsonEncode(request));
  expect(f('reviewed'),findsNothing);expect(t.widget<FilledButton>(f('sign')).onPressed,isNull);expect(s.payouts,0);
  t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
 });
}
