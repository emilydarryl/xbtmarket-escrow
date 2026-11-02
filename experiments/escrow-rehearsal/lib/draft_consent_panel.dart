import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'draft_consent.dart';
import 'funding_draft.dart';
import 'rehearsal.dart';

/// Offline public challenge/proof transport. Never writes keys or saved orders.
class DraftConsentPanel extends StatefulWidget {
  const DraftConsentPanel({
    super.key,
    required this.identity,
    required this.role,
    required this.recoveryVerified,
    this.now,
  });
  final RehearsalIdentity identity;
  final String role;
  final bool recoveryVerified;
  final int Function()? now;
  @override
  State<DraftConsentPanel> createState() => _DraftConsentPanelState();
}

class _DraftConsentPanelState extends State<DraftConsentPanel>
    with WidgetsBindingObserver {
  final incoming = TextEditingController();
  final expectedHash = TextEditingController();
  final audience = TextEditingController();
  DraftConsentRequest? request;
  bool approved = false, confirming = false;
  String proof = '', status = '';
  int generation = 0;
  int get now => widget.now?.call() ?? DateTime.now().millisecondsSinceEpoch;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    for (final controller in [incoming, expectedHash, audience]) {
      controller.addListener(invalidate);
    }
  }

  void invalidate() {
    if (!mounted) return;
    setState(() {
      generation++;
      request = null;
      approved = false;
      proof = '';
      status = '';
    });
  }

  @override
  void didUpdateWidget(covariant DraftConsentPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.identity.publicKey != widget.identity.publicKey ||
        oldWidget.role != widget.role ||
        oldWidget.recoveryVerified != widget.recoveryVerified) {
      invalidate();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) invalidate();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    for (final controller in [incoming, expectedHash, audience]) {
      controller.removeListener(invalidate);
      controller.dispose();
    }
    super.dispose();
  }

  void review() {
    invalidate();
    try {
      if (!widget.recoveryVerified) throw const FormatException();
      final parsed = DraftConsentRequest.parse(
        incoming.text,
        expectedDraftHash: expectedHash.text.trim(),
        audience: audience.text.trim(),
        ownPublicKey: widget.identity.publicKey,
        role: widget.role,
        now: now,
      );
      setState(() {
        request = parsed;
        status =
            'Review the complete draft below. No deposit or payment is authorized.';
      });
    } catch (_) {
      setState(
        () => status =
            'Cannot review this request. Check the independently copied draft hash, test origin, role and expiry. Request a fresh challenge if needed.',
      );
    }
  }

  Future<void> sign() async {
    final reviewed = request, version = generation;
    if (confirming ||
        !approved ||
        reviewed == null ||
        !widget.recoveryVerified) {
      return;
    }
    setState(() => confirming = true);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Approve this unfunded test draft?'),
        content: SingleChildScrollView(
          child: Text(
            'Order: ${reviewed.draft.orderId}\nDraft hash: ${reviewed.draft.hash}\n\n'
            'This signs a key-control and draft-approval message only. It cannot fund escrow, authorize shipping, sign a payment or broadcast a transaction.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('consent-confirm'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Approve unfunded draft'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    setState(() => confirming = false);
    if (confirmed != true ||
        version != generation ||
        !identical(request, reviewed) ||
        !approved ||
        !widget.recoveryVerified) {
      return;
    }
    try {
      final result = reviewed.sign(
        widget.identity.key,
        confirmUnfunded: true,
        recoveryVerified: widget.recoveryVerified,
        now: now,
      );
      setState(() {
        proof = jsonEncode(result);
        approved = false;
        status =
            'Public approval proof ready. Return it to the same local test order before the challenge expires. Server acceptance is still required.';
      });
    } catch (_) {
      invalidate();
      setState(
        () => status =
            'Approval expired or became invalid. Review a fresh challenge; no proof was created.',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final draft = request?.draft;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Unfunded contract approval',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const Text(
              'TEST ONLY · No payment or shipping authorization. This separate flow leaves your saved test order and key unchanged.',
            ),
            const Text(
              'Copy the expected draft hash and local test origin from the authenticated order screen separately from the challenge JSON. Do not take these values from an untrusted message. The origin identifies the laptop test service; this phone does not connect to it.',
            ),
            TextField(
              key: const ValueKey('consent-hash'),
              controller: expectedHash,
              maxLength: 64,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(
                labelText: 'Expected draft hash from order screen',
              ),
            ),
            TextField(
              key: const ValueKey('consent-audience'),
              controller: audience,
              maxLength: 128,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(
                labelText: 'Local test origin',
                hintText: 'http://127.0.0.1:4364',
              ),
            ),
            TextField(
              key: const ValueKey('consent-request'),
              controller: incoming,
              maxLines: 4,
              maxLength: 40000,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(
                labelText: 'Public unfunded challenge JSON',
              ),
            ),
            FilledButton(
              key: const ValueKey('consent-review'),
              onPressed: widget.recoveryVerified && !confirming ? review : null,
              child: const Text('Review unfunded draft'),
            ),
            if (!widget.recoveryVerified)
              const Text(
                'Verify your saved recovery kit above before approving a draft.',
              ),
            if (draft != null) ...[
              Text(
                'Your role: ${widget.role}\nOrder: ${draft.orderId}\n'
                'Seller price: ${FundingDraft.xbt(draft.sellerPrice)} test XBT\n'
                'Buyer network-fee reserve: ${FundingDraft.xbt(draft.reserve)} test XBT\n'
                'Total proposed deposit: ${FundingDraft.xbt(draft.deposit)} test XBT',
              ),
              const Text(
                'Buyer pays the network fee from the additional reserve. Unused reserve returns to the buyer. No platform fee is included. This draft has no funding address.',
              ),
              Text(
                'Challenge expires: ${DateTime.fromMillisecondsSinceEpoch(request!.expiresAt).toUtc().toIso8601String()}',
              ),
              const Text(
                'Complete contract: compare terms, all three public keys, snapshot and fee policy with your order.',
              ),
              SelectableText(
                draft.reviewJson,
                key: const ValueKey('consent-contract'),
              ),
              CheckboxListTile(
                key: const ValueKey('consent-reviewed'),
                contentPadding: EdgeInsets.zero,
                title: const Text(
                  'I checked the terms, keys, price, reserve and draft hash. I approve only this unfunded test draft.',
                ),
                value: approved,
                onChanged: confirming
                    ? null
                    : (value) => setState(() => approved = value ?? false),
              ),
              FilledButton(
                key: const ValueKey('consent-sign'),
                onPressed: approved && widget.recoveryVerified && !confirming
                    ? sign
                    : null,
                child: const Text('Create public draft approval'),
              ),
            ],
            if (proof.isNotEmpty)
              FilledButton(
                key: const ValueKey('consent-copy'),
                onPressed: () async {
                  if (request == null || now >= request!.expiresAt) {
                    invalidate();
                    setState(
                      () => status =
                          'Challenge expired. Request and review a fresh challenge.',
                    );
                    return;
                  }
                  await Clipboard.setData(ClipboardData(text: proof));
                  if (mounted) {
                    setState(
                      () => status =
                          'Public draft approval copied. Paste it into the same local order. No private key is included.',
                    );
                  }
                },
                child: const Text('Copy public draft approval'),
              ),
            if (status.isNotEmpty)
              Semantics(
                liveRegion: true,
                child: Text(status, key: const ValueKey('consent-status')),
              ),
          ],
        ),
      ),
    );
  }
}
