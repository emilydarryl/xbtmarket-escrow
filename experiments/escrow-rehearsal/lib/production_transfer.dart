import 'production_withdrawal.dart';
import 'dart:convert';
import 'production_contract.dart';
import 'production_funding.dart';
import 'production_resolution.dart';
import 'production_spend.dart';
import 'production_identity.dart';

// Transport is not authentication. The user compares the code with their
// authenticated order, then reviews terms; existing verifiers still run twice.
class ProductionTransfer {
  ProductionTransfer._(this.envelope,this.request,this.contract,this.termsHash,this.kind);
  final Map<String,dynamic> envelope,request,contract;
  final String? termsHash;
  final String kind;
  String get encoded=>jsonEncode(request);
  String get code=>RegExp('.{4}').allMatches(ProductionContractReview.digest(envelope).substring(0,16)).map((m)=>m.group(0)).join(' ');
  String get orderId=>kind=='connect'?request['orderId'] as String:contract['preflight']['orderId'] as String;
  String get title=>kind=='connect'?'Connect my signer':contract['snapshot']['title'] as String;
  String get terms=>kind=='connect'?'Select this public identity for this order. Ownership is verified later by your signed agreement.':contract['snapshot']['terms'] as String;
  String get action=>{'connect':'Connect signer for this order','contract':'Approve agreement','funding':'Authorize deposit terms','resolution':'Approve dispute decision','spend':'Sign exact payout','withdrawal':'Sign withdrawal to my wallet'}[kind]!;
  static ProductionTransfer parse(String text,ProductionIdentitySession s,String mediator,int now){
    if(text.length>100000)throw const FormatException('Request too large');
    final e=Map<String,dynamic>.from(jsonDecode(text) as Map);
    ProductionContractReview.exact(e,{'schema','origin','role','request'});
    if(e['schema']!='xbt-signer-transfer-v1'||e['origin']!=s.origin||e['role']!=s.role||s.publicKey==null)throw const FormatException('Wrong origin or signer');
    final r=Map<String,dynamic>.from(e['request'] as Map);
    late Map<String,dynamic> c;String? t;late String kind;
    switch(r['schema']){
      case 'xbt-signer-connect-request-v1':c={};kind='connect';
      case 'xbt-production-contract-request-v1':c=Map<String,dynamic>.from(r['contract'] as Map);kind='contract';
      case 'xbt-production-funding-request-v1':c=Map<String,dynamic>.from(r['bundle']['contract'] as Map);t=r['terms']['fundingTermsHash'] as String;kind='funding';
      case 'xbt-production-resolution-request-v1':c=Map<String,dynamic>.from(r['payoutRequest']['authorization']['bundle']['contract'] as Map);t=r['payoutRequest']['authorization']['terms']['fundingTermsHash'] as String;kind='resolution';
      case 'xbt-order-withdrawal-request-v1':c=Map<String,dynamic>.from(r['payoutRequest']['authorization']['bundle']['contract'] as Map);t=r['payoutRequest']['authorization']['terms']['fundingTermsHash'] as String;kind='withdrawal';
      case 'xbt-production-spend-request-v1':c=Map<String,dynamic>.from(r['authorization']['bundle']['contract'] as Map);t=r['authorization']['terms']['fundingTermsHash'] as String;kind='spend';
      default:throw const FormatException('Only public order requests are supported');
    }
    final value=ProductionTransfer._(e,r,c,t,kind);value.validate(s,mediator,now);return value;
  }
  void validate(ProductionIdentitySession s,String mediator,int now){
    if(envelope['origin']!=s.origin||envelope['role']!=s.role||s.publicKey==null)throw const FormatException('Signer changed');
    if(kind=='connect'){
      ProductionContractReview.exact(request,{'schema','origin','role','orderId','expectedPreflightHash','sellerId'});
      final uuid=RegExp(r'^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$');
      if(request['origin']!=s.origin||request['role']!=s.role||!['buyer','seller'].contains(s.role)||!uuid.hasMatch(request['orderId'] as String)||!RegExp(r'^[a-f0-9]{64}$').hasMatch(request['expectedPreflightHash'] as String)||(s.role=='seller'?!uuid.hasMatch(request['sellerId'] as String):request['sellerId']!=null))throw const FormatException('Invalid signer connection');
      return;
    }
    if(kind=='withdrawal'){
      ProductionContractReview.exact(request,{'schema','payoutRequest','withdrawal'});
      if(!['buyer','seller'].contains(s.role))throw const FormatException('Participant required');
      final p=request['payoutRequest'] as Map,w=request['withdrawal'] as Map;
      // Validate the full payout without signing it. A refund/reserve recipient
      // need not be one of the eligible escrow-payout co-signers.
      if(contract['keys'][s.role]!=s.publicKey)throw const FormatException('Participant key changed');
      final verifierRole=p['decision']['disputed']==true?'market':s.role;
      ProductionSpendReview.parse(jsonEncode(p),expectedRequestHash:p['requestHash'] as String,expectedContractHash:contract['contractHash'] as String,expectedFundingTermsHash:termsHash!,expectedOrigin:s.origin,ownPublicKey:contract['keys'][verifierRole] as String,expectedMediatorPublicKey:mediator,role:verifierRole);
      if(w['parentHex']!=p['transaction']['unsignedHex']||w['parent']['txid']!=p['transaction']['txid'])throw const FormatException('Withdrawal payout changed');
      ProductionWithdrawalReview.parse(jsonEncode(w),expectedRequestHash:w['requestHash'] as String,expectedDestination:w['destination'] as String,maximumFeeSats:w['feeSats'] as String,expectedOrigin:s.origin,role:s.role,ownPublicKey:s.publicKey!);
      return;
    }
    final hash=contract['contractHash'] as String;
    switch(kind){
      case 'contract':ProductionContractReview.parse(encoded,expectedContractHash:hash,expectedOrigin:s.origin,ownPublicKey:s.publicKey!,expectedMediatorPublicKey:mediator,role:s.role,now:now);
      case 'funding':ProductionFundingReview.parse(encoded,expectedContractHash:hash,expectedFundingTermsHash:termsHash!,expectedOrigin:s.origin,ownPublicKey:s.publicKey!,expectedMediatorPublicKey:mediator,role:s.role,now:now);
      case 'resolution':
        if(s.role!='market'||s.publicKey!=mediator)throw const FormatException('Mediator required');
        ProductionResolutionReview.parse(encoded,expectedDecisionHash:request['decisionHash'] as String,expectedContractHash:hash,expectedFundingTermsHash:termsHash!,expectedOrigin:s.origin,ownPublicKey:s.publicKey!,now:now);
      case 'spend':ProductionSpendReview.parse(encoded,expectedRequestHash:request['requestHash'] as String,expectedContractHash:hash,expectedFundingTermsHash:termsHash!,expectedOrigin:s.origin,ownPublicKey:s.publicKey!,expectedMediatorPublicKey:mediator,role:s.role);
    }
  }
  Map<String,dynamic> approve(ProductionIdentitySession s,String mediator,int now){
    validate(s,mediator,now);
    if(kind=='withdrawal'){
      final w=request['withdrawal'] as Map;
      return {'schema':'xbt-order-withdrawal-signed-v1','orderId':orderId,'requestHash':w['requestHash'],'result':s.signWithdrawal(jsonEncode(w),expectedRequestHash:w['requestHash'] as String,expectedDestination:w['destination'] as String,maximumFeeSats:w['feeSats'] as String,confirmWithdrawal:true)};
    }
    if(kind=='connect')return {'schema':'xbt-signer-selection-v1','orderId':orderId,'expectedPreflightHash':request['expectedPreflightHash'],'enrollment':s.enrollment()};
    final hash=contract['contractHash'] as String;
    switch(kind){
      case 'contract':return s.signReview(encoded,expectedContractHash:hash,expectedMediatorPublicKey:mediator,confirmReview:true,now:now);
      case 'funding':return s.signFunding(encoded,expectedContractHash:hash,expectedFundingTermsHash:termsHash!,expectedMediatorPublicKey:mediator,confirmDeposit:true,now:now);
      case 'resolution':return s.signResolution(encoded,expectedDecisionHash:request['decisionHash'] as String,expectedContractHash:hash,expectedFundingTermsHash:termsHash!,confirmDecision:true,now:now);
      case 'spend':return s.signSpend(encoded,expectedRequestHash:request['requestHash'] as String,expectedContractHash:hash,expectedFundingTermsHash:termsHash!,expectedMediatorPublicKey:mediator,confirmPayout:true);
      default:throw StateError('Unsupported request');
    }
  }
}
