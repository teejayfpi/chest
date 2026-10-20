import 'package:flutter/material.dart';
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
          ? '${app.label} released.'
          : '${app.label} released from the freeze list.';
    } else {
      message = result.isHard
          ? '${app.label} frozen and disabled by the system.'
          : '${app.label} added to the freeze list. Grant device admin for a hard freeze.';
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
                              hardFreezeAvailable: capabilities.hardFreezeAvailable,
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

/// Explains which enforcement tier is currently active, and offers to fix it.
///
/// Being explicit here matters: a "soft" freeze only bounces the user home when
/// the app comes to the foreground, which is a weaker guarantee than the
/// platform-level disable. The user should know which one they have.
class _EnforcementPanel extends StatelessWidget {
  const _EnforcementPanel({required this.capabilities, required this.frozenCount});

  final FreezeCapabilities capabilities;
  final int frozenCount;

  @override
  Widget build(BuildContext context) {
    final controller = context.read<ChestController>();
    final hard = capabilities.hardFreezeAvailable;

    return ChestPanel(
      accent: hard ? ChestTheme.moss : ChestTheme.gold,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                hard ? Icons.verified_user : Icons.shield_outlined,
                size: 19,
                color: hard ? ChestTheme.moss : ChestTheme.gold,
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  hard ? 'Hard freeze active' : 'Soft freeze only',
                  style: TextStyle(
                    color: hard ? ChestTheme.moss : ChestTheme.gold,
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
            hard
                ? 'Frozen apps are disabled by Android itself, so they cannot be launched and stay disabled after a restart.'
                : 'Without device-admin rights Chest can only send you home when a frozen app tries to open. Grant device admin for a real, system-enforced freeze.',
            style: const TextStyle(color: ChestTheme.muted, fontSize: 12.5, height: 1.5),
          ),
          const SizedBox(height: 13),
          Wrap(
            spacing: 9,
            runSpacing: 9,
            children: [
              if (!capabilities.deviceAdminActive)
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
                  emphasised: !capabilities.deviceAdminActive,
                  onPressed: () async {
                    await controller.appLock.openAccessibilitySettings();
                  },
                ),
              if (capabilities.anyEnforcement)
                _PanelAction(
                  icon: Icons.refresh,
                  label: 'Re-check',
                  onPressed: controller.refreshCapabilities,
                ),
            ],
          ),
        ],
      ),
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
    required this.hardFreezeAvailable,
    required this.onToggle,
    required this.onOpenSettings,
  });

  final FreezableApp app;
  final bool hardFreezeAvailable;
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
