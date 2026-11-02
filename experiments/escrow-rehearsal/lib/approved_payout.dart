// Offline variable-value payout review. Independent draft and request pins required.
import 'dart:convert';
import 'package:bitcoin_base/bitcoin_base.dart';
import 'package:blockchain_utils/blockchain_utils.dart' show BytesUtils, QuickCrypto;
import 'package:xbt_market_escrow_lab/escrow_signer.dart';
import 'funding_draft.dart';

class ApprovedPayout {
  ApprovedPayout._(this._data, this.role, this.publicKey);
  final Map<String,dynamic> _data;
  final String role, publicKey;
  String get requestHash => _data['requestHash'] as String;
  String get draftHash => (_data['draft'] as Map)['draftHash'] as String;
  String get reviewJson => const JsonEncoder.withIndent('  ').convert(_data);
  String get summary {
    final decision=_data['decision'] as Map,tx=_data['transaction'] as Map;
    final payouts=[for(final o in tx['outputs'] as List) '${o['role']}: ${FundingDraft.xbt(o['sats'] as String)} test XBT'];
    return 'Outcome: ${decision['scenario']}\nDecision by: ${decision['by']}\n${decision['reason']}\n\n${payouts.join('\n')}\nNetwork fee: ${FundingDraft.xbt(tx['networkFeeSats'] as String)} test XBT\nUnused fee reserve is included in the buyer payout.';
  }
  static ApprovedPayout parse(String encoded, {required String expectedRequestHash,
      required String expectedDraftHash,required String ownPublicKey,required String role}) {
    final require=FundingDraft.require, exact=FundingDraft.exact, digest=FundingDraft.digest;
    require(encoded.length<40000);
    final r=Map<String,dynamic>.from(jsonDecode(encoded) as Map);
    exact(r,{'schema','chain','testOnly','draft','receiptHash','decision','transaction','requestHash'});
    require(r['schema']=='xbt-approved-payout-request-v1'&&r['chain']=='regtest'&&r['testOnly']==true);
    final unhashed={...r}..remove('requestHash');
    require(r['requestHash']==expectedRequestHash&&digest(unhashed)==expectedRequestHash);
    require(r['receiptHash'] is String&&RegExp(r'^[a-f0-9]{64}$').hasMatch(r['receiptHash'] as String));
    final draft=FundingDraft.parse(jsonEncode(r['draft']),expectedDraftHash,ownPublicKey,role);
    final d=Map<String,dynamic>.from(r['decision'] as Map);
    exact(d,{'scenario','by','disputed','reason','networkFeeSats','sellerAwardSats'});
    require(d['disputed'] is bool&&d['by']==(d['disputed']==true?'market':'buyer')&&(d['disputed']==true||d['scenario']=='release'));
    require(d['reason'] is String&&(d['reason'] as String).length>=10&&(d['reason'] as String).length<=1000&&!RegExp(r'[\x00-\x1f\x7f]').hasMatch(d['reason'] as String));
    final plan=draft.payout(d['scenario'] as String,d['networkFeeSats'] as String,sellerAwardSats:d['sellerAwardSats'] as String?);
    final tx=Map<String,dynamic>.from(r['transaction'] as Map);
    exact(tx,{'schema','chain','testOnly','draftHash','planHash','pin','input','outputs','networkFeeSats','witnessScript','scriptPubKey','unsignedHex','transactionHash','txid','psbt','fundingEnabled','shippingAuthorized','broadcast'});
    require(tx['schema']=='xbt-approved-draft-test-transaction-v1'&&tx['chain']=='regtest'&&tx['testOnly']==true&&tx['fundingEnabled']==false&&tx['shippingAuthorized']==false&&tx['broadcast']==false&&tx['draftHash']==draft.hash&&tx['planHash']==plan['planHash']&&tx['networkFeeSats']==d['networkFeeSats']);
    final pin=Map<String,dynamic>.from(tx['pin'] as Map);
    exact(pin,{'outpoint','fundingBlockHash'});
    require(pin['fundingBlockHash'] is String&&RegExp(r'^[a-f0-9]{64}$').hasMatch(pin['fundingBlockHash'] as String));
    require(pin['outpoint'] is String&&RegExp(r'^[a-f0-9]{64}:(0|[1-9][0-9]{0,9})$').hasMatch(pin['outpoint'] as String));
    final parts=(pin['outpoint'] as String).split(':');
    require(int.parse(parts[1])<=4294967295);
    require(digest(tx['input'])==digest({'txid':parts[0],'vout':int.parse(parts[1])}));
    final keys=((r['draft'] as Map)['keys'] as Map).values.cast<String>().toList()..sort();
    final witness='52${keys.map((k)=>'21$k').join()}53ae';
    require(tx['witnessScript']==witness&&tx['scriptPubKey']=='0020${sha(BytesUtils.fromHexString(witness))}');
    final outputs=[for(final p in plan['payouts'] as List) {'role':p['role'],'sats':p['sats'],'scriptPubKey':ECPublic.fromHex(p['publicKey'] as String).toSegwitAddress().toScriptPubKey().toHex()}];
    require(digest(tx['outputs'])==digest(outputs));
    final psbt=EscrowPsbt.parse(tx['psbt'] as String);
    require(psbt.serialize()==tx['psbt']);
    require(psbt.inputs.single.keys.toSet().length==3&&psbt.inputs.single.keys.every(['01','03','05'].contains)&&psbt.outputs.every((m)=>m.isEmpty));
    require(hex(psbt.inputs.single['03']!)=='21000000'&&hex(psbt.tx.version)=='02000000'&&hex(psbt.tx.locktime)=='00000000'&&hex(psbt.tx.inputs.single.sequence)=='fdffffff');
    final summary=psbt.review(witnessScript:witness,funding:{pin['outpoint'] as String:draft.deposit},maximumFeeSats:BigInt.parse(d['networkFeeSats'] as String));
    require(summary['feeSats']==d['networkFeeSats']&&summary['transactionHash']==tx['transactionHash']&&hex(psbt.raw)==tx['unsignedHex']);
    require(hex(QuickCrypto.sha256Hash(QuickCrypto.sha256Hash(psbt.raw)).reversed.toList())==tx['txid']);
    require(digest(summary['outputs'])==digest([for(final o in outputs){'script':o['scriptPubKey'],'sats':o['sats']}]));
    return ApprovedPayout._(r,role,ownPublicKey);
  }
  Map<String,dynamic> sign(ECPrivate key,{required bool recoveryVerified,required bool confirmPayout}) {
    FundingDraft.require(recoveryVerified&&confirmPayout&&key.getPublic().toHex()==publicKey);
    final tx=_data['transaction'] as Map,draft=_data['draft'] as Map;
    final psbt=EscrowPsbt.parse(tx['psbt'] as String);
    final result=psbt.sign(privateKey:key,witnessScript:tx['witnessScript'] as String,
      funding:{(tx['pin'] as Map)['outpoint'] as String:draft['totalDepositSats'] as String},
      maximumFeeSats:BigInt.parse(tx['networkFeeSats'] as String),approvedTransactionHash:tx['transactionHash'] as String);
    return {'schema':'xbt-approved-payout-signed-v1','chain':'regtest','testOnly':true,'orderId':draft['orderId'],'draftHash':draftHash,
      'requestHash':requestHash,'transactionHash':tx['transactionHash'],'signerRole':role,'signerPublicKey':publicKey,'psbt':result};
  }
}

