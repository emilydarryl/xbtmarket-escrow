import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'device_restart_check.dart';

class AndroidRestartRecordStore implements RestartRecordStore {
  static const storage=FlutterSecureStorage(aOptions:AndroidOptions(resetOnError:false));
  static const key='xbt_selftest_private_restart_record_v1';
  @override Future<String?> read()=>storage.read(key:key);
  @override Future<void> write(String record)=>storage.write(key:key,value:record);
}
Future<int?> androidBootCount() async =>const MethodChannel('tech.xbtpulse.selftest/restart').invokeMethod<int>('bootCount');
