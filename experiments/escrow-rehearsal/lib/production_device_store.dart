import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'production_identity.dart';

class ProductionDeviceStore implements ProductionKeyStore {
  static const _storage=FlutterSecureStorage(aOptions:AndroidOptions(resetOnError:false));
  void _check(String name){if(!RegExp(r'^xbt_production_identity_v1_[a-f0-9]{64}(_recovery_check_v1)?$').hasMatch(name))throw ArgumentError('Production storage namespace required.');}
  @override
  Future<String?> read(String namespace){_check(namespace);return _storage.read(key:namespace);}
  @override
  Future<void> write(String namespace,String encryptedBackup){_check(namespace);return _storage.write(key:namespace,value:encryptedBackup);}
}
