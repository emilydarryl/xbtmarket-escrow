import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xbt_escrow_rehearsal/production_resolution_panel.dart';
import 'production_app_test.dart' show UiSession;
class ResolutionSession extends UiSession {
 ResolutionSession(super.key);
 String selectedRole='market';int approvals=0;
 @override String get role=>selectedRole;
 @override Map<String,dynamic> signResolution(String request,{required String expectedDecisionHash,required String expectedContractHash,required String expectedFundingTermsHash,required bool confirmDecision,required int now}){if(!verified||!confirmDecision)throw StateError('Confirmation required');approvals++;return {'schema':'synthetic-ui-decision'};}
}
void main(){
 final fixture=jsonDecode(File('test-fixtures/production-resolution.json').readAsStringSync()) as Map;
 final r=fixture['entries'][0] as Map,p=r['payoutRequest'],c=p['authorization']['bundle']['contract'];
 Finder f(String name)=>find.byKey(ValueKey('resolution-$name'));
 Future<void> tap(WidgetTester t,String name)async{await t.ensureVisible(f(name));await t.tap(f(name));await t.pumpAndSettle();}
 Future<void> start(WidgetTester t,ResolutionSession s,{int? now,int generation=0})async{await t.pumpWidget(MaterialApp(home:Scaffold(body:SingleChildScrollView(child:ProductionResolutionPanel(session:s,lockGeneration:generation,now:()=>now??fixture['now'])))));await t.pumpAndSettle();}
 Future<void> fill(WidgetTester t)async{await t.enterText(f('contract'),c['contractHash']);await t.enterText(f('terms'),p['authorization']['terms']['fundingTermsHash']);await t.enterText(f('decision'),r['decisionHash']);await t.enterText(f('request'),jsonEncode(r));await tap(t,'review');}
 testWidgets('mediator decision requires recovery, market role, independent pins and confirmation',(t)async{
  final s=ResolutionSession(c['keys']['market']);await start(t,s);expect(t.widget<FilledButton>(f('review')).onPressed,isNull);
  s.verified=true;s.selectedRole='buyer';await start(t,s);expect(t.widget<FilledButton>(f('review')).onPressed,isNull);
  s.selectedRole='market';await start(t,s);await fill(t);expect(f('reviewed'),findsOneWidget);expect(t.widget<FilledButton>(f('sign')).onPressed,isNull);
  await tap(t,'confirm');await tap(t,'sign');expect(s.approvals,1);expect(f('result'),findsOneWidget);
  await t.enterText(f('decision'),'0'*64);await tap(t,'review');expect(f('reviewed'),findsNothing);expect(f('result'),findsNothing);expect(s.approvals,1);
 });
 testWidgets('background and manual lock retain public fields but revoke reviewed decision',(t)async{
  final s=ResolutionSession(c['keys']['market'])..verified=true;await start(t,s);await fill(t);await tap(t,'confirm');
  t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);await t.pumpAndSettle();
  expect(t.widget<TextField>(f('request')).controller!.text,jsonEncode(r));expect(f('reviewed'),findsNothing);expect(t.widget<FilledButton>(f('sign')).onPressed,isNull);
  t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);await tap(t,'review');expect(f('reviewed'),findsOneWidget);
  await start(t,s,generation:1);expect(f('reviewed'),findsNothing);expect(s.approvals,0);
 });
 testWidgets('expired decision is rejected',(t)async{final s=ResolutionSession(c['keys']['market'])..verified=true;await start(t,s,now:r['challenge']['expiresAt']);await fill(t);expect(f('reviewed'),findsNothing);expect(s.approvals,0);});
}
