import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../platform/biometric_service.dart';
import '../state/chest_controller.dart';
import '../theme/chest_theme.dart';
import '../widgets/chest_widgets.dart';

/// Unlock screen for an existing vault.
class UnlockScreen extends StatefulWidget {
  const UnlockScreen({super.key});

  @override
  State<UnlockScreen> createState() => _UnlockScreenState();
}

class _UnlockScreenState extends State<UnlockScreen> {
  final _passphrase = TextEditingController();
  bool _obscure = true;
  bool _biometricsAvailable = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _probeBiometrics());
  }

  @override
  void dispose() {
    _passphrase.dispose();
    super.dispose();
  }

  /// Offers the biometric prompt on open when the device supports it.
  ///
  /// This only shortcuts typing the passphrase. The key still comes from the
  /// passphrase, so a user who fails the prompt can simply type it instead.
  Future<void> _probeBiometrics() async {
    final controller = context.read<ChestController>();
    final available = await controller.biometrics.canAuthenticate();
    if (!mounted) return;
    setState(() => _biometricsAvailable = available);
    if (available && controller.biometricsEnabled) {
      await _runBiometricPrompt();
    }
  }

  Future<void> _runBiometricPrompt() async {
    final controller = context.read<ChestController>();
    final outcome = await controller.requestBiometricUnlock();
    if (!mounted) return;

    switch (outcome) {
      case BiometricOutcome.success:
        // The prompt proves presence, not knowledge of the passphrase, so the
        // field is focused for the user to complete the unlock.
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Identity confirmed. Enter your passphrase to open the chest.')),
        );
        break;
      case BiometricOutcome.failed:
      case BiometricOutcome.error:
      case BiometricOutcome.unavailable:
        break;
    }
  }

  Future<void> _submit() async {
    final controller = context.read<ChestController>();
    await controller.unlock(_passphrase.text);
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<ChestController>();

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const ChestMark(size: 84),
                const SizedBox(height: 20),
                const Text(
                  'CHEST',
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 9,
                    color: ChestTheme.goldPale,
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  'SEALED BY DESIGN',
                  style: TextStyle(
                    fontSize: 10,
                    letterSpacing: 3,
                    fontWeight: FontWeight.w600,
                    color: ChestTheme.cyan,
                  ),
                ),
                const SizedBox(height: 36),
                TextField(
                  controller: _passphrase,
                  obscureText: _obscure,
                  autocorrect: false,
                  enableSuggestions: false,
                  autofocus: false,
                  textInputAction: TextInputAction.go,
                  onSubmitted: (_) => _submit(),
                  decoration: InputDecoration(
                    hintText: 'Passphrase',
                    prefixIcon: const Icon(Icons.key_outlined),
                    suffixIcon: IconButton(
                      tooltip: _obscure ? 'Show' : 'Hide',
                      icon: Icon(_obscure ? Icons.visibility_off : Icons.visibility),
                      onPressed: () => setState(() => _obscure = !_obscure),
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                if (controller.error != null) ...[
                  ChestErrorBanner(
                    message: controller.error!,
                    onDismiss: controller.clearError,
                  ),
                  const SizedBox(height: 16),
                ],
                FilledButton.icon(
                  onPressed: controller.busy ? null : _submit,
                  icon: controller.busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.lock_open),
                  label: Text(controller.busy ? 'Opening' : 'Open the chest'),
                ),
                if (_biometricsAvailable) ...[
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: controller.busy ? null : _runBiometricPrompt,
                    icon: const Icon(Icons.fingerprint),
                    label: const Text('Confirm with biometrics'),
                  ),
                ],
                const SizedBox(height: 26),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: ChestTheme.hairline),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.memory, size: 17, color: ChestTheme.cyan),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Key material held in: ${controller.hardware.grade}',
                          style: const TextStyle(
                            color: ChestTheme.muted,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
