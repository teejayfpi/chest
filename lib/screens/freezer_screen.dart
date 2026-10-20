import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/vault_models.dart';
import '../state/chest_controller.dart';
import '../theme/chest_theme.dart';
import '../widgets/chest_widgets.dart';

/// Freeze screen: choose apps to disable at the operating-system level.
class FreezerScreen extends StatefulWidget {
  const FreezerScreen({super.key});

  @override
  State<FreezerScreen> createState() => _FreezerScreenState();
}

class _FreezerScreenState extends State<FreezerScreen> {
  final _search = TextEditingController();
  String _filter = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<ChestController>().loadApps();
    });
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// Re-reads native state, for use when returning from a Settings page.
  Future<void> _refresh() async {
    final controller = context.read<ChestController>();
    await controller.loadApps();
  }

  Future<void> _toggle(FreezableApp app) async {
    final controller = context.read<ChestController>();
    final messenger = ScaffoldMessenger.of(context);
    final result = await controller.toggleFreeze(app);

    final String message;
    if (app.frozen) {
      message = result.applied
          ? '${app.label} is back in the launcher.'
          : '${app.label} released from the freeze list.';
    } else if (result.isHard) {
      message = '${app.label} hidden from the launcher.';
    } else if (result.method == 'protected') {
      message = '${app.label} is protected and cannot be frozen.';
    } else {
      message = '${app.label} could not be hidden. Set up device owner first.';
    }
    messenger.showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<ChestController>();
    final capabilities = controller.capabilities;

    final apps = controller.apps.where((app) {
      if (_filter.isEmpty) return true;
      return app.label.toLowerCase().contains(_filter) ||
          app.packageName.toLowerCase().contains(_filter);
    }).toList();

    final frozenCount = controller.apps.where((a) => a.frozen).length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Freezer'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: _refresh,
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 6, 18, 12),
            child: Column(
              children: [
                _EnforcementPanel(capabilities: capabilities, frozenCount: frozenCount),
                const SizedBox(height: 14),
                TextField(
                  controller: _search,
                  onChanged: (value) => setState(() => _filter = value.toLowerCase()),
                  decoration: const InputDecoration(
                    hintText: 'Search apps',
                    prefixIcon: Icon(Icons.search),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: controller.busy && controller.apps.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : apps.isEmpty
                    ? const _NoApps()
                    : RefreshIndicator(
                        onRefresh: _refresh,
                        color: ChestTheme.gold,
                        backgroundColor: ChestTheme.slate,
                        child: ListView.separated(
                          padding: const EdgeInsets.fromLTRB(18, 0, 18, 30),
                          itemCount: apps.length,
                          separatorBuilder: (_, _) => const SizedBox(height: 9),
                          itemBuilder: (context, index) {
                            final app = apps[index];
                            return _AppTile(
                              app: app,
                              onToggle: () => _toggle(app),
                              onOpenSettings: () =>
                                  controller.appLock.openAppDetailsSettings(app.packageName),
                            );
                          },
                        ),
                      ),
          ),
        ],
      ),
    );
  }
}

/// Explains which enforcement tier is active, and offers to fix it.
///
/// Being explicit here matters. Hiding an app from the launcher requires Chest
/// to be provisioned as device owner, which is a deliberate, one-time step the
/// user has to perform on a computer. Without it a freeze cannot remove the app
/// from the launcher at all, so the panel says so rather than implying a hide
/// happened when it did not.
class _EnforcementPanel extends StatelessWidget {
  const _EnforcementPanel({required this.capabilities, required this.frozenCount});

  final FreezeCapabilities capabilities;
  final int frozenCount;

  @override
  Widget build(BuildContext context) {
    final controller = context.read<ChestController>();
    final canHide = capabilities.canHideApps;

    return ChestPanel(
      accent: canHide ? ChestTheme.moss : ChestTheme.gold,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                canHide ? Icons.visibility_off : Icons.shield_outlined,
                size: 19,
                color: canHide ? ChestTheme.moss : ChestTheme.gold,
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  canHide ? 'Launcher hiding active' : 'Device owner not set up',
                  style: TextStyle(
                    color: canHide ? ChestTheme.moss : ChestTheme.gold,
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                  ),
                ),
              ),
              ChestChip(
                label: '$frozenCount frozen',
                color: ChestTheme.muted,
                icon: Icons.ac_unit,
              ),
            ],
          ),
          const SizedBox(height: 9),
          Text(
            canHide
                ? 'Frozen apps are hidden from your launcher and cannot be started. Their data is kept, and they come back the moment you unfreeze them.'
                : 'Chest needs to be the device owner before it can hide an app from the launcher. '
                    'This is a one-time setup that needs a computer and, usually, a freshly reset phone.',
            style: const TextStyle(color: ChestTheme.muted, fontSize: 12.5, height: 1.5),
          ),
          if (!canHide) ...[
            const SizedBox(height: 13),
            _SetupCommand(command: capabilities.provisioningCommand),
          ],
          const SizedBox(height: 13),
          Wrap(
            spacing: 9,
            runSpacing: 9,
            children: [
              if (!canHide)
                _PanelAction(
                  icon: Icons.admin_panel_settings_outlined,
                  label: 'Grant device admin',
                  emphasised: true,
                  onPressed: () async {
                    await controller.appLock.requestDeviceAdmin();
                    await controller.refreshCapabilities();
                  },
                ),
              if (!capabilities.accessibilityEnabled)
                _PanelAction(
                  icon: Icons.accessibility_new,
                  label: 'Enable app guard',
                  emphasised: false,
                  onPressed: () async {
                    await controller.appLock.openAccessibilitySettings();
                  },
                ),
              if (capabilities.anyEnforcement || canHide)
                _PanelAction(
                  icon: Icons.refresh,
                  label: 'Re-check',
                  onPressed: controller.refreshCapabilities,
                ),
              if (frozenCount > 0)
                _PanelAction(
                  icon: Icons.lock_open,
                  label: 'Restore all',
                  onPressed: () async {
                    final messenger = ScaffoldMessenger.of(context);
                    final restored = await controller.unhideAll();
                    messenger.showSnackBar(
                      SnackBar(
                        content: Text(
                          restored == 1
                              ? '1 app restored to the launcher.'
                              : '$restored apps restored to the launcher.',
                        ),
                      ),
                    );
                  },
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Shows the `dpm set-device-owner` command with a copy button.
class _SetupCommand extends StatelessWidget {
  const _SetupCommand({required this.command});

  final String command;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                'Run this once over USB with adb:',
                style: TextStyle(color: ChestTheme.muted, fontSize: 12),
              ),
            ),
            IconButton(
              tooltip: 'Copy command',
              icon: const Icon(Icons.copy_all, size: 16, color: ChestTheme.gold),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: command));
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Command copied.')),
                );
              },
            ),
          ],
        ),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
          decoration: BoxDecoration(
            color: ChestTheme.obsidian,
            borderRadius: BorderRadius.circular(9),
            border: Border.all(color: ChestTheme.hairline),
          ),
          child: SelectableText(
            command,
            style: ChestTheme.mono.copyWith(fontSize: 11, color: ChestTheme.parchment),
          ),
        ),
        const SizedBox(height: 7),
        const Text(
          'The device must have no accounts and no other users, so this usually '
          'means a factory reset first. Setting up device owner also lets Chest '
          'wipe the device; Chest never does.',
          style: TextStyle(color: ChestTheme.muted, fontSize: 11.5, height: 1.45),
        ),
      ],
    );
  }
}

class _PanelAction extends StatelessWidget {
  const _PanelAction({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.emphasised = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final bool emphasised;

  @override
  Widget build(BuildContext context) {
    final style = emphasised
        ? FilledButton.styleFrom(
            backgroundColor: ChestTheme.gold,
            foregroundColor: ChestTheme.obsidian,
            minimumSize: const Size(0, 40),
            padding: const EdgeInsets.symmetric(horizontal: 15),
            textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
          )
        : OutlinedButton.styleFrom(
            foregroundColor: ChestTheme.parchment,
            minimumSize: const Size(0, 40),
            padding: const EdgeInsets.symmetric(horizontal: 15),
            side: const BorderSide(color: ChestTheme.hairline),
            textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          );

    final child = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 15),
        const SizedBox(width: 7),
        Text(label),
      ],
    );

    return emphasised
        ? FilledButton(style: style, onPressed: onPressed, child: child)
        : OutlinedButton(style: style, onPressed: onPressed, child: child);
  }
}

class _AppTile extends StatelessWidget {
  const _AppTile({
    required this.app,
    required this.onToggle,
    required this.onOpenSettings,
  });

  final FreezableApp app;
  final VoidCallback onToggle;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    return ChestPanel(
      padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
      accent: app.frozen ? ChestTheme.gold : null,
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: app.frozen
                  ? ChestTheme.gold.withValues(alpha: 0.12)
                  : ChestTheme.hairline.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Text(
              app.label.isEmpty ? '?' : app.label.characters.first.toUpperCase(),
              style: TextStyle(
                color: app.frozen ? ChestTheme.gold : ChestTheme.muted,
                fontWeight: FontWeight.w800,
                fontSize: 15,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        app.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: ChestTheme.parchment,
                          fontSize: 14.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (app.isSystem) ...[
                      const SizedBox(width: 7),
                      const ChestChip(label: 'SYSTEM', color: ChestTheme.muted),
                    ],
                    // Only shown when the platform actually removed the app
                    // from the launcher, so the badge cannot overstate things.
                    if (app.hidden) ...[
                      const SizedBox(width: 7),
                      const ChestChip(
                        label: 'HIDDEN',
                        color: ChestTheme.moss,
                        icon: Icons.visibility_off,
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  app.packageName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ChestTheme.mono.copyWith(fontSize: 11),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'App info',
            icon: const Icon(Icons.info_outline, size: 18, color: ChestTheme.muted),
            onPressed: onOpenSettings,
          ),
          Switch(value: app.frozen, onChanged: (_) => onToggle()),
        ],
      ),
    );
  }
}

class _NoApps extends StatelessWidget {
  const _NoApps();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.apps_outage, size: 48, color: ChestTheme.muted),
            SizedBox(height: 16),
            Text(
              'No apps to show',
              style: TextStyle(
                color: ChestTheme.parchment,
                fontSize: 17,
                fontWeight: FontWeight.w700,
              ),
            ),
            SizedBox(height: 8),
            Text(
              'Chest lists launchable apps on this device. On a device without the Android bridge, this list stays empty.',
              textAlign: TextAlign.center,
              style: TextStyle(color: ChestTheme.muted, fontSize: 13, height: 1.5),
            ),
          ],
        ),
      ),
    );
  }
}
