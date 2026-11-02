import 'dart:convert';
import 'dart:io';
import 'package:bitcoin_base/bitcoin_base.dart';
import 'package:blockchain_utils/blockchain_utils.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xbt_escrow_rehearsal/draft_consent.dart';

void main() {
  final fixture=jsonDecode(File('test-fixtures/draft-consent.json').readAsStringSync()) as Map;
  final entries=fixture['entries'] as List, now=fixture['now'] as int;
  ECPrivate key(Map entry)=>ECPrivate.fromHex((entry['scalar'] as int).toRadixString(16).padLeft(64,'0'));
  DraftConsentRequest parse(Map entry, {int? at, String? audience, String? role, String? hash})=>DraftConsentRequest.parse(
    jsonEncode(entry['request']),expectedDraftHash:hash ?? entry['request']['draft']['draftHash'] as String,
    audience:audience ?? fixture['audience'] as String,ownPublicKey:key(entry).getPublic().toHex(),role:role ?? entry['role'] as String,now:at ?? now);
  test('all three roles produce independent Dart proofs with the Node message digest', () {
    final proofs=<Map<String,dynamic>>[];
    for(final item in entries) {
      final entry=item as Map, request=parse(entry);
      expect(request.messageHash,entry['messageHash']);
      proofs.add(request.sign(key(entry),confirmUnfunded:true,recoveryVerified:true,now:now+1));
    }
    // Public proofs only. Read back by the independent Node verifier.
    Directory('test-results').createSync(recursive:true);
    File('test-results/dart-consent-proofs.json').writeAsStringSync(jsonEncode(proofs));
    for(final proof in proofs) {expect(proof.keys.toSet(),{'schema','challenge','signature'});}
  });
  test('Node signatures verify in Dart against the same domain-separated digest', () {
    for(final entry in entries) {
      final request=parse(entry as Map),proof=entry['nodeProof'] as Map;
      expect(BitcoinSignatureVerifier.fromKeyBytes(BytesUtils.fromHexString(key(entry).getPublic().toHex())).verifyECDSADerSignature(digest:BytesUtils.fromHexString(request.messageHash),signature:base64Decode(proof['signature'] as String)),isTrue);
    }
  });
  test('consent requires deliberate confirmation, recovery verification and the matching private key', () {
    final entry=entries.first as Map,request=parse(entry);
    expect(()=>request.sign(key(entry),confirmUnfunded:false,recoveryVerified:true,now:now),throwsA(anything));
    expect(()=>request.sign(key(entry),confirmUnfunded:true,recoveryVerified:false,now:now),throwsA(anything));
    expect(()=>request.sign(key(entries[1] as Map),confirmUnfunded:true,recoveryVerified:true,now:now),throwsA(anything));
    expect(()=>request.sign(key(entry),confirmUnfunded:true,recoveryVerified:true,now:now+900000),throwsA(anything));
  });
  test('pinned draft, role, audience and challenge expiration cannot be substituted', () {
    final entry=entries.first as Map;
    for(final run in [()=>parse(entry,hash:'0'*64),()=>parse(entry,role:'seller'),()=>parse(entry,audience:'http://127.0.0.1:9999'),()=>parse(entry,at:now-1),()=>parse(entry,at:now+900000)]) {
      expect(run,throwsA(anything));
    }
  });
  test('phone rejects payment purpose, network flags, altered keys and extra fields', () {
    final base=entries.first as Map;
    for(final change in [{'purpose':'send-payment'},{'chain':'mainnet'},{'fundingEnabled':true},{'testOnly':false},{'publicKey':key(entries[1] as Map).getPublic().toHex()},{'expiresAt':now+900001},{'nonce':'bad'},{'extra':true}]) {
      final entry=jsonDecode(jsonEncode(base)) as Map;
      (entry['request']['challenge'] as Map).addAll(change);
      expect(()=>parse(entry),throwsA(anything));
    }
  });
}
