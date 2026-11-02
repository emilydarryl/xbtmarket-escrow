import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xbt_escrow_rehearsal/production_withdrawal_panel.dart';
import 'production_app_test.dart' show UiSession;
class WithdrawalSession extends UiSession {
 WithdrawalSession(super.key);
 @override String get origin=>'https://xbtmarket.store';
 int payouts=0;
 @override Map<String,dynamic> signWithdrawal(String request,{required String expectedRequestHash,required String expectedDestination,required String maximumFeeSats,required bool confirmWithdrawal}) {
  if(!verified||!confirmWithdrawal)throw StateError('Recovery and confirmation required');
  payouts++;return {'schema':'synthetic-ui-signature'};
 }
}
void main(){
 final fixture=jsonDecode(File('test-fixtures/production-withdrawal.json').readAsStringSync()) as Map;
 final request=fixture['requests'][0] as Map;
 Finder f(String name)=>find.byKey(ValueKey('withdrawal-$name'));
 Future<void> tap(WidgetTester t,String name)async{await t.ensureVisible(f(name));await t.tap(f(name));await t.pumpAndSettle();}
 Future<void> start(WidgetTester t,WithdrawalSession s)async{await t.pumpWidget(MaterialApp(home:Scaffold(body:SingleChildScrollView(child:ProductionWithdrawalPanel(session:s)))));await t.pumpAndSettle();}
 Future<void> fill(WidgetTester t)async{
  await t.enterText(f('destination'),request['destination']);await t.enterText(f('fee'),'1000');await t.enterText(f('payout'),request['requestHash']);await t.enterText(f('request'),jsonEncode(request));await tap(t,'review');
 }
 testWidgets('payout requires recovery, independent hashes and explicit confirmation; edits revoke approval',(t)async{
  final s=WithdrawalSession(request['publicKey']);await start(t,s);expect(t.widget<FilledButton>(f('review')).onPressed,isNull);
  s.verified=true;await start(t,s);await fill(t);expect(f('reviewed'),findsOneWidget);expect(t.widget<FilledButton>(f('sign')).onPressed,isNull);
  await tap(t,'confirm');await tap(t,'sign');expect(s.payouts,1);expect(f('result'),findsOneWidget);
  await t.enterText(f('payout'),'0'*64);await t.pumpAndSettle();expect(f('result'),findsNothing);expect(f('reviewed'),findsNothing);
  await tap(t,'review');expect(f('reviewed'),findsNothing);expect(s.payouts,1);
 });
 testWidgets('backgrounding keeps public payout inputs but revokes review and confirmation',(t)async{
  final s=WithdrawalSession(request['publicKey'])..verified=true;await start(t,s);await fill(t);await tap(t,'confirm');
  t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);await t.pumpAndSettle();
  expect(t.widget<TextField>(f('destination')).controller!.text,request['destination']);
  expect(t.widget<TextField>(f('fee')).controller!.text,'1000');
  expect(t.widget<TextField>(f('payout')).controller!.text,request['requestHash']);
  expect(t.widget<TextField>(f('request')).controller!.text,jsonEncode(request));
  expect(f('reviewed'),findsNothing);expect(t.widget<FilledButton>(f('sign')).onPressed,isNull);expect(s.payouts,0);
  t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
 });
}
