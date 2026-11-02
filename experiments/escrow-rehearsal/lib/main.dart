import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:bitcoin_base/bitcoin_base.dart';
import 'package:xbt_market_escrow_lab/escrow_signer.dart';
import 'rehearsal.dart';
import 'shared_order.dart';
import 'draft_consent_panel.dart';
import 'approved_payout_panel.dart';

void main() => runApp(const RehearsalApp());
const configuredRole = String.fromEnvironment(
  'ESCROW_ROLE',
  defaultValue: 'buyer',
);

class DeviceKeyStore implements KeyStore {
  static const storage = FlutterSecureStorage(
    aOptions: AndroidOptions(resetOnError: false),
  );
  @override
  Future<String?> read() => storage.read(key: 'regtest_rehearsal_key_v1');
  @override
  Future<void> write(String value) =>
      storage.write(key: 'regtest_rehearsal_key_v1', value: value);
  @override
  Future<String?> readOrder() => storage.read(key: 'regtest_shared_order_v1');
  @override
  Future<void> writeOrder(String value) =>
      storage.write(key: 'regtest_shared_order_v1', value: value);
}

class RehearsalApp extends StatelessWidget {
  const RehearsalApp({
    super.key,
    this.store,
    this.sample,
    this.role = configuredRole,
  });
  final String role;
  final KeyStore? store;
  final String? sample;
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'XBT Escrow Rehearsal',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff205a48)),
      useMaterial3: true,
    ),
    home: RehearsalHome(
      store: store ?? DeviceKeyStore(),
      sample: sample,
      role: role,
    ),
  );
}

class RehearsalHome extends StatefulWidget {
  const RehearsalHome({
    super.key,
    required this.store,
    this.sample,
    required this.role,
  });
  final String role;
  final KeyStore store;
  final String? sample;
  @override
  State<RehearsalHome> createState() => _RehearsalHomeState();
}

class _RehearsalHomeState extends State<RehearsalHome>
    with WidgetsBindingObserver {
  late final session = RehearsalSession(widget.store, role: widget.role);
  final recovery = TextEditingController(), incoming = TextEditingController();
  bool busy = true,
      storageReady = false,
      showKit = false,
      approved = false,
      selfTestPassed = false;
  String message = '', signed = '', storageFailure = '';
  RehearsalRequest? request;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    start();
  }

  Future<void> start() async {
    if (mounted) {
      setState(() {
        busy = true;
        storageReady = false;
      });
    }
    try {
      await session.open();
      storageReady = true;
      storageFailure = '';
    } on RehearsalLoadException catch (error) {
      storageFailure = error.code;
    } catch (_) {
      storageFailure = 'STORAGE_LOAD_FAILED';
    }
    if (mounted) setState(() => busy = false);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    recovery.dispose();
    incoming.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed && mounted) {
      setState(() => showKit = false);
    }
  }

  Future<void> task(Future<void> Function() action) async {
    if (busy) return;
    setState(() {
      busy = true;
      message = '';
    });
    try {
      await action();
    } on FormatException catch (error) {
      message = error.message;
    } catch (_) {
      message =
          'The rehearsal step could not finish. Your existing key has not been replaced. Keep your recovery kit private and try again.';
    }
    if (mounted) setState(() => busy = false);
  }

  Widget panel(String title, List<Widget> children) => Card(
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          ...children,
        ],
      ),
    ),
  );
  Widget button(String label, VoidCallback onPressed, {bool enabled = true}) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: FilledButton(
          onPressed: busy || !enabled ? null : onPressed,
          child: Text(label),
        ),
      );
  Future<void> selfTest() async {
    final fixture =
        widget.sample ?? await rootBundle.loadString('assets/release.json');
    final identity = RehearsalIdentity(
      ECPrivate.fromBytes([
        ...List<int>.filled(31, 0),
        widget.role == 'seller' ? 22 : 11,
      ]),
    );
    final test = RehearsalRequest.parse(fixture, identity, role: widget.role),
        result = jsonDecode(test.sign()) as Map<String, dynamic>;
    final psbt = EscrowPsbt.parse(result['psbt'] as String);
    final expected =
        jsonDecode(fixture)[widget.role == 'seller'
            ? 'expectedSellerSignature'
            : 'expectedBuyerSignature'];
    if (expected is! String ||
        hex(psbt.inputs.single['02${identity.publicKey}']!) != expected) {
      throw const FormatException(
        'Built-in signing check failed. Do not use this build.',
      );
    }
    selfTestPassed = true;
    message =
        'Built-in phone signing check passed against the node-accepted test signature. No real funds or wallet keys were used.';
  }

  Future<void> signReviewed() async {
    if (!approved || request == null || !session.recoveryVerified) return;
    final consent = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Sign this test transaction?'),
        content: const Text(
          'This signs an artificial 5-XBT rehearsal only. It does not pay for your purchase or broadcast a transaction.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Sign rehearsal'),
          ),
        ],
      ),
    );
    if (consent != true || !mounted) return;
    await task(() async {
      signed = request!.sign();
      message =
          'Test signature created. Copy only the signed test result below for node verification.';
    });
  }

  Future<void> approveSharedOrder() async {
    final payload = jsonDecode(incoming.text) as Map;
    final order = SharedOrder.parse(
      jsonEncode(payload['contract']),
      session.identity!.publicKey,
      widget.role,
    );
    final previous = session.sharedOrder;
    final replacing = previous != null && previous.hash != order.hash;
    final consent = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          replacing
              ? 'Retire old test order and review new one'
              : 'Verify both test participants',
        ),
        content: SingleChildScrollView(
          child: Text(
            '${order.title}\n${order.terms}\n\nOrder: ${order.id}\nBuyer fingerprint: ${publicFingerprint(order.buyer)}\nSeller fingerprint: ${publicFingerprint(order.seller)}\nMediator fingerprint: ${publicFingerprint(order.market)}\nYour role: ${widget.role}\n\nCompare all three fingerprints with the enrollment records. ${replacing ? "This explicitly replaces the saved artificial test order; old requests will be rejected. No key changes and no real funds are supported." : ""} This pins the keys and funding outpoint; it does not independently verify funding or a blockchain.\n\nContract hash: ${order.hash}',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(
              replacing
                  ? 'Retire old test order and approve new one'
                  : 'Approve these participants',
            ),
          ),
        ],
      ),
    );
    if (consent != true || !mounted) return;
    if (replacing) {
      await session.replaceTestOrder(order, previous.hash);
    } else {
      await session.pinOrder(order);
    }
    request = null;
    signed = '';
    approved = false;
    message = 'Shared test order saved. Now review its transaction below.';
  }

  Future<void> repairLegacyKit() async {
    final kit = recovery.text;
    final candidate = await session.reviewLegacyKit(kit);
    if (!mounted) return;
    final consent = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Confirm the existing test key'),
        content: SingleChildScrollView(
          child: Text(
            'The private backup matches the key already saved in this app.\n\nRole: ${widget.role}\nPublic fingerprint: ${candidate.fingerprint}\nPublic key: ${candidate.publicKey}\n\nCompare this fingerprint with your original ${widget.role} enrollment. Cancel if it differs. Repair changes the kit format, not the key. Save the new recovery kit afterward; keep the old backup until verification succeeds.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Same fingerprint — repair format'),
          ),
        ],
      ),
    );
    if (consent != true || !mounted) return;
    await session.repairLegacyKit(kit, candidate.publicKey);
    storageReady = true;
    storageFailure = '';
    recovery.clear();
    request = null;
    signed = '';
    approved = false;
    showKit = true;
    message =
        'Kit format repaired; public key unchanged. Save the new role-specific recovery kit below, then verify it. Keep the original backup until verification succeeds.';
  }

  @override
  Widget build(BuildContext context) {
    final identity = session.identity;
    return Scaffold(
      appBar: AppBar(
        title: Text('XBT Escrow · ${widget.role.toUpperCase()} TEST'),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Card(
              color: Color(0xffffe5bb),
              child: Padding(
                padding: EdgeInsets.all(18),
                child: Text(
                  'TEST COINS ONLY\nThis app accepts labeled test requests only; it cannot independently verify a blockchain. Never send real XBT to test keys. Keep using your normal wallet separately.',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            ),
            if (busy) const LinearProgressIndicator(),
            if (message.isNotEmpty)
              Semantics(
                liveRegion: true,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(message, key: const ValueKey('status')),
                ),
              ),
            if (storageFailure.isNotEmpty)
              panel('Saved test data could not be loaded', [
                Text('Diagnostic code: $storageFailure'),
                const Text(
                  'Keep your recovery kit private. Do not uninstall, clear app data or create another key. You can share only this diagnostic code with the operator. Loading does not overwrite your test key.',
                ),
                button('Retry loading saved test data', start),
                if (storageFailure == 'SAVED_KEY_ROLE_MISMATCH') ...[
                  const Text(
                    'The saved test key uses the other role’s kit format. Enter your existing private test backup in the recovery field below, then tap Repair saved kit format. The backup must match the existing saved key; no new key is generated.',
                  ),
                  button(
                    'Repair saved kit format',
                    () => task(repairLegacyKit),
                  ),
                ],
              ]),
            panel('1 · Check this phone', [
              const Text(
                'Run the built-in signing check before creating your own rehearsal key. The sample uses public test keys, not your wallet.',
              ),
              button(
                selfTestPassed ? 'Built-in check passed' : 'Run built-in check',
                () => task(selfTest),
              ),
            ]),
            if (identity == null)
              panel('2 · Create a separate test key', [
                const Text(
                  'A fresh rehearsal key is generated only on this phone and stored using device secure storage. Never import your existing wallet seed here.',
                ),
                button(
                  'Create rehearsal key',
                  () => task(() async {
                    await session.create();
                    showKit = true;
                    message =
                        'New test key created. Save its recovery kit privately, then verify it below.';
                  }),
                  enabled: storageReady && selfTestPassed,
                ),
              ]),
            if (identity != null)
              panel('2 · Back up and verify recovery', [
                Text('Public fingerprint: ${identity.fingerprint}'),
                const Text(
                  'Save the recovery kit in your own password manager or offline backup. It is PRIVATE. Do not send it to chat, the seller, or XBT Market.',
                ),
                TextButton(
                  onPressed: busy
                      ? null
                      : () => setState(() => showKit = !showKit),
                  child: Text(
                    showKit
                        ? 'Hide private recovery kit'
                        : 'Show private recovery kit',
                  ),
                ),
                if (showKit)
                  Container(
                    padding: const EdgeInsets.all(12),
                    color: const Color(0xffffe5bb),
                    child: SelectableText(
                      identity.recoveryKitFor(widget.role),
                      key: const ValueKey('private-kit'),
                    ),
                  ),
              ]),
            panel(
              identity == null
                  ? 'Restore a rehearsal key'
                  : 'Verify your saved recovery kit',
              [
                TextField(
                  controller: recovery,
                  maxLength: 128,
                  obscureText: true,
                  enableSuggestions: false,
                  autocorrect: false,
                  decoration: InputDecoration(
                    labelText: 'Private rehearsal recovery kit',
                    helperText:
                        'Only this ${widget.role} app’s rehearsal kit. Never a real wallet seed.',
                  ),
                ),
                button(
                  identity == null
                      ? 'Restore rehearsal key'
                      : 'Verify recovery kit',
                  () => task(() async {
                    await session.recover(recovery.text);
                    recovery.clear();
                    showKit = false;
                    request = null;
                    signed = '';
                    approved = false;
                    message =
                        'Recovery verified. The saved kit reproduces this phone’s test key.';
                  }),
                  enabled: storageReady,
                ),
              ],
            ),
            if (identity != null)
              panel('3 · Share PUBLIC enrollment', [
                const Text(
                  'After recovery verification, copy this public enrollment into the Codex chat. It contains no private key or recovery kit. The lab will prepare test transactions for this phone.',
                ),
                SelectableText(identity.publicKey),
                button(
                  'Copy public test enrollment',
                  () => task(() async {
                    await Clipboard.setData(
                      ClipboardData(
                        text: identity.enrollment(role: widget.role),
                      ),
                    );
                    message =
                        'Public test enrollment copied. This is safe to share for the rehearsal.';
                  }),
                  enabled: session.recoveryVerified,
                ),
              ]),
            if (identity != null && storageReady)
              DraftConsentPanel(identity: identity, role: widget.role,
                recoveryVerified: session.recoveryVerified),
            if (identity != null && storageReady)
              ApprovedPayoutPanel(identity: identity, role: widget.role, recoveryVerified: session.recoveryVerified),
            if (identity != null)
              panel('4 · Import and review a test request', [
                const Text(
                  'Paste the test-only request returned by the lab. Funding evidence comes from that isolated lab; it is not independently verified on this offline phone. No mainnet request is supported.',
                ),
                TextField(
                  key: const ValueKey('request'),
                  controller: incoming,
                  maxLines: 5,
                  maxLength: 150000,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: const InputDecoration(
                    labelText: 'Rehearsal request JSON',
                  ),
                  onChanged: (_) => setState(() {
                    request = null;
                    signed = '';
                    approved = false;
                  }),
                ),
                if (session.sharedOrder != null)
                  Text(
                    'Pinned shared order: ${session.sharedOrder!.id}\nBuyer: ${publicFingerprint(session.sharedOrder!.buyer)} · Seller: ${publicFingerprint(session.sharedOrder!.seller)}',
                  ),
                button(
                  'Review shared order setup',
                  () => task(approveSharedOrder),
                  enabled: session.recoveryVerified,
                ),
                button(
                  'Review test transaction',
                  () => task(() async {
                    request = RehearsalRequest.parse(
                      incoming.text,
                      identity,
                      role: widget.role,
                      sharedOrder: session.sharedOrder,
                    );
                    signed = '';
                    approved = false;
                    message =
                        'Check the scenario, recipients and amounts below before signing.';
                  }),
                  enabled: session.recoveryVerified,
                ),
              ]),
            if (request != null)
              panel('5 · Confirm the exact test outcome', [
                if (session.sharedOrder != null)
                  Text(
                    'Shared order: ${session.sharedOrder!.title}\n${session.sharedOrder!.terms}\nContract hash: ${session.sharedOrder!.hash}',
                  ),
                Text('Scenario: ${request!.scenario}'),
                const Text(
                  'Artificial escrow input: 5.00000000 XBT\nNetwork fee: 0.00001000 test XBT',
                ),
                Text(switch (request!.scenario) {
                  'release' => 'Seller test payout: 4.99999000 XBT',
                  'refund' => 'Buyer test refund: 4.99999000 XBT',
                  _ =>
                    'Buyer test refund: 2.00000000 XBT\nSeller test payout: 2.99999000 XBT',
                }),
                Text(
                  'Your role: ${widget.role}\nYour fingerprint: ${identity!.fingerprint}\nBuyer: ${(request!.payload['buyerPublicKey'] as String).substring(0, 16)}…\nSeller: ${(request!.payload['sellerPublicKey'] as String).substring(0, 16)}…\nMarket mediator: ${(request!.payload['marketPublicKey'] as String).substring(0, 16)}…',
                ),
                SelectableText(
                  'Transaction review hash: ${request!.summary['transactionHash']}',
                ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text(
                    'I reviewed these test recipients and amounts. This is not my real purchase.',
                  ),
                  value: approved,
                  onChanged: busy
                      ? null
                      : (value) => setState(() => approved = value ?? false),
                ),
                button(
                  'Sign reviewed test transaction',
                  signReviewed,
                  enabled: approved && session.recoveryVerified,
                ),
              ]),
            if (signed.isNotEmpty)
              panel('6 · Return only the signed test result', [
                const Text(
                  'Copy this public test result into the Codex chat so the isolated XBT node can verify it. It contains a partial test signature, not your private key.',
                ),
                button(
                  'Copy signed test result',
                  () => task(() async {
                    await Clipboard.setData(ClipboardData(text: signed));
                    message =
                        'Signed test result copied. Keep the recovery kit private.';
                  }),
                ),
              ]),
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'Development rehearsal only. No escrow service, deposit address, network access, carrier verification, or real-money payment is offered by this build.',
              ),
            ),
          ],
        ),
      ),
    );
  }
}
