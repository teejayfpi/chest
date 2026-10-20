import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/chest_controller.dart';
import '../theme/chest_theme.dart';
import 'chest_widgets.dart';

/// Confirms that the person holding the phone may release a frozen app.
///
/// Releasing is the direction that exposes data, so it is the one gated here.
/// Freezing an app is not gated: it only adds protection.
///
/// Two factors are required when the device offers them:
///
///  1. A **biometric prompt**, proving the person is the enrolled owner.
///  2. The **vault passphrase**, proving knowledge of the secret. This is always
///     required, and the dialog makes that explicit rather than letting a
///     successful fingerprint stand in for it.
///
/// The passphrase is deliberately not optional after biometrics succeed. On a
/// rooted device a fingerprint can be spoofed, and an unattended phone can be
/// held up to a sleeping owner's finger, so a biometric result on its own is a
/// weaker claim than it appears. Biometrics answer "is this the right person";
/// the passphrase answers "does this person know the secret", and only the
/// second one is real evidence.
///
/// The dialog verifies through [ChestController.authorizeRelease], which compares
/// against the key held in memory — no verifier is written to disk. On success it
/// returns the one-shot authorization token that the caller must present to the
/// release call. On any failure it returns null, and nothing is released.
class ProtectedReleaseGate extends StatefulWidget {
  /// What the user is being asked to confirm, for the dialog copy.
  final String actionLabel;

  /// A short description of what will happen, for the dialog copy.
  final String detail;

  const ProtectedReleaseGate({
    super.key,
    required this.actionLabel,
    required this.detail,
  });

  /// Shows the gate and resolves to the authorization token, or null if the user
  /// cancelled or failed to authenticate.
  static Future<String?> show(
    BuildContext context, {
    required String actionLabel,
    required String detail,
  }) {
    return showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => ProtectedReleaseGate(actionLabel: actionLabel, detail: detail),
    );
  }

  @override
  State<ProtectedReleaseGate> createState() => _ProtectedReleaseGateState();
}

class _ProtectedReleaseGateState extends State<ProtectedReleaseGate> {
  final _passphrase = TextEditingController();
  bool _obscure = true;
  bool _working = false;
  String? _error;
  bool _biometricDone = false;
  bool _biometricAvailable = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  @override
  void dispose() {
    _passphrase.dispose();
    super.dispose();
  }

  /// Probes the biometric factor and runs the prompt once, so the natural flow is
  /// fingerprint first, then passphrase.
  Future<void> _start() async {
    final controller = context.read<ChestController>();
    await controller.refreshBiometricAvailability();
    if (!mounted) return;
    setState(() => _biometricAvailable = controller.releaseNeedsBiometric);
    if (_biometricAvailable) {
      await _runBiometric();
    }
  }

  Future<void> _runBiometric() async {
    final controller = context.read<ChestController>();
    setState(() {
      _working = true;
      _error = null;
    });
    final ok = await controller.confirmReleaseWithBiometrics();
    if (!mounted) return;
    setState(() {
      _working = false;
      _biometricDone = ok;
      if (!ok) {
        _error = 'Biometric check did not pass. Try again, or use your passphrase.';
      }
    });
  }

  Future<void> _submit() async {
    final controller = context.read<ChestController>();
    final navigator = Navigator.of(context);

    setState(() {
      _working = true;
      _error = null;
    });

    final result = await controller.authorizeRelease(_passphrase.text);
    if (!mounted) return;

    if (result.authorized) {
      // Hand the caller a one-shot token rather than a bare success flag.
      navigator.pop(controller.pendingReleaseAuthorization);
      return;
    }

    setState(() {
      _working = false;
      // A failed attempt consumed the biometric factor, so the step must go back
      // to incomplete. Leaving it on "PASSED" would tell the user the first
      // factor is still satisfied when the controller has already spent it.
      _biometricDone = false;
      switch (result.decision) {
        case ReleaseDecision.vaultLocked:
          _error = 'The vault locked. Unlock it again before releasing an app.';
        case ReleaseDecision.throttled:
          final seconds = (result.retryAfter ?? Duration.zero).inSeconds;
          _error = 'Too many attempts. Wait ${seconds}s before trying again.';
        case ReleaseDecision.wrongPassphrase:
          final left = result.attemptsRemaining ?? 0;
          _error = left > 0
              ? 'That is not your passphrase. $left ${left == 1 ? 'try' : 'tries'} left.'
              : 'That is not your passphrase. Releasing is locked for a while.';
        case ReleaseDecision.authorized:
          break;
      }
    });
    _passphrase.clear();
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<ChestController>();
    final needsBiometric = controller.releaseNeedsBiometric;
    // Either the dialog is mid-flight or the controller is still deriving a key,
    // so the button must not offer a second attempt.
    final busy = _working || controller.authorizingRelease;

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        decoration: const BoxDecoration(
          color: ChestTheme.slate,
          borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
          border: Border(top: BorderSide(color: ChestTheme.hairline)),
        ),
        padding: const EdgeInsets.fromLTRB(22, 16, 22, 26),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 42,
                height: 4,
                decoration: BoxDecoration(
                  color: ChestTheme.hairline,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                const Icon(Icons.lock_person_outlined, color: ChestTheme.gold, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Confirm to ${widget.actionLabel}',
                    style: const TextStyle(
                      color: ChestTheme.parchment,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              widget.detail,
              style: const TextStyle(
                color: ChestTheme.muted,
                fontSize: 12.5,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 16),

            // Step 1 — biometrics, when the device can offer them.
            if (needsBiometric) ...[
              _StepRow(
                index: 1,
                label: 'Biometric check',
                done: _biometricDone,
                trailing: _biometricDone
                    ? const ChestChip(label: 'PASSED', color: ChestTheme.moss, icon: Icons.check)
                    : TextButton(
                        onPressed: busy ? null : _runBiometric,
                        child: const Text('Retry'),
                      ),
              ),
              const SizedBox(height: 14),
            ],

            // Step 2 — the passphrase, always required.
            _StepRow(
              index: needsBiometric ? 2 : 1,
              label: 'Vault passphrase',
              done: false,
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _passphrase,
              obscureText: _obscure,
              autocorrect: false,
              enableSuggestions: false,
              autofocus: false,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => busy ? null : _submit(),
              decoration: InputDecoration(
                hintText: 'Your passphrase',
                prefixIcon: const Icon(Icons.key_outlined),
                suffixIcon: IconButton(
                  tooltip: _obscure ? 'Show' : 'Hide',
                  icon: Icon(_obscure ? Icons.visibility_off : Icons.visibility),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              needsBiometric
                  ? 'Your fingerprint is not enough on its own. The passphrase is what '
                      'proves you know the secret, so both are required to release an app.'
                  : 'No biometrics are enrolled on this device, so the passphrase is the '
                      'only factor available.',
              style: const TextStyle(color: ChestTheme.muted, fontSize: 11.5, height: 1.45),
            ),

            if (_error != null) ...[
              const SizedBox(height: 14),
              ChestErrorBanner(message: _error!),
            ],

            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: busy ? null : () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: busy ? null : _submit,
                    icon: busy
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.lock_open),
                    label: Text(busy ? 'Checking' : 'Release'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// A numbered step in the two-factor prompt.
class _StepRow extends StatelessWidget {
  const _StepRow({
    required this.index,
    required this.label,
    required this.done,
    this.trailing,
  });

  final int index;
  final String label;
  final bool done;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 22,
          height: 22,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: (done ? ChestTheme.moss : ChestTheme.gold).withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(7),
          ),
          child: done
              ? const Icon(Icons.check, size: 13, color: ChestTheme.moss)
              : Text(
                  '$index',
                  style: const TextStyle(
                    color: ChestTheme.gold,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                  ),
                ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            label,
            style: const TextStyle(
              color: ChestTheme.parchment,
              fontSize: 13.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        ?trailing,
      ],
    );
  }
}
