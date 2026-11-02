import 'production_order_keys.dart';
import 'dart:convert';
import 'package:bitcoin_base/bitcoin_base.dart';
import 'package:blockchain_utils/blockchain_utils.dart' show QuickCrypto;
import 'package:xbt_market_escrow_lab/escrow_signer.dart';
import 'production_contract.dart';
import 'production_funding.dart';

class ProductionSpendReview {
 ProductionSpendReview._(this._data,this.role,this.publicKey);
 final Map<String,dynamic> _data;final String role,publicKey;
 String get reviewJson=>const JsonEncoder.withIndent('  ').convert({'order':_data['authorization']['bundle']['contract']['snapshot'],'decision':_data['decision'],'deposit':_data['deposit'],'outputs':_data['transaction']['outputs'],'transactionHash':_data['transaction']['transactionHash'],'replacementAuthorized':false});
 static void need(bool v){if(!v)throw const FormatException('Production payout mismatch.');}
 static String digest(dynamic v)=>ProductionContractReview.digest(v);
 static void exact(Map v,Set<String> fields)=>ProductionContractReview.exact(v,fields);
 static BigInt sats(dynamic v)=>ProductionContractReview.sats(v);
 static ProductionSpendReview parse(String encoded,{required String expectedRequestHash,required String expectedContractHash,required String expectedFundingTermsHash,required String expectedOrigin,required String ownPublicKey,required String expectedMediatorPublicKey,required String role}){
  need(encoded.length<=80000);final r=Map<String,dynamic>.from(jsonDecode(encoded) as Map);exact(r,{'schema','authorization','deposit','decision','transaction','requestHash'});need(r['schema']=='xbt-production-spend-request-v1'&&ProductionContractReview.hex(expectedRequestHash)&&r['requestHash']==expectedRequestHash&&digest({...r}..remove('requestHash'))==expectedRequestHash);
  final a=Map<String,dynamic>.from(r['authorization'] as Map);exact(a,{'schema','bundle','terms','proofs','acceptedAt','spendingAuthorized','authorizationHash'});need(a['schema']=='xbt-production-funding-authorization-v1'&&a['spendingAuthorized']==false&&digest({...a}..remove('authorizationHash'))==a['authorizationHash']);
  final proofs=Map<String,dynamic>.from(a['proofs'] as Map),accepted=Map<String,dynamic>.from(a['acceptedAt'] as Map),c=Map<String,dynamic>.from(a['bundle']['contract'] as Map);exact(proofs,{'buyer','seller','market'});exact(accepted,{'buyer','seller','market'});need(['buyer','seller','market'].contains(role)&&c['keys'][role]==ownPublicKey);
  for(final who in ['buyer','seller','market']){final p=Map<String,dynamic>.from(proofs[who] as Map);exact(p,{'schema','challenge','signature'});need(p['schema']=='xbt-production-funding-proof-v1'&&accepted[who] is int);
   ProductionFundingReview.parse(jsonEncode({'schema':'xbt-production-funding-request-v1','bundle':a['bundle'],'terms':a['terms'],'challenge':p['challenge']}),expectedContractHash:expectedContractHash,expectedFundingTermsHash:expectedFundingTermsHash,expectedOrigin:expectedOrigin,ownPublicKey:c['keys'][who],expectedMediatorPublicKey:expectedMediatorPublicKey,role:who,now:accepted[who]);
   ProductionFundingReview.verify(c['keys'][who],ProductionFundingReview.messageHash(ProductionFundingReview.domain,p['challenge']),p['signature']);
  }
  final deposit=Map<String,dynamic>.from(r['deposit'] as Map);exact(deposit,{'txid','vout','fundingBlockHash','valueSats','scriptPubKey'});need(ProductionContractReview.hex(deposit['txid'])&&ProductionContractReview.hex(deposit['fundingBlockHash'])&&deposit['vout'] is int&&deposit['vout']>=0&&deposit['vout']<=4294967295&&deposit['valueSats']==c['totalDepositSats']&&deposit['scriptPubKey']==c['scriptPubKey']);
  final d=Map<String,dynamic>.from(r['decision'] as Map);exact(d,{'scenario','by','disputed','reason','networkFeeSats','sellerAwardSats'});need(d['disputed'] is bool&&d['by']==(d['disputed']?'market':'buyer')&&(d['disputed']||d['scenario']=='release'));need(d['reason'] is String&&d['reason'].length>=10&&d['reason'].length<=1000&&!RegExp(r'[\x00-\x1f\x7f]').hasMatch(d['reason']));
  final price=sats(c['sellerPriceSats']),reserve=sats(c['buyerFeeReserveSats']),fee=sats(d['networkFeeSats']);need(fee>=BigInt.from(1000)&&fee<=reserve);BigInt award;
  final eligible=d['disputed']?{'release':['seller','market'],'refund':['buyer','market'],'split-refund':['buyer','seller','market']}[d['scenario']]:['buyer','seller'];need(eligible!=null&&eligible.contains(role));
  if(d['scenario']=='release'){award=price;}else if(d['scenario']=='refund'){award=BigInt.zero;}else if(d['scenario']=='split-refund'){award=sats(d['sellerAwardSats']);}else{throw const FormatException('Unsupported payout.');}
  need(award<=price&&(d['scenario']=='split-refund'||d['sellerAwardSats']==null));final amounts={'buyer':price-award+reserve-fee,'seller':award},outputs=<Map<String,dynamic>>[];
  for(final who in ['buyer','seller']){if(amounts[who]!>BigInt.zero){need(amounts[who]!>=BigInt.from(546));outputs.add({'role':who,'sats':amounts[who].toString(),'scriptPubKey':c['payoutScripts'][who]});}}
  need(outputs.isNotEmpty&&outputs.fold(fee,(BigInt n,o)=>n+BigInt.parse(o['sats']))==sats(c['totalDepositSats']));
  final tx=Map<String,dynamic>.from(r['transaction'] as Map);exact(tx,{'unsignedHex','transactionHash','txid','outputs','psbt'});need(digest(tx['outputs'])==digest(outputs));
  final p=EscrowPsbt.parse(tx['psbt']);need(p.serialize()==tx['psbt']&&p.inputs.length==1&&p.inputs.single.length==3&&p.inputs.single.keys.every(['01','03','05'].contains)&&p.outputs.every((m)=>m.isEmpty));
  need(hex(p.inputs.single['03']!)=='21000000'&&hex(p.tx.version)=='02000000'&&hex(p.tx.locktime)=='00000000'&&hex(p.tx.inputs.single.sequence)=='feffffff');
  final summary=p.review(witnessScript:c['witnessScript'],funding:{'${deposit['txid']}:${deposit['vout']}':deposit['valueSats']},maximumFeeSats:fee);
  need(summary['feeSats']==d['networkFeeSats']&&summary['transactionHash']==tx['transactionHash']&&hex(p.raw)==tx['unsignedHex']);need(hex(QuickCrypto.sha256Hash(QuickCrypto.sha256Hash(p.raw)).reversed.toList())==tx['txid']);
  need(digest(summary['outputs'])==digest([for(final o in outputs){'script':o['scriptPubKey'],'sats':o['sats']}]));
  return ProductionSpendReview._(r,role,ownPublicKey);
 }
 Map<String,dynamic> sign(ECPrivate key,{required bool recoveryVerified,required bool confirmPayout}){
  need(recoveryVerified&&confirmPayout&&key.getPublic().toHex()==publicKey);final a=_data['authorization'] as Map,c=a['bundle']['contract'] as Map,tx=_data['transaction'] as Map,deposit=_data['deposit'] as Map,p=EscrowPsbt.parse(tx['psbt']);
  final signed=p.sign(privateKey:ProductionOrderKeys.signingKey(c,role,key),witnessScript:c['witnessScript'],funding:{'${deposit['txid']}:${deposit['vout']}':deposit['valueSats']},maximumFeeSats:sats(_data['decision']['networkFeeSats']),approvedTransactionHash:tx['transactionHash']);
  return {'schema':'xbt-production-spend-signed-v2','orderId':c['preflight']['orderId'],'contractHash':c['contractHash'],'fundingTermsHash':a['terms']['fundingTermsHash'],'requestHash':_data['requestHash'],'transactionHash':tx['transactionHash'],'signerRole':role,'signerPublicKey':publicKey,'orderPublicKey':c['orderKeys'][role],'psbt':signed};
 }
}
