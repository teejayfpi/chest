import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../crypto/key_derivation.dart';
import '../state/chest_controller.dart';
import '../theme/chest_theme.dart';
import '../widgets/chest_widgets.dart';

/// First-run screen: explains what Chest does, then creates the vault.
class CreateVaultScreen extends StatefulWidget {
  const CreateVaultScreen({super.key});

  @override
  State<CreateVaultScreen> createState() => _CreateVaultScreenState();
}

class _CreateVaultScreenState extends State<CreateVaultScreen> {
  final _passphrase = TextEditingController();
  final _confirm = TextEditingController();
  bool _obscure = true;
  String? _localError;

  @override
  void dispose() {
    _passphrase.dispose();
    _confirm.dispose();
    super.dispose();
  }

  /// Minimum accepted length.
  ///
  /// Argon2id is the real defence, but a short passphrase still collapses to a
  /// guessable search space, so a floor is enforced before the vault is created.
  static const int minimumLength = 12;

  Future<void> _submit() async {
    final controller = context.read<ChestController>();
    final passphrase = _passphrase.text;

    if (passphrase.length < minimumLength) {
      setState(() => _localError = 'Use at least $minimumLength characters.');
      return;
    }
    if (passphrase != _confirm.text) {
      setState(() => _localError = 'The two passphrases do not match.');
      return;
    }
    setState(() => _localError = null);

    final ok = await controller.createVault(passphrase);
    if (!ok && mounted) {
      setState(() => _localError = controller.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<ChestController>();
    final error = _localError ?? controller.error;

    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(22, 32, 22, 32),
          children: [
            const Center(child: ChestMark(size: 96)),
            const SizedBox(height: 22),
            const Center(
              child: Text(
                'CHEST',
                style: TextStyle(
                  fontSize: 34,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 10,
                  color: ChestTheme.goldPale,
                ),
              ),
            ),
            const SizedBox(height: 6),
            const Center(
              child: Text(
                'SEALED BY DESIGN',
                style: TextStyle(
                  fontSize: 11,
                  letterSpacing: 3.4,
                  fontWeight: FontWeight.w600,
                  color: ChestTheme.cyan,
                ),
              ),
            ),
            const SizedBox(height: 30),
            const ChestPanel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _Feature(
                    icon: Icons.enhanced_encryption,
                    title: 'Five-layer encryption',
                    body:
                        'Argon2id stretches your passphrase, HKDF splits it into four independent keys, then every file is sealed with AES-256-GCM inside XChaCha20-Poly1305 and wrapped in two HMAC envelopes.',
                  ),
                  SizedBox(height: 16),
                  _Feature(
                    icon: Icons.fingerprint,
                    title: 'Keys never leave the device',
                    body:
                        'Your passphrase is never stored. Chest holds the derived key only while the vault is unlocked, then wipes it from memory.',
                  ),
                  SizedBox(height: 16),
                  _Feature(
                    icon: Icons.ac_unit,
                    title: 'Freeze other apps',
                    body:
                        'Disable chosen apps at the operating-system level so they cannot run until you release them.',
                  ),
                ],
              ),
            ),
            const SizedBox(height: 26),
            const ChestSectionHeader(title: 'Create your passphrase'),
            TextField(
              controller: _passphrase,
              obscureText: _obscure,
              autocorrect: false,
              enableSuggestions: false,
              onChanged: (_) => setState(() {}),
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
            const SizedBox(height: 12),
            PassphraseStrengthBar(passphrase: _passphrase.text),
            const SizedBox(height: 16),
            TextField(
              controller: _confirm,
              obscureText: _obscure,
              autocorrect: false,
              enableSuggestions: false,
              onChanged: (_) => setState(() => _localError = null),
              decoration: const InputDecoration(
                hintText: 'Confirm passphrase',
                prefixIcon: Icon(Icons.lock_outline),
              ),
            ),
            const SizedBox(height: 20),
            const ChestSectionHeader(title: 'Key stretching preset'),
            _ProfileSelector(
              selected: controller.profile,
              onChanged: controller.setProfile,
            ),
            const SizedBox(height: 22),
            if (error != null) ...[
              ChestErrorBanner(
                message: error,
                onDismiss: () {
                  setState(() => _localError = null);
                  controller.clearError();
                },
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
                  : const Icon(Icons.lock),
              label: Text(controller.busy ? 'Sealing the chest' : 'Create vault'),
            ),
            const SizedBox(height: 14),
            const Text(
              'There is no recovery. If you lose this passphrase, the contents of the chest are unrecoverable — that is what makes it a chest.',
              textAlign: TextAlign.center,
              style: TextStyle(color: ChestTheme.muted, fontSize: 12, height: 1.5),
            ),
          ],
        ),
      ),
    );
  }
}

class _Feature extends StatelessWidget {
  const _Feature({required this.icon, required this.title, required this.body});

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(9),
          decoration: BoxDecoration(
            color: ChestTheme.gold.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(11),
          ),
          child: Icon(icon, size: 19, color: ChestTheme.gold),
        ),
        const SizedBox(width: 13),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  color: ChestTheme.parchment,
                  fontSize: 14.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                body,
                style: const TextStyle(
                  color: ChestTheme.muted,
                  fontSize: 12.5,
                  height: 1.5,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Lets the user trade unlock time against resistance to guessing.
class _ProfileSelector extends StatelessWidget {
  const _ProfileSelector({required this.selected, required this.onChanged});

  final KdfProfile selected;
  final ValueChanged<KdfProfile> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (final profile in KdfProfile.values)
          Padding(
            padding: const EdgeInsets.only(bottom: 9),
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: () => onChanged(profile),
              child: Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: ChestTheme.slate,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: profile == selected ? ChestTheme.gold : ChestTheme.hairline,
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      profile == selected
                          ? Icons.radio_button_checked
                          : Icons.radio_button_unchecked,
                      size: 19,
                      color: profile == selected ? ChestTheme.gold : ChestTheme.muted,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            profile.label,
                            style: const TextStyle(
                              color: ChestTheme.parchment,
                              fontWeight: FontWeight.w700,
                              fontSize: 14,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            profile.description,
                            style: const TextStyle(
                              color: ChestTheme.muted,
                              fontSize: 12,
                              height: 1.4,
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
      ],
    );
  }
}
