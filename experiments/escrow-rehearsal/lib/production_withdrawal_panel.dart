import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'production_identity.dart';
import 'production_withdrawal.dart';

class ProductionWithdrawalPanel extends StatefulWidget {
 const ProductionWithdrawalPanel({super.key,required this.session,this.lockGeneration=0});
 final int lockGeneration;
 final ProductionIdentitySession session;

 @override State<ProductionWithdrawalPanel> createState()=>_ProductionWithdrawalPanelState();
}
class _ProductionWithdrawalPanelState extends State<ProductionWithdrawalPanel> with WidgetsBindingObserver {
 final request=TextEditingController(),destination=TextEditingController(),fee=TextEditingController(text:'1000'),payout=TextEditingController();
 ProductionWithdrawalReview? review;bool confirmed=false;String result='',message='';
 @override void initState(){super.initState();WidgetsBinding.instance.addObserver(this);for(final c in [request,destination,fee,payout]){c.addListener(invalidate);}}
 void invalidate(){if(mounted)setState((){review=null;confirmed=false;result='';message='';});}
 @override void didChangeAppLifecycleState(AppLifecycleState state){if(state!=AppLifecycleState.resumed)invalidate();}
 @override void didUpdateWidget(covariant ProductionWithdrawalPanel oldWidget){super.didUpdateWidget(oldWidget);if(oldWidget.lockGeneration!=widget.lockGeneration)invalidate();}
 @override void dispose(){WidgetsBinding.instance.removeObserver(this);for(final c in [request,destination,fee,payout]){c.removeListener(invalidate);c.clear();c.dispose();}super.dispose();}
 void inspect(){invalidate();try{final s=widget.session;if(!s.recoveryVerified)throw StateError('Recovery required.');final value=ProductionWithdrawalReview.parse(request.text,expectedRequestHash:payout.text,expectedDestination:destination.text,maximumFeeSats:fee.text,expectedOrigin:s.origin,ownPublicKey:s.publicKey!,role:s.role);setState(()=>review=value);}catch(_){setState(()=>message='Withdrawal could not be reviewed. Check your wallet address, request hash, fee limit and recovery verification.');}}
 void approve(){try{if(review==null||!confirmed)throw StateError('Confirm exact payout.');final proof=widget.session.signWithdrawal(request.text,expectedRequestHash:payout.text,expectedDestination:destination.text,maximumFeeSats:fee.text,confirmWithdrawal:confirmed);setState((){result=jsonEncode(proof);confirmed=false;message='Withdrawal signature created. It authorizes this transfer without another signer. Nothing was broadcast.';});}catch(_){invalidate();setState(()=>message='Withdrawal stopped. Review the current request again.');}}
 Widget field(String name,String label,TextEditingController c,int max,int lines)=>Padding(padding:const EdgeInsets.only(bottom:12),child:TextField(key:ValueKey('withdrawal-$name'),controller:c,maxLength:max,maxLines:lines,autocorrect:false,enableSuggestions:false,decoration:InputDecoration(labelText:label,border:const OutlineInputBorder(),counterText:'')));
 @override Widget build(BuildContext context)=>Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
  const Divider(),const Text('Withdraw to my wallet'),
  const Text('Move a received refund or seller payment to your XBT wallet. Copy the receive address directly from your wallet. Check the amount and fee. This offline app cannot verify current confirmations or whether the output is unspent. Your signature authorizes spending; no second signer is required.'),
  field('destination','Receive address copied from my XBT wallet',destination,90,2),field('fee','Maximum network fee (sats, at most 10000)',fee,5,1),field('payout','Independently copied withdrawal request hash',payout,64,1),field('request','Public withdrawal request JSON',request,220000,6),
  TextButton(onPressed:(){for(final c in [request,destination,fee,payout]){c.clear();}},child:const Text('Clear public withdrawal fields')),
  FilledButton(key:const ValueKey('withdrawal-review'),onPressed:widget.session.recoveryVerified?inspect:null,child:const Text('Review withdrawal')),
  if(message.isNotEmpty)Text(message),
  if(review!=null)...[SelectableText(review!.reviewJson,key:const ValueKey('withdrawal-reviewed')),CheckboxListTile(key:const ValueKey('withdrawal-confirm'),value:confirmed,onChanged:(v)=>setState(()=>confirmed=v??false),title:const Text('I checked my wallet address, amount and fee and authorize this withdrawal.'))],
  FilledButton(key:const ValueKey('withdrawal-sign'),onPressed:review!=null&&confirmed&&widget.session.recoveryVerified?approve:null,child:const Text('Sign withdrawal to my wallet')),
  if(result.isNotEmpty)...[SelectableText(result,key:const ValueKey('withdrawal-result')),TextButton(onPressed:()=>Clipboard.setData(ClipboardData(text:result)),child:const Text('Copy withdrawal signature'))],
 ]);
}
