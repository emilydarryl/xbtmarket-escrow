import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'production_identity.dart';
import 'production_spend.dart';

class ProductionSpendPanel extends StatefulWidget {
 const ProductionSpendPanel({super.key,required this.session,required this.mediatorPublicKey,this.lockGeneration=0});
 final int lockGeneration;
 final ProductionIdentitySession session;
 final String mediatorPublicKey;
 @override State<ProductionSpendPanel> createState()=>_ProductionSpendPanelState();
}
class _ProductionSpendPanelState extends State<ProductionSpendPanel> with WidgetsBindingObserver {
 final request=TextEditingController(),contract=TextEditingController(),terms=TextEditingController(),payout=TextEditingController();
 ProductionSpendReview? review;bool confirmed=false;String result='',message='';
 @override void initState(){super.initState();WidgetsBinding.instance.addObserver(this);for(final c in [request,contract,terms,payout]){c.addListener(invalidate);}}
 void invalidate(){if(mounted)setState((){review=null;confirmed=false;result='';message='';});}
 @override void didChangeAppLifecycleState(AppLifecycleState state){if(state!=AppLifecycleState.resumed)invalidate();}
 @override void didUpdateWidget(covariant ProductionSpendPanel oldWidget){super.didUpdateWidget(oldWidget);if(oldWidget.lockGeneration!=widget.lockGeneration)invalidate();}
 @override void dispose(){WidgetsBinding.instance.removeObserver(this);for(final c in [request,contract,terms,payout]){c.removeListener(invalidate);c.clear();c.dispose();}super.dispose();}
 void inspect(){invalidate();try{final s=widget.session;if(!s.recoveryVerified)throw StateError('Recovery required.');final value=ProductionSpendReview.parse(request.text,expectedRequestHash:payout.text,expectedContractHash:contract.text,expectedFundingTermsHash:terms.text,expectedOrigin:s.origin,ownPublicKey:s.publicKey!,expectedMediatorPublicKey:widget.mediatorPublicKey,role:s.role);setState(()=>review=value);}catch(_){setState(()=>message='Payout request could not be reviewed. Check all independent hashes, keys, origin and outputs.');}}
 void approve(){try{if(review==null||!confirmed)throw StateError('Confirm exact payout.');final proof=widget.session.signSpend(request.text,expectedRequestHash:payout.text,expectedContractHash:contract.text,expectedFundingTermsHash:terms.text,expectedMediatorPublicKey:widget.mediatorPublicKey,confirmPayout:confirmed);setState((){result=jsonEncode(proof);confirmed=false;message='Public payout signature created. It can authorize spending when combined with another required signature. Nothing was broadcast.';});}catch(_){invalidate();setState(()=>message='Payout signing stopped. Review the current request again.');}}
 Widget field(String name,String label,TextEditingController c,int max,int lines)=>Padding(padding:const EdgeInsets.only(bottom:12),child:TextField(key:ValueKey('spend-$name'),controller:c,maxLength:max,maxLines:lines,autocorrect:false,enableSuggestions:false,decoration:InputDecoration(labelText:label,border:const OutlineInputBorder(),counterText:'')));
 @override Widget build(BuildContext context)=>Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
  const Divider(),const Text('Exact payout signing'),
  const Text('A payout signature can authorize spending. Independently compare the contract, funding and payout hashes. Inspect every output and fee. This offline app does not verify live confirmations or broadcast transactions.'),
  field('contract','Independently copied contract hash',contract,64,1),field('terms','Independently copied funding terms hash',terms,64,1),field('payout','Independently copied payout request hash',payout,64,1),field('request','Public payout request JSON',request,50000,6),
  TextButton(onPressed:(){for(final c in [request,contract,terms,payout]){c.clear();}},child:const Text('Clear public payout fields')),
  FilledButton(key:const ValueKey('spend-review'),onPressed:widget.session.recoveryVerified?inspect:null,child:const Text('Review exact payout')),
  if(message.isNotEmpty)Text(message),
  if(review!=null)...[SelectableText(review!.reviewJson,key:const ValueKey('spend-reviewed')),CheckboxListTile(key:const ValueKey('spend-confirm'),value:confirmed,onChanged:(v)=>setState(()=>confirmed=v??false),title:const Text('I checked the recipients, amounts, fee and decision and authorize this exact payout.'))],
  FilledButton(key:const ValueKey('spend-sign'),onPressed:review!=null&&confirmed&&widget.session.recoveryVerified?approve:null,child:const Text('Create public payout signature')),
  if(result.isNotEmpty)...[SelectableText(result,key:const ValueKey('spend-result')),TextButton(onPressed:()=>Clipboard.setData(ClipboardData(text:result)),child:const Text('Copy public payout signature'))],
 ]);
}
