import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xbt_escrow_rehearsal/production_transfer_panel.dart';
import 'production_spend_panel_test.dart' show SpendSession;
void main(){
 TestWidgetsFlutterBinding.ensureInitialized();
 final f=jsonDecode(File('test-fixtures/production-spend.json').readAsStringSync()) as Map;
 final r=f['cases'][0]['request'],c=r['authorization']['bundle']['contract'];
 const channel=MethodChannel('store.xbtmarket/public-files');
 testWidgets('file import requires code comparison and explicit approval; background revokes consent',(t)async{
  final s=SpendSession(c['keys']['buyer'])..verified=true;
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel,(call)async=>call.method=='takeIncoming'?null:jsonEncode({'schema':'xbt-signer-transfer-v1','origin':s.origin,'role':'buyer','request':r}));
  addTearDown(()=>TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel,null));
  await t.pumpWidget(MaterialApp(home:Scaffold(body:SingleChildScrollView(child:ProductionTransferPanel(session:s,mediator:c['keys']['market'],lockGeneration:0,funding:true,spending:true,resolutions:false)))));
  Future<void> tap(String text)async{await t.ensureVisible(find.text(text).last);await t.tap(find.text(text).last);await t.pumpAndSettle();}
  await tap('Advanced: import a request file');await tap('Open order request file');await tap('Review imported order');
  expect(t.widget<FilledButton>(find.widgetWithText(FilledButton,'Sign exact payout')).onPressed,isNull);
  await tap('This code matches the code on my signed-in order page.');
  await tap('I checked the order, terms, recipients and amounts and approve this action.');
  t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);await t.pumpAndSettle();
  expect(find.widgetWithText(FilledButton,'Sign exact payout'),findsNothing);expect(s.payouts,0);
  t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);await t.pumpAndSettle();
  await tap('Review imported order');await tap('This code matches the code on my signed-in order page.');await tap('I checked the order, terms, recipients and amounts and approve this action.');await tap('Sign exact payout');
  expect(s.payouts,1);expect(find.text('Return approval to website'),findsOneWidget);
 });

 testWidgets('connect flow shows no deposit and returns only a public selection',(t)async{
  final s=SpendSession(c['keys']['buyer'])..verified=true;
  final request={'schema':'xbt-signer-transfer-v1','origin':s.origin,'role':'buyer','request':{'schema':'xbt-signer-connect-request-v1','origin':s.origin,'role':'buyer','orderId':c['preflight']['orderId'],'expectedPreflightHash':'a'*64,'sellerId':null}};
  Map? returned;
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel,(call)async{
   if(call.method=='takeIncoming')return null;
   if(call.method=='returnApproval'){returned=jsonDecode(call.arguments['content'] as String) as Map;return true;}
   return jsonEncode(request);
  });
  addTearDown(()=>TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel,null));
  await t.pumpWidget(MaterialApp(home:Scaffold(body:SingleChildScrollView(child:ProductionTransferPanel(session:s,mediator:c['keys']['market'],lockGeneration:0,funding:false,spending:false,resolutions:false)))));
  Future<void> tap(String text)async{await t.ensureVisible(find.text(text).last);await t.tap(find.text(text).last);await t.pumpAndSettle();}
  await tap('Advanced: import a request file');await tap('Open order request file');await tap('Review imported order');
  expect(find.textContaining('Exact deposit:'),findsNothing);
  expect(t.widget<FilledButton>(find.widgetWithText(FilledButton,'Connect signer for this order')).onPressed,isNull);
  await tap('This code matches the code on my signed-in order page.');await tap('I checked the order, terms, recipients and amounts and approve this action.');await tap('Connect signer for this order');await tap('Return approval to website');
  expect(returned!['result']['schema'],'xbt-signer-selection-v1');expect(returned!['sellerId'],isNull);expect(s.payouts,0);
 });

 testWidgets('a new share while already open clears prior review and requires fresh consent',(t)async{
  final s=SpendSession(c['keys']['buyer'])..verified=true;
  final encoded=jsonEncode({'schema':'xbt-signer-transfer-v1','origin':s.origin,'role':'buyer','request':r});
  String? pending;
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel,(call)async{
   if(call.method=='takeIncoming'){final value=pending;pending=null;return value;}
   return encoded;
  });
  addTearDown(()=>TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel,null));
  await t.pumpWidget(MaterialApp(home:Scaffold(body:SingleChildScrollView(child:ProductionTransferPanel(session:s,mediator:c['keys']['market'],lockGeneration:0,funding:true,spending:true,resolutions:false)))));
  Future<void> tap(String text)async{await t.ensureVisible(find.text(text).last);await t.tap(find.text(text).last);await t.pumpAndSettle();}
  await tap('Advanced: import a request file');await tap('Open order request file');await tap('Review imported order');await tap('This code matches the code on my signed-in order page.');await tap('I checked the order, terms, recipients and amounts and approve this action.');
  pending=encoded;
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(channel.name,const StandardMethodCodec().encodeMethodCall(const MethodCall('incomingAvailable')),(_){ });
  await t.pumpAndSettle();expect(find.widgetWithText(FilledButton,'Sign exact payout'),findsNothing);expect(s.payouts,0);
  await tap('Review imported order');expect(t.widget<FilledButton>(find.widgetWithText(FilledButton,'Sign exact payout')).onPressed,isNull);
 });
}

