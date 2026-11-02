import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:xbt_escrow_rehearsal/funding_draft.dart';

void main() {
  final fixture = jsonDecode(File('test-fixtures/funding-draft.json').readAsStringSync()) as Map;
  final draft = fixture['draft'] as Map;
  final keys = fixture['keys'] as Map;
  FundingDraft parse(String role) => FundingDraft.parse(jsonEncode(draft), draft['draftHash'] as String, keys[role] as String, role);
  test('buyer, seller and mediator independently review exact price plus reserve', () {
    for(final role in ['buyer','seller','market']) {
      final d=parse(role);
      expect(d.sellerPrice,'500000000');expect(d.reserve,'10000');expect(d.deposit,'500010000');
    }
  });
  test('phone payout and plan hash match Node for every release/refund/split fixture', () {
    final d=parse('buyer');
    for(final entry in fixture['plans'] as List) {
      final o=entry['options'] as Map;
      expect(d.payout(o['scenario'] as String,o['networkFeeSats'] as String,sellerAwardSats:o['sellerAwardSats'] as String?),entry['expected']);
    }
  });
  test('changed price, network, keys, policy and funding claims fail even if rehashed', () {
    for(final entry in fixture['rejects'] as List) {
      final changed=entry['draft'] as Map;
      expect(()=>FundingDraft.parse(jsonEncode(changed),changed['draftHash'] as String,keys['buyer'] as String,'buyer'),throwsA(anything),reason:entry['name'] as String);
    }
  });
  test('independent draft pin and signer role are required', () {
    expect(()=>FundingDraft.parse(jsonEncode(draft),'0'*64,keys['buyer'] as String,'buyer'),throwsA(anything));
    expect(()=>FundingDraft.parse(jsonEncode(draft),draft['draftHash'] as String,keys['buyer'] as String,'seller'),throwsA(anything));
  });
  test('phone rejects excessive fees and never converts dust change into a fee', () {
    final d=parse('buyer');
    for(final fee in ['999','10001','9455','9999','01']) {
      expect(()=>d.payout('release',fee),throwsA(anything));
    }
    for(final award in ['0','545','500000000','500000001']) {
      expect(()=>d.payout('split-refund','1000',sellerAwardSats:award),throwsA(anything));
    }
  });
}
