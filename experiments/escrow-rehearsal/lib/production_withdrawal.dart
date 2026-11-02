import 'dart:convert';
import 'package:bitcoin_base/bitcoin_base.dart';
import 'package:blockchain_utils/blockchain_utils.dart';
import 'package:xbt_market_escrow_lab/unified_digest.dart';
import 'production_contract.dart';

// Separate participant-owned P2WPKH withdrawal; no escrow key derivation or network.
class ProductionWithdrawalReview {
 ProductionWithdrawalReview._(this._r,this._tx,this._amount,this._ownScript);
 final Map<String,dynamic> _r;final BtcTransaction _tx;final BigInt _amount;final String _ownScript;
 static void need(bool v){if(!v)throw const FormatException('Withdrawal review mismatch.');}
 static String hex(List<int> b)=>BytesUtils.toHexString(b);
 static List<int> bytes(String h)=>BytesUtils.fromHexString(h);
 static List<int> le(BigInt n,int size)=>[for(var i=0;i<size;i++)((n>> (i*8))&BigInt.from(255)).toInt()];
 static String destinationScript(String address){
  need(address==address.toLowerCase()&&address.startsWith('bc1')&&address.length<=90);
  const chars='qpzry9x8gf2tvdw0s3jn54khce6mua7l';final data=address.substring(3).split('').map(chars.indexOf).toList();need(data.length>=7&&data.every((v)=>v>=0)&&data[0]==0);
  var check=1;for(final v in [3,3,0,2,3,...data]){final top=check>>25;check=((check&0x1ffffff)<<5)^v;for(var i=0;i<5;i++){if(((top>>i)&1)!=0)check^=[0x3b6a57b2,0x26508e6d,0x1ea119fa,0x3d4233dd,0x2a1462b3][i];}}need(check==1);
  var acc=0,bits=0;final program=<int>[];for(final v in data.sublist(1,data.length-6)){acc=((acc<<5)|v)&0xffffff;bits+=5;if(bits>=8){bits-=8;program.add((acc>>bits)&255);}}
  need(bits<5&&((acc<<(8-bits))&255)==0&&[20,32].contains(program.length));return hex([0,program.length,...program]);
 }
 String get reviewJson=>const JsonEncoder.withIndent('  ').convert({'network':'XBT Blake2b mainnet','role':_r['role'],'sourceTxid':_r['parent']['txid'],'sourceOutput':_r['vout'],'inputSats':_r['parent']['valueSats'],'destination':_r['destination'],'receiveSats':_r['outputSats'],'feeSats':_r['feeSats'],'requestHash':_r['requestHash'],'liveConfirmationsVerifiedByPhone':false});
 static ProductionWithdrawalReview parse(String encoded,{required String expectedRequestHash,required String expectedDestination,required String maximumFeeSats,required String expectedOrigin,required String role,required String ownPublicKey}){
  need(encoded.length<=220000);final r=Map<String,dynamic>.from(jsonDecode(encoded) as Map);
  ProductionContractReview.exact(r,{'schema','chainProfile','origin','role','publicKey','parentHex','vout','parent','destination','feeSats','outputSats','unsignedHex','requestHash'});
  need(r['schema']=='xbt-production-withdrawal-request-v1'&&ProductionContractReview.digest(r['chainProfile'])==ProductionContractReview.digest(ProductionContractReview.chain));
  need(['buyer','seller'].contains(role)&&r['role']==role&&r['publicKey']==ownPublicKey&&r['origin']==expectedOrigin&&r['destination']==expectedDestination&&ProductionContractReview.hex(expectedRequestHash)&&r['requestHash']==expectedRequestHash&&ProductionContractReview.digest({...r}..remove('requestHash'))==expectedRequestHash);
  need(RegExp(r'^[1-9][0-9]{0,4}$').hasMatch(maximumFeeSats)&&r['feeSats'] is String&&RegExp(r'^[1-9][0-9]{0,4}$').hasMatch(r['feeSats']));
  final fee=BigInt.parse(r['feeSats']),cap=BigInt.parse(maximumFeeSats);need(cap<=BigInt.from(10000)&&fee<=cap);
  final parentHex=r['parentHex'];need(parentHex is String&&RegExp(r'^(?:[a-f0-9]{2}){10,100000}$').hasMatch(parentHex));
  final parent=BtcTransaction.deserialize(bytes(parentHex));need(parent.toHex()==parentHex&&parent.inputs.isNotEmpty&&parent.inputs.length<=100&&parent.outputs.isNotEmpty&&parent.outputs.length<=100);
  final vout=r['vout'];need(vout is int&&vout>=0&&vout<parent.outputs.length);final selected=parent.outputs[vout];
  final txid=hex(QuickCrypto.sha256Hash(QuickCrypto.sha256Hash(bytes(parentHex))).reversed.toList()),own=ECPublic.fromHex(ownPublicKey).toSegwitAddress().toScriptPubKey().toHex();
  ProductionContractReview.exact(r['parent'],{'txid','valueSats','scriptPubKey'});
  need(r['parent']['txid']==txid&&selected.scriptPubKey.toHex()==own&&r['parent']['scriptPubKey']==own&&r['parent']['valueSats']==selected.amount.toString());
  final amount=selected.amount;need(amount<=BigInt.from(2100000000000000)&&amount-fee>=BigInt.from(546)&&r['outputSats']==(amount-fee).toString());
  final destination=destinationScript(expectedDestination);need(destination!=own);final script=bytes(destination);
  final raw=<int>[2,0,0,0,1,...bytes(txid).reversed,...le(BigInt.from(vout),4),0,254,255,255,255,1,...le(amount-fee,8),script.length,...script,0,0,0,0];
  need(r['unsignedHex']==hex(raw));return ProductionWithdrawalReview._(r,BtcTransaction.deserialize(raw),amount,own);
 }
 Map<String,dynamic> sign(ECPrivate key,{required bool recoveryVerified,required bool confirmWithdrawal}){
  need(recoveryVerified&&confirmWithdrawal&&key.getPublic().toHex()==_r['publicKey']);
  final scriptCode=Script.deserialize(bytes:bytes('76a914${_ownScript.substring(4)}88ac'));
  final digest=escrowDigest(_tx,0,scriptCode,[_amount],[Script.deserialize(bytes:bytes(_ownScript))]);
  final sig=bytes(key.signECDSA(digest,sighash:0x21));need(sig.last==0x21);
  final der=sig.sublist(0,sig.length-1);need(BitcoinSignatureVerifier.fromKeyBytes(bytes(_r['publicKey'])).verifyECDSADerSignature(digest:digest,signature:der));
  return {'schema':'xbt-production-withdrawal-signed-v1','requestHash':_r['requestHash'],'publicKey':_r['publicKey'],'signature':base64Encode(der)};
 }
}
