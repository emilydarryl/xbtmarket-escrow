// Domain-separated consent signature only. Never a PSBT or spend signature.
import 'dart:convert';
import 'package:bitcoin_base/bitcoin_base.dart';
import 'package:blockchain_utils/blockchain_utils.dart';
import 'package:xbt_market_escrow_lab/escrow_signer.dart' show sha;
import 'shared_order.dart' show sortedJson;
import 'funding_draft.dart';

class DraftConsentRequest {
  DraftConsentRequest._(this.draft, this._challenge, this.role, this.publicKey);
  final FundingDraft draft;
  final Map<String,dynamic> _challenge;
  final String role, publicKey;
  static const domain = 'XBT Market: approve an UNFUNDED REGTEST contract, not a payment. v1\n';
  String get messageHash => sha(utf8.encode(domain+jsonEncode(sortedJson(_challenge))));
  int get expiresAt => _challenge['expiresAt'] as int;
  static DraftConsentRequest parse(String encoded, {
    required String expectedDraftHash, required String audience,
    required String ownPublicKey, required String role, required int now,
  }) {
    FundingDraft.require(encoded.length<=40000);
    final input=Map<String,dynamic>.from(jsonDecode(encoded) as Map);
    FundingDraft.exact(input, {'schema','draft','challenge'});
    FundingDraft.require(input['schema']=='xbt-unfunded-consent-request-v1');
    final draft=FundingDraft.parse(jsonEncode(input['draft']),expectedDraftHash,ownPublicKey,role);
    final c=Map<String,dynamic>.from(input['challenge'] as Map);
    FundingDraft.exact(c, {'schema','purpose','chain','testOnly','fundingEnabled','audience','orderId','draftHash','setupRevision','role','publicKey','nonce','issuedAt','expiresAt'});
    final url=Uri.parse(audience);
    FundingDraft.require(url.origin==audience && url.scheme=='http' && url.host=='127.0.0.1' && url.port>0 && url.port<=65535);
    FundingDraft.require(c['schema']=='xbt-unfunded-consent-challenge-v1' && c['purpose']=='approve-unfunded-regtest-draft' && c['chain']=='regtest' && c['testOnly']==true && c['fundingEnabled']==false);
    final data=input['draft'] as Map;
    FundingDraft.require(c['audience']==audience && c['orderId']==data['orderId'] && c['draftHash']==expectedDraftHash && c['setupRevision']==data['setupRevision'] && c['role']==role && c['publicKey']==ownPublicKey);
    FundingDraft.require(c['nonce'] is String && RegExp(r'^[a-f0-9]{64}$').hasMatch(c['nonce'] as String));
    FundingDraft.require(c['issuedAt'] is int && c['expiresAt'] is int && c['issuedAt']>=0 && c['expiresAt']<=9007199254740991 && c['expiresAt']-c['issuedAt']==900000 && now>=c['issuedAt'] && now<c['expiresAt']);
    return DraftConsentRequest._(draft,c,role,ownPublicKey);
  }

  Map<String,dynamic> sign(ECPrivate key, {required bool confirmUnfunded, required bool recoveryVerified, required int now}) {
    FundingDraft.require(confirmUnfunded && recoveryVerified && key.getPublic().toHex()==publicKey && now>=_challenge['issuedAt'] && now<expiresAt);
    final digest=BytesUtils.fromHexString(messageHash);
    // The library appends a sighash byte. Remove it: this is a message proof,
    // not a Bitcoin transaction signature or BIP-322 spend.
    final encoded=BytesUtils.fromHexString(key.signECDSA(digest,sighash:1));
    final signature=encoded.sublist(0,encoded.length-1);
    FundingDraft.require(BitcoinSignatureVerifier.fromKeyBytes(BytesUtils.fromHexString(publicKey)).verifyECDSADerSignature(digest:digest,signature:signature));
    return {'schema':'xbt-unfunded-consent-proof-v1','challenge':jsonDecode(jsonEncode(_challenge)),'signature':base64Encode(signature)};
  }
}
