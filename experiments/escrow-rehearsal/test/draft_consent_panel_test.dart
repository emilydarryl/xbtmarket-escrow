import 'dart:convert';
import 'dart:io';
import 'package:bitcoin_base/bitcoin_base.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xbt_escrow_rehearsal/draft_consent_panel.dart';
import 'package:xbt_escrow_rehearsal/rehearsal.dart';
import 'package:xbt_escrow_rehearsal/draft_consent.dart';

void main() {
  final fixture =
      jsonDecode(File('test-fixtures/draft-consent.json').readAsStringSync())
          as Map;
  final entries = fixture['entries'] as List;
  Finder field(String name) => find.byKey(ValueKey('consent-$name'));
  Future<void> tap(WidgetTester tester, String name) async {
    await tester.ensureVisible(field(name));
    await tester.tap(field(name));
    await tester.pumpAndSettle();
  }

  Future<void> setup(
    WidgetTester tester,
    Map entry,
    int Function() now, {
    bool recovered = true,
  }) async {
    final identity = RehearsalIdentity(
      ECPrivate.fromHex(
        (entry['scalar'] as int).toRadixString(16).padLeft(64, '0'),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: DraftConsentPanel(
              identity: identity,
              role: entry['role'] as String,
              recoveryVerified: recovered,
              now: now,
            ),
          ),
        ),
      ),
    );
    await tester.enterText(
      field('hash'),
      entry['request']['draft']['draftHash'] as String,
    );
    await tester.enterText(field('audience'), fixture['audience'] as String);
    await tester.enterText(field('request'), jsonEncode(entry['request']));
    await tester.pumpAndSettle();
  }

  for (final role in ['buyer', 'seller']) {
    testWidgets(
      '$role reviews exact reserve and copies only a public consent proof',
      (tester) async {
        final entry = entries.firstWhere((e) => e['role'] == role) as Map;
        final now = fixture['now'] as int;
        String? copied;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, (call) async {
              if (call.method == 'Clipboard.setData') {
                copied = (call.arguments as Map)['text'] as String;
              }
              return null;
            });
        addTearDown(
          () => TestDefaultBinaryMessengerBinding
              .instance
              .defaultBinaryMessenger
              .setMockMethodCallHandler(SystemChannels.platform, null),
        );
        await setup(tester, entry, () => now);
        await tap(tester, 'review');
        expect(
          find.textContaining('Buyer network-fee reserve:'),
          findsOneWidget,
        );
        expect(tester.widget<FilledButton>(field('sign')).onPressed, isNull);
        await tap(tester, 'reviewed');
        await tap(tester, 'sign');
        expect(find.text('Approve this unfunded test draft?'), findsOneWidget);
        await tap(tester, 'confirm');
        await tap(tester, 'copy');
        final proof = jsonDecode(copied!) as Map;
        expect(proof.keys.toSet(), {'schema', 'challenge', 'signature'});
        expect(proof['schema'], 'xbt-unfunded-consent-proof-v1');
        expect(proof['challenge']['role'], role);
        expect(
          proof['challenge']['draftHash'],
          entry['request']['draft']['draftHash'],
        );
        expect(proof.containsKey('psbt'), isFalse);
        // The UI must produce exactly the independently validated signer output.
        final key = ECPrivate.fromHex(
          (entry['scalar'] as int).toRadixString(16).padLeft(64, '0'),
        );
        final parsed = DraftConsentRequest.parse(
          jsonEncode(entry['request']),
          expectedDraftHash: entry['request']['draft']['draftHash'] as String,
          audience: fixture['audience'] as String,
          ownPublicKey: key.getPublic().toHex(),
          role: role,
          now: now,
        );
        expect(
          proof,
          parsed.sign(
            key,
            confirmUnfunded: true,
            recoveryVerified: true,
            now: now,
          ),
        );
      },
    );
  }
  testWidgets('cancel, input changes and app background require fresh review', (
    tester,
  ) async {
    final entry = entries.first as Map;
    await setup(tester, entry, () => fixture['now'] as int);
    await tap(tester, 'review');
    await tap(tester, 'reviewed');
    await tap(tester, 'sign');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(field('copy'), findsNothing);
    await tester.enterText(field('hash'), '0' * 64);
    await tester.pumpAndSettle();
    expect(field('sign'), findsNothing);
    await tap(tester, 'review');
    expect(find.textContaining('Cannot review this request.'), findsOneWidget);
    await tester.enterText(
      field('hash'),
      entry['request']['draft']['draftHash'] as String,
    );
    await tap(tester, 'review');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pumpAndSettle();
    expect(field('sign'), findsNothing);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });
  testWidgets('expiry during confirmation produces no proof', (tester) async {
    var clock = fixture['now'] as int;
    await setup(tester, entries.first as Map, () => clock);
    await tap(tester, 'review');
    await tap(tester, 'reviewed');
    await tap(tester, 'sign');
    clock += 900000;
    await tap(tester, 'confirm');
    expect(field('copy'), findsNothing);
    expect(
      find.textContaining('Approval expired or became invalid.'),
      findsOneWidget,
    );
  });
  testWidgets('recovery gate and independent origin prevent approval', (
    tester,
  ) async {
    await setup(
      tester,
      entries.first as Map,
      () => fixture['now'] as int,
      recovered: false,
    );
    expect(tester.widget<FilledButton>(field('review')).onPressed, isNull);
    await setup(tester, entries.first as Map, () => fixture['now'] as int);
    await tester.enterText(field('audience'), 'http://127.0.0.1:9999');
    await tap(tester, 'review');
    expect(field('sign'), findsNothing);
    expect(find.textContaining('Cannot review this request.'), findsOneWidget);
  });
}
