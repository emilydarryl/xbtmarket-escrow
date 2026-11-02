import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'production_identity.dart';
import 'production_transfer.dart';

class ProductionTransferPanel extends StatefulWidget {
  const ProductionTransferPanel({super.key,required this.session,required this.mediator,required this.lockGeneration,required this.funding,required this.spending,required this.resolutions});
  final ProductionIdentitySession session;
  final String mediator;
  final int lockGeneration;
  final bool funding,spending,resolutions;
  @override State<ProductionTransferPanel> createState()=>_ProductionTransferPanelState();
}
class _ProductionTransferPanelState extends State<ProductionTransferPanel> with WidgetsBindingObserver {
  static const channel=MethodChannel('store.xbtmarket/public-files');
  String? source,result;ProductionTransfer? review;
  String message='';bool matched=false,confirmed=false,busy=false;
  @override void initState(){super.initState();WidgetsBinding.instance.addObserver(this);channel.setMethodCallHandler((call)async{if(call.method=='incomingAvailable')await incoming();});incoming();}
  Future<void> incoming()async{try{final value=await channel.invokeMethod<String>('takeIncoming');if(value!=null&&mounted)setState((){invalidate();source=value;message='Request received. Unlock, then review this order. A first-time backup check may be required.';});}catch(_){/* File import remains available. */}}
  void invalidate(){review=null;matched=false;confirmed=false;result=null;}
  @override void didChangeAppLifecycleState(AppLifecycleState state){if(state!=AppLifecycleState.resumed&&mounted){setState(invalidate);}else if(state==AppLifecycleState.resumed){incoming();}}
  @override void didUpdateWidget(covariant ProductionTransferPanel old){super.didUpdateWidget(old);if(old.lockGeneration!=widget.lockGeneration)invalidate();}
  @override void dispose(){WidgetsBinding.instance.removeObserver(this);channel.setMethodCallHandler(null);super.dispose();}
  Future<void> open() async {
    setState((){invalidate();source=null;message='';busy=true;});
    try{final value=await channel.invokeMethod<String>('open');if(mounted)setState((){source=value;message=value==null?'No file selected.':'Request loaded. Unlock, then review this order. A first-time backup check may be required.';});}
    catch(_){if(mounted)setState(()=>message='Could not open the public request file.');}
    finally{if(mounted)setState(()=>busy=false);}
  }
  void inspect(){
    setState(invalidate);
    try{if(!widget.session.recoveryVerified)throw StateError('Recovery required');final r=ProductionTransfer.parse(source!,widget.session,widget.mediator,DateTime.now().millisecondsSinceEpoch);
      if((r.kind=='funding'&&!widget.funding)||(['spend','withdrawal'].contains(r.kind)&&!widget.spending)||(r.kind=='resolution'&&!widget.resolutions))throw StateError('Feature disabled');
      setState((){review=r;message='Compare the transfer code with your order on xbtmarket.store. Then read the terms and amounts below.';});
    }catch(_){setState(()=>message='Request could not be reviewed. Check the account role, recovery, order and expiry. Return to your order and open a fresh request if it expired.');}
  }
  void approve(){try{if(review==null||!matched||!confirmed||!widget.session.recoveryVerified)throw StateError('Review required');final proof=review!.approve(widget.session,widget.mediator,DateTime.now().millisecondsSinceEpoch);setState((){result=jsonEncode(proof);confirmed=false;message='Approval created. Tap Return approval to website to save it to your order. Nothing was broadcast.';});}catch(_){setState((){invalidate();message='Approval stopped. Review the current request again.';});}}
  Future<void> returnApproval()async{
    final value=result,r=review;if(value==null||r==null)return;
    final envelope={'schema':'xbt-signer-return-v1','result':jsonDecode(value),'sellerId':widget.session.role=='seller'?(r.kind=='connect'?r.request['sellerId']:r.contract['snapshot']['sellerProfileId']):null};
    try{await channel.invokeMethod<bool>('returnApproval',{'content':jsonEncode(envelope)});}catch(_){if(mounted)setState(()=>message='Could not open the website. Save the approval file instead.');}
  }
  Future<void> save()async{
    final value=result;if(value==null)return;
    try{final saved=await channel.invokeMethod<bool>('save',{'content':value});if(mounted)setState(()=>message=saved==true?'Return to your order and choose the saved approval file.':'Save cancelled. Review again if the app locked.');}catch(_){if(mounted)setState(()=>message='Approval could not be saved. Review and approve again if the app locked.');}
  }
  @override Widget build(BuildContext context){
    final r=review;final payout=r==null?null:r.kind=='resolution'?r.request['payoutRequest']:r.kind=='spend'?r.request:null;
    return Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
      const Divider(),const Text('Review an order from the website'),
      const Text('On your signed-in order page, tap Open signer app. The order arrives here automatically. Unlock, review and approve, then return to the website.'),
      ExpansionTile(title:const Text('Advanced: import a request file'),children:[OutlinedButton(onPressed:busy?null:open,child:const Text('Open order request file'))]),
      if(source!=null&&r==null&&!widget.session.recoveryVerified)const Text('Before reviewing: unlock your identity and complete the recovery check above. The review button becomes available after Recovery verified.'),
      if(source!=null&&r==null)FilledButton(onPressed:widget.session.recoveryVerified?inspect:null,child:const Text('Review imported order')),
      if(message.isNotEmpty)Text(message),
      if(r!=null)...[
        SelectableText('Transfer code: ${r.code}'),
        CheckboxListTile(value:matched,onChanged:(v)=>setState((){matched=v??false;confirmed=false;result=null;}),title:const Text('This code matches the code on my signed-in order page.')),
        Text(r.action,style:Theme.of(context).textTheme.titleLarge),Text(r.title),Text('Order: ${r.orderId}'),Text('My role: ${widget.session.role}'),Text(widget.session.origin),Text(r.terms),
        if(r.kind=='withdrawal')...[Text('Receive address: ${r.request['withdrawal']['destination']}'),Text('Receive amount: ${r.request['withdrawal']['outputSats']} sats'),Text('Network fee: ${r.request['withdrawal']['feeSats']} sats'),const Text('Compare the entire receive address with your XBT wallet. This signature authorizes a withdrawal; the phone has not verified live confirmations.')],
        if(r.kind!='connect'&&r.kind!='withdrawal')...[Text('Item price: ${r.contract['sellerPriceSats']} sats'),Text('Buyer fee reserve: ${r.contract['buyerFeeReserveSats']} sats'),
        if(payout!=null)...[Text('Outcome: ${payout['decision']['scenario']}'),Text(payout['decision']['reason'] as String),Text('Network fee: ${payout['decision']['networkFeeSats']} sats'),for(final output in payout['transaction']['outputs'] as List)Text('${output['role']} receives ${output['sats']} sats to the agreed signer identity.')]
        else Text('Exact deposit: ${r.contract['totalDepositSats']} sats')],
        Text(r.kind=='withdrawal'?'This signature authorizes this exact withdrawal to the displayed wallet address.':r.kind=='spend'?'Your signature can spend funds when combined with the other required signer.':r.kind=='funding'?'This authorizes the deposit terms and permanent monitoring. It does not send payment.':'This approval does not sign or send a payment.'),
        ExpansionTile(title:const Text('Technical details'),children:[SelectableText(const JsonEncoder.withIndent('  ').convert(r.request))]),
        CheckboxListTile(value:confirmed,onChanged:matched?(v)=>setState(()=>confirmed=v??false):null,title:const Text('I checked the order, terms, recipients and amounts and approve this action.')),
        if(result==null)FilledButton(onPressed:matched&&confirmed?approve:null,child:Text(r.action)),
      ],
      if(result!=null)...[FilledButton(onPressed:returnApproval,child:const Text('Return approval to website')),TextButton(onPressed:save,child:const Text('Save approval file instead'))],
    ]);
  }
}
