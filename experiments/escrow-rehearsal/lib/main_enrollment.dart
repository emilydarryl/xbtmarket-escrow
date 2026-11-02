// Bootstrap the mediator identity without trusting any preconfigured mediator key.
import 'package:flutter/material.dart';
import 'production_identity.dart';
import 'production_device_store.dart';
import 'production_app.dart';

void main(){
  WidgetsFlutterBinding.ensureInitialized();
  const role=String.fromEnvironment('PRODUCTION_ROLE');
  const origin=String.fromEnvironment('PRODUCTION_ORIGIN');
  if(role!='market'||origin!='https://xbtmarket.store'){
    runApp(const MaterialApp(home:Scaffold(body:SafeArea(child:Text('Mediator enrollment configuration is invalid. No identity was opened.')))));
    return;
  }
  runApp(ProductionReviewApp(
    session:ProductionIdentitySession(ProductionDeviceStore(),role:role,origin:origin),
    mediatorPublicKey:'',enrollmentOnly:true,
  ));
}
