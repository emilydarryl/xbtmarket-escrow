import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'production_identity.dart';
import 'production_resolution.dart';

class ProductionResolutionPanel extends StatefulWidget {
 const ProductionResolutionPanel({super.key,required this.session,this.lockGeneration=0,this.now});
 final ProductionIdentitySession session;
 final int lockGeneration;
 final int Function()? now;
 @override State<ProductionResolutionPanel> createState()=>_ProductionResolutionPanelState();
}
class _ProductionResolutionPanelState extends State<ProductionResolutionPanel> with WidgetsBindingObserver {
 final request=TextEditingController(),contract=TextEditingController(),terms=TextEditingController(),decision=TextEditingController();
 ProductionResolutionReview? review;bool confirmed=false;String result='',message='';
 int get now=>widget.now?.call()??DateTime.now().millisecondsSinceEpoch;
 bool get ready=>widget.session.role=='market'&&widget.session.recoveryVerified;
 @override void initState(){super.initState();WidgetsBinding.instance.addObserver(this);for(final c in [request,contract,terms,decision]){c.addListener(invalidate);}}
 void invalidate(){if(mounted)setState((){review=null;confirmed=false;result='';message='';});}
 @override void didChangeAppLifecycleState(AppLifecycleState state){if(state!=AppLifecycleState.resumed)invalidate();}
 @override void didUpdateWidget(covariant ProductionResolutionPanel oldWidget){super.didUpdateWidget(oldWidget);if(oldWidget.lockGeneration!=widget.lockGeneration)invalidate();}
 @override void dispose(){WidgetsBinding.instance.removeObserver(this);for(final c in [request,contract,terms,decision]){c.removeListener(invalidate);c.clear();c.dispose();}super.dispose();}
 void inspect(){invalidate();try{if(!ready)throw StateError('Verified mediator required');final checked=ProductionResolutionReview.parse(request.text,expectedDecisionHash:decision.text,expectedContractHash:contract.text,expectedFundingTermsHash:terms.text,expectedOrigin:widget.session.origin,ownPublicKey:widget.session.publicKey!,now:now);setState(()=>review=checked);}catch(_){setState(()=>message='Decision could not be reviewed. Check the mediator identity, independent hashes, dispute and expiry.');}}
 void approve(){try{if(!ready||review==null||!confirmed)throw StateError('Confirmed review required');final proof=widget.session.signResolution(request.text,expectedDecisionHash:decision.text,expectedContractHash:contract.text,expectedFundingTermsHash:terms.text,confirmDecision:confirmed,now:now);setState((){result=jsonEncode(proof);confirmed=false;message='Public mediator decision approval created. This does not sign or broadcast a payout transaction.';});}catch(_){invalidate();setState(()=>message='Decision approval stopped. Review the current request again.');}}
 Widget field(String name,String label,TextEditingController c,int max,int lines)=>Padding(padding:const EdgeInsets.only(bottom:12),child:TextField(key:ValueKey('resolution-$name'),controller:c,maxLength:max,maxLines:lines,autocorrect:false,enableSuggestions:false,decoration:InputDecoration(labelText:label,border:const OutlineInputBorder(),counterText:'')));
 @override Widget build(BuildContext context)=>Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
  const Divider(),const Text('Mediator decision review'),
  const Text('Compare the dispute, exact payout recipients, amounts and fee. Approving this selection is separate from signing its payout transaction.'),
  field('contract','Independently copied contract hash',contract,64,1),field('terms','Independently copied funding terms hash',terms,64,1),field('decision','Independently copied decision hash',decision,64,1),field('request','Public mediator decision request JSON',request,100000,6),
  TextButton(onPressed:(){for(final c in [request,contract,terms,decision]){c.clear();}},child:const Text('Clear public decision fields')),
  FilledButton(key:const ValueKey('resolution-review'),onPressed:ready?inspect:null,child:const Text('Review mediator decision')),
  if(message.isNotEmpty)Text(message),
  if(review!=null)...[SelectableText(review!.reviewJson,key:const ValueKey('resolution-reviewed')),CheckboxListTile(key:const ValueKey('resolution-confirm'),value:confirmed,onChanged:(v)=>setState(()=>confirmed=v??false),title:const Text('I checked the dispute and exact payout and approve this mediator decision.'))],
  FilledButton(key:const ValueKey('resolution-sign'),onPressed:ready&&review!=null&&confirmed?approve:null,child:const Text('Create public mediator approval')),
  if(result.isNotEmpty)...[SelectableText(result,key:const ValueKey('resolution-result')),TextButton(onPressed:()=>Clipboard.setData(ClipboardData(text:result)),child:const Text('Copy public mediator approval'))],
 ]);
}
