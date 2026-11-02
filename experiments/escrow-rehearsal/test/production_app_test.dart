import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xbt_escrow_rehearsal/production_app.dart';
import 'package:xbt_escrow_rehearsal/production_identity.dart';

class EmptyStore implements ProductionKeyStore {
  @override Future<String?> read(String namespace) async=>null;
  @override Future<void> write(String namespace,String record) async{}
}
// Widget tests isolate UI state; real encryption/signatures have separate tests.
class UiSession extends ProductionIdentitySession {
  UiSession(this.key):super(EmptyStore(),role:'buyer',origin:'https://market.example.test');
  final String key;
  bool verified=false,failOpen=false,unlockedOnly=false;
  Completer<void>? gate;
  int signatures=0;
  IdentityProblem? recoveryFailure;
  @override bool get hasSavedIdentity=>true;
  @override bool get recoveryVerified=>verified;
  @override String? get publicKey=>verified||unlockedOnly?key:null;
  @override Future<void> open() async{if(failOpen)throw StateError('PRIVATE storage detail');}
  @override void lock(){verified=false;}
  @override Future<void> unlock(String password)async{verified=true;}
  @override Future<void> verifyRecovery(String backup,String password) async {if(recoveryFailure!=null)throw IdentityFailure(recoveryFailure!);await gate?.future;verified=true;}
  @override Map<String,dynamic> signReview(String request,{required String expectedContractHash,required String expectedMediatorPublicKey,required bool confirmReview,required int now}) {signatures++;return {'schema':'ui-test-public-proof'};}
  @override Map<String,dynamic> enrollment(){if(!verified)throw StateError('Recovery required');return {'schema':'xbt-production-enrollment-v1','publicKey':key,'recoveryVerifiedLocally':true};}
}
void main(){
  final fixture=jsonDecode(File('test-fixtures/production-contract.json').readAsStringSync()) as Map;
  final original=fixture['entries'][0]['request'] as Map;
  final contract=original['contract'] as Map;
  Finder f(String name)=>find.byKey(ValueKey('production-$name'));
  Future<void> tap(WidgetTester t,String name) async{if(name=='recover'&&f(name).evaluate().isEmpty){await t.ensureVisible(find.text('Advanced: backup and recovery'));await t.tap(find.text('Advanced: backup and recovery'));await t.pumpAndSettle();}final target=name=='advanced'?find.text('Advanced: manual requests'):f(name);await t.ensureVisible(target);await t.tap(target);await t.pumpAndSettle();}
  Future<void> start(WidgetTester t,UiSession s) async{await t.pumpWidget(ProductionReviewApp(session:s,mediatorPublicKey:contract['keys']['market']));await t.pumpAndSettle();if(find.byKey(const ValueKey('production-advanced')).evaluate().isNotEmpty)await tap(t,'advanced');}
  testWidgets('unlocked identity needing recovery explains the next step and uses primary recovery action',(t) async{
    final s=UiSession(contract['keys']['buyer'])..unlockedOnly=true;await start(t,s);
    expect(find.text('Identity unlocked — recovery verification required'),findsOneWidget);
    expect(find.textContaining('Next: enter the original recovery passphrase'),findsOneWidget);
    final recover=t.widget<FilledButton>(f('recover'));expect(recover.onPressed,isNotNull);expect(recover.style,isNull);
    await tap(t,'recover');expect(find.text('Recovery verified'),findsOneWidget);expect(f('recover'),findsNothing);
  });
  testWidgets('incoming public request survives recovery status changing and app locking',(t) async{
    const channel=MethodChannel('store.xbtmarket/public-files');
    String? pending='synthetic public request';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel,(call)async{if(call.method=='takeIncoming'){final value=pending;pending=null;return value;}return null;});
    addTearDown(()=>TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel,null));
    final s=UiSession(contract['keys']['buyer']);await start(t,s);
    expect(find.text('Review imported order'),findsOneWidget);
    await tap(t,'recover');
    expect(find.text('Review imported order'),findsOneWidget);
    await tap(t,'lock');
    expect(find.text('Review imported order'),findsOneWidget);
    expect(t.widget<FilledButton>(find.widgetWithText(FilledButton,'Review imported order')).onPressed,isNull);
    expect(s.signatures,0);
    await tap(t,'unlock');
    expect(find.text('Review imported order'),findsOneWidget);
    expect(f('recover'),findsNothing);expect(f('backup'),findsNothing);expect(f('password'),findsNothing);expect(f('unlock'),findsNothing);
  });
  testWidgets('enrollment-only mode requires recovery and hides every signing surface even if flags are enabled',(t) async{
    final s=UiSession(contract['keys']['buyer']);
    await t.pumpWidget(ProductionReviewApp(session:s,mediatorPublicKey:'',enrollmentOnly:true,enableFundingConsent:true,enablePayoutSigning:true,enableMediatorDecisions:true));await t.pumpAndSettle();
    expect(f('enrollment'),findsNothing);
    for(final key in ['review','sign','request','hash']){expect(f(key),findsNothing);}
    for(final key in ['funding-panel','spend-panel','resolution-panel']){expect(find.byKey(ValueKey(key)),findsNothing);}
    await tap(t,'recover');await tap(t,'enrollment');
    expect(find.textContaining('xbt-production-enrollment-v1'),findsOneWidget);
    expect(s.signatures,0);
    await tap(t,'lock');expect(f('enrollment'),findsNothing);expect(f('public-result'),findsNothing);
  });
  Future<void> review(WidgetTester t) async{
    final request=jsonDecode(jsonEncode(original)) as Map,now=DateTime.now().millisecondsSinceEpoch;
    request['challenge']['issuedAt']=now-1000;request['challenge']['expiresAt']=now+899000;
    await t.enterText(f('hash'),contract['contractHash']);await t.enterText(f('request'),jsonEncode(request));await tap(t,'review');
  }
  testWidgets('recovery, independent hash and explicit confirmation gate approval; edits revoke review',(t) async{
    final s=UiSession(contract['keys']['buyer']);await start(t,s);
    expect(t.widget<FilledButton>(f('review')).onPressed,isNull);
    await tap(t,'recover');await review(t);
    expect(f('reviewed-contract'),findsOneWidget);expect(t.widget<FilledButton>(f('sign')).onPressed,isNull);
    await tap(t,'confirm');await tap(t,'sign');expect(s.signatures,1);expect(f('public-result'),findsOneWidget);
    await t.enterText(f('hash'),'0'*64);await t.pumpAndSettle();expect(f('reviewed-contract'),findsNothing);expect(f('public-result'),findsNothing);
    await tap(t,'review');expect(f('reviewed-contract'),findsNothing);expect(s.signatures,1);
  });
  testWidgets('backgrounding preserves public inputs but locks and clears private fields and approvals',(t) async{
    final s=UiSession(contract['keys']['buyer']);await start(t,s);await tap(t,'recover');await review(t);await tap(t,'confirm');
    await t.ensureVisible(find.text('Advanced: backup and recovery'));await t.tap(find.text('Advanced: backup and recovery'));await t.pumpAndSettle();await t.enterText(f('password'),'synthetic password');await t.enterText(f('backup'),'synthetic backup');
    final savedRequest=t.widget<TextField>(f('request')).controller!.text;
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);await t.pumpAndSettle();
    expect(s.verified,isFalse);for(final name in ['password','backup']){expect(t.widget<TextField>(find.byKey(ValueKey('production-$name'),skipOffstage:false)).controller!.text,isEmpty);}
    expect(t.widget<TextField>(f('request')).controller!.text,savedRequest);
    expect(t.widget<TextField>(f('hash')).controller!.text,contract['contractHash']);
    expect(f('reviewed-contract'),findsNothing);expect(t.widget<FilledButton>(f('sign')).onPressed,isNull);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tap(t,'recover');expect(t.widget<FilledButton>(f('sign')).onPressed,isNull);
    await tap(t,'review');expect(f('reviewed-contract'),findsOneWidget);
    expect(t.widget<FilledButton>(f('sign')).onPressed,isNull);
    await tap(t,'clear-public');expect(t.widget<TextField>(f('request')).controller!.text,isEmpty);
  });
  testWidgets('public funding and payout inputs survive repeated app switching and manual locks',(t) async{
    final s=UiSession(contract['keys']['buyer']);
    await t.pumpWidget(ProductionReviewApp(session:s,mediatorPublicKey:contract['keys']['market'],enableFundingConsent:true,enablePayoutSigning:true));await t.pumpAndSettle();
    await tap(t,'advanced');
    final names=['funding-contract','funding-terms','funding-request','spend-contract','spend-terms','spend-payout','spend-request'];
    for(final name in names){
      final finder=find.byKey(ValueKey(name));await t.ensureVisible(finder);await t.enterText(finder,'public-$name');
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);await t.pumpAndSettle();
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);await t.pumpAndSettle();
    }
    await tap(t,'recover');await tap(t,'lock');
    for(final name in names){expect(t.widget<TextField>(find.byKey(ValueKey(name))).controller!.text,'public-$name');}
    for(final name in ['funding-review','funding-sign','spend-review','spend-sign']){expect(t.widget<FilledButton>(find.byKey(ValueKey(name))).onPressed,isNull);}
    expect(s.verified,isFalse);
  });
  testWidgets('storage failures are redacted and cannot expose identity actions',(t) async{
    final s=UiSession(contract['keys']['buyer'])..failOpen=true;await start(t,s);
    expect(f('create'),findsNothing);expect(f('recover'),findsNothing);expect(find.textContaining('PRIVATE'),findsNothing);expect(f('open'),findsOneWidget);
  });
  testWidgets('safe recovery categories are visible and failed recovery never enables approval',(t) async{
    final s=UiSession(contract['keys']['buyer']);await start(t,s);
    for(final p in IdentityProblem.values){
      s.recoveryFailure=p;await tap(t,'recover');
      expect(find.textContaining('[${p.name}]'),findsOneWidget);
      expect(t.widget<FilledButton>(f('review')).onPressed,isNull);
      expect(f('enrollment'),findsNothing);
    }
  });

  testWidgets('guided transfer is primary and manual forms stay collapsed until requested',(t)async{
    final s=UiSession(contract['keys']['buyer']);await t.pumpWidget(ProductionReviewApp(session:s,mediatorPublicKey:contract['keys']['market'],enableFundingConsent:true,enablePayoutSigning:true));await t.pumpAndSettle();
    expect(find.text('Open order request file'),findsNothing);expect(f('request'),findsNothing);expect(find.byKey(const ValueKey('funding-request')),findsNothing);
    await tap(t,'advanced');expect(f('request'),findsOneWidget);
    await t.enterText(f('request'),'public retained request');await tap(t,'advanced');expect(f('request'),findsNothing);
    await tap(t,'advanced');expect(t.widget<TextField>(f('request')).controller!.text,'public retained request');
  });
}
