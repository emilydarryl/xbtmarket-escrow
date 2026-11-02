import 'dart:convert';
import 'dart:io';
import 'package:bitcoin_base/bitcoin_base.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xbt_escrow_rehearsal/main.dart';
import 'package:xbt_escrow_rehearsal/rehearsal.dart';
import 'package:xbt_escrow_rehearsal/shared_order.dart';
import 'package:xbt_market_escrow_lab/escrow_signer.dart' show sha, EscrowPsbt;

class MemoryStore implements KeyStore {
  MemoryStore([this.value]);
  String? value;
  String? order;
  bool failRead = false, failOrderRead = false;
  @override
  Future<String?> readOrder() async {
    if (failOrderRead) {
      throw StateError('Private contents must not be displayed');
    }
    return order;
  }

  @override
  Future<void> writeOrder(String next) async {
    if (fail) throw StateError('Test storage failure');
    order = next;
  }

  bool fail = false;
  @override
  Future<String?> read() async {
    if (failRead) throw StateError('Private contents must not be displayed');
    return value;
  }

  @override
  Future<void> write(String next) async {
    if (fail) throw StateError('Test storage failure');
    value = next;
  }
}

final fixtureIdentity = RehearsalIdentity(
  ECPrivate.fromBytes([...List<int>.filled(31, 0), 11]),
);
final fixture = File('assets/release.json').readAsStringSync();
final sharedFixture = File(
  'test-fixtures/shared-release.json',
).readAsStringSync();
String nextMediatorFixture() {
  final bundle = jsonDecode(sharedFixture) as Map<String, dynamic>;
  final c = Map<String, dynamic>.from(bundle['contract'] as Map)
    ..remove('contractHash');
  final market = RehearsalIdentity(
    ECPrivate.fromBytes([...List<int>.filled(31, 0), 44]),
  ).publicKey;
  final oldMarket = c['marketPublicKey'] as String;
  c['marketPublicKey'] = market;
  c['orderId'] = '20000000-0000-4000-8000-000000000002';
  final keys = [
    c['buyerPublicKey'] as String,
    c['sellerPublicKey'] as String,
    market,
  ]..sort();
  c['witnessScript'] = '52${keys.map((k) => '21$k').join()}53ae';
  List<int> unhex(String value) => [
    for (var i = 0; i < value.length; i += 2)
      int.parse(value.substring(i, i + 2), radix: 16),
  ];
  final psbt = EscrowPsbt.parse(bundle['psbt'] as String);
  psbt.inputs.single['05'] = unhex(c['witnessScript'] as String);
  psbt.inputs.single['01'] = [
    ...psbt.inputs.single['01']!.take(8),
    34,
    0,
    32,
    ...unhex(sha(unhex(c['witnessScript'] as String))),
  ];
  final path = psbt.inputs.single.remove('06$oldMarket');
  if (path != null) psbt.inputs.single['06$market'] = path;
  c['contractHash'] = sha(utf8.encode(jsonEncode(sortedJson(c))));
  bundle['contract'] = c;
  bundle['psbt'] = psbt.serialize();
  return jsonEncode(bundle);
}

void main() {
  test(
    'a fresh mediator requires explicit new-order replacement and old requests stay rejected',
    () async {
      final old = SharedOrder.parse(
        jsonEncode((jsonDecode(sharedFixture) as Map)['contract']),
        fixtureIdentity.publicKey,
        'buyer',
      );
      final next = nextMediatorFixture();
      final fresh = SharedOrder.parse(
        jsonEncode((jsonDecode(next) as Map)['contract']),
        fixtureIdentity.publicKey,
        'buyer',
      );
      expect(fresh.market, isNot(old.market));
      final store = MemoryStore(fixtureIdentity.recoveryKit)
        ..order = old.encode();
      final session = RehearsalSession(store);
      await session.open();
      await expectLater(
        session.replaceTestOrder(fresh, old.hash),
        throwsStateError,
      );
      await session.recover(fixtureIdentity.recoveryKit);
      await expectLater(session.pinOrder(fresh), throwsFormatException);
      await expectLater(
        session.replaceTestOrder(fresh, 'wrong'),
        throwsStateError,
      );
      store.fail = true;
      await expectLater(
        session.replaceTestOrder(fresh, old.hash),
        throwsStateError,
      );
      expect(session.sharedOrder!.hash, old.hash);
      store.fail = false;
      await session.replaceTestOrder(fresh, old.hash);
      expect(session.sharedOrder!.market, fresh.market);
      expect(session.identity!.publicKey, fixtureIdentity.publicKey);
      expect(
        () => RehearsalRequest.parse(
          sharedFixture,
          fixtureIdentity,
          sharedOrder: session.sharedOrder,
        ),
        throwsFormatException,
      );
      final signed =
          jsonDecode(
                RehearsalRequest.parse(
                  next,
                  fixtureIdentity,
                  sharedOrder: session.sharedOrder,
                ).sign(),
              )
              as Map;
      expect(signed['contractHash'], fresh.hash);
      final reopened = RehearsalSession(store);
      await reopened.open();
      expect(reopened.sharedOrder!.hash, fresh.hash);
    },
  );
  testWidgets(
    'new-order UI shows mediator fingerprint and cancellation preserves previous order',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 10000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final old = SharedOrder.parse(
        jsonEncode((jsonDecode(sharedFixture) as Map)['contract']),
        fixtureIdentity.publicKey,
        'buyer',
      );
      final store = MemoryStore(fixtureIdentity.recoveryKit)
        ..order = old.encode();
      await tester.pumpWidget(RehearsalApp(store: store, sample: fixture));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Private rehearsal recovery kit'),
        fixtureIdentity.recoveryKit,
      );
      await tester.tap(find.text('Verify recovery kit'));
      await tester.pumpAndSettle();
      final next = nextMediatorFixture();
      await tester.enterText(find.byKey(const ValueKey('request')), next);
      Future<void> review() async {
        await tester.tap(find.text('Review shared order setup'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
      }

      await review();
      expect(
        find.text('Retire old test order and review new one'),
        findsOneWidget,
      );
      final c = (jsonDecode(next) as Map)['contract'] as Map;
      expect(
        find.textContaining(
          'Mediator fingerprint: ${publicFingerprint(c['marketPublicKey'] as String)}',
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(store.order, old.encode());
      await review();
      await tester.tap(find.text('Retire old test order and approve new one'));
      await tester.pumpAndSettle();
      expect(
        (jsonDecode(store.order!) as Map)['contractHash'],
        c['contractHash'],
      );
      await tester.tap(find.text('Review test transaction'));
      await tester.pumpAndSettle();
      expect(find.text('5 · Confirm the exact test outcome'), findsOneWidget);
    },
  );
  test(
    'legacy-format repair preserves the same key and rejects replacement or unreadable orders',
    () async {
      final original = fixtureIdentity.recoveryKit;
      final store = MemoryStore(original);
      final session = RehearsalSession(store, role: 'seller');
      await expectLater(
        session.open(),
        throwsA(
          isA<RehearsalLoadException>().having(
            (e) => e.code,
            'code',
            'SAVED_KEY_ROLE_MISMATCH',
          ),
        ),
      );
      final preview = await session.reviewLegacyKit(original);
      expect(preview.publicKey, fixtureIdentity.publicKey);
      expect(store.value, original);
      final different = RehearsalIdentity(
        ECPrivate.fromBytes([...List<int>.filled(31, 0), 22]),
      );
      await expectLater(
        session.reviewLegacyKit(different.recoveryKit),
        throwsFormatException,
      );
      await expectLater(
        session.repairLegacyKit(original, different.publicKey),
        throwsFormatException,
      );
      store.order = '{}';
      await expectLater(
        session.repairLegacyKit(original, preview.publicKey),
        throwsFormatException,
      );
      expect(store.value, original);
      store.order = null;
      store.fail = true;
      await expectLater(
        session.repairLegacyKit(original, preview.publicKey),
        throwsStateError,
      );
      expect(store.value, original);
      store.fail = false;
      await session.repairLegacyKit(original, preview.publicKey);
      expect(store.value, fixtureIdentity.recoveryKitFor('seller'));
      expect(session.identity!.publicKey, fixtureIdentity.publicKey);
      expect(session.recoveryVerified, false);
      final reopened = RehearsalSession(store, role: 'seller');
      await reopened.open();
      expect(reopened.identity!.publicKey, fixtureIdentity.publicKey);
      await reopened.recover(fixtureIdentity.recoveryKitFor('seller'));
      expect(reopened.recoveryVerified, true);
      await expectLater(
        reopened.reviewLegacyKit(original),
        throwsFormatException,
      );
    },
  );
  testWidgets(
    'legacy repair requires fingerprint consent and a newly verified backup',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 10000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = MemoryStore(fixtureIdentity.recoveryKit);
      await tester.pumpWidget(
        RehearsalApp(store: store, sample: fixture, role: 'seller'),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('Diagnostic code: SAVED_KEY_ROLE_MISMATCH'),
        findsOneWidget,
      );
      final recovery = find.widgetWithText(
        TextField,
        'Private rehearsal recovery kit',
      );
      await tester.enterText(recovery, fixtureIdentity.recoveryKit);
      Future<void> review() async {
        await tester.tap(find.text('Repair saved kit format'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('Confirm the existing test key'), findsOneWidget);
      }

      await review();
      expect(store.value, fixtureIdentity.recoveryKit);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(store.value, fixtureIdentity.recoveryKit);
      await review();
      await tester.tap(find.text('Same fingerprint — repair format'));
      await tester.pumpAndSettle();
      expect(store.value, fixtureIdentity.recoveryKitFor('seller'));
      final signReview = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Review test transaction'),
      );
      expect(signReview.onPressed, isNull);
      await tester.enterText(
        recovery,
        fixtureIdentity.recoveryKitFor('seller'),
      );
      await tester.tap(find.text('Verify recovery kit'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Review test transaction'),
            )
            .onPressed,
        isNotNull,
      );
    },
  );
  test(
    'load failures identify their stage without writing or replacing a key',
    () async {
      final store = MemoryStore(fixtureIdentity.recoveryKit)..failRead = true;
      final session = RehearsalSession(store);
      Future<void> failsWith(String code) => expectLater(
        session.open(),
        throwsA(
          isA<RehearsalLoadException>().having((e) => e.code, 'code', code),
        ),
      );
      await failsWith('KEY_READ_FAILED');
      expect(store.value, fixtureIdentity.recoveryKit);
      store.failRead = false;
      store.failOrderRead = true;
      await failsWith('ORDER_READ_FAILED');
      store.failOrderRead = false;
      store.order = '{}';
      await failsWith('SAVED_ORDER_INVALID');
      expect(store.order, '{}');
      store.order = null;
      store.value = 'invalid private kit';
      await failsWith('SAVED_KEY_INVALID');
      expect(store.value, 'invalid private kit');
      store.value = null;
      store.order = '{}';
      await failsWith('ORDER_WITHOUT_KEY');
      store.order = null;
      store.value = fixtureIdentity.recoveryKit;
      await session.open();
      expect(session.identity!.publicKey, fixtureIdentity.publicKey);
      expect(session.recoveryVerified, false);
    },
  );
  testWidgets(
    'storage failure remains visible and retry preserves the saved key',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = MemoryStore(fixtureIdentity.recoveryKit)..failRead = true;
      await tester.pumpWidget(RehearsalApp(store: store, sample: fixture));
      await tester.pumpAndSettle();
      expect(find.text('Diagnostic code: KEY_READ_FAILED'), findsOneWidget);
      final restore = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Restore rehearsal key'),
      );
      expect(restore.onPressed, isNull);
      expect(
        find.textContaining('Private contents must not be displayed'),
        findsNothing,
      );
      store.failRead = false;
      await tester.ensureVisible(find.text('Retry loading saved test data'));
      await tester.tap(find.text('Retry loading saved test data'));
      await tester.pumpAndSettle();
      expect(find.text('Diagnostic code: KEY_READ_FAILED'), findsNothing);
      expect(
        find.text('Public fingerprint: ${fixtureIdentity.fingerprint}'),
        findsOneWidget,
      );
      expect(store.value, fixtureIdentity.recoveryKit);
    },
  );
  test(
    'both phone roles bind the same shared order and return its exact transaction hash',
    () {
      final payload = jsonDecode(sharedFixture) as Map;
      for (final role in ['buyer', 'seller']) {
        final identity = RehearsalIdentity(
          ECPrivate.fromBytes([
            ...List<int>.filled(31, 0),
            role == 'buyer' ? 11 : 22,
          ]),
        );
        final order = SharedOrder.parse(
          jsonEncode(payload['contract']),
          identity.publicKey,
          role,
        );
        final request = RehearsalRequest.parse(
          sharedFixture,
          identity,
          role: role,
          sharedOrder: order,
        );
        final result = jsonDecode(request.sign()) as Map;
        expect(result['schema'], 'xbt-shared-rehearsal-signed-v1');
        expect(
          result['contractHash'],
          (payload['contract'] as Map)['contractHash'],
        );
        expect(result['orderId'], order.id);
        expect(result['transactionHash'], payload['approvedTransactionHash']);
        expect(result['signerRole'], role);
        expect(result['signerPublicKey'], identity.publicKey);
      }
    },
  );
  test(
    'shared-order pins persist, require recovery and cannot be silently replaced',
    () async {
      final store = MemoryStore(fixtureIdentity.recoveryKit);
      final session = RehearsalSession(store);
      await session.open();
      final payload = jsonDecode(sharedFixture) as Map;
      final order = SharedOrder.parse(
        jsonEncode(payload['contract']),
        fixtureIdentity.publicKey,
        'buyer',
      );
      await expectLater(session.pinOrder(order), throwsStateError);
      await session.recover(fixtureIdentity.recoveryKit);
      store.fail = true;
      await expectLater(session.pinOrder(order), throwsStateError);
      expect(session.sharedOrder, isNull);
      store.fail = false;
      await session.pinOrder(order);
      final reopened = RehearsalSession(store);
      await reopened.open();
      expect(reopened.sharedOrder!.hash, order.hash);
      expect(reopened.recoveryVerified, false);
      final changed = Map<String, dynamic>.from(payload['contract'] as Map)
        ..remove('contractHash');
      changed['terms'] = '${changed['terms']} Changed after approval.';
      changed['contractHash'] = sha(
        utf8.encode(jsonEncode(sortedJson(changed))),
      );
      final other = SharedOrder.parse(
        jsonEncode(changed),
        fixtureIdentity.publicKey,
        'buyer',
      );
      await expectLater(session.pinOrder(other), throwsFormatException);
      expect(session.sharedOrder!.hash, order.hash);
      expect(
        () => RehearsalRequest.parse(
          fixture,
          fixtureIdentity,
          sharedOrder: order,
        ),
        throwsFormatException,
      );
      expect(
        () => RehearsalRequest.parse(
          jsonEncode({...payload, 'contract': changed}),
          fixtureIdentity,
          sharedOrder: order,
        ),
        throwsFormatException,
      );
    },
  );
  test(
    'shared setup rejects substituted keys, hash, chain, funding and wrong phone',
    () {
      final contract = Map<String, dynamic>.from(
        (jsonDecode(sharedFixture) as Map)['contract'] as Map,
      );
      for (final patch in [
        {'chain': 'main'},
        {'testOnly': false},
        {'contractHash': '0' * 64},
        {'sellerPublicKey': labBuyer},
        {
          'funding': {'bad:0': '500000000'},
        },
        {'depositSats': '100000000'},
      ]) {
        expect(
          () => SharedOrder.parse(
            jsonEncode({...contract, ...patch}),
            fixtureIdentity.publicKey,
            'buyer',
          ),
          throwsFormatException,
        );
      }
      expect(
        () => SharedOrder.parse(
          jsonEncode(contract),
          RehearsalIdentity.generate().publicKey,
          'buyer',
        ),
        throwsFormatException,
      );
      expect(
        () => RehearsalRequest.parse(sharedFixture, fixtureIdentity),
        throwsFormatException,
      );
    },
  );
  test(
    'fresh keys persist across sessions and recover without the original store',
    () async {
      final store = MemoryStore(), first = RehearsalSession(store);
      await first.create();
      final original = first.identity!;
      final reopened = RehearsalSession(store);
      await reopened.open();
      expect(reopened.identity!.publicKey, original.publicKey);
      expect(reopened.recoveryVerified, false);
      final recovered = RehearsalSession(MemoryStore());
      await recovered.recover(original.recoveryKit);
      expect(recovered.identity!.publicKey, original.publicKey);
      expect(recovered.recoveryVerified, true);
      final enrollment = jsonDecode(original.enrollment()) as Map;
      expect(enrollment['chain'], 'regtest');
      expect(enrollment['simulatedDepositSats'], '500000000');
      expect(enrollment.containsKey('privateKey'), false);
      expect(original.enrollment().contains(original.secretHex), false);
      expect(original.enrollment().contains(original.recoveryKit), false);
    },
  );
  test(
    'wrong or corrupted recovery material cannot replace an existing key',
    () async {
      final store = MemoryStore(fixtureIdentity.recoveryKit),
          session = RehearsalSession(store);
      await session.open();
      await expectLater(
        session.recover(RehearsalIdentity.generate().recoveryKit),
        throwsFormatException,
      );
      expect(store.value, fixtureIdentity.recoveryKit);
      for (final bad in [
        'abandon ' * 24,
        '00' * 32,
        'x' * 1000,
        '${fixtureIdentity.recoveryKit}x',
      ]) {
        expect(() => RehearsalIdentity.restore(bad), throwsFormatException);
      }
      store.fail = true;
      await expectLater(
        session.recover(fixtureIdentity.recoveryKit),
        throwsStateError,
      );
      expect(session.recoveryVerified, false);
    },
  );
  test(
    '5-XBT fixture signs only the pinned role destinations and exports no recovery secret',
    () {
      final request = RehearsalRequest.parse(fixture, fixtureIdentity),
          signed = jsonDecode(request.sign()) as Map;
      expect(signed['chain'], 'regtest');
      expect(signed['testOnly'], true);
      expect(signed['scenario'], 'release');
      expect(signed['psbt'], isA<String>());
      expect(request.summary['inputSats'], '500000000');
      expect(request.summary['feeSats'], '1000');
      expect(request.sign().contains(fixtureIdentity.secretHex), false);
      expect(request.sign().contains(fixtureIdentity.recoveryKit), false);
    },
  );
  test(
    'mainnet labels, missing test markers, other amounts and substituted peers are rejected',
    () {
      final base = jsonDecode(fixture) as Map<String, dynamic>;
      for (final patch in [
        {'chain': 'main'},
        {'testOnly': false},
        {'depositSats': '100000000'},
        {'sellerPublicKey': labMarket},
        {'scenario': 'withdraw'},
        {'buyerPublicKey': labSeller},
      ]) {
        expect(
          () => RehearsalRequest.parse(
            jsonEncode({...base, ...patch}),
            fixtureIdentity,
          ),
          throwsFormatException,
        );
      }
      expect(
        () => RehearsalRequest.parse(fixture, RehearsalIdentity.generate()),
        throwsFormatException,
      );
    },
  );
  test(
    'seller enrollment and signing bind the seller identity and reject swapped roles',
    () {
      final seller = RehearsalIdentity(
        ECPrivate.fromBytes([...List<int>.filled(31, 0), 22]),
      );
      expect(
        (jsonDecode(seller.enrollment(role: 'seller')) as Map)['role'],
        'seller',
      );
      final request = RehearsalRequest.parse(fixture, seller, role: 'seller');
      final result = jsonDecode(request.sign()) as Map;
      expect(result['signerRole'], 'seller');
      expect(result['signerPublicKey'], labSeller);
      expect(result['buyerPublicKey'], labBuyer);
      expect(
        () => RehearsalRequest.parse(fixture, seller),
        throwsFormatException,
      );
      expect(
        () => RehearsalRequest.parse(fixture, fixtureIdentity, role: 'seller'),
        throwsFormatException,
      );
      expect(
        () => RehearsalRequest.parse(fixture, seller, role: 'market'),
        throwsFormatException,
      );
    },
  );
  test('buyer and seller recovery kits cannot cross roles', () async {
    final identity = RehearsalIdentity.generate();
    final sellerKit = identity.recoveryKitFor('seller');
    expect(() => RehearsalIdentity.restore(sellerKit), throwsFormatException);
    expect(
      () => RehearsalIdentity.restore(identity.recoveryKit, role: 'seller'),
      throwsFormatException,
    );
    final sellerSession = RehearsalSession(MemoryStore(), role: 'seller');
    await sellerSession.recover(sellerKit);
    expect(sellerSession.identity!.publicKey, identity.publicKey);
    final reopened = RehearsalSession(sellerSession.store, role: 'seller');
    await reopened.open();
    expect(reopened.identity!.publicKey, identity.publicKey);
    await expectLater(
      reopened.recover(identity.recoveryKit),
      throwsFormatException,
    );
  });
  for (final role in ['buyer', 'seller']) {
    for (final shared in [false, true]) {
      testWidgets(
        '$role ${shared ? "shared" : "legacy"} signing stays locked until recovery verification and explicit transaction consent',
        (tester) async {
          final testIdentity = role == 'buyer'
              ? fixtureIdentity
              : RehearsalIdentity(
                  ECPrivate.fromBytes([...List<int>.filled(31, 0), 22]),
                );
          tester.view.physicalSize = const Size(1000, 10000);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          await tester.pumpWidget(
            RehearsalApp(
              role: role,
              store: MemoryStore(testIdentity.recoveryKitFor(role)),
              sample: fixture,
            ),
          );
          await tester.pumpAndSettle();
          await tester.ensureVisible(find.text('Run built-in check'));
          await tester.tap(find.text('Run built-in check'));
          await tester.pumpAndSettle();
          expect(find.text('Built-in check passed'), findsOneWidget);
          FilledButton review() => tester.widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Review test transaction'),
          );
          expect(review().onPressed, isNull);
          final recovery = find.widgetWithText(
            TextField,
            'Private rehearsal recovery kit',
          );
          await tester.ensureVisible(recovery);
          await tester.enterText(recovery, testIdentity.recoveryKitFor(role));
          await tester.ensureVisible(find.text('Verify recovery kit'));
          await tester.tap(find.text('Verify recovery kit'));
          await tester.pumpAndSettle();
          expect(review().onPressed, isNotNull);
          await tester.ensureVisible(find.byKey(const ValueKey('request')));
          await tester.enterText(
            find.byKey(const ValueKey('request')),
            shared ? sharedFixture : fixture,
          );
          if (shared) {
            await tester.tap(find.text('Review shared order setup'));
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 300));
            expect(find.text('Verify both test participants'), findsOneWidget);
            await tester.tap(find.text('Approve these participants'));
            await tester.pumpAndSettle();
          }
          await tester.ensureVisible(find.text('Review test transaction'));
          await tester.tap(find.text('Review test transaction'));
          await tester.pumpAndSettle();
          final sign = find.widgetWithText(
            FilledButton,
            'Sign reviewed test transaction',
          );
          expect(tester.widget<FilledButton>(sign).onPressed, isNull);
          await tester.ensureVisible(find.byType(CheckboxListTile));
          await tester.tap(find.byType(CheckboxListTile));
          await tester.pumpAndSettle();
          await tester.ensureVisible(sign);
          await tester.tap(sign);
          await tester.pumpAndSettle();
          expect(find.text('Sign this test transaction?'), findsOneWidget);
          await tester.tap(find.text('Sign rehearsal'));
          await tester.pumpAndSettle();
          expect(find.text('Copy signed test result'), findsOneWidget);
        },
      );
    }
  }
}
