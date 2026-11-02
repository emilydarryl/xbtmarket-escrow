import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'production_identity.dart';
import 'production_funding.dart';

class ProductionFundingPanel extends StatefulWidget {
 const ProductionFundingPanel({super.key,required this.session,required this.mediatorPublicKey,this.lockGeneration=0});
 final int lockGeneration;
 final ProductionIdentitySession session;
 final String mediatorPublicKey;
 @override State<ProductionFundingPanel> createState()=>_ProductionFundingPanelState();
}
class _ProductionFundingPanelState extends State<ProductionFundingPanel> with WidgetsBindingObserver {
 final request=TextEditingController(),contract=TextEditingController(),terms=TextEditingController();
 ProductionFundingReview? review;bool confirmed=false;String result='',message='';
 @override void initState(){super.initState();WidgetsBinding.instance.addObserver(this);for(final c in [request,contract,terms]){c.addListener(invalidate);}}
 void invalidate(){if(mounted)setState((){review=null;confirmed=false;result='';message='';});}
 @override void didChangeAppLifecycleState(AppLifecycleState state){if(state!=AppLifecycleState.resumed)invalidate();}
 @override void didUpdateWidget(covariant ProductionFundingPanel oldWidget){super.didUpdateWidget(oldWidget);if(oldWidget.lockGeneration!=widget.lockGeneration)invalidate();}
 @override void dispose(){WidgetsBinding.instance.removeObserver(this);for(final c in [request,contract,terms]){c.removeListener(invalidate);c.clear();c.dispose();}super.dispose();}
 void inspect(){invalidate();try{final s=widget.session;if(!s.recoveryVerified)throw StateError('Recovery required.');final value=ProductionFundingReview.parse(request.text,expectedContractHash:contract.text,expectedFundingTermsHash:terms.text,expectedOrigin:s.origin,ownPublicKey:s.publicKey!,expectedMediatorPublicKey:widget.mediatorPublicKey,role:s.role,now:DateTime.now().millisecondsSinceEpoch);setState(()=>review=value);}catch(_){setState(()=>message='Funding request could not be reviewed. Check the independent hashes, keys, origin and expiry.');}}
 void approve(){try{if(review==null||!confirmed)throw StateError('Confirm funding terms.');final proof=widget.session.signFunding(request.text,expectedContractHash:contract.text,expectedFundingTermsHash:terms.text,expectedMediatorPublicKey:widget.mediatorPublicKey,confirmDeposit:confirmed,now:DateTime.now().millisecondsSinceEpoch);setState((){result=jsonEncode(proof);confirmed=false;message='Public funding consent created. No transaction was signed or sent.';});}catch(_){invalidate();setState(()=>message='Funding approval stopped. Review the current request again.');}}
 Widget field(String name,String label,TextEditingController c,int max,int lines)=>Padding(padding:const EdgeInsets.only(bottom:12),child:TextField(key:ValueKey('funding-$name'),controller:c,maxLength:max,maxLines:lines,autocorrect:false,enableSuggestions:false,decoration:InputDecoration(labelText:label,border:const OutlineInputBorder(),counterText:'')));
 @override Widget build(BuildContext context)=>Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
  const Divider(),const Text('Separate funding authorization'),
  const Text('After all three funding approvals, this order requires permanent deposit reconciliation. The earlier unfunded withdrawal action will no longer unlock it. This consent does not authorize spending.'),
  field('contract','Independently copied contract hash',contract,64,1),field('terms','Independently copied funding terms hash',terms,64,1),field('request','Public funding request JSON',request,50000,6),
  TextButton(onPressed:(){for(final c in [request,contract,terms]){c.clear();}},child:const Text('Clear public funding fields')),
  FilledButton(key:const ValueKey('funding-review'),onPressed:widget.session.recoveryVerified?inspect:null,child:const Text('Review exact deposit authorization')),
  if(message.isNotEmpty)Text(message),
  if(review!=null)...[SelectableText(review!.reviewJson,key:const ValueKey('funding-reviewed')),CheckboxListTile(key:const ValueKey('funding-confirm'),value:confirmed,onChanged:(v)=>setState(()=>confirmed=v??false),title:const Text('I authorize the exact deposit terms and permanent reconciliation requirement.'))],
  FilledButton(key:const ValueKey('funding-sign'),onPressed:review!=null&&confirmed&&widget.session.recoveryVerified?approve:null,child:const Text('Create public funding consent')),
  if(result.isNotEmpty)...[SelectableText(result,key:const ValueKey('funding-result')),TextButton(onPressed:()=>Clipboard.setData(ClipboardData(text:result)),child:const Text('Copy public funding consent'))],
 ]);
}
