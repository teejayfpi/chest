import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/vault_models.dart';
import '../state/chest_controller.dart';
import '../theme/chest_theme.dart';
import '../widgets/chest_widgets.dart';
import '../widgets/protected_release_gate.dart';

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

  /// Freezes [app] immediately, or routes a release through the two-factor gate.
  ///
  /// Freezing is deliberately not gated: it only adds protection. Releasing is
  /// gated because it puts the app back in the launcher.
  Future<void> _toggle(FreezableApp app) async {
    if (app.frozen) {
      await _release(app);
      return;
    }
    await _freeze(app);
  }

  Future<void> _freeze(FreezableApp app) async {
    final controller = context.read<ChestController>();
    final messenger = ScaffoldMessenger.of(context);
    final result = await controller.freezeApp(app);

    final String message;
    if (result.isHard) {
      message = '${app.label} hidden from your launcher.';
    } else if (result.isGuarded) {
      message = '${app.label} is frozen. It stays in your launcher but cannot be opened.';
    } else if (result.method == 'protected') {
      message = '${app.label} is protected and cannot be frozen.';
    } else if (result.isUnenforced) {
      message = '${app.label} could not be frozen. Turn on the app guard first.';
    } else {
      message = '${app.label} could not be frozen.';
    }
    messenger.showSnackBar(SnackBar(content: Text(message)));
  }

  /// Asks for the two factors, then releases only if they both pass.
  Future<void> _release(FreezableApp app) async {
    final controller = context.read<ChestController>();
    final messenger = ScaffoldMessenger.of(context);

    final authorization = await ProtectedReleaseGate.show(
      context,
      actionLabel: 'release ${app.label}',
      detail: 'You are about to put ${app.label} back in your launcher. '
          'Anyone holding this phone could then open it.',
    );

    // A null token means the user cancelled or failed the gate. Nothing is
    // released, and no channel call is made.
    if (authorization == null) return;

    final result = await controller.releaseApp(app, authorization: authorization);
    if (result == null) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Release refused: the confirmation expired.')),
      );
      return;
    }
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          result.applied
              ? '${app.label} is back in the launcher.'
              : '${app.label} released from the freeze list.',
        ),
      ),
    );
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
    final guardOn = capabilities.accessibilityEnabled;

    // The phone-only tier is the primary path, so the panel leads with it and
    // reports it as active on its own terms. Device owner is presented as the
    // stronger upgrade, not as the thing standing between the user and a
    // working freeze.
    final (Color accent, IconData icon, String title, String body) = switch ((
      canHide,
      guardOn,
    )) {
      (true, _) => (
          ChestTheme.moss,
          Icons.visibility_off,
          'Launcher hiding active',
          'Frozen apps are removed from your launcher and cannot be started. Their data is kept, '
              'and they return the moment you release them.',
        ),
      (false, true) => (
          ChestTheme.moss,
          Icons.shield_moon_outlined,
          'App guard active',
          'Frozen apps stay in your launcher but cannot be opened: the app guard covers them and '
              'returns you home the instant they start. Their data is untouched.',
        ),
      (false, false) => (
          ChestTheme.gold,
          Icons.shield_outlined,
          'App guard is off',
          'Turn on the app guard to freeze apps. It is a one-time switch in Android Settings, on '
              'this phone, with nothing to install and no computer needed.',
        ),
    };

    return ChestPanel(
      accent: accent,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 19, color: accent),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    color: accent,
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
            body,
            style: const TextStyle(color: ChestTheme.muted, fontSize: 12.5, height: 1.5),
          ),
          if (!guardOn) ...[
            const SizedBox(height: 13),
            _GuardSteps(),
          ],
          if (capabilities.profileOwnerOnly) ...[
            const SizedBox(height: 13),
            const _Note(
              icon: Icons.info_outline,
              text: 'Chest manages a work profile on this device. That lets it hide work apps, '
                  'but not the personal apps in your main launcher. Personal apps are still '
                  'frozen by the app guard.',
            ),
          ],
          const SizedBox(height: 13),
          Wrap(
            spacing: 9,
            runSpacing: 9,
            children: [
              if (!guardOn)
                _PanelAction(
                  icon: Icons.shield_moon_outlined,
                  label: 'Turn on app guard',
                  emphasised: true,
                  onPressed: () async {
                    await controller.appLock.openAccessibilitySettings();
                  },
                ),
              if (guardOn && !capabilities.notificationAccessEnabled)
                _PanelAction(
                  icon: Icons.notifications_off_outlined,
                  label: 'Hide notifications',
                  emphasised: false,
                  onPressed: () async {
                    await controller.appLock.openNotificationAccessSettings();
                  },
                ),
              _PanelAction(
                icon: Icons.refresh,
                label: 'Re-check',
                onPressed: controller.refreshCapabilities,
              ),
              if (frozenCount > 0)
                _PanelAction(
                  icon: Icons.lock_open,
                  label: 'Release all',
                  onPressed: () async {
                    final messenger = ScaffoldMessenger.of(context);
                    final authorization = await ProtectedReleaseGate.show(
                      context,
                      actionLabel: 'release every app',
                      detail: 'You are about to unfreeze all $frozenCount frozen '
                          '${frozenCount == 1 ? 'app' : 'apps'} at once.',
                    );
                    if (authorization == null) return;
                    final restored = await controller.releaseAll(
                      authorization: authorization,
                    );
                    if (restored == null) {
                      messenger.showSnackBar(
                        const SnackBar(
                          content: Text('Release refused: the confirmation expired.'),
                        ),
                      );
                      return;
                    }
                    messenger.showSnackBar(
                      SnackBar(
                        content: Text(
                          restored == 1
                              ? '1 app released.'
                              : '$restored apps released.',
                        ),
                      ),
                    );
                  },
                ),
            ],
          ),
          const SizedBox(height: 6),
          _StrongerTierNote(canHide: canHide),
        ],
      ),
    );
  }
}

/// The phone-only setup, spelled out as steps rather than a shell command.
///
/// This is the whole point of the tier: everything here happens on the device
/// the app is installed on, with no computer, no cable and no factory reset.
class _GuardSteps extends StatelessWidget {
  const _GuardSteps();

  @override
  Widget build(BuildContext context) {
    const steps = [
      'Open Android Settings.',
      'Go to Accessibility, then Downloaded apps.',
      'Choose Chest and turn on the app guard.',
      'Come back here and tap Re-check.',
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < steps.length; i++)
          Padding(
            padding: EdgeInsets.only(bottom: i == steps.length - 1 ? 0 : 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${i + 1}.',
                  style: const TextStyle(
                    color: ChestTheme.gold,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    steps[i],
                    style: const TextStyle(
                      color: ChestTheme.muted,
                      fontSize: 12,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Explains the device-owner upgrade without presenting it as required.
class _StrongerTierNote extends StatelessWidget {
  const _StrongerTierNote({required this.canHide});

  final bool canHide;

  @override
  Widget build(BuildContext context) {
    if (canHide) {
      return const _Note(
        icon: Icons.check_circle_outline,
        text: 'Chest is the device owner, so freezing removes an app from the launcher entirely. '
            'This is the strongest freeze Android offers.',
      );
    }
    return const _Note(
      icon: Icons.upgrade_outlined,
      text: 'To also remove a frozen app from the launcher, Chest would need to be provisioned as '
          'device owner. Android only allows that at device setup, from a computer or a QR code, '
          'and usually after a factory reset. The app guard freezes without any of that.',
    );
  }
}

/// A small icon-and-text note.
class _Note extends StatelessWidget {
  const _Note({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 14, color: ChestTheme.muted),
        const SizedBox(width: 7),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(color: ChestTheme.muted, fontSize: 11.5, height: 1.45),
          ),
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
