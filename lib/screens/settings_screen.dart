import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../crypto/cascade_cipher.dart';
import '../state/chest_controller.dart';
import '../theme/chest_theme.dart';
import '../widgets/chest_widgets.dart';

/// Settings and the security posture report.
///
/// The report states what is actually protecting the vault on *this* device
/// rather than repeating marketing claims: which KDF preset is in force, where
/// the platform holds key material, and whether freezing is enforced by the OS
/// or only by Chest's own guard service.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  /// The ordered layers, for display.
  static const List<(String, String)> layers = [
    ('Argon2id', 'Memory-hard passphrase stretching with a 128-bit salt'),
    ('HKDF-SHA256', 'Splits the root key into four independent subkeys'),
    ('AES-256-GCM', 'Authenticated encryption of the padded plaintext'),
    ('XChaCha20-Poly1305', 'A second, independent cipher over the first output'),
    ('HMAC-SHA256', 'Header and envelope tags binding every field'),
  ];

  Future<void> _confirmDestroy(BuildContext context) async {
    final controller = context.read<ChestController>();
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Destroy the vault?'),
        content: const Text(
          'Every sealed file and the encrypted index will be deleted from this device. '
          'There is no recovery and no backup. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Keep my vault'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: ChestTheme.ember),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Destroy'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;
    controller.lock();
    await controller.vault.destroy();
    if (navigator.mounted) navigator.popUntil((route) => route.isFirst);
    messenger.showSnackBar(const SnackBar(content: Text('The vault was destroyed.')));
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<ChestController>();
    final capabilities = controller.capabilities;
    final hardware = controller.hardware;
    final descriptor = controller.isUnlocked ? controller.vault : null;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        actions: [
          IconButton(
            tooltip: 'Back to the chest',
            icon: const Icon(Icons.inventory_2_outlined),
            onPressed: () => controller.goTo(ChestRoute.vault),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(18, 8, 18, 40),
        children: [
          const ChestSectionHeader(title: 'Encryption in force'),
          ChestPanel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < layers.length; i++) ...[
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 22,
                        height: 22,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: ChestTheme.gold.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(7),
                        ),
                        child: Text(
                          '${i + 1}',
                          style: const TextStyle(
                            color: ChestTheme.gold,
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      const SizedBox(width: 11),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              layers[i].$1,
                              style: const TextStyle(
                                color: ChestTheme.parchment,
                                fontSize: 13.5,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              layers[i].$2,
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
                  if (i != layers.length - 1) const SizedBox(height: 14),
                ],
              ],
            ),
          ),
          const SizedBox(height: 22),
          const ChestSectionHeader(title: 'This device'),
          ChestPanel(
            child: Column(
              children: [
                ChestKeyValue(
                  label: 'Key storage',
                  value: hardware.grade,
                  valueColor: hardware.insideSecureHardware
                      ? ChestTheme.moss
                      : ChestTheme.gold,
                ),
                ChestKeyValue(
                  label: 'StrongBox',
                  value: hardware.strongBoxAvailable ? 'Present' : 'Not present',
                ),
                ChestKeyValue(
                  label: 'Android API',
                  value: capabilities.sdkInt == 0 ? 'Unknown' : '${capabilities.sdkInt}',
                ),
                ChestKeyValue(
                  label: 'Format version',
                  value: 'v${CascadeCipher.formatVersion}',
                ),
                if (hardware.error != null)
                  ChestKeyValue(
                    label: 'Probe note',
                    value: hardware.error!,
                    valueColor: ChestTheme.muted,
                    mono: true,
                  ),
              ],
            ),
          ),
          const SizedBox(height: 22),
          const ChestSectionHeader(title: 'Freeze enforcement'),
          ChestPanel(
            child: Column(
              children: [
                ChestKeyValue(
                  label: 'Device owner',
                  value: capabilities.canHideApps ? 'Active' : 'Not set up',
                  valueColor: capabilities.canHideApps
                      ? ChestTheme.moss
                      : ChestTheme.gold,
                ),
                ChestKeyValue(
                  label: 'Device admin',
                  value: capabilities.deviceAdminActive ? 'Granted' : 'Not granted',
                  valueColor: capabilities.deviceAdminActive
                      ? ChestTheme.moss
                      : ChestTheme.muted,
                ),
                ChestKeyValue(
                  label: 'App guard service',
                  value: capabilities.accessibilityEnabled ? 'Running' : 'Off',
                  valueColor: capabilities.accessibilityEnabled
                      ? ChestTheme.moss
                      : ChestTheme.muted,
                ),
                ChestKeyValue(
                  label: 'Apps hidden',
                  value: '${capabilities.hiddenCount}',
                  valueColor: capabilities.hiddenCount > 0
                      ? ChestTheme.moss
                      : ChestTheme.muted,
                ),
                const SizedBox(height: 10),
                Text(
                  capabilities.canHideApps
                      ? 'Chest is the device owner, so frozen apps are removed from '
                          'the launcher and cannot be started.'
                      : 'Without device-owner provisioning Chest cannot hide an app '
                          'from the launcher. See the Freezer screen for the one-time '
                          'setup command.',
                  style: const TextStyle(
                    color: ChestTheme.muted,
                    fontSize: 12,
                    height: 1.45,
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () async {
                          await controller.appLock.requestDeviceAdmin();
                          await controller.refreshCapabilities();
                        },
                        child: const Text('Device admin'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton(
                        onPressed: controller.appLock.openAccessibilitySettings,
                        child: const Text('App guard'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 22),
          const ChestSectionHeader(title: 'Unlocking'),
          ChestPanel(
            child: Column(
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: controller.biometricsEnabled,
                  onChanged: controller.setBiometricsEnabled,
                  title: const Text(
                    'Offer biometric prompt',
                    style: TextStyle(color: ChestTheme.parchment, fontSize: 14),
                  ),
                  subtitle: const Text(
                    'Convenience only. The vault key still comes from your passphrase, so a biometric prompt can never open the chest on its own.',
                    style: TextStyle(color: ChestTheme.muted, fontSize: 12, height: 1.4),
                  ),
                ),
                const Divider(height: 22),
                ChestKeyValue(
                  label: 'Auto-lock',
                  value: '${controller.autoLockAfter.inMinutes} minutes idle',
                ),
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    onPressed: controller.lock,
                    icon: const Icon(Icons.lock_outline, size: 17),
                    label: const Text('Lock now'),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 22),
          const ChestSectionHeader(title: 'Privacy'),
          const ChestPanel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _PrivacyRow(
                  icon: Icons.wifi_off,
                  text: 'Chest requests no network permission. There is no code path '
                      'that can send your data anywhere, including one added by a future dependency.',
                ),
                SizedBox(height: 13),
                _PrivacyRow(
                  icon: Icons.backup_outlined,
                  text: 'Cloud backup and device transfer are switched off, so sealed '
                      'files never leave this handset without you moving them deliberately.',
                ),
                SizedBox(height: 13),
                _PrivacyRow(
                  icon: Icons.visibility_off_outlined,
                  text: 'The app guard service cannot read window content. It compares '
                      'package names only.',
                ),
              ],
            ),
          ),
          const SizedBox(height: 26),
          const ChestSectionHeader(title: 'Danger zone'),
          ChestPanel(
            accent: ChestTheme.ember,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Destroying the vault deletes every sealed file and the encrypted index.',
                  style: TextStyle(color: ChestTheme.muted, fontSize: 12.5, height: 1.5),
                ),
                const SizedBox(height: 13),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: ChestTheme.ember,
                    side: const BorderSide(color: ChestTheme.ember),
                  ),
                  onPressed: () => _confirmDestroy(context),
                  icon: const Icon(Icons.delete_forever_outlined, size: 18),
                  label: const Text('Destroy the vault'),
                ),
              ],
            ),
          ),
          if (descriptor != null) const SizedBox(height: 0),
          const SizedBox(height: 24),
          const Center(
            child: Text(
              'Chest · sealed by design',
              style: TextStyle(color: ChestTheme.muted, fontSize: 11.5, letterSpacing: 0.6),
            ),
          ),
        ],
      ),
    );
  }
}

class _PrivacyRow extends StatelessWidget {
  const _PrivacyRow({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 17, color: ChestTheme.cyan),
        const SizedBox(width: 11),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(color: ChestTheme.muted, fontSize: 12.5, height: 1.5),
          ),
        ),
      ],
    );
  }
}
