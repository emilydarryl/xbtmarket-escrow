import 'production_transfer_panel.dart';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'production_identity.dart';
import 'production_contract.dart';
import 'production_funding_panel.dart';
import 'production_spend_panel.dart';
import 'production_withdrawal_panel.dart';
import 'production_resolution_panel.dart';

class ProductionReviewApp extends StatelessWidget {
  const ProductionReviewApp({super.key,required this.session,required this.mediatorPublicKey,this.enableFundingConsent=false,this.enablePayoutSigning=false,this.enableMediatorDecisions=false,this.enrollmentOnly=false});
  final bool enableFundingConsent,enablePayoutSigning,enableMediatorDecisions,enrollmentOnly;
  final ProductionIdentitySession session;
  final String mediatorPublicKey;
  @override Widget build(BuildContext context)=>MaterialApp(title:'XBT Escrow Review',debugShowCheckedModeBanner:false,theme:ThemeData(colorScheme:ColorScheme.fromSeed(seedColor:const Color(0xff205a48)),useMaterial3:true),home:ProductionReviewHome(session:session,mediatorPublicKey:mediatorPublicKey,enableFundingConsent:enableFundingConsent,enablePayoutSigning:enablePayoutSigning,enableMediatorDecisions:enableMediatorDecisions,enrollmentOnly:enrollmentOnly));
}
class ProductionReviewHome extends StatefulWidget {
  const ProductionReviewHome({super.key,required this.session,required this.mediatorPublicKey,this.enableFundingConsent=false,this.enablePayoutSigning=false,this.enableMediatorDecisions=false,this.enrollmentOnly=false});
  final bool enableFundingConsent,enablePayoutSigning,enableMediatorDecisions,enrollmentOnly;
  final ProductionIdentitySession session;
  final String mediatorPublicKey;
  @override State<ProductionReviewHome> createState()=>_ProductionReviewHomeState();
}
class _ProductionReviewHomeState extends State<ProductionReviewHome> with WidgetsBindingObserver {
  final password=TextEditingController(),repeat=TextEditingController(),backup=TextEditingController(),request=TextEditingController(),pin=TextEditingController();
  bool busy=false,opened=false,confirmed=false;
  int generation=0;
  String message='',publicResult='',encryptedExport='';
  ProductionContractReview? review;
  ProductionIdentitySession get session=>widget.session;
  @override void initState(){super.initState();WidgetsBinding.instance.addObserver(this);request.addListener(_invalidate);pin.addListener(_invalidate);_open();}
  void _invalidate(){if(!mounted)return;setState((){review=null;confirmed=false;publicResult='';});}
  void _clear(){password.clear();repeat.clear();backup.clear();encryptedExport='';publicResult='';review=null;confirmed=false;}
  void _lock(){generation++;session.lock();_clear();if(mounted)setState((){busy=false;message='Locked. Public request fields are kept in memory. Unlock with your passphrase and review again before approving.';});}
  @override void didChangeAppLifecycleState(AppLifecycleState state){if(state!=AppLifecycleState.resumed)_lock();}
  @override void dispose(){generation++;session.lock();WidgetsBinding.instance.removeObserver(this);request.removeListener(_invalidate);pin.removeListener(_invalidate);for(final c in [password,repeat,backup,request,pin]){c.clear();c.dispose();}super.dispose();}
  Future<void> _run(Future<void> Function(int token) action) async {
    if(busy)return;final token=generation;setState((){busy=true;message='';publicResult='';});
    try{await action(token);}catch(error){if(mounted&&token==generation)setState((){review=null;confirmed=false;publicResult='';message=error is IdentityFailure?'${error.problem.message} [${error.problem.name}]':'Could not complete this step. Keep your backup and reopen the app before retrying. No payment was sent.';});}
    finally{if(mounted&&token==generation)setState((){busy=false;password.clear();repeat.clear();});}
  }
  Future<void> _open()=>_run((token)async{opened=false;await session.open();if(mounted&&token==generation)setState(()=>opened=true);});
  Future<void> _create()=>_run((token)async{
    if(password.text!=repeat.text||password.text.isEmpty)throw StateError('Passphrases differ.');
    final result=await session.create(password.text);if(mounted&&token==generation)setState((){encryptedExport=result;message='Save this encrypted backup and its passphrase separately. Paste your saved backup below to verify recovery.';});
  });
  Future<void> _recover()=>_run((token)async{
    if(session.hasSavedIdentity){await session.verifyRecovery(backup.text,password.text);}else{await session.restoreEmpty(backup.text,password.text);}
    if(mounted&&token==generation)setState((){backup.clear();encryptedExport='';message='Recovery verified and remembered on this device. Next time, unlock with your passphrase.';});
  });
  Future<void> _unlock()=>_run((token)async{await session.unlock(password.text);if(mounted&&token==generation)setState(()=>message=session.recoveryVerified?'Unlocked. Your earlier backup check is verified. Review the current order before approving.':'Identity unlocked. Verify your separate backup once on this device before approving.');});
  Future<void> _export()=>_run((token)async{final value=await session.exportBackup();if(mounted&&token==generation)setState(()=>encryptedExport=value);});
  void _review(){
    if(widget.enrollmentOnly)return;
    setState((){review=null;confirmed=false;publicResult='';message='';});
    try{if(!session.recoveryVerified)throw StateError('Recovery required.');final checked=ProductionContractReview.parse(request.text,expectedContractHash:pin.text,expectedOrigin:session.origin,ownPublicKey:session.publicKey!,expectedMediatorPublicKey:widget.mediatorPublicKey,role:session.role,now:DateTime.now().millisecondsSinceEpoch);setState(()=>review=checked);}
    catch(_){setState(()=>message='Request could not be reviewed. Check the independently copied hash, role, origin, keys and expiry.');}
  }
  void _sign(){
    if(widget.enrollmentOnly)return;
    try{if(review==null||!confirmed||!session.recoveryVerified)throw StateError('Review required.');final proof=session.signReview(request.text,expectedContractHash:pin.text,expectedMediatorPublicKey:widget.mediatorPublicKey,confirmReview:confirmed,now:DateTime.now().millisecondsSinceEpoch);setState((){publicResult=jsonEncode(proof);confirmed=false;message='Public contract approval created. No payment was signed or sent.';});}
    catch(_){setState((){publicResult='';confirmed=false;review=null;message='Approval stopped. Review the current request again.';});}
  }
  Widget field(String name,String label,TextEditingController controller,{bool secret=false,int lines=1,int limit=40000})=>Padding(padding:const EdgeInsets.only(bottom:12),child:TextField(key:ValueKey('production-$name'),controller:controller,enabled:!busy,obscureText:secret,autocorrect:false,enableSuggestions:false,maxLength:limit,maxLines:secret?1:lines,decoration:InputDecoration(labelText:label,border:const OutlineInputBorder(),counterText:'')));
  Widget button(String name,String label,VoidCallback? action)=>Padding(padding:const EdgeInsets.only(bottom:12),child:FilledButton(key:ValueKey('production-$name'),style:(['unlock','create','open','review','sign'].contains(name)||(name=='recover'&&!session.recoveryVerified))?null:FilledButton.styleFrom(backgroundColor:Theme.of(context).colorScheme.surfaceContainerHighest,foregroundColor:Theme.of(context).colorScheme.onSurface),onPressed:busy?null:action,child:Text(label)));
  @override Widget build(BuildContext context)=>Scaffold(appBar:AppBar(title:Text('XBT Escrow · ${session.role}'),actions:[TextButton(key:const ValueKey('production-lock'),onPressed:_lock,child:const Text('Lock'))]),body:SingleChildScrollView(padding:const EdgeInsets.all(20),child:Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
    Text(widget.enrollmentOnly?'Identity enrollment only. Create and verify your private recovery backup, then share only the public enrollment. Contract approvals and payment signing are unavailable.':'Review candidate — real-fund use is not approved. Public approvals and signatures are not proof of payment.'),const SizedBox(height:12),Text(session.origin),
    if(busy)const LinearProgressIndicator(),if(message.isNotEmpty)Padding(padding:const EdgeInsets.symmetric(vertical:12),child:Text(message)),
    if(!opened)button('open','Open secure storage',_open),
    if(opened)...[
      Text(session.recoveryVerified?'Recovery verified':session.publicKey!=null?'Identity unlocked — recovery verification required':session.hasSavedIdentity?'Production identity saved':'No production identity saved',key:const ValueKey('production-status')),

      if(!session.recoveryVerified)...[Text(session.hasSavedIdentity?'Unlock with your original backup passphrase. Switching apps locks the signer.':'Choose a private passphrase of at least 16 characters for a new identity, or restore your saved backup with its original passphrase.'),
      field('password','Recovery passphrase',password,secret:true,limit:1024),
      if(!session.hasSavedIdentity)...[field('repeat','Repeat recovery passphrase',repeat,secret:true,limit:1024),button('create','Create a separate production identity',_create)],
      if(session.hasSavedIdentity)const Text('Use your backup passphrase to unlock. After a successful backup check on this device, you do not need to paste the backup each time.'),
      if(session.hasSavedIdentity)button('unlock','Unlock existing identity',_unlock),
      ],
      ExpansionTile(key:ValueKey('production-recovery-options-${session.recoveryVerified}-${session.publicKey!=null}'),initiallyExpanded:session.publicKey!=null&&!session.recoveryVerified,maintainState:true,title:const Text('Advanced: backup and recovery'),children:[
      if(!session.recoveryVerified)const Text('Next: enter the original recovery passphrase above and paste your saved encrypted backup below, then tap Verify recovery. This checks your existing identity; it does not create a new one.'),
      if(session.recoveryVerified)field('password','Backup passphrase (only for backup operations)',password,secret:true,limit:1024),
      if(session.publicKey!=null)button('export','Show encrypted backup',_export),
      if(encryptedExport.isNotEmpty)...[const Text('Encrypted recovery backup — keep private.'),SelectableText(encryptedExport,key:const ValueKey('production-encrypted-backup')),button('copy-backup','Copy encrypted backup',()=>Clipboard.setData(ClipboardData(text:encryptedExport)))],
      field('backup','Paste your saved encrypted recovery backup',backup,lines:4,limit:4096),button('recover',session.hasSavedIdentity?'Verify recovery':'Restore existing production identity',_recover),
      ]),
      if(session.recoveryVerified)button('enrollment','Show public enrollment',()=>setState(()=>publicResult=jsonEncode(session.enrollment()))),
      if(!widget.enrollmentOnly)ProductionTransferPanel(key:const ValueKey('guided-transfer-panel'),session:session,mediator:widget.mediatorPublicKey,lockGeneration:generation,funding:widget.enableFundingConsent,spending:widget.enablePayoutSigning,resolutions:widget.enableMediatorDecisions),
      if(!widget.enrollmentOnly)ExpansionTile(key:const ValueKey('production-advanced'),maintainState:true,title:const Text('Advanced: manual requests'),subtitle:const Text('Only use these forms if guided transfer is unavailable.'),children:[const Divider(),const Text('Contract review'),const Text('Public JSON and hashes stay filled when switching apps. Private fields and approval state are cleared. Closing the app can discard the form.'),field('hash','Independently copied contract hash',pin,limit:64),field('request','Public contract request JSON',request,lines:6),
      button('clear-public','Clear public contract fields',(){request.clear();pin.clear();}),
      button('review','Review contract',session.recoveryVerified?_review:null),
      if(review!=null)...[SelectableText(review!.reviewJson,key:const ValueKey('production-reviewed-contract')),CheckboxListTile(key:const ValueKey('production-confirm'),value:confirmed,onChanged:busy?null:(v)=>setState(()=>confirmed=v??false),title:const Text('I checked the terms, amounts, keys and network. This approves the contract review only.'))],
      button('sign','Create public contract approval',review!=null&&confirmed&&session.recoveryVerified?_sign:null),
      if(!widget.enrollmentOnly&&widget.enableFundingConsent)ProductionFundingPanel(key:const ValueKey('funding-panel'),session:session,mediatorPublicKey:widget.mediatorPublicKey,lockGeneration:generation),
      if(!widget.enrollmentOnly&&widget.enableMediatorDecisions&&session.role=='market')ProductionResolutionPanel(key:const ValueKey('resolution-panel'),session:session,lockGeneration:generation),
      if(!widget.enrollmentOnly&&widget.enablePayoutSigning)ProductionSpendPanel(key:const ValueKey('spend-panel'),session:session,mediatorPublicKey:widget.mediatorPublicKey,lockGeneration:generation),
      ]),
      if(publicResult.isNotEmpty)...[SelectableText(publicResult,key:const ValueKey('production-public-result')),button('copy-public','Copy public result',()=>Clipboard.setData(ClipboardData(text:publicResult)))],
      if(session.publicKey!=null)ExpansionTile(title:const Text('My public identity'),children:[SelectableText(session.publicKey!,key:const ValueKey('production-public-key'))]),
      if(!widget.enrollmentOnly&&widget.enablePayoutSigning&&session.role!='market')ExpansionTile(maintainState:true,title:const Text('Withdraw to my wallet'),children:[ProductionWithdrawalPanel(key:const ValueKey('withdrawal-panel'),session:session,lockGeneration:generation)]),
    ],
  ])));
}
