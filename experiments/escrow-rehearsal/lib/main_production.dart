// Separate review-candidate entry point. No default mediator or inherited keys.
import 'package:flutter/material.dart';
import 'package:bitcoin_base/bitcoin_base.dart';
import 'production_contract.dart';
import 'production_identity.dart';
import 'production_device_store.dart';
import 'production_app.dart';

void main(){
  WidgetsFlutterBinding.ensureInitialized();
  const role=String.fromEnvironment('PRODUCTION_ROLE'),origin=String.fromEnvironment('PRODUCTION_ORIGIN'),mediator=String.fromEnvironment('PRODUCTION_MEDIATOR_PUBLIC_KEY');
  try{
    ProductionContractReview.origin(origin);if(!['buyer','seller','market'].contains(role)||!RegExp(r'^0[23][a-f0-9]{64}$').hasMatch(mediator))throw StateError('Configuration missing.');ECPublic.fromHex(mediator);
    final session=ProductionIdentitySession(ProductionDeviceStore(),role:role,origin:origin);
    runApp(ProductionReviewApp(session:session,mediatorPublicKey:mediator,enableFundingConsent:const bool.fromEnvironment('PRODUCTION_FUNDING_PROTOCOL'),enablePayoutSigning:const bool.fromEnvironment('PRODUCTION_PAYOUT_SIGNING'),enableMediatorDecisions:const bool.fromEnvironment('PRODUCTION_MEDIATOR_DECISIONS')));
  }catch(_){runApp(const MaterialApp(home:Scaffold(body:SafeArea(child:Padding(padding:EdgeInsets.all(24),child:Text('Production review configuration is missing or invalid. No identity was opened.'))))));}
}
