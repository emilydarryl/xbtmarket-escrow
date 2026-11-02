import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'approved_payout.dart';
import 'rehearsal.dart';

class ApprovedPayoutPanel extends StatefulWidget {
  const ApprovedPayoutPanel({super.key,required this.identity,required this.role,required this.recoveryVerified});
  final RehearsalIdentity identity;
  final String role;
  final bool recoveryVerified;
  @override
  State<ApprovedPayoutPanel> createState()=>_ApprovedPayoutPanelState();
}
class _ApprovedPayoutPanelState extends State<ApprovedPayoutPanel> with WidgetsBindingObserver {
  final incoming=TextEditingController(),draftPin=TextEditingController(),requestPin=TextEditingController();
  ApprovedPayout? request;
  bool checked=false,busy=false;
  int generation=0;
  String result='',status='';
  @override
  void initState(){super.initState();WidgetsBinding.instance.addObserver(this);for(final c in [incoming,draftPin,requestPin]){c.addListener(clear);}}
  void clear(){if(mounted){setState((){generation++;request=null;checked=false;result='';status='';});}}
  @override
  void didChangeAppLifecycleState(AppLifecycleState state){if(state!=AppLifecycleState.resumed){clear();}}
  @override
  void didUpdateWidget(covariant ApprovedPayoutPanel oldWidget){super.didUpdateWidget(oldWidget);if(oldWidget.identity.publicKey!=widget.identity.publicKey||oldWidget.role!=widget.role||oldWidget.recoveryVerified!=widget.recoveryVerified){clear();}}
  @override
  void dispose(){WidgetsBinding.instance.removeObserver(this);for(final c in [incoming,draftPin,requestPin]){c.removeListener(clear);c.dispose();}super.dispose();}
  void review(){clear();try{final value=ApprovedPayout.parse(incoming.text,expectedRequestHash:requestPin.text.trim(),expectedDraftHash:draftPin.text.trim(),ownPublicKey:widget.identity.publicKey,role:widget.role);setState(()=>request=value);}catch(_){setState(()=>status='Cannot review this payout. Check the independent hashes, order, role and amounts.');}}
  Future<void> sign() async {
    if(busy||!checked||!widget.recoveryVerified||request==null){return;}
    final version=generation,r=request!;setState(()=>busy=true);
    final confirmed=await showDialog<bool>(context:context,builder:(context)=>AlertDialog(
      title:const Text('Sign this exact test payout?'),
      content:Text('This creates a transaction signature for the reviewed artificial regtest payout. It is different from approving an unfunded draft.\n\nRequest: ${r.requestHash}\n\nThe offline phone cannot check current funding or shipment evidence.'),
      actions:[TextButton(onPressed:()=>Navigator.pop(context,false),child:const Text('Cancel')),TextButton(onPressed:()=>Navigator.pop(context,true),child:const Text('Sign test payout'))]));
    if(!mounted){return;}
    try{if(confirmed==true&&version==generation&&checked&&widget.recoveryVerified){final signed=r.sign(widget.identity.key,recoveryVerified:true,confirmPayout:true);setState((){result=jsonEncode(signed);status='Public partial ready. The local order must verify and accept it.';});}}
    catch(_){setState(()=>status='Payout signing failed. Review the request again.');}
    finally{if(mounted){setState(()=>busy=false);}}
  }
  @override
  Widget build(BuildContext context)=>Card(child:Padding(padding:const EdgeInsets.all(16),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
    Text('Selected shipping payout · regtest only',style:Theme.of(context).textTheme.titleLarge),
    const Text('Copy both hashes separately from the authenticated local order. Review the complete decision, participant keys, payout amounts and network fee. Funding and shipping evidence cannot be verified by this offline phone.'),
    TextField(key:const ValueKey('payout-draft'),controller:draftPin,decoration:const InputDecoration(labelText:'Approved draft hash')),
    TextField(key:const ValueKey('payout-pin'),controller:requestPin,decoration:const InputDecoration(labelText:'Selected payout request hash')),
    TextField(key:const ValueKey('payout-json'),controller:incoming,maxLines:4,decoration:const InputDecoration(labelText:'Public payout request JSON')),
    TextButton(key:const ValueKey('payout-review'),onPressed:busy?null:review,child:const Text('Review selected payout')),
    if(request!=null)...[
      SelectableText(request!.summary),
      ExpansionTile(title:const Text('Complete decision and transaction details'),children:[SelectableText(request!.reviewJson)]),
      CheckboxListTile(key:const ValueKey('payout-confirm'),value:checked,onChanged:busy?null:(v)=>setState((){checked=v==true;result='';}),title:const Text('I checked the decision, amounts, fee and both hashes.')),
      if(!widget.recoveryVerified)const Text('Verify your recovery kit before signing.'),
      FilledButton(key:const ValueKey('payout-sign'),onPressed:checked&&widget.recoveryVerified&&!busy?sign:null,child:const Text('Create public payout signature')),
    ],
    if(status.isNotEmpty)Text(status),
    if(result.isNotEmpty)TextButton(key:const ValueKey('payout-copy'),onPressed:() async {await Clipboard.setData(ClipboardData(text:result));},child:const Text('Copy public payout signature')),
  ])));
}
