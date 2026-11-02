import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'device_selftest.dart';
import 'production_device_store.dart';
import 'device_restart_check.dart';
import 'device_restart_platform.dart';

void main(){WidgetsFlutterBinding.ensureInitialized();runApp(const MaterialApp(home:SelfTestHome()));}
class SelfTestHome extends StatefulWidget {
  const SelfTestHome({super.key});
  @override State<SelfTestHome> createState()=>_SelfTestHomeState();
}
class _SelfTestHomeState extends State<SelfTestHome> with WidgetsBindingObserver {
  DeviceSelfTest? runner;bool busy=false;String progress='',report='',summary='';
  final restart=DeviceRestartCheck(ProductionDeviceStore(),AndroidRestartRecordStore(),androidBootCount);
  bool restartBusy=false;String restartMessage='',restartReport='';
  @override void initState(){super.initState();WidgetsBinding.instance.addObserver(this);}
  @override void didChangeAppLifecycleState(AppLifecycleState state){if(busy&&state!=AppLifecycleState.resumed)runner?.cancel();}
  @override void dispose(){runner?.cancel();WidgetsBinding.instance.removeObserver(this);super.dispose();}
  Future<void> run() async {
    if(busy||restartBusy)return;setState((){busy=true;progress='Starting';report='';summary='';});
    try{
      if(!Platform.isAndroid)throw StateError('Android required');
      final fixture=jsonDecode(await rootBundle.loadString('assets/device-selftest.json')) as Map;
      final test=DeviceSelfTest(ProductionDeviceStore(),fixture,storageKind:'android-secure-storage',onProgress:(step){if(mounted)setState(()=>progress=step);});runner=test;
      final result=await test.run();
      if(mounted)setState((){report=jsonEncode(result).replaceAll('https://',r'\u0068ttps://');summary=result['passed']==true?'PASS — ${result['checks'].length} checks. Copy the report for independent signature verification.':'STOPPED — ${result['failedCheck']} (${result['failureCategory']}). Copy the report.';});
    }catch(_){if(mounted)setState(()=>summary='Could not start the self-test. No owner data was accessed.');}
    finally{if(mounted)setState(()=>busy=false);}
  }
  Future<void> restartAction(bool prepare) async {
    if(busy||restartBusy)return;setState((){restartBusy=true;restartMessage='Checking saved test identity…';restartReport='';});
    try{
      final result=prepare?await restart.prepare():await restart.verify();
      if(mounted)setState((){restartReport=jsonEncode(result);restartMessage=prepare?'Prepared. Restart the PHONE, reopen XBT SELF TEST, then tap Verify after phone restart. Do not prepare again.':'PASS — the same saved random identity survived a newer phone boot. Copy the restart report.';});
    }catch(error){if(mounted)setState(()=>restartMessage=error is RestartFailure?'Restart check stopped: ${error.code}. No missing identity was recreated.':'Restart check stopped because storage or the boot counter could not be checked.');}
    finally{if(mounted)setState(()=>restartBusy=false);}
  }
  @override Widget build(BuildContext context)=>Scaffold(appBar:AppBar(title:const Text('XBT SELF TEST')),body:SingleChildScrollView(padding:const EdgeInsets.all(20),child:Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
    const Text('Disposable test identities only. No funds, network access or owner backups. This app cannot approve your seller account or certify launch readiness.'),
    const SizedBox(height:16),const Text('Tap Run tests and keep this app open. It tests buyer, seller and mediator storage, recovery and signing automatically. Switching apps during a run stops it; you can rerun.'),
    const SizedBox(height:16),FilledButton(onPressed:busy||restartBusy?null:run,child:const Text('Run tests')),
    if(busy)...[const LinearProgressIndicator(),Text(progress)],
    if(summary.isNotEmpty)SelectableText(summary),
    if(report.isNotEmpty)FilledButton(onPressed:() async {await Clipboard.setData(ClipboardData(text:report));if(context.mounted)ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Public test report copied. You can switch apps now.')));},child:const Text('Copy public test report')),
    const SizedBox(height:16),const Text('Limitations: uses a fixture clock and synthetic transactions. Reopening storage is tested, but real background/restart behavior, network confirmation and independent security review are separate checks.'),
    const Divider(),const Text('Phone restart persistence check'),
    const Text('Prepare once, restart the phone, then verify. This separate check requires an existing random identity and a newer Android boot count. It never recreates a missing identity.'),
    FilledButton(onPressed:busy||restartBusy?null:()=>restartAction(true),child:const Text('1. Prepare restart check')),
    FilledButton(onPressed:busy||restartBusy?null:()=>restartAction(false),child:const Text('2. Verify after phone restart')),
    if(restartBusy)const LinearProgressIndicator(),if(restartMessage.isNotEmpty)SelectableText(restartMessage),
    if(restartReport.isNotEmpty)TextButton(onPressed:()=>Clipboard.setData(ClipboardData(text:restartReport)),child:const Text('Copy restart report')),
  ])));
}
