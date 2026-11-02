import 'dart:convert';
import 'dart:math';
import 'package:bitcoin_base/bitcoin_base.dart';
import 'package:blockchain_utils/blockchain_utils.dart';
import 'package:xbt_market_escrow_lab/escrow_signer.dart';
import 'shared_order.dart';

const labBuyer =
    '03774ae7f858a9411e5ef4246b70c65aac5649980be5c17891bbec17895da008cb';
const labSeller =
    '03421f5fc9a21065445c96fdb91c0c1e2f2431741c72713b4b99ddcb316f31e9fc';
const labMarket =
    '021697ffa6fd9de627c077e3d2fe541084ce13300b0bec1146f95ae57f0d0bd6a5';
const rehearsalAmount = '500000000';

abstract class KeyStore {
  Future<String?> read();
  Future<void> write(String value);
  Future<String?> readOrder();
  Future<void> writeOrder(String value);
}

class RehearsalIdentity {
  RehearsalIdentity(this.key);
  final ECPrivate key;
  String get publicKey => key.getPublic().toHex();
  String get fingerprint =>
      sha(BytesUtils.fromHexString(publicKey)).substring(0, 12);
  String get secretHex => key.toHex();
  String get recoveryKit => recoveryKitFor('buyer');
  String recoveryKitFor(String role) {
    if (!['buyer', 'seller'].contains(role)) {
      throw const FormatException('Unsupported rehearsal role.');
    }
    final encoded = base64UrlEncode(
      BytesUtils.fromHexString(secretHex),
    ).replaceAll('=', '');
    final prefix = role == 'seller'
        ? 'XBT-SELLER-REHEARSAL-1'
        : 'XBT-REHEARSAL-1';
    final context = role == 'seller'
        ? 'regtest:seller:$encoded'
        : 'regtest:$encoded';
    return '$prefix.$encoded.${sha(utf8.encode(context)).substring(0, 12)}';
  }

  static RehearsalIdentity generate() {
    final random = Random.secure();
    while (true) {
      final bytes = List<int>.generate(32, (_) => random.nextInt(256));
      try {
        return RehearsalIdentity(ECPrivate.fromBytes(bytes));
      } catch (_) {
        /* retry invalid scalar */
      }
    }
  }

  static RehearsalIdentity restore(String kit, {String role = 'buyer'}) {
    if (!['buyer', 'seller'].contains(role)) {
      throw const FormatException('Unsupported rehearsal role.');
    }
    if (kit.length > 128) {
      throw const FormatException('Recovery kit is too long.');
    }
    final parts = kit.trim().split('.');
    final prefix = role == 'seller'
        ? 'XBT-SELLER-REHEARSAL-1'
        : 'XBT-REHEARSAL-1';
    final context = parts.length == 3
        ? (role == 'seller'
              ? 'regtest:seller:${parts[1]}'
              : 'regtest:${parts[1]}')
        : '';
    if (parts.length != 3 ||
        parts[0] != prefix ||
        parts[1].length != 43 ||
        sha(utf8.encode(context)).substring(0, 12) != parts[2]) {
      throw const FormatException(
        'Use this role’s rehearsal recovery kit, not another app’s kit, a wallet seed or private key.',
      );
    }
    final bytes = base64Url.decode(base64Url.normalize(parts[1]));
    if (bytes.length != 32) {
      throw const FormatException('Invalid rehearsal recovery kit.');
    }
    return RehearsalIdentity(ECPrivate.fromBytes(bytes));
  }

  String enrollment({String role = 'buyer'}) {
    if (!['buyer', 'seller'].contains(role)) {
      throw const FormatException('Unsupported rehearsal role.');
    }
    return jsonEncode({
      'schema': 'xbt-escrow-rehearsal-enrollment-v1',
      'chain': 'regtest',
      'testOnly': true,
      'role': role,
      'publicKey': publicKey,
      'fingerprint': fingerprint,
      'simulatedDepositSats': rehearsalAmount,
    });
  }
}

class RehearsalLoadException implements Exception {
  const RehearsalLoadException(this.code);
  final String code;
}

class RehearsalSession {
  RehearsalSession(this.store, {this.role = 'buyer'});
  final KeyStore store;
  final String role;
  RehearsalIdentity? identity;
  bool recoveryVerified = false;
  SharedOrder? sharedOrder;
  Future<void> open() async {
    recoveryVerified = false;
    identity = null;
    sharedOrder = null;
    final String? saved;
    try {
      saved = await store.read();
    } catch (_) {
      throw const RehearsalLoadException('KEY_READ_FAILED');
    }
    try {
      if (saved != null) {
        identity = RehearsalIdentity.restore(saved, role: role);
      }
    } catch (_) {
      try {
        RehearsalIdentity.restore(
          saved!,
          role: role == 'seller' ? 'buyer' : 'seller',
        );
      } catch (_) {
        throw const RehearsalLoadException('SAVED_KEY_INVALID');
      }
      throw const RehearsalLoadException('SAVED_KEY_ROLE_MISMATCH');
    }
    final String? order;
    try {
      order = await store.readOrder();
    } catch (_) {
      throw const RehearsalLoadException('ORDER_READ_FAILED');
    }
    if (order != null) {
      if (identity == null) {
        throw const RehearsalLoadException('ORDER_WITHOUT_KEY');
      }
      try {
        sharedOrder = SharedOrder.parse(order, identity!.publicKey, role);
      } catch (_) {
        throw const RehearsalLoadException('SAVED_ORDER_INVALID');
      }
    }
  }

  Future<RehearsalIdentity> reviewLegacyKit(String kit) async {
    final oldRole = role == 'seller' ? 'buyer' : 'seller';
    final saved = await store.read();
    if (saved == null) {
      throw const FormatException(
        'No existing legacy key was found. No key changed.',
      );
    }
    // Only the existing opposite-format record may use this repair path.
    final existing = RehearsalIdentity.restore(saved, role: oldRole);
    final backup = RehearsalIdentity.restore(kit, role: oldRole);
    if (existing.publicKey != backup.publicKey) {
      throw const FormatException(
        'This backup does not match the saved test key. No key changed.',
      );
    }
    return backup;
  }

  Future<void> repairLegacyKit(String kit, String approvedPublicKey) async {
    final recovered = await reviewLegacyKit(kit);
    if (recovered.publicKey != approvedPublicKey) {
      throw const FormatException(
        'The saved key changed after review. Repair stopped.',
      );
    }
    final savedOrder = await store.readOrder();
    final order = savedOrder == null
        ? null
        : SharedOrder.parse(savedOrder, recovered.publicKey, role);
    final canonical = recovered.recoveryKitFor(role);
    await store.write(canonical);
    if (await store.read() != canonical) {
      throw StateError(
        'Repaired key could not be read back. Keep the original backup.',
      );
    }
    identity = recovered;
    sharedOrder = order;
    recoveryVerified = false;
  }

  Future<void> create() async {
    if (identity != null) throw StateError('A rehearsal key already exists.');
    final fresh = RehearsalIdentity.generate();
    await store.write(fresh.recoveryKitFor(role));
    identity = fresh;
  }

  Future<void> replaceTestOrder(SharedOrder order, String previousHash) async {
    if (!recoveryVerified ||
        identity == null ||
        sharedOrder?.hash != previousHash) {
      throw StateError(
        'Verify recovery and explicitly review the current test order.',
      );
    }
    final checked = SharedOrder.parse(
      order.encode(),
      identity!.publicKey,
      role,
    );
    if (checked.buyer != sharedOrder!.buyer ||
        checked.seller != sharedOrder!.seller ||
        checked.id == sharedOrder!.id) {
      throw const FormatException(
        'A new test order must retain both enrolled phone keys and use a fresh order ID.',
      );
    }
    await store.writeOrder(checked.encode());
    sharedOrder = checked;
  }

  Future<void> recover(String kit) async {
    final recovered = RehearsalIdentity.restore(kit, role: role);
    if (identity != null && recovered.publicKey != identity!.publicKey) {
      throw const FormatException(
        'This kit belongs to a different rehearsal key.',
      );
    }
    await store.write(recovered.recoveryKitFor(role));
    identity = recovered;
    recoveryVerified = true;
  }

  Future<void> pinOrder(SharedOrder order) async {
    if (!recoveryVerified || identity == null) {
      throw StateError('Verify recovery before approving a shared order.');
    }
    final checked = SharedOrder.parse(
      order.encode(),
      identity!.publicKey,
      role,
    );
    if (sharedOrder != null && sharedOrder!.hash != checked.hash) {
      throw const FormatException(
        'A different shared order is already pinned. Do not replace its participants or funding.',
      );
    }
    await store.writeOrder(checked.encode());
    sharedOrder = checked;
  }
}

class RehearsalRequest {
  RehearsalRequest._(
    this.payload,
    this.psbt,
    this.summary,
    this.script,
    this.funding,
    this.identity,
    this.role,
  );
  final Map<String, dynamic> payload;
  final EscrowPsbt psbt;
  final Map<String, Object> summary;
  final String script;
  final Map<String, String> funding;
  final RehearsalIdentity identity;
  final String role;
  String get scenario => payload['scenario'] as String;
  static RehearsalRequest parse(
    String encoded,
    RehearsalIdentity identity, {
    String role = 'buyer',
    SharedOrder? sharedOrder,
  }) {
    if (!['buyer', 'seller'].contains(role)) {
      throw const FormatException('Unsupported rehearsal role.');
    }
    if (encoded.length > 150000) {
      throw const FormatException('Rehearsal request is too large.');
    }
    var payload = Map<String, dynamic>.from(jsonDecode(encoded) as Map);
    final shared = payload['schema'] == 'xbt-shared-rehearsal-request-v1';
    if (shared) {
      if (sharedOrder == null) {
        throw const FormatException(
          'Approve the shared test order before reviewing its transaction.',
        );
      }
      final supplied = SharedOrder.parse(
        jsonEncode(payload['contract']),
        identity.publicKey,
        role,
      );
      if (supplied.hash != sharedOrder.hash) {
        throw const FormatException(
          'This request changes the pinned shared order.',
        );
      }
      payload = {
        ...supplied.data,
        'schema': 'xbt-escrow-rehearsal-request-v1',
        'maximumFeeSats': '1000',
        'scenario': payload['scenario'],
        'psbt': payload['psbt'],
        'sharedOrderId': supplied.id,
        'sharedContractHash': supplied.hash,
      };
    } else if (sharedOrder != null) {
      throw const FormatException('Use a request for the pinned shared order.');
    }
    if (payload['schema'] != 'xbt-escrow-rehearsal-request-v1' ||
        payload['chain'] != 'regtest' ||
        payload['testOnly'] != true ||
        payload['depositSats'] != rehearsalAmount) {
      throw const FormatException(
        'Only 5-XBT artificial regtest rehearsals are accepted. Real purchases are not supported by this test build.',
      );
    }
    final buyer = shared
        ? sharedOrder!.buyer
        : (role == 'buyer' ? identity.publicKey : labBuyer);
    final seller = shared
        ? sharedOrder!.seller
        : (role == 'seller' ? identity.publicKey : labSeller);
    final market = shared ? sharedOrder!.market : labMarket;
    if (payload['buyerPublicKey'] != buyer ||
        payload['sellerPublicKey'] != seller ||
        payload['marketPublicKey'] != market) {
      throw const FormatException(
        'Participant keys differ from this rehearsal.',
      );
    }
    final keys = [buyer, seller, market]..sort();
    if (keys.toSet().length != 3) {
      throw const FormatException('Participant keys must be distinct.');
    }
    final script = '52${keys.map((key) => '21$key').join()}53ae';
    final funding = Map<String, String>.from(payload['funding'] as Map);
    if (funding.length != 1 ||
        funding.values.single != rehearsalAmount ||
        !RegExp(r'^[a-f0-9]{64}:\d+$').hasMatch(funding.keys.single)) {
      throw const FormatException('Invalid rehearsal funding.');
    }
    final psbt = EscrowPsbt.parse(payload['psbt'] as String);
    final summary = psbt.review(
      witnessScript: script,
      funding: funding,
      maximumFeeSats: BigInt.from(1000),
    );
    if (summary['feeSats'] != '1000' ||
        summary['inputSats'] != rehearsalAmount) {
      throw const FormatException('The test amount or network fee changed.');
    }
    String destination(String publicKey) =>
        ECPublic.fromHex(publicKey).toSegwitAddress().toScriptPubKey().toHex();
    final buyerScript = destination(buyer), sellerScript = destination(seller);
    final expected = switch (payload['scenario']) {
      'release' => {sellerScript: '499999000'},
      'refund' => {buyerScript: '499999000'},
      'split-refund' => {buyerScript: '200000000', sellerScript: '299999000'},
      _ => throw const FormatException('Unsupported rehearsal scenario.'),
    };
    final actual = <String, String>{};
    for (final output in summary['outputs'] as List) {
      final row = Map<String, dynamic>.from(output as Map);
      if (actual.containsKey(row['script'])) {
        throw const FormatException('Duplicate payout destination.');
      }
      actual[row['script'] as String] = row['sats'] as String;
    }
    if (actual.length != expected.length ||
        expected.entries.any((entry) => actual[entry.key] != entry.value)) {
      throw const FormatException(
        'The payout destination or amount differs from this rehearsal.',
      );
    }
    return RehearsalRequest._(
      payload,
      psbt,
      summary,
      script,
      funding,
      identity,
      role,
    );
  }

  String sign() => jsonEncode({
    'schema': payload.containsKey('sharedContractHash')
        ? 'xbt-shared-rehearsal-signed-v1'
        : 'xbt-escrow-rehearsal-signed-v1',
    if (payload.containsKey('sharedContractHash'))
      'contractHash': payload['sharedContractHash'],
    if (payload.containsKey('sharedOrderId'))
      'orderId': payload['sharedOrderId'],
    'chain': 'regtest',
    'testOnly': true,
    'scenario': scenario,
    'buyerPublicKey': payload['buyerPublicKey'],
    'signerRole': role,
    'signerPublicKey': identity.publicKey,
    'transactionHash': summary['transactionHash'],
    'psbt': psbt.sign(
      privateKey: identity.key,
      witnessScript: script,
      funding: funding,
      maximumFeeSats: BigInt.from(1000),
      approvedTransactionHash: summary['transactionHash'] as String,
    ),
  });
}
